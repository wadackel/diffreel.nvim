use crate::model::{self, Entry, Metadata, Result, Side};
use serde::Serialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File};
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};
use std::time::{Duration, Instant};

#[derive(Default, Serialize)]
pub struct Metrics {
    pub git_spawns: u64,
    pub git_wall_ms: f64,
    pub git_cpu_ms: f64,
    pub jobs: Vec<Value>,
    pub stats_files: u64,
}

#[derive(Clone)]
struct IndexEntry {
    mode: String,
    oid: String,
    conflict: bool,
}

#[derive(Clone)]
pub struct Comparison {
    pub id: String,
    pub left: String,
    pub right: String,
    pub paths: Vec<String>,
    pub untracked: bool,
    pub file: Option<String>,
    pub entries: BTreeMap<String, Entry>,
    pub generation: u64,
    pub dirty_epoch: u64,
    pub stale: bool,
    pub error: Option<String>,
    pub checked_at: Instant,
    pub last_used: Instant,
    index: Arc<BTreeMap<String, IndexEntry>>,
    stats: BTreeMap<String, Value>,
    stats_generation: u64,
}

impl Comparison {
    pub fn has_index(&self) -> bool {
        self.left == ":0" || self.right == ":0"
    }

    pub fn mutable(&self) -> bool {
        self.right == "worktree"
            || self.has_index()
            || self
                .paths
                .iter()
                .any(|path| path.starts_with(":(") && path.contains("attr:"))
    }
}

#[derive(Clone)]
pub struct View {
    pub comparison_id: String,
    pub visible: bool,
}

pub struct Repository {
    pub root: PathBuf,
    pub git_dir: PathBuf,
    pub common_dir: PathBuf,
    pub session_id: String,
    pub git: gix::Repository,
    pub head: Option<String>,
    pub comparisons: BTreeMap<String, Comparison>,
    pub views: BTreeMap<String, View>,
    pub notifications: Vec<(String, Value)>,
    pub metrics: Metrics,
    pub stopping: Arc<AtomicBool>,
    pub(crate) initialized: bool,
    max_bytes: usize,
    attributes: BTreeMap<String, BTreeMap<String, String>>,
    tracked: BTreeMap<String, char>,
    metadata: BTreeMap<String, Metadata>,
}

pub fn usage(who: i32) -> (f64, u64) {
    let mut value = std::mem::MaybeUninit::<libc::rusage>::zeroed();
    if unsafe { libc::getrusage(who, value.as_mut_ptr()) } != 0 {
        return (f64::NAN, 0);
    }
    let value = unsafe { value.assume_init() };
    let cpu_ms = (value.ru_utime.tv_sec + value.ru_stime.tv_sec) as f64 * 1000.0
        + (value.ru_utime.tv_usec + value.ru_stime.tv_usec) as f64 / 1000.0;
    let rss = value.ru_maxrss as u64 * if cfg!(target_os = "macos") { 1 } else { 1024 };
    (cpu_ms, rss)
}

fn parameter<'a>(params: &'a Value, name: &str) -> Result<&'a str> {
    params
        .get(name)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("Missing parameter: {name}").into())
}

pub(crate) fn nonblocking(pipe: &impl AsRawFd) -> std::io::Result<()> {
    let flags = unsafe { libc::fcntl(pipe.as_raw_fd(), libc::F_GETFL) };
    if flags < 0
        || unsafe { libc::fcntl(pipe.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0
    {
        return Err(std::io::Error::last_os_error());
    }
    Ok(())
}

pub(crate) fn drain(
    pipe: &mut impl Read,
    bytes: &mut Vec<u8>,
    eof: &mut bool,
    limit: usize,
) -> std::io::Result<()> {
    if *eof {
        return Ok(());
    }
    let mut buffer = [0; 65536];
    loop {
        match pipe.read(&mut buffer) {
            Ok(0) => {
                *eof = true;
                return Ok(());
            }
            Ok(count) => {
                bytes.extend_from_slice(&buffer[..count]);
                if bytes.len() > limit {
                    return Err(std::io::Error::other("Git output exceeds limit"));
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => return Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
}

impl Repository {
    pub fn new(root: &Path, max_bytes: usize) -> Result<Self> {
        let mut git = gix::discover(root)?;
        git.object_cache_size(Some(67108864));
        let root = git
            .workdir()
            .ok_or("Bare repositories are not supported")?
            .canonicalize()?;
        let git_dir = git.git_dir().canonicalize()?;
        let common_dir = git.common_dir().canonicalize()?;
        Ok(Self {
            root,
            git_dir,
            common_dir,
            git,
            session_id: format!(
                "rust-{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)?
                    .as_nanos()
            ),
            head: None,
            comparisons: BTreeMap::new(),
            views: BTreeMap::new(),
            notifications: Vec::new(),
            metrics: Metrics::default(),
            stopping: Arc::new(AtomicBool::new(false)),
            initialized: false,
            max_bytes,
            attributes: BTreeMap::new(),
            tracked: BTreeMap::new(),
            metadata: BTreeMap::new(),
        })
    }

    pub fn run_git(
        &mut self,
        args: &[String],
        reason: &str,
        stdin: Option<Vec<u8>>,
    ) -> Result<Vec<u8>> {
        self.run_git_paths(args, reason, stdin, true)
    }

    fn run_git_paths(
        &mut self,
        args: &[String],
        reason: &str,
        stdin: Option<Vec<u8>>,
        literal: bool,
    ) -> Result<Vec<u8>> {
        let (status, stdout, stderr) = self.git_process(args, reason, stdin, literal)?;
        if !status.success() {
            return Err(format!("Git failed: {}", String::from_utf8_lossy(&stderr).trim()).into());
        }
        Ok(stdout)
    }

    fn git_process(
        &mut self,
        args: &[String],
        reason: &str,
        stdin: Option<Vec<u8>>,
        literal: bool,
    ) -> Result<(std::process::ExitStatus, Vec<u8>, Vec<u8>)> {
        if self.stopping.load(Ordering::Relaxed) {
            return Err("Backend is stopping".into());
        }
        let started = Instant::now();
        let cpu = usage(libc::RUSAGE_CHILDREN).0;
        self.metrics.git_spawns += 1;
        let mut command = Command::new("git");
        command.arg("--no-optional-locks");
        if literal {
            command.arg("--literal-pathspecs");
        } else {
            for name in [
                "GIT_LITERAL_PATHSPECS",
                "GIT_GLOB_PATHSPECS",
                "GIT_NOGLOB_PATHSPECS",
                "GIT_ICASE_PATHSPECS",
            ] {
                command.env_remove(name);
            }
        }
        let mut child = command
            .args(args)
            .current_dir(&self.root)
            .process_group(0)
            .stdin(if stdin.is_some() {
                Stdio::piped()
            } else {
                Stdio::null()
            })
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;
        let collected = (|| -> Result<_> {
            let mut stdout = child.stdout.take().ok_or("Missing Git stdout")?;
            let mut stderr = child.stderr.take().ok_or("Missing Git stderr")?;
            let mut input = child.stdin.take();
            nonblocking(&stdout)?;
            nonblocking(&stderr)?;
            if let Some(pipe) = &input {
                nonblocking(pipe)?;
            }
            let (mut out, mut err) = (Vec::new(), Vec::new());
            let (mut out_eof, mut err_eof, mut written) = (false, false, 0);
            loop {
                if self.stopping.load(Ordering::Relaxed)
                    || crate::STOP.load(Ordering::Relaxed)
                    || started.elapsed() > Duration::from_secs(30)
                {
                    return Err("Git timed out or backend stopped".into());
                }
                drain(&mut stdout, &mut out, &mut out_eof, 67108864)?;
                drain(&mut stderr, &mut err, &mut err_eof, 1048576)?;
                if let (Some(pipe), Some(bytes)) = (&mut input, &stdin) {
                    match pipe.write(&bytes[written..]) {
                        Ok(count) => written += count,
                        Err(error)
                            if matches!(
                                error.kind(),
                                std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted
                            ) => {}
                        Err(error) if error.kind() == std::io::ErrorKind::BrokenPipe => {
                            written = bytes.len()
                        }
                        Err(error) => return Err(error.into()),
                    }
                    if written == bytes.len() {
                        input = None;
                    }
                }
                // Reaping the leader before inherited pipes close can release its process-group ID.
                if out_eof && err_eof && input.is_none() {
                    if let Some(status) = child.try_wait()? {
                        return Ok((status, out, err));
                    }
                }
                std::thread::sleep(Duration::from_millis(1));
            }
        })();
        if collected.is_err() {
            unsafe {
                libc::kill(-(child.id() as i32), libc::SIGKILL);
            }
            let _ = child.wait();
        }
        let (status, stdout, stderr) = collected?;
        let wall_ms = started.elapsed().as_secs_f64() * 1000.0;
        let cpu_ms = usage(libc::RUSAGE_CHILDREN).0 - cpu;
        self.metrics.git_wall_ms += wall_ms;
        self.metrics.git_cpu_ms += cpu_ms;
        self.metrics.jobs.push(json!({"args":args,"reason":reason,"wall_ms":wall_ms,"cpu_ms":cpu_ms,"code":status.code()}));
        if self.metrics.jobs.len() > 1000 {
            self.metrics.jobs.remove(0);
        }
        Ok((status, stdout, stderr))
    }

    pub fn ignored(&mut self, paths: &BTreeSet<String>) -> Result<BTreeSet<String>> {
        let candidates = {
            let tree = match &self.head {
                Some(head) => Some(
                    self.git
                        .find_object(gix::hash::ObjectId::from_hex(head.as_bytes())?)?
                        .peel_to_tree()?,
                ),
                None => None,
            };
            let compared = self
                .comparisons
                .values()
                .flat_map(|comparison| &comparison.entries)
                .flat_map(|(path, entry)| [Some(path.as_str()), entry.old_path.as_deref()])
                .flatten()
                .collect::<BTreeSet<_>>();
            let mut candidates = Vec::new();
            'paths: for path in paths {
                // check-ignore reads its input as pathspecs and rejects literal magic.
                if !model::safe_path(path)
                    || path.starts_with(':')
                    || self.metadata.contains_key(path)
                    || compared.contains(path.as_str())
                {
                    continue;
                }
                if let Some(tree) = &tree {
                    let mut prefix = path.as_str();
                    loop {
                        if let Some(entry) = tree.lookup_entry_by_path(prefix)? {
                            if prefix == path || entry.mode().is_commit() {
                                continue 'paths;
                            }
                        }
                        match prefix.rsplit_once('/') {
                            Some((parent, _)) => prefix = parent,
                            None => break,
                        }
                    }
                }
                candidates.push(path.clone());
            }
            candidates
        };
        if candidates.is_empty() {
            return Ok(BTreeSet::new());
        }
        // The index lookup costs one full index scan per path; tracked paths are excluded above.
        let args = ["check-ignore", "--no-index", "-z", "--stdin"]
            .into_iter()
            .map(str::to_owned)
            .collect::<Vec<_>>();
        let input = (candidates.join("\0") + "\0").into_bytes();
        let (status, stdout, stderr) = self.git_process(&args, "ignore", Some(input), false)?;
        if !status.success() && status.code() != Some(1) {
            return Err(format!("Git failed: {}", String::from_utf8_lossy(&stderr).trim()).into());
        }
        Ok(model::names(&stdout)?.into_iter().collect())
    }

    fn command(&mut self, args: &[&str], reason: &str) -> Result<Vec<u8>> {
        self.run_git(
            &args.iter().map(|arg| (*arg).into()).collect::<Vec<_>>(),
            reason,
            None,
        )
    }

    fn head_value(&self) -> Value {
        self.head.as_ref().map_or(json!(false), |head| json!(head))
    }

    fn set_head(&mut self, head: Option<String>) {
        if self.initialized && self.head != head {
            self.notifications.push(("repo/changed".into(), json!({
                "session_id":self.session_id,"scope":"head","head":head.as_ref().map_or(json!(false), |head| json!(head))
            })));
        }
        self.head = head;
    }

    fn status(&mut self, reason: &str, paths: Option<&[String]>) -> Result<()> {
        let mut args = [
            "status",
            "--porcelain=v2",
            "-z",
            "-uall",
            "--no-renames",
            "--branch",
            "--no-ahead-behind",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect::<Vec<_>>();
        if let Some(paths) = paths {
            args.push("--".into());
            args.extend_from_slice(paths);
        }
        let value = model::parse_status(&self.run_git(&args, reason, None)?)?;
        self.set_head(value.head);
        if let Some(paths) = paths {
            for path in paths {
                self.metadata.remove(path);
                if let Some(entry) = value.entries.get(path) {
                    self.metadata.insert(path.clone(), entry.clone());
                }
            }
        } else {
            self.metadata = value.entries;
        }
        Ok(())
    }

    fn resolve(&mut self, revision: &str) -> Result<String> {
        if revision.is_empty() || revision == ":0" {
            return Ok(revision.into());
        }
        if revision == "HEAD" {
            let head = self.git.head()?.id().map(|id| id.to_string());
            self.set_head(head.clone());
            return Ok(head.unwrap_or_default());
        }
        if revision.contains('\0') {
            return Err("Invalid revision".into());
        }
        let spec = format!("{revision}^{{commit}}");
        if (revision.len() == 40 || revision.len() == 64)
            && revision.bytes().all(|byte| byte.is_ascii_hexdigit())
        {
            let oid = gix::hash::ObjectId::from_hex(revision.as_bytes())?;
            let kind = self.git.find_header(oid)?.kind();
            if kind != gix::objs::Kind::Commit && kind != gix::objs::Kind::Tag {
                return Err("Invalid commit OID".into());
            }
            return Ok(self
                .git
                .find_object(oid)?
                .peel_to_commit()?
                .id()
                .to_string());
        }
        Ok(String::from_utf8(self.command(
            &["rev-parse", "--verify", "--end-of-options", &spec],
            "resolve",
        )?)?
        .trim()
        .into())
    }

    pub fn tree_entry(&self, revision: &str, path: &str) -> Result<Option<(String, String)>> {
        if revision.is_empty() {
            return Ok(None);
        }
        let oid = gix::hash::ObjectId::from_hex(revision.as_bytes())?;
        let tree = self.git.find_object(oid)?.peel_to_tree()?;
        Ok(tree.lookup_entry_by_path(path)?.map(|entry| {
            (
                format!("{:06o}", entry.mode().value()),
                entry.object_id().to_string(),
            )
        }))
    }

    pub fn blob(&self, oid: &str, mode: &str) -> Result<Side> {
        let oid = gix::hash::ObjectId::from_hex(oid.as_bytes())?;
        let header = self.git.find_header(oid)?;
        if header.kind() != gix::objs::Kind::Blob {
            return Err("Object is not a blob".into());
        }
        if header.size() > self.max_bytes as u64 {
            return Ok(Side::limited("too-large", mode, header.size()));
        }
        Ok(Side::decode(
            &self.git.find_blob(oid)?.data,
            mode,
            self.max_bytes,
        ))
    }

    fn revision_side(&self, revision: &str, path: &str) -> Result<Side> {
        let Some((mode, oid)) = self.tree_entry(revision, path)? else {
            return Ok(Side::missing());
        };
        let mut side = if mode == "160000" {
            Side::limited("submodule", &mode, 0)
        } else if mode == "040000" {
            Side::limited("directory", &mode, 0)
        } else {
            self.blob(&oid, &mode)?
        };
        side.oid = Some(oid);
        Ok(side)
    }

    fn read_index(&mut self, reason: &str) -> Result<Arc<BTreeMap<String, IndexEntry>>> {
        let records = model::names(&self.command(&["ls-files", "--stage", "-z"], reason)?)?;
        let mut index: BTreeMap<String, IndexEntry> = BTreeMap::new();
        for record in records {
            let (header, path) = record.split_once('\t').ok_or("Malformed index entry")?;
            let fields = header.split(' ').collect::<Vec<_>>();
            if fields.len() != 3
                || !model::safe_path(path)
                || !matches!(fields[2], "0" | "1" | "2" | "3")
            {
                return Err("Unsupported index entry".into());
            }
            // Stage zero also uses the empty-blob OID for intent-to-add entries.
            if self
                .metadata
                .get(path)
                .is_some_and(|meta| meta.intent_to_add)
            {
                continue;
            }
            let entry = index.entry(path.into()).or_insert_with(|| IndexEntry {
                mode: fields[0].into(),
                oid: fields[1].into(),
                conflict: false,
            });
            entry.conflict |= fields[2] != "0";
        }
        Ok(Arc::new(index))
    }

    fn endpoint_side(&self, comparison: &Comparison, revision: &str, path: &str) -> Result<Side> {
        if revision != ":0" {
            return self.revision_side(revision, path);
        }
        let Some(entry) = comparison.index.get(path) else {
            return Ok(Side::missing());
        };
        if entry.conflict {
            return Ok(Side::limited("conflict", &entry.mode, 0));
        }
        let mut side = if entry.mode == "160000" {
            Side::limited("submodule", &entry.mode, 0)
        } else if entry.mode == "040000" {
            Side::limited("sparse-checkout", &entry.mode, 0)
        } else {
            self.blob(&entry.oid, &entry.mode)?
        };
        side.oid = Some(entry.oid.clone());
        Ok(side)
    }

    fn attributes_for(&mut self, paths: &[String], reason: &str) -> Result<()> {
        let needed = paths
            .iter()
            .filter(|path| !self.attributes.contains_key(*path))
            .cloned()
            .collect::<Vec<_>>();
        if needed.is_empty() {
            return Ok(());
        }
        let args = [
            "check-attr",
            "-z",
            "--stdin",
            "filter",
            "working-tree-encoding",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect::<Vec<_>>();
        let input = (needed.join("\0") + "\0").into_bytes();
        let raw = self.run_git(&args, reason, Some(input))?;
        let records = model::names(&raw)?;
        if records.len() % 3 != 0 {
            return Err("Malformed Git attributes".into());
        }
        for item in records.chunks_exact(3) {
            self.attributes
                .entry(item[0].clone())
                .or_default()
                .insert(item[1].clone(), item[2].clone());
        }
        let mut args = vec!["ls-files".into(), "-t".into(), "-z".into(), "--".into()];
        args.extend(needed.iter().cloned());
        let records = model::names(&self.run_git(&args, reason, None)?)?;
        for path in &needed {
            self.tracked.remove(path);
        }
        for record in records {
            if record.len() < 3 {
                return Err("Malformed tracked path".into());
            }
            self.tracked
                .insert(record[2..].into(), record.as_bytes()[0] as char);
        }
        Ok(())
    }

    fn disk_side(&self, path: &str, include_ignored: bool) -> Result<Side> {
        let meta = self.metadata.get(path).cloned().unwrap_or_default();
        if meta.conflict {
            return Ok(Side::limited("conflict", "100644", 0));
        }
        if meta.submodule {
            return Ok(Side::limited("submodule", "160000", 0));
        }
        if self.tracked.get(path) == Some(&'S') {
            return Ok(Side::limited("sparse-checkout", "100644", 0));
        }
        if !include_ignored && !self.tracked.contains_key(path) && !meta.untracked {
            return Ok(Side::missing());
        }
        if let Some(attributes) = self.attributes.get(path) {
            for (key, value) in attributes {
                if value != "unspecified" && value != "unset" {
                    return Ok(Side::limited(key, "100644", 0));
                }
            }
        }
        let full = self.root.join(path);
        let parent = full.parent().ok_or("Missing parent")?;
        match parent.canonicalize() {
            Ok(resolved) if resolved != parent => {
                return Ok(Side::limited("symlink-parent", "100644", 0));
            }
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::NotFound | std::io::ErrorKind::NotADirectory
                ) =>
            {
                return Ok(Side::missing());
            }
            Err(e) => return Err(e.into()),
            _ => {}
        }
        let stat = match fs::symlink_metadata(&full) {
            Ok(stat) => stat,
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::NotFound | std::io::ErrorKind::NotADirectory
                ) =>
            {
                return Ok(Side::missing());
            }
            Err(e) => return Err(e.into()),
        };
        if stat.file_type().is_symlink() {
            use std::os::unix::ffi::OsStrExt;
            return Ok(Side::decode(
                fs::read_link(&full)?.as_os_str().as_bytes(),
                "120000",
                self.max_bytes,
            ));
        }
        if !stat.is_file() {
            return Ok(Side::limited("directory", "040000", stat.len()));
        }
        let mode = if stat.mode() & 0o111 != 0 {
            "100755"
        } else {
            "100644"
        };
        if stat.len() > self.max_bytes as u64 {
            return Ok(Side::limited("too-large", mode, stat.len()));
        }
        let file = match File::options()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(full)
        {
            Ok(file) => file,
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::NotFound | std::io::ErrorKind::NotADirectory
                ) =>
            {
                return Ok(Side::missing());
            }
            Err(e) => return Err(e.into()),
        };
        let opened = file.metadata()?;
        if opened.ino() != stat.ino() || opened.dev() != stat.dev() || !opened.is_file() {
            return Err("File replaced during read".into());
        }
        let mut data = Vec::new();
        file.take((self.max_bytes + 1) as u64)
            .read_to_end(&mut data)?;
        Ok(Side::decode(&data, mode, self.max_bytes))
    }

    pub fn snapshot(&self, id: &str) -> Result<Value> {
        let c = self.comparisons.get(id).ok_or("Unknown comparison")?;
        let mut result = json!({
            "session_id":self.session_id,"comparison_id":c.id,"left":c.left,"right":c.right,
            "generation":c.generation,"entries":c.entries.values().collect::<Vec<_>>(),
            "updating":c.stale,"scope":"all"
        });
        if let Some(error) = &c.error {
            result["error"] = json!(error);
        }
        Ok(result)
    }

    fn file(&self, comparison: &Comparison, path: &str, include_ignored: bool) -> Result<Entry> {
        let left = self.endpoint_side(comparison, &comparison.left, path)?;
        let worktree = comparison.right == "worktree";
        let right = if worktree {
            self.disk_side(path, include_ignored)?
        } else {
            self.endpoint_side(comparison, &comparison.right, path)?
        };
        let status = if left.kind == "limited" || right.kind == "limited" {
            "limited"
        } else if !left.exists {
            "added"
        } else if !right.exists {
            "deleted"
        } else if left.kind != right.kind {
            "typechange"
        } else if left.content_id == right.content_id {
            "metadata"
        } else {
            "modified"
        };
        Ok(Entry {
            path: path.into(),
            status: status.into(),
            left: left.metadata(),
            right: right.metadata(),
            old_path: None,
            git: if worktree {
                self.metadata.get(path).cloned()
            } else {
                None
            },
        })
    }

    pub fn refresh(&mut self, id: &str, reason: &str, paths: Option<&[String]>) -> Result<Value> {
        let mut c = self
            .comparisons
            .get(id)
            .ok_or("Unknown comparison")?
            .clone();
        let paths = paths.filter(|_| {
            c.right == "worktree" && !c.has_index() && c.paths.is_empty() && c.file.is_none()
        });
        if c.right == "worktree" || c.has_index() {
            self.status(reason, paths)?;
            if paths.is_none() && c.right == "worktree" {
                self.attributes.clear();
                self.tracked.clear();
            }
        }
        if c.has_index() {
            c.index = self.read_index(reason)?;
        }
        let mut candidates = BTreeSet::new();
        let mut rows = Vec::new();
        if let Some(path) = &c.file {
            candidates.insert(path.clone());
        } else {
            if c.left != ":0" || c.right != ":0" {
                let mut args = [
                    "diff",
                    "--raw",
                    "-z",
                    "--no-abbrev",
                    "--no-ext-diff",
                    "--no-textconv",
                    if paths.is_some() {
                        "--no-renames"
                    } else {
                        "-M"
                    },
                ]
                .into_iter()
                .map(str::to_owned)
                .collect::<Vec<_>>();
                let empty_tree = self.git.object_hash().empty_tree().to_string();
                let left = if c.left.is_empty() {
                    &empty_tree
                } else {
                    &c.left
                };
                let right = if c.right.is_empty() {
                    &empty_tree
                } else {
                    &c.right
                };
                if c.right == ":0" {
                    args.extend(["--cached".into(), left.clone()]);
                } else if c.left == ":0" {
                    if c.right != "worktree" {
                        args.extend(["--cached".into(), "-R".into(), right.clone()]);
                    }
                } else {
                    args.push(left.clone());
                    if c.right != "worktree" {
                        args.push(right.clone());
                    }
                }
                args.push("--".into());
                if let Some(paths) = paths {
                    args.extend_from_slice(paths);
                } else {
                    args.extend_from_slice(&c.paths);
                }
                rows = model::parse_raw(&self.run_git_paths(
                    &args,
                    reason,
                    None,
                    paths.is_some() || c.paths.is_empty(),
                )?)?;
                for row in &rows {
                    candidates.insert(row.path.clone());
                    candidates.insert(row.old_path.clone());
                }
            }
            if c.right == "worktree" && c.untracked {
                if c.paths.is_empty() {
                    for (path, meta) in &self.metadata {
                        if meta.untracked {
                            candidates.insert(path.clone());
                        }
                    }
                } else if self.metadata.values().any(|meta| meta.untracked) {
                    let mut args = vec![
                        "ls-files".into(),
                        "--others".into(),
                        "--exclude-standard".into(),
                        "-z".into(),
                        "--".into(),
                    ];
                    args.extend_from_slice(&c.paths);
                    candidates.extend(model::names(
                        &self.run_git_paths(&args, reason, None, false)?,
                    )?);
                }
            }
            if c.right == "worktree" && self.metadata.values().any(|meta| meta.conflict) {
                // Raw HEAD/worktree diff can be empty while the index is still unmerged.
                if c.paths.is_empty() {
                    candidates.extend(
                        self.metadata
                            .iter()
                            .filter(|(_, meta)| meta.conflict)
                            .map(|(path, _)| path.clone()),
                    );
                } else {
                    let mut args = vec![
                        "ls-files".into(),
                        "--unmerged".into(),
                        "-z".into(),
                        "--".into(),
                    ];
                    args.extend_from_slice(&c.paths);
                    for record in model::names(&self.run_git_paths(&args, reason, None, false)?)? {
                        candidates.insert(
                            record
                                .split_once('\t')
                                .ok_or("Malformed unmerged path")?
                                .1
                                .to_owned(),
                        );
                    }
                }
            }
            if let Some(paths) = paths {
                candidates.retain(|path| paths.contains(path));
            }
        }
        let names = candidates.into_iter().collect::<Vec<_>>();
        if names.iter().any(|path| !model::safe_path(path)) {
            return Err("Unsupported comparison path".into());
        }
        if c.right == "worktree" {
            self.attributes_for(&names, reason)?;
        }
        let mut entries = if paths.is_some() {
            c.entries.clone()
        } else {
            BTreeMap::new()
        };
        if let Some(paths) = paths {
            for path in paths {
                entries.remove(path);
            }
        }
        for path in &names {
            let mut entry = self.file(&c, path, c.file.is_some())?;
            entries.remove(path);
            if c.file.is_some() && entry.left.same(&entry.right) {
                entry.status = if entry.left.exists {
                    "unchanged"
                } else {
                    "missing"
                }
                .into();
            }
            if c.file.is_some() || !entry.left.same(&entry.right) {
                entries.insert(path.clone(), entry);
            }
        }
        for row in rows {
            if row.status == "R"
                && entries
                    .get(&row.old_path)
                    .is_some_and(|entry| entry.status == "deleted")
                && entries
                    .get(&row.path)
                    .is_some_and(|entry| entry.status == "added")
            {
                let old = entries
                    .remove(&row.old_path)
                    .ok_or("Missing rename source")?;
                let new = entries
                    .get_mut(&row.path)
                    .ok_or("Missing rename destination")?;
                new.status = "renamed".into();
                new.old_path = Some(row.old_path);
                new.left = old.left;
            }
        }
        let current = self.comparisons.get_mut(id).ok_or("Comparison closed")?;
        current.entries = entries;
        current.index = c.index;
        current.stats.clear();
        current.generation += 1;
        current.stale = current.dirty_epoch != c.dirty_epoch;
        current.error = None;
        current.checked_at = Instant::now();
        let snapshot = self.snapshot(id)?;
        self.notifications
            .push(("comparison/updated".into(), snapshot.clone()));
        Ok(snapshot)
    }

    pub fn invalidate(&mut self) {
        for comparison in self.comparisons.values_mut() {
            if comparison.mutable() {
                comparison.stale = true;
                comparison.dirty_epoch += 1;
            }
        }
    }

    pub fn visible(&self) -> BTreeSet<String> {
        self.views
            .values()
            .filter(|view| {
                view.visible
                    && self
                        .comparisons
                        .get(&view.comparison_id)
                        .is_some_and(Comparison::mutable)
            })
            .map(|view| view.comparison_id.clone())
            .collect()
    }

    fn evict(&mut self) {
        let used = self
            .views
            .values()
            .map(|v| v.comparison_id.clone())
            .collect::<BTreeSet<_>>();
        let mut unused = self
            .comparisons
            .values()
            .filter(|c| !used.contains(&c.id))
            .map(|c| (c.last_used, c.id.clone()))
            .collect::<Vec<_>>();
        unused.sort();
        for (_, id) in unused {
            if self.comparisons.len() <= 8 {
                break;
            }
            self.comparisons.remove(&id);
        }
    }

    fn statistics_for(
        &self,
        entry: &Entry,
        worktree: bool,
        include_ignored: bool,
    ) -> Result<Value> {
        for side in [&entry.left, &entry.right] {
            if side.kind == "limited" {
                return Ok(json!({"reason":side.reason.as_deref().unwrap_or("unavailable")}));
            }
        }
        if entry.left.size.saturating_add(entry.right.size) > crate::stats::MAX_INPUT_BYTES {
            return Ok(json!({"reason":"stats-too-large"}));
        }
        let right = if worktree {
            let side = self.disk_side(&entry.path, include_ignored)?;
            if !side.same(&entry.right) {
                return Ok(json!({"reason":"stale"}));
            }
            side
        } else if entry.right.exists {
            self.blob(
                entry.right.oid.as_deref().ok_or("Missing statistics OID")?,
                &entry.right.mode,
            )?
        } else {
            Side::missing()
        };
        if entry.left.content_id == entry.right.content_id {
            return Ok(json!({"additions":0,"deletions":0}));
        }
        let left = if entry.left.exists {
            self.blob(
                entry.left.oid.as_deref().ok_or("Missing statistics OID")?,
                &entry.left.mode,
            )?
        } else {
            Side::missing()
        };
        crate::stats::count(&left, &right)
    }

    fn statistics(&mut self, params: &Value) -> Result<Value> {
        let id = parameter(params, "comparison_id")?;
        let generation = params
            .get("generation")
            .and_then(Value::as_u64)
            .ok_or("Missing generation")?;
        let offset = match params.get("offset") {
            Some(value) => usize::try_from(value.as_u64().ok_or("Invalid statistics offset")?)?,
            None => 0,
        };
        let comparison = self.comparisons.get_mut(id).ok_or("Unknown comparison")?;
        if generation != comparison.generation {
            return Err("Stale statistics generation".into());
        }
        if offset > comparison.entries.len() {
            return Err("Invalid statistics offset".into());
        }
        if comparison.stats_generation != generation {
            comparison.stats.clear();
            comparison.stats_generation = generation;
        }
        let total = comparison.entries.len();
        let worktree = comparison.right == "worktree";
        let include_ignored = comparison.file.is_some();
        let entries = comparison
            .entries
            .values()
            .skip(offset)
            .take(crate::stats::MAX_BATCH_FILES)
            .cloned()
            .collect::<Vec<_>>();
        let mut files = BTreeMap::new();
        let mut bytes = 0u64;
        let started = Instant::now();
        for entry in entries {
            if self.stopping.load(Ordering::Relaxed) || crate::STOP.load(Ordering::Relaxed) {
                return Err("Backend is stopping".into());
            }
            let size = entry.left.size.saturating_add(entry.right.size);
            if !files.is_empty()
                && (started.elapsed() >= Duration::from_millis(16)
                    || bytes.saturating_add(size) > crate::stats::MAX_INPUT_BYTES)
            {
                break;
            }
            let value = if let Some(cached) = self.comparisons[id].stats.get(&entry.path) {
                cached.clone()
            } else {
                bytes = bytes.saturating_add(size);
                self.metrics.stats_files += 1;
                let value = self
                    .statistics_for(&entry, worktree, include_ignored)
                    .unwrap_or_else(
                        |error| json!({"reason":"unavailable","error":error.to_string()}),
                    );
                self.comparisons
                    .get_mut(id)
                    .ok_or("Comparison closed")?
                    .stats
                    .insert(entry.path.clone(), value.clone());
                value
            };
            files.insert(entry.path, value);
        }
        let next = offset + files.len();
        Ok(
            json!({"session_id":self.session_id,"comparison_id":id,"generation":generation,
            "files":files,"next_offset":next,"complete":next == total}),
        )
    }

    pub fn handle(&mut self, method: &str, params: &Value) -> Result<Value> {
        match method {
            "initialize" => {
                if params.get("protocol").and_then(Value::as_u64) != Some(4) {
                    return Err("Protocol mismatch: expected 4".into());
                }
                if !self.initialized {
                    self.status("initialize", None)?;
                    self.initialized = true;
                }
                let mut info = crate::build_info();
                info["binary_version"] = info["version"].clone();
                info["session_id"] = json!(self.session_id);
                info["root"] = json!(self.root);
                info["git_dir"] = json!(self.git_dir);
                info["common_dir"] = json!(self.common_dir);
                info["head"] = self.head_value();
                return Ok(info);
            }
            "debug/metrics" => {
                let mut value = serde_json::to_value(&self.metrics)?;
                let own = usage(libc::RUSAGE_SELF);
                value["cpu_ms"] = json!(own.0 + usage(libc::RUSAGE_CHILDREN).0);
                value["max_rss_bytes"] = json!(own.1);
                value["views"] = json!(self.views.len());
                return Ok(value);
            }
            "shutdown" => {
                self.stopping.store(true, Ordering::Relaxed);
                return Ok(json!({}));
            }
            _ => {}
        }
        if !self.initialized {
            return Err("Backend is not initialized".into());
        }
        match method {
            "blob/read" => Ok(serde_json::to_value(
                self.blob(
                    parameter(params, "oid")?,
                    params
                        .get("mode")
                        .and_then(Value::as_str)
                        .unwrap_or("100644"),
                )?,
            )?),
            "comparison/open" => {
                let mut left =
                    self.resolve(params.get("left").and_then(Value::as_str).unwrap_or("HEAD"))?;
                let right = params
                    .get("right")
                    .and_then(Value::as_str)
                    .unwrap_or("worktree");
                let right = if right == "worktree" {
                    right.into()
                } else {
                    self.resolve(right)?
                };
                if let Some(value) = params.get("merge_base") {
                    if value.as_bool().ok_or("merge_base must be boolean")? {
                        if left.is_empty() || left == ":0" || right.is_empty() || right == ":0" {
                            return Err("Merge-base requires committed revisions".into());
                        }
                        let target = if right == "worktree" {
                            self.resolve("HEAD")?
                        } else {
                            right.clone()
                        };
                        if target.is_empty() {
                            return Err("Merge-base requires a committed HEAD".into());
                        }
                        left = String::from_utf8(
                            self.command(&["merge-base", "--all", &left, &target], "merge-base")?,
                        )?
                        .trim()
                        .into();
                        if left.is_empty() || left.contains('\n') {
                            return Err("Comparison requires a single merge base".into());
                        }
                    }
                }
                let mut paths = match params.get("paths") {
                    Some(value) => value
                        .as_array()
                        .ok_or("paths must be an array")?
                        .iter()
                        .map(|path| {
                            let path = path.as_str().ok_or("pathspec must be a string")?;
                            if path.is_empty() || path.contains('\0') {
                                return Err("Invalid pathspec");
                            }
                            Ok(path.to_owned())
                        })
                        .collect::<std::result::Result<Vec<_>, &str>>()?,
                    None => Vec::new(),
                };
                paths.sort();
                paths.dedup();
                let untracked = match params.get("untracked") {
                    Some(value) => value.as_bool().ok_or("untracked must be boolean")?,
                    None => true,
                };
                let file = match params.get("file") {
                    Some(value) => {
                        let path = value.as_str().ok_or("file must be a string")?;
                        if !model::safe_path(path) {
                            return Err("Unsupported comparison file".into());
                        }
                        Some(path.to_owned())
                    }
                    None => None,
                };
                let id: String = Sha256::digest(serde_json::to_vec(&json!([
                    left, right, paths, untracked, file
                ]))?)
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect();
                if !self.comparisons.contains_key(&id) {
                    self.comparisons.insert(
                        id.clone(),
                        Comparison {
                            id: id.clone(),
                            left,
                            right,
                            paths,
                            untracked,
                            file,
                            entries: BTreeMap::new(),
                            generation: 0,
                            dirty_epoch: 0,
                            stale: false,
                            error: None,
                            checked_at: Instant::now(),
                            last_used: Instant::now(),
                            index: Arc::default(),
                            stats: BTreeMap::new(),
                            stats_generation: 0,
                        },
                    );
                    if let Err(error) = self.refresh(&id, "open", None) {
                        self.comparisons.remove(&id);
                        return Err(error);
                    }
                } else if self.comparisons[&id].has_index() {
                    self.refresh(&id, "reopen", None)?;
                }
                self.comparisons
                    .get_mut(&id)
                    .ok_or("Missing comparison")?
                    .last_used = Instant::now();
                self.views.insert(
                    parameter(params, "view_id")?.into(),
                    View {
                        comparison_id: id.clone(),
                        visible: true,
                    },
                );
                self.evict();
                self.snapshot(&id)
            }
            "comparison/list" => self.snapshot(parameter(params, "comparison_id")?),
            "comparison/stats" => self.statistics(params),
            "comparison/refresh" => {
                self.refresh(parameter(params, "comparison_id")?, "manual", None)
            }
            "comparison/file" => {
                let path = parameter(params, "path")?;
                if !model::safe_path(path) {
                    return Err("Unsupported comparison path".into());
                }
                let comparison = self
                    .comparisons
                    .get(parameter(params, "comparison_id")?)
                    .ok_or("Unknown comparison")?
                    .clone();
                if comparison.right == "worktree" {
                    let paths = [path.to_owned()];
                    self.status("file", Some(&paths))?;
                    self.attributes.remove(path);
                    self.attributes_for(&paths, "file")?;
                }
                Ok(serde_json::to_value(self.file(&comparison, path, true)?)?)
            }
            "comparison/close" => {
                self.views.remove(parameter(params, "view_id")?);
                self.evict();
                Ok(json!({}))
            }
            "view/update" => {
                let id = parameter(params, "comparison_id")?;
                let view_id = parameter(params, "view_id")?;
                let visible = params
                    .get("visible")
                    .and_then(Value::as_bool)
                    .unwrap_or(false);
                if !self.comparisons.contains_key(id) {
                    return Err("Unknown comparison".into());
                }
                if visible
                    && self.comparisons[id].has_index()
                    && self
                        .views
                        .get(view_id)
                        .is_none_or(|view| !view.visible || view.comparison_id != id)
                {
                    self.refresh(id, "redisplay", None)?;
                }
                self.views.insert(
                    view_id.into(),
                    View {
                        comparison_id: id.into(),
                        visible,
                    },
                );
                Ok(json!({}))
            }
            _ => Err(format!("Unknown method: {method}").into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::process::Command;

    fn git(root: &std::path::Path, args: &[&str]) -> String {
        let output = Command::new("git")
            .args([
                "-c",
                "user.name=Example",
                "-c",
                "user.email=example@example.invalid",
                "-c",
                "commit.gpgsign=false",
                "-c",
                "core.hooksPath=/dev/null",
            ])
            .args(args)
            .current_dir(root)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout).unwrap().trim().into()
    }

    #[test]
    fn worktree_normalization_and_warm_reads() {
        let root = tempfile::tempdir().unwrap();
        git(root.path(), &["init", "-q"]);
        std::fs::write(root.path().join("a.txt"), "original\n").unwrap();
        git(root.path(), &["add", "."]);
        git(root.path(), &["commit", "-qm", "one"]);
        let mut repo = Repository::new(root.path(), 1048576).unwrap();
        repo.handle("initialize", &json!({"protocol":4})).unwrap();
        std::fs::write(root.path().join("a.txt"), "changed\n").unwrap();
        let snapshot = repo
            .handle(
                "comparison/open",
                &json!({"left":"HEAD","right":"worktree","view_id":"one"}),
            )
            .unwrap();
        let id = snapshot["comparison_id"].as_str().unwrap();
        assert_eq!(snapshot["entries"][0]["status"], "modified");
        let count = repo.metrics.git_spawns;
        let blob = repo
            .handle(
                "blob/read",
                &json!({"oid":snapshot["entries"][0]["left"]["oid"],"mode":"100644"}),
            )
            .unwrap();
        assert_eq!(blob["lines"][0], "original");
        repo.handle("comparison/list", &json!({"comparison_id":id}))
            .unwrap();
        assert_eq!(repo.metrics.git_spawns, count);
        git(root.path(), &["rm", "--cached", "a.txt"]);
        std::fs::write(root.path().join("a.txt"), "original\n").unwrap();
        let snapshot = repo
            .handle("comparison/refresh", &json!({"comparison_id":id}))
            .unwrap();
        assert_eq!(snapshot["entries"].as_array().unwrap().len(), 0);
    }

    #[test]
    fn frozen_empty_baseline_and_current_head_resolution() {
        let root = tempfile::tempdir().unwrap();
        git(root.path(), &["init", "-q"]);
        std::fs::write(root.path().join("a.txt"), "first\n").unwrap();
        let mut repo = Repository::new(root.path(), 1048576).unwrap();
        repo.handle("initialize", &json!({"protocol":4})).unwrap();
        let empty = repo
            .handle("comparison/open", &json!({"left":"HEAD","view_id":"empty"}))
            .unwrap();
        git(root.path(), &["add", "."]);
        git(root.path(), &["commit", "-qm", "first"]);
        let first = git(root.path(), &["rev-parse", "HEAD"]);
        let refreshed = repo
            .handle(
                "comparison/refresh",
                &json!({"comparison_id":empty["comparison_id"]}),
            )
            .unwrap();
        assert_eq!(refreshed["entries"].as_array().unwrap().len(), 1);
        std::fs::write(root.path().join("a.txt"), "second\n").unwrap();
        git(root.path(), &["add", "."]);
        git(root.path(), &["commit", "-qm", "second"]);
        let second = git(root.path(), &["rev-parse", "HEAD"]);
        let snapshot = repo
            .handle(
                "comparison/open",
                &json!({"left":first,"right":"HEAD","view_id":"fixed"}),
            )
            .unwrap();
        assert_eq!(snapshot["right"], second);
        assert_eq!(snapshot["entries"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn index_endpoints_separate_staged_and_unstaged_contents() {
        let root = tempfile::tempdir().unwrap();
        git(root.path(), &["init", "-q"]);
        fs::write(root.path().join("a.txt"), "base\n").unwrap();
        git(root.path(), &["add", "."]);
        git(root.path(), &["commit", "-qm", "base"]);
        fs::write(root.path().join("a.txt"), "staged\n").unwrap();
        git(root.path(), &["add", "a.txt"]);
        fs::write(root.path().join("a.txt"), "working\n").unwrap();
        let mut repo = Repository::new(root.path(), 1048576).unwrap();
        repo.handle("initialize", &json!({"protocol":4})).unwrap();
        let staged = repo
            .handle(
                "comparison/open",
                &json!({"left":"HEAD","right":":0","view_id":"staged"}),
            )
            .unwrap();
        let unstaged = repo
            .handle(
                "comparison/open",
                &json!({"left":":0","right":"worktree","view_id":"unstaged"}),
            )
            .unwrap();
        assert_eq!(staged["right"], ":0");
        assert_eq!(unstaged["left"], ":0");
        assert_eq!(
            staged["entries"][0]["right"]["content_id"],
            unstaged["entries"][0]["left"]["content_id"]
        );
        assert_ne!(
            staged["entries"][0]["right"]["content_id"],
            unstaged["entries"][0]["right"]["content_id"]
        );
        let oid = staged["entries"][0]["right"]["oid"].as_str().unwrap();
        assert_eq!(
            repo.blob(oid, "100644").unwrap().lines.unwrap(),
            vec!["staged"]
        );
    }

    #[test]
    fn comparison_scopes_are_git_pathspecs_and_have_independent_identity() {
        let root = tempfile::tempdir().unwrap();
        git(root.path(), &["init", "-q"]);
        fs::create_dir(root.path().join("src")).unwrap();
        for name in ["src/a.lua", "src/a.lock", "other.txt"] {
            fs::write(root.path().join(name), "before\n").unwrap();
        }
        git(root.path(), &["add", "."]);
        git(root.path(), &["commit", "-qm", "base"]);
        for name in ["src/a.lua", "src/a.lock", "other.txt", "src/new.lua"] {
            fs::write(root.path().join(name), "after\n").unwrap();
        }
        let mut repo = Repository::new(root.path(), 1048576).unwrap();
        repo.handle("initialize", &json!({"protocol":4})).unwrap();
        let all = repo
            .handle("comparison/open", &json!({"view_id":"all"}))
            .unwrap();
        let scoped = repo.handle("comparison/open", &json!({"view_id":"scoped","paths":["src",":(exclude,glob)**/*.lock"],"untracked":false})).unwrap();
        assert_ne!(all["comparison_id"], scoped["comparison_id"]);
        assert_eq!(scoped["entries"].as_array().unwrap().len(), 1);
        assert_eq!(scoped["entries"][0]["path"], "src/a.lua");
    }

    #[test]
    fn merge_base_is_resolved_before_a_fixed_comparison_is_opened() {
        let root = tempfile::tempdir().unwrap();
        git(root.path(), &["init", "-q", "-b", "main"]);
        fs::write(root.path().join("base"), "base\n").unwrap();
        git(root.path(), &["add", "."]);
        git(root.path(), &["commit", "-qm", "base"]);
        let base = git(root.path(), &["rev-parse", "HEAD"]);
        git(root.path(), &["checkout", "-qb", "feature"]);
        fs::write(root.path().join("feature"), "feature\n").unwrap();
        git(root.path(), &["add", "."]);
        git(root.path(), &["commit", "-qm", "feature"]);
        git(root.path(), &["checkout", "-q", "main"]);
        fs::write(root.path().join("main"), "main\n").unwrap();
        git(root.path(), &["add", "."]);
        git(root.path(), &["commit", "-qm", "main"]);
        let mut repo = Repository::new(root.path(), 1048576).unwrap();
        repo.handle("initialize", &json!({"protocol":4})).unwrap();
        let snapshot = repo
            .handle(
                "comparison/open",
                &json!({"view_id":"one","left":"main","right":"feature","merge_base":true}),
            )
            .unwrap();
        assert_eq!(snapshot["left"], base);
        assert_eq!(snapshot["entries"].as_array().unwrap().len(), 1);
        assert_eq!(snapshot["entries"][0]["path"], "feature");
    }

    #[test]
    fn statistics_are_lazy_and_cached_for_the_comparison_generation() {
        let root = tempfile::tempdir().unwrap();
        git(root.path(), &["init", "-q"]);
        fs::write(root.path().join("a.txt"), "old\nkeep\n").unwrap();
        git(root.path(), &["add", "."]);
        git(root.path(), &["commit", "-qm", "base"]);
        fs::write(root.path().join("a.txt"), "new\nkeep\nextra\n").unwrap();
        let mut repo = Repository::new(root.path(), 1048576).unwrap();
        repo.handle("initialize", &json!({"protocol":4})).unwrap();
        let snapshot = repo
            .handle("comparison/open", &json!({"view_id":"one"}))
            .unwrap();
        let params =
            json!({"comparison_id":snapshot["comparison_id"],"generation":snapshot["generation"]});
        let stats = repo.handle("comparison/stats", &params).unwrap();
        assert_eq!(stats["files"]["a.txt"]["additions"], 2);
        assert_eq!(stats["files"]["a.txt"]["deletions"], 1);
        let spawns = repo.metrics.git_spawns;
        let computed = repo.metrics.stats_files;
        assert_eq!(repo.handle("comparison/stats", &params).unwrap(), stats);
        assert_eq!(repo.metrics.git_spawns, spawns);
        assert_eq!(repo.metrics.stats_files, computed);
    }

    #[test]
    fn statistics_count_saved_bytes_and_reject_stale_worktree_contents() {
        let root = tempfile::tempdir().unwrap();
        git(root.path(), &["init", "-q"]);
        let files: &[(&str, &[u8], &[u8], u64, u64)] = &[
            ("empty", b"", b"one\n", 1, 0),
            ("eof", b"one", b"one\n", 1, 1),
            ("crlf", b"one\n", b"one\r\n", 1, 1),
            ("bom", b"one\n", b"\xef\xbb\xbfone\n", 1, 1),
            ("delete", b"one\ntwo\n", b"", 0, 2),
        ];
        for (name, before, _, _, _) in files {
            fs::write(root.path().join(name), before).unwrap();
        }
        fs::write(root.path().join("renamed"), "same\n").unwrap();
        fs::write(root.path().join("stale"), "base\n").unwrap();
        fs::write(root.path().join("ignored-recreated"), "base\n").unwrap();
        git(root.path(), &["add", "."]);
        git(root.path(), &["commit", "-qm", "base"]);
        git(root.path(), &["rm", "--cached", "ignored-recreated"]);
        fs::write(root.path().join(".gitignore"), "ignored-recreated\n").unwrap();
        git(root.path(), &["mv", "renamed", "destination"]);
        for (name, _, after, _, _) in files {
            fs::write(root.path().join(name), after).unwrap();
        }
        fs::write(root.path().join("new-empty"), "").unwrap();
        fs::write(root.path().join("binary"), b"\0").unwrap();
        fs::write(root.path().join("stale"), "first\n").unwrap();
        let mut repo = Repository::new(root.path(), 1048576).unwrap();
        repo.handle("initialize", &json!({"protocol":4})).unwrap();
        let snapshot = repo
            .handle("comparison/open", &json!({"view_id":"stats"}))
            .unwrap();
        fs::write(root.path().join("stale"), "second\nthird\n").unwrap();
        let params =
            json!({"comparison_id":snapshot["comparison_id"],"generation":snapshot["generation"]});
        let stats = repo.handle("comparison/stats", &params).unwrap();
        for (name, _, _, additions, deletions) in files {
            assert_eq!(stats["files"][name]["additions"], *additions, "{name}");
            assert_eq!(stats["files"][name]["deletions"], *deletions, "{name}");
        }
        assert_eq!(
            stats["files"]["new-empty"],
            json!({"additions":0,"deletions":0})
        );
        assert_eq!(
            stats["files"]["destination"],
            json!({"additions":0,"deletions":0})
        );
        assert_eq!(stats["files"]["binary"]["reason"], "binary");
        assert_eq!(stats["files"]["stale"]["reason"], "stale");
        assert_eq!(
            stats["files"]["ignored-recreated"],
            json!({"additions":0,"deletions":1})
        );
        let refreshed = repo.handle("comparison/refresh", &params).unwrap();
        assert!(repo.handle("comparison/stats", &params).is_err());
        let stats = repo.handle("comparison/stats", &json!({"comparison_id":refreshed["comparison_id"],"generation":refreshed["generation"]})).unwrap();
        assert_eq!(
            stats["files"]["stale"],
            json!({"additions":2,"deletions":1})
        );
    }

    #[test]
    fn empty_baselines_support_globs_and_index_intent_to_add() {
        let root = tempfile::tempdir().unwrap();
        git(root.path(), &["init", "-q"]);
        fs::write(root.path().join("intent.txt"), "pending\n").unwrap();
        fs::write(root.path().join("empty.txt"), "").unwrap();
        fs::write(root.path().join("omit.txt"), "omit\n").unwrap();
        git(root.path(), &["add", "-N", "intent.txt"]);
        git(root.path(), &["add", "empty.txt", "omit.txt"]);
        let mut repo = Repository::new(root.path(), 1048576).unwrap();
        repo.handle("initialize", &json!({"protocol":4})).unwrap();
        let staged = repo.handle("comparison/open", &json!({"view_id":"staged","right":":0","paths":[":(glob)*.txt",":(exclude)omit.txt"]})).unwrap();
        assert_eq!(staged["entries"].as_array().unwrap().len(), 1);
        assert_eq!(staged["entries"][0]["path"], "empty.txt");
        let unstaged = repo
            .handle(
                "comparison/open",
                &json!({"view_id":"unstaged","left":":0"}),
            )
            .unwrap();
        assert_eq!(unstaged["entries"].as_array().unwrap().len(), 1);
        assert_eq!(unstaged["entries"][0]["path"], "intent.txt");
        assert_eq!(unstaged["entries"][0]["left"]["exists"], false);
        let frozen = repo.handle("comparison/open", &json!({"view_id":"frozen","left":"","paths":[":(glob)*.txt",":(exclude)omit.txt"]})).unwrap();
        assert_eq!(frozen["entries"].as_array().unwrap().len(), 2);
        git(root.path(), &["add", "."]);
        git(root.path(), &["commit", "-qm", "first"]);
        let refreshed = repo
            .handle(
                "comparison/refresh",
                &json!({"comparison_id":frozen["comparison_id"]}),
            )
            .unwrap();
        assert_eq!(refreshed["left"], "");
        assert_eq!(refreshed["entries"].as_array().unwrap().len(), 2);
    }

    #[test]
    fn scoped_rename_projects_each_endpoint_and_keeps_recreated_tracked_paths() {
        let root = tempfile::tempdir().unwrap();
        git(root.path(), &["init", "-q"]);
        fs::create_dir(root.path().join("out")).unwrap();
        fs::create_dir(root.path().join("inside")).unwrap();
        fs::write(root.path().join("out/old"), "same\n").unwrap();
        fs::write(root.path().join("recreated"), "original\n").unwrap();
        git(root.path(), &["add", "."]);
        git(root.path(), &["commit", "-qm", "base"]);
        git(root.path(), &["mv", "out/old", "inside/new"]);
        git(root.path(), &["rm", "recreated"]);
        fs::write(root.path().join("recreated"), "different\n").unwrap();
        let mut repo = Repository::new(root.path(), 1048576).unwrap();
        repo.handle("initialize", &json!({"protocol":4})).unwrap();
        for (scope, name, status) in [
            ("out", "out/old", "deleted"),
            ("inside", "inside/new", "added"),
        ] {
            let snapshot = repo
                .handle(
                    "comparison/open",
                    &json!({"view_id":scope,"paths":[scope],"right":":0"}),
                )
                .unwrap();
            assert_eq!(snapshot["entries"].as_array().unwrap().len(), 1);
            assert_eq!(snapshot["entries"][0]["path"], name);
            assert_eq!(snapshot["entries"][0]["status"], status);
        }
        let recreated = repo
            .handle(
                "comparison/open",
                &json!({"view_id":"recreated","paths":["recreated"],"untracked":false}),
            )
            .unwrap();
        assert_eq!(recreated["entries"][0]["status"], "modified");
        let inspection = repo
            .handle(
                "comparison/file",
                &json!({"comparison_id":recreated["comparison_id"],"path":"recreated"}),
            )
            .unwrap();
        assert_eq!(inspection["right"], recreated["entries"][0]["right"]);
    }

    #[test]
    fn index_snapshots_are_immutable_but_reopening_reconciles_the_index() {
        let root = tempfile::tempdir().unwrap();
        git(root.path(), &["init", "-q"]);
        fs::write(root.path().join("a"), "base\n").unwrap();
        git(root.path(), &["add", "."]);
        git(root.path(), &["commit", "-qm", "base"]);
        fs::write(root.path().join("a"), "stage one\n").unwrap();
        git(root.path(), &["add", "."]);
        let mut repo = Repository::new(root.path(), 1048576).unwrap();
        repo.handle("initialize", &json!({"protocol":4})).unwrap();
        let params = json!({"view_id":"staged","right":":0"});
        let first = repo.handle("comparison/open", &params).unwrap();
        fs::write(root.path().join("a"), "stage two\n").unwrap();
        git(root.path(), &["add", "."]);
        let inspection = repo
            .handle(
                "comparison/file",
                &json!({"comparison_id":first["comparison_id"],"path":"a"}),
            )
            .unwrap();
        assert_eq!(inspection["right"], first["entries"][0]["right"]);
        assert!(
            repo.visible()
                .contains(first["comparison_id"].as_str().unwrap())
        );
        repo.invalidate();
        assert!(repo.comparisons[first["comparison_id"].as_str().unwrap()].stale);
        let second = repo.handle("comparison/open", &params).unwrap();
        assert_eq!(first["comparison_id"], second["comparison_id"]);
        assert_ne!(first["entries"][0]["right"], second["entries"][0]["right"]);
        assert!(second["generation"].as_u64().unwrap() > first["generation"].as_u64().unwrap());
    }

    #[test]
    fn pinned_files_include_clean_ignored_and_missing_contents() {
        let root = tempfile::tempdir().unwrap();
        git(root.path(), &["init", "-q"]);
        fs::write(root.path().join("a.txt"), "base\n").unwrap();
        fs::write(root.path().join(".gitignore"), "*.tmp\n").unwrap();
        git(root.path(), &["add", "."]);
        git(root.path(), &["commit", "-qm", "base"]);
        fs::write(root.path().join("ignored.tmp"), "first\nsecond\n").unwrap();
        fs::write(root.path().join("other.txt"), "other\n").unwrap();
        let mut repo = Repository::new(root.path(), 1048576).unwrap();
        repo.handle("initialize", &json!({"protocol":4})).unwrap();
        let clean = repo
            .handle(
                "comparison/open",
                &json!({"view_id":"clean","file":"a.txt"}),
            )
            .unwrap();
        assert_eq!(clean["entries"].as_array().unwrap().len(), 1);
        assert_eq!(clean["entries"][0]["path"], "a.txt");
        assert_eq!(clean["entries"][0]["status"], "unchanged");
        let counts = repo
            .handle(
                "comparison/stats",
                &json!({"comparison_id":clean["comparison_id"],"generation":clean["generation"]}),
            )
            .unwrap();
        assert_eq!(
            counts["files"]["a.txt"],
            json!({"additions":0,"deletions":0})
        );
        let ignored = repo
            .handle(
                "comparison/open",
                &json!({"view_id":"ignored","file":"ignored.tmp"}),
            )
            .unwrap();
        assert_eq!(ignored["entries"].as_array().unwrap().len(), 1);
        assert_eq!(ignored["entries"][0]["path"], "ignored.tmp");
        let counts = repo.handle("comparison/stats", &json!({"comparison_id":ignored["comparison_id"],"generation":ignored["generation"]})).unwrap();
        assert_eq!(
            counts["files"]["ignored.tmp"],
            json!({"additions":2,"deletions":0})
        );
        let missing = repo
            .handle(
                "comparison/open",
                &json!({"view_id":"missing","file":"missing.txt"}),
            )
            .unwrap();
        assert_eq!(missing["entries"][0]["status"], "missing");
        fs::write(root.path().join("missing.txt"), "created\n").unwrap();
        let updated = repo
            .handle(
                "comparison/refresh",
                &json!({"comparison_id":missing["comparison_id"]}),
            )
            .unwrap();
        assert_eq!(updated["entries"][0]["status"], "added");
        for path in ["../outside", ".git/config", "a\0b"] {
            assert!(
                repo.handle("comparison/open", &json!({"view_id":"invalid","file":path}))
                    .is_err()
            );
        }
    }

    #[test]
    fn pinned_files_keep_limitations_and_literal_fixed_endpoints() {
        let root = tempfile::tempdir().unwrap();
        git(root.path(), &["init", "-q"]);
        fs::write(root.path().join("binary"), b"a\0b").unwrap();
        fs::write(root.path().join("[literal].txt"), "base\n").unwrap();
        git(root.path(), &["add", "."]);
        git(root.path(), &["commit", "-qm", "base"]);
        let base = git(root.path(), &["rev-parse", "HEAD"]);
        let mut repo = Repository::new(root.path(), 1048576).unwrap();
        repo.handle("initialize", &json!({"protocol":4})).unwrap();
        let limited = repo
            .handle(
                "comparison/open",
                &json!({"view_id":"binary","file":"binary","left":"HEAD","right":"HEAD"}),
            )
            .unwrap();
        assert_eq!(limited["entries"][0]["status"], "limited");
        assert_eq!(limited["entries"][0]["right"]["reason"], "binary");
        fs::write(root.path().join("[literal].txt"), "next\n").unwrap();
        git(root.path(), &["add", "."]);
        git(root.path(), &["commit", "-qm", "next"]);
        let fixed = repo.handle("comparison/open", &json!({"view_id":"fixed","file":"[literal].txt","left":base,"right":"HEAD","merge_base":true})).unwrap();
        assert_eq!(fixed["entries"].as_array().unwrap().len(), 1);
        assert_eq!(fixed["entries"][0]["path"], "[literal].txt");
        let before = fixed["entries"][0]["right"]["content_id"].clone();
        fs::write(root.path().join("[literal].txt"), "third\n").unwrap();
        git(root.path(), &["add", "."]);
        git(root.path(), &["commit", "-qm", "third"]);
        let refreshed = repo
            .handle(
                "comparison/refresh",
                &json!({"comparison_id":fixed["comparison_id"]}),
            )
            .unwrap();
        assert_eq!(refreshed["entries"][0]["right"]["content_id"], before);
    }

    #[test]
    fn unresolved_conflicts_remain_visible_when_the_disk_matches_head() {
        let root = tempfile::tempdir().unwrap();
        git(root.path(), &["init", "-q", "-b", "main"]);
        fs::write(root.path().join("conflict"), "base\n").unwrap();
        git(root.path(), &["add", "."]);
        git(root.path(), &["commit", "-qm", "base"]);
        git(root.path(), &["checkout", "-qb", "side"]);
        fs::write(root.path().join("conflict"), "theirs\n").unwrap();
        git(root.path(), &["commit", "-qam", "theirs"]);
        git(root.path(), &["checkout", "-q", "main"]);
        fs::write(root.path().join("conflict"), "ours\n").unwrap();
        git(root.path(), &["commit", "-qam", "ours"]);
        let merge = Command::new("git")
            .args([
                "-c",
                "user.name=Example",
                "-c",
                "user.email=example@example.invalid",
                "merge",
                "side",
            ])
            .current_dir(root.path())
            .output()
            .unwrap();
        assert!(!merge.status.success());
        fs::write(root.path().join("conflict"), "ours\n").unwrap();
        assert!(git(root.path(), &["diff", "HEAD", "--raw"]).is_empty());
        let mut repo = Repository::new(root.path(), 1048576).unwrap();
        repo.handle("initialize", &json!({"protocol":4})).unwrap();
        for paths in [json!([]), json!([":(glob)conf*"])] {
            for untracked in [true, false] {
                let snapshot = repo
                    .handle(
                        "comparison/open",
                        &json!({"view_id":"conflict","paths":paths,"untracked":untracked}),
                    )
                    .unwrap();
                assert_eq!(snapshot["entries"].as_array().unwrap().len(), 1);
                assert_eq!(snapshot["entries"][0]["right"]["reason"], "conflict");
            }
        }
        let excluded = repo
            .handle(
                "comparison/open",
                &json!({"view_id":"excluded","paths":[":(exclude)conflict"]}),
            )
            .unwrap();
        assert!(excluded["entries"].as_array().unwrap().is_empty());
        let index = repo
            .handle("comparison/open", &json!({"view_id":"index","right":":0"}))
            .unwrap();
        assert_eq!(index["entries"][0]["right"]["reason"], "conflict");
        git(root.path(), &["add", "conflict"]);
        let resolved = repo
            .handle(
                "comparison/refresh",
                &json!({"comparison_id":index["comparison_id"]}),
            )
            .unwrap();
        assert!(resolved["entries"].as_array().unwrap().is_empty());
    }
}
