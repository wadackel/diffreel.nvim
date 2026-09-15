use crate::model::Result;
use crate::repository::{drain, nonblocking};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
    mpsc,
};
use std::time::{Duration, Instant};

const PREFIX: &str = "refs/diffreel/pr/";

pub struct CacheLock(File);

impl CacheLock {
    fn acquire(common: &Path, exclusive: bool) -> Result<Self> {
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(common.join("diffreel-pr.lock"))?;
        let operation = if exclusive {
            libc::LOCK_EX
        } else {
            libc::LOCK_SH
        };
        if unsafe { libc::flock(file.as_raw_fd(), operation | libc::LOCK_NB) } != 0 {
            return Err("PR cache is in use; close PR views in all editors and retry".into());
        }
        Ok(Self(file))
    }
}

struct Runner<'a> {
    root: &'a Path,
    stop: Arc<AtomicBool>,
    deadline: Instant,
    lock: Option<&'a CacheLock>,
}

impl<'a> Runner<'a> {
    fn new(root: &'a Path, stop: Arc<AtomicBool>, lock: Option<&'a CacheLock>) -> Self {
        Self {
            root,
            stop,
            deadline: Instant::now() + Duration::from_secs(120),
            lock,
        }
    }

    fn run(&self, program: &str, args: &[String], input: Option<&[u8]>) -> Result<Vec<u8>> {
        if self.stop.load(Ordering::Relaxed)
            || crate::STOP.load(Ordering::Relaxed)
            || Instant::now() >= self.deadline
        {
            return Err("PR operation cancelled or timed out".into());
        }
        let mut command = Command::new(program);
        command
            .args(args)
            .current_dir(self.root)
            .process_group(0)
            .stdin(if input.is_some() {
                Stdio::piped()
            } else {
                Stdio::null()
            })
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .env("GH_PROMPT_DISABLED", "1")
            .env("GH_NO_UPDATE_NOTIFIER", "1")
            .env("GH_NO_EXTENSION_UPDATE_NOTIFIER", "1")
            .env("GIT_TERMINAL_PROMPT", "0")
            .env("GCM_INTERACTIVE", "Never");
        for name in [
            "GH_REPO",
            "GH_DEBUG",
            "DEBUG",
            "GIT_DIR",
            "GIT_WORK_TREE",
            "GIT_COMMON_DIR",
            "GIT_INDEX_FILE",
            "GIT_OBJECT_DIRECTORY",
            "GIT_ALTERNATE_OBJECT_DIRECTORIES",
            "GIT_TRACE",
            "GIT_TRACE_PACKET",
            "GIT_TRACE_CURL",
            "GIT_CURL_VERBOSE",
            "GIT_TRACE_SETUP",
        ] {
            command.env_remove(name);
        }
        if let Some(lock) = self.lock {
            let fd = lock.0.as_raw_fd();
            // A killed supervisor cannot unlock a cache while its Git descendants still write refs.
            unsafe {
                command.pre_exec(move || {
                    let flags = libc::fcntl(fd, libc::F_GETFD);
                    if flags < 0 || libc::fcntl(fd, libc::F_SETFD, flags & !libc::FD_CLOEXEC) < 0 {
                        return Err(std::io::Error::last_os_error());
                    }
                    Ok(())
                });
            }
        }
        let mut child = command.spawn().map_err(|_| {
            format!("Cannot execute {program}; PR review requires Git and an authenticated gh")
        })?;
        let result = (|| -> Result<_> {
            let mut stdout = child.stdout.take().ok_or("Missing PR stdout")?;
            let mut stderr = child.stderr.take().ok_or("Missing PR stderr")?;
            let mut stdin = child.stdin.take();
            nonblocking(&stdout)?;
            nonblocking(&stderr)?;
            if let Some(pipe) = &stdin {
                nonblocking(pipe)?;
            }
            let (mut out, mut err) = (Vec::new(), Vec::new());
            let (mut out_end, mut err_end, mut written) = (false, false, 0);
            loop {
                if self.stop.load(Ordering::Relaxed)
                    || crate::STOP.load(Ordering::Relaxed)
                    || Instant::now() >= self.deadline
                {
                    return Err("PR operation cancelled or timed out after 120 seconds".into());
                }
                drain(&mut stdout, &mut out, &mut out_end, 8 * 1024 * 1024)?;
                drain(&mut stderr, &mut err, &mut err_end, 1024 * 1024)?;
                if let (Some(pipe), Some(bytes)) = (&mut stdin, input) {
                    match pipe.write(&bytes[written..]) {
                        Ok(count) => written += count,
                        Err(error)
                            if matches!(
                                error.kind(),
                                std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted
                            ) => {}
                        Err(error) => return Err(error.into()),
                    }
                    if written == bytes.len() {
                        stdin = None;
                    }
                }
                if out_end && err_end && stdin.is_none() {
                    if let Some(status) = child.try_wait()? {
                        if !status.success() {
                            return Err(format!("{program} failed during PR acquisition (exit {}); check gh authentication, repository access and commit availability", status.code().unwrap_or(-1)).into());
                        }
                        return Ok(out);
                    }
                }
                std::thread::sleep(Duration::from_millis(2));
            }
        })();
        if result.is_err() {
            unsafe {
                libc::kill(-(child.id() as i32), libc::SIGKILL);
            }
            let _ = child.wait();
        }
        result
    }

    fn git(&self, args: &[&str], input: Option<&[u8]>) -> Result<String> {
        let mut command = vec![
            "--no-optional-locks".into(),
            "-c".into(),
            "core.hooksPath=/dev/null".into(),
        ];
        command.extend(args.iter().map(|s| (*s).to_owned()));
        Ok(String::from_utf8(self.run("git", &command, input)?)?
            .trim()
            .to_owned())
    }

    fn gh(&self, args: &[&str]) -> Result<Value> {
        let bytes = self.run(
            "gh",
            &args.iter().map(|s| (*s).into()).collect::<Vec<_>>(),
            None,
        )?;
        Ok(serde_json::from_slice(&bytes).map_err(|_| "GitHub returned invalid JSON")?)
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct Target {
    pub host: String,
    pub owner: String,
    pub repo: String,
    pub number: u64,
}

fn component(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 255
        && s != "."
        && s != ".."
        && s.bytes()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'-' | b'_' | b'.'))
}

fn repository_url(url: &str) -> Option<(String, String, String)> {
    let url = url
        .strip_prefix("https://")
        .or_else(|| url.strip_prefix("http://"))
        .or_else(|| url.strip_prefix("ssh://git@"))?;
    let parts = url.trim_end_matches('/').split('/').collect::<Vec<_>>();
    if parts.len() != 3 {
        return None;
    }
    let name = parts[2].strip_suffix(".git").unwrap_or(parts[2]);
    if !parts.iter().all(|s| component(s)) || !component(name) {
        return None;
    }
    Some((
        parts[0].to_ascii_lowercase(),
        parts[1].to_ascii_lowercase(),
        name.to_ascii_lowercase(),
    ))
}

impl Target {
    fn from_url(url: &str) -> Result<Self> {
        let url = url.split(['?', '#']).next().unwrap_or(url);
        let parts = url
            .strip_prefix("https://")
            .ok_or("PR URL must use HTTPS")?
            .trim_end_matches('/')
            .split('/')
            .collect::<Vec<_>>();
        if parts.len() < 5
            || parts.len() > 6
            || parts[3] != "pull"
            || (parts.len() == 6 && !["files", "commits", "checks"].contains(&parts[5]))
        {
            return Err("Expected a GitHub pull request URL".into());
        }
        let number = parts[4].parse::<u64>().map_err(|_| "Invalid PR number")?;
        if number == 0 || !parts[..3].iter().all(|s| component(s)) {
            return Err("Invalid PR URL".into());
        }
        Ok(Self {
            host: parts[0].to_ascii_lowercase(),
            owner: parts[1].to_ascii_lowercase(),
            repo: parts[2].to_ascii_lowercase(),
            number,
        })
    }

    fn repository(&self) -> String {
        format!("{}/{}/{}", self.host, self.owner, self.repo)
    }
    fn url(&self) -> String {
        format!("https://{}/{}/{}", self.host, self.owner, self.repo)
    }
    fn cache(&self) -> String {
        let hash: String = Sha256::digest(self.repository())
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect();
        format!("{PREFIX}cache/{hash}/{}", self.number)
    }
}

fn text<'a>(value: &'a Value, name: &str) -> Result<&'a str> {
    value
        .get(name)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("Missing PR field: {name}").into())
}

fn oid(value: &str) -> Result<String> {
    if !matches!(value.len(), 40 | 64) || !value.bytes().all(|c| c.is_ascii_hexdigit()) {
        return Err("Invalid PR commit SHA".into());
    }
    Ok(value.to_ascii_lowercase())
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Snapshot {
    #[serde(flatten)]
    pub target: Target,
    pub base: String,
    pub head: String,
    pub merge_base: String,
    pub title: String,
    pub url: String,
    pub state: String,
}

fn metadata(runner: &Runner, target: &Target) -> Result<Snapshot> {
    let endpoint = format!(
        "repos/{}/{}/pulls/{}",
        target.owner, target.repo, target.number
    );
    let value = runner.gh(&["api", "--hostname", &target.host, &endpoint])?;
    let actual = Target::from_url(text(&value, "html_url")?)?;
    if &actual != target || value.get("number").and_then(Value::as_u64) != Some(target.number) {
        return Err("GitHub returned a different PR".into());
    }
    let state = if value.get("merged").and_then(Value::as_bool) == Some(true) {
        "merged"
    } else if text(&value, "state")? == "closed" {
        "closed"
    } else if value.get("draft").and_then(Value::as_bool) == Some(true) {
        "draft"
    } else {
        "open"
    };
    Ok(Snapshot {
        target: target.clone(),
        base: oid(text(&value["base"], "sha")?)?,
        head: oid(text(&value["head"], "sha")?)?,
        merge_base: String::new(),
        title: text(&value, "title")?.into(),
        url: format!("{}/pull/{}", target.url(), target.number),
        state: state.into(),
    })
}

fn resolve_target(runner: &Runner, requested: &Value) -> Result<Target> {
    let string = requested
        .as_str()
        .map(str::to_owned)
        .or_else(|| requested.as_u64().map(|n| n.to_string()))
        .ok_or("PR must be a number or URL")?;
    let target = if string.bytes().all(|c| c.is_ascii_digit()) {
        let number = string.parse::<u64>().map_err(|_| "Invalid PR number")?;
        if number == 0 {
            return Err("PR number must be positive".into());
        }
        let repo = runner.gh(&["repo", "view", "--json", "url"])?;
        Target::from_url(&format!(
            "{}/pull/{number}",
            text(&repo, "url")?.trim_end_matches('/')
        ))?
    } else {
        Target::from_url(&string)?
    };
    let remotes = runner.git(&["remote"], None)?;
    for remote in remotes.lines() {
        let url = runner.git(&["remote", "get-url", remote], None)?;
        let normalized = url
            .strip_prefix("git@")
            .map(|s| format!("https://{}", s.replacen(':', "/", 1)))
            .unwrap_or(url);
        let Some((host, owner, repo)) = repository_url(&normalized) else {
            continue;
        };
        if host != target.host {
            continue;
        }
        if owner == target.owner && repo == target.repo {
            return Ok(target);
        }
        let endpoint = format!("repos/{owner}/{repo}");
        if let Ok(value) = runner.gh(&["api", "--hostname", &host, &endpoint]) {
            if value["parent"]["html_url"]
                .as_str()
                .and_then(repository_url)
                == Some((
                    target.host.clone(),
                    target.owner.clone(),
                    target.repo.clone(),
                ))
            {
                return Ok(target);
            }
        }
    }
    Err(
        "PR repository does not match a local remote or its fork parent; use the matching clone"
            .into(),
    )
}

fn references(runner: &Runner, prefix: &str) -> Result<Vec<(String, String)>> {
    let result = runner.git(
        &[
            "for-each-ref",
            "--format=%(refname) %(objectname) %(symref)",
            prefix,
        ],
        None,
    )?;
    let mut refs = Vec::new();
    for line in result.lines() {
        let fields = line.split_whitespace().collect::<Vec<_>>();
        if fields.len() != 2 || !fields[0].starts_with(prefix) {
            return Err("Unexpected symbolic PR cache ref; inspect it before clearing".into());
        }
        refs.push((fields[0].into(), oid(fields[1])?));
    }
    Ok(refs)
}

fn delete_refs(runner: &Runner, prefix: &str) -> Result<usize> {
    let refs = references(runner, prefix)?;
    if refs.is_empty() {
        return Ok(0);
    }
    let mut transaction = String::from("start\noption no-deref\n");
    for (name, value) in &refs {
        transaction.push_str(&format!("delete {name} {value}\n"));
    }
    transaction.push_str("prepare\ncommit\n");
    runner.git(&["update-ref", "--stdin"], Some(transaction.as_bytes()))?;
    Ok(refs.len())
}

fn publish(runner: &Runner, snapshot: &Snapshot) -> Result<()> {
    oid(&snapshot.base)?;
    oid(&snapshot.head)?;
    oid(&snapshot.merge_base)?;
    let prefix = format!(
        "{}/{}-{}",
        snapshot.target.cache(),
        snapshot.base,
        snapshot.head
    );
    let mut transaction = String::from("start\noption no-deref\n");
    for (side, value) in [
        ("base", &snapshot.base),
        ("head", &snapshot.head),
        ("merge-base", &snapshot.merge_base),
    ] {
        let name = format!("{prefix}/{side}");
        let found = references(runner, &name)?;
        if found.is_empty() {
            transaction.push_str(&format!("update {name} {value}\n"));
        } else if found.len() != 1 || found[0] != (name, value.clone()) {
            return Err("PR snapshot cache does not match its commit identity".into());
        }
    }
    transaction.push_str("prepare\ncommit\n");
    runner.git(&["update-ref", "--stdin"], Some(transaction.as_bytes()))?;
    Ok(())
}

fn prepare(runner: &Runner, requested: &Value, staging: &str) -> Result<Snapshot> {
    let target = resolve_target(runner, requested)?;
    for attempt in 0..2 {
        let mut snapshot = metadata(runner, &target)?;
        let url = format!("{}.git", target.url());
        let helper = format!(
            "credential.https://{}.helper=!gh auth git-credential",
            target.host
        );
        let base_ref = format!("{staging}/base");
        let head_ref = format!("{staging}/head");
        for (source, destination) in [
            (snapshot.base.clone(), &base_ref),
            (format!("refs/pull/{}/head", target.number), &head_ref),
        ] {
            let spec = format!("+{source}:{destination}");
            let flags = [
                "-c",
                "credential.helper=",
                "-c",
                &helper,
                // Bundle acquisition writes fetch.bundleCreationToken and refs/bundles outside this cache.
                "-c",
                "fetch.bundleURI=",
                "fetch",
                "--no-tags",
                "--no-prune",
                "--no-prune-tags",
                "--no-write-fetch-head",
                "--no-recurse-submodules",
                "--no-auto-maintenance",
                "--no-write-commit-graph",
                "--refmap=",
                "--",
                &url,
                &spec,
            ];
            if runner.git(&flags, None).is_err() {
                let expected = if destination == &base_ref {
                    &snapshot.base
                } else {
                    &snapshot.head
                };
                let fallback = format!("+{expected}:{destination}");
                let mut flags = flags;
                flags[flags.len() - 1] = &fallback;
                runner.git(&flags, None)?;
            }
        }
        let fetched = runner.git(
            &["rev-parse", "--verify", &format!("{head_ref}^{{commit}}")],
            None,
        )?;
        if fetched != snapshot.head {
            if attempt == 0 {
                continue;
            }
            return Err("PR changed during acquisition; refresh to retry".into());
        }
        let actual_base = runner.git(
            &["rev-parse", "--verify", &format!("{base_ref}^{{commit}}")],
            None,
        )?;
        if actual_base != snapshot.base {
            return Err("Fetched PR base does not match GitHub metadata".into());
        }
        snapshot.merge_base = runner.git(&["merge-base", "--all", &snapshot.base, &snapshot.head], None)
            .map_err(|_| "Cannot find the PR merge base; deepen a shallow clone manually or verify the historical commits")?;
        oid(&snapshot.merge_base).map_err(|_| "PR comparison requires a single merge base")?;
        publish(runner, &snapshot)?;
        return Ok(snapshot);
    }
    Err("PR acquisition failed".into())
}

pub fn worker(root: &Path) -> Result<()> {
    let mut input = BufReader::new(std::io::stdin());
    let mut line = String::new();
    input.by_ref().take(1048576).read_line(&mut line)?;
    let request: Value = serde_json::from_str(&line)?;
    let stop = Arc::new(AtomicBool::new(false));
    let disconnected = stop.clone();
    std::thread::spawn(move || {
        let mut byte = [0];
        let _ = input.read(&mut byte);
        disconnected.store(true, Ordering::Relaxed);
    });
    let repository = gix::discover(root)?;
    let common = repository.common_dir().canonicalize()?;
    let lock = CacheLock::acquire(&common, false)?;
    let runner = Runner::new(root, stop, Some(&lock));
    let job = text(&request, "job_id")?;
    if !component(job) {
        return Err("Invalid PR job identity".into());
    }
    let staging = format!("{PREFIX}staging/{job}");
    let result = prepare(&runner, &request["pr"], &staging);
    crate::STOP.store(false, Ordering::Relaxed);
    let mut cleanup = Runner::new(root, Arc::new(AtomicBool::new(false)), Some(&lock));
    cleanup.deadline = Instant::now() + Duration::from_secs(5);
    let _ = delete_refs(&cleanup, &staging);
    let response = match result {
        Ok(value) => json!({"result":value}),
        Err(error) => json!({"error":error.to_string()}),
    };
    println!("{response}");
    Ok(())
}

struct Job {
    view: String,
    request_id: Value,
    child: Child,
    input: Option<ChildStdin>,
    result: mpsc::Receiver<Value>,
    response: Option<Value>,
}

pub struct Jobs {
    root: PathBuf,
    common: PathBuf,
    session: String,
    sequence: u64,
    leases: BTreeMap<String, CacheLock>,
    jobs: BTreeMap<String, Job>,
}

impl Jobs {
    pub fn new(root: &Path, common: &Path, session: &str) -> Self {
        Self {
            root: root.into(),
            common: common.into(),
            session: session.into(),
            sequence: 0,
            leases: BTreeMap::new(),
            jobs: BTreeMap::new(),
        }
    }

    pub fn start(&mut self, params: &Value) -> Result<Value> {
        let view = text(params, "view_id")?.to_owned();
        if view.is_empty() || view.len() > 255 || view.contains('\0') {
            return Err("Invalid PR view identity".into());
        }
        let requested = params.get("pr").ok_or("Missing PR")?.clone();
        if requested.as_u64().is_none()
            && requested
                .as_str()
                .is_none_or(|s| s.is_empty() || s.len() > 2048)
        {
            return Err("PR must be a number or URL".into());
        }
        self.cancel_view(&view);
        if !self.leases.contains_key(&view) {
            self.leases
                .insert(view.clone(), CacheLock::acquire(&self.common, false)?);
        }
        self.sequence += 1;
        let job_id = format!("{}-{}", self.session, self.sequence);
        let mut child = Command::new(std::env::current_exe()?)
            .args(["--pr-worker", "--root"])
            .arg(&self.root)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        let mut input = child.stdin.take().ok_or("Missing worker control pipe")?;
        let request = json!({"job_id":job_id,"pr":requested});
        if let Err(error) = writeln!(input, "{request}") {
            drop(input);
            let _ = child.wait();
            return Err(error.into());
        }
        let output = child.stdout.take().ok_or("Missing worker output")?;
        let (send, receive) = mpsc::channel();
        std::thread::spawn(move || {
            let mut bytes = Vec::new();
            let result = output.take(8 * 1024 * 1024 + 1).read_to_end(&mut bytes);
            let value = result
                .ok()
                .and_then(|_| serde_json::from_slice::<Value>(&bytes).ok())
                .unwrap_or_else(|| json!({"error":"PR worker stopped unexpectedly"}));
            let _ = send.send(value);
        });
        self.jobs.insert(
            job_id.clone(),
            Job {
                view,
                request_id: params.get("request_id").cloned().unwrap_or(Value::Null),
                child,
                input: Some(input),
                result: receive,
                response: None,
            },
        );
        Ok(json!({"job_id":job_id}))
    }

    fn cancel_view(&mut self, view: &str) {
        for job in self.jobs.values_mut().filter(|job| job.view == view) {
            job.input = None;
        }
    }

    pub fn release(&mut self, view: &str) {
        self.cancel_view(view);
        self.leases.remove(view);
    }

    pub fn cancel(&mut self, params: &Value) -> Result<Value> {
        if let Some(job) = self.jobs.get_mut(text(params, "job_id")?) {
            job.input = None;
        }
        Ok(json!({}))
    }

    pub fn poll(&mut self) -> Vec<(String, Value)> {
        let mut ready = Vec::new();
        for (id, job) in &mut self.jobs {
            if job.response.is_none() {
                job.response = job.result.try_recv().ok();
            }
            if job.response.is_some() && matches!(job.child.try_wait(), Ok(Some(_))) {
                ready.push(id.clone());
            }
        }
        ready
            .into_iter()
            .filter_map(|id| {
                let job = self.jobs.remove(&id)?;
                if job.input.is_none() {
                    return None;
                }
                let mut response = job.response?;
                response["view_id"] = json!(job.view);
                response["job_id"] = json!(id);
                response["session_id"] = json!(self.session);
                response["request_id"] = job.request_id;
                Some((
                    if response.get("error").is_some() {
                        "pr/error"
                    } else {
                        "pr/prepared"
                    }
                    .into(),
                    response,
                ))
            })
            .collect()
    }

    pub fn restore(&mut self, params: &Value) -> Result<Value> {
        let view = text(params, "view_id")?.to_owned();
        let snapshot: Snapshot = serde_json::from_value(params["snapshot"].clone())?;
        let target = Target::from_url(&snapshot.url)?;
        if target != snapshot.target {
            return Err("Invalid saved PR identity".into());
        }
        let lock = CacheLock::acquire(&self.common, false)?;
        let mut runner = Runner::new(&self.root, Arc::new(AtomicBool::new(false)), Some(&lock));
        runner.deadline = Instant::now() + Duration::from_secs(5);
        for value in [&snapshot.base, &snapshot.head, &snapshot.merge_base] {
            oid(value)?;
            runner
                .git(&["cat-file", "-e", &format!("{value}^{{commit}}")], None)
                .map_err(
                    |_| "Saved PR commits are unavailable; reopen the PR to acquire it again",
                )?;
        }
        publish(&runner, &snapshot)?;
        self.leases.insert(view, lock);
        Ok(json!({}))
    }

    pub fn clear(&self) -> Result<Value> {
        let lock = CacheLock::acquire(&self.common, true)?;
        let mut runner = Runner::new(&self.root, Arc::new(AtomicBool::new(false)), Some(&lock));
        runner.deadline = Instant::now() + Duration::from_secs(10);
        Ok(json!({"removed_refs":delete_refs(&runner, PREFIX)?}))
    }
}

impl Drop for Jobs {
    fn drop(&mut self) {
        for job in self.jobs.values_mut() {
            job.input = None;
        }
        for job in self.jobs.values_mut() {
            let _ = job.child.wait();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn target_urls_preserve_valid_repository_names_and_reject_ambiguous_input() {
        for name in ["project", ".github", "_configuration", "project-name"] {
            let target = Target::from_url(&format!(
                "https://github.com/example/{name}/pull/12/files#diff-x"
            ))
            .unwrap();
            assert_eq!(target.repo, name);
            assert_eq!(target.number, 12);
        }
        for url in [
            "http://github.com/a/b/pull/1",
            "https://github.com/a/../pull/1",
            "https://user@github.com/a/b/pull/1",
            "https://github.com/a/b/pull/0",
            "https://github.com/a/b/pull/1/invalid",
            "https://github.com/a/b/pull/1\n",
        ] {
            assert!(Target::from_url(url).is_err(), "{url}");
        }
    }

    #[test]
    fn cache_locks_require_all_readers_to_finish() {
        let root = tempfile::tempdir().unwrap();
        let first = CacheLock::acquire(root.path(), false).unwrap();
        let second = CacheLock::acquire(root.path(), false).unwrap();
        assert!(CacheLock::acquire(root.path(), true).is_err());
        drop(first);
        assert!(CacheLock::acquire(root.path(), true).is_err());
        drop(second);
        let deadline = Instant::now() + Duration::from_secs(2);
        // Concurrent test forks briefly inherit CLOEXEC descriptors until their exec completes.
        while CacheLock::acquire(root.path(), true).is_err() {
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(1));
        }
    }

    #[test]
    fn runner_deadline_and_stderr_do_not_escape_the_job() {
        let root = tempfile::tempdir().unwrap();
        let mut runner = Runner::new(root.path(), Arc::new(AtomicBool::new(false)), None);
        runner.deadline = Instant::now() + Duration::from_millis(50);
        let started = Instant::now();
        assert!(
            runner
                .run("/bin/sh", &["-c".into(), "sleep 60".into()], None)
                .is_err()
        );
        assert!(started.elapsed() < Duration::from_secs(2));
        runner.deadline = Instant::now() + Duration::from_secs(5);
        let error = runner
            .run(
                "/bin/sh",
                &["-c".into(), "echo fixture-secret >&2; exit 1".into()],
                None,
            )
            .unwrap_err()
            .to_string();
        assert!(!error.contains("fixture-secret"));
    }
}
