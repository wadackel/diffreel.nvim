mod model;
mod pr;
mod repository;
mod rpc;
mod stats;

use model::Result;
use notify::{RecursiveMode, Watcher};
use repository::Repository;
use serde_json::{Value, json};
use std::collections::BTreeSet;
use std::io::{BufReader, BufWriter};
use std::path::{Path, PathBuf};
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
    mpsc,
};
use std::time::{Duration, Instant};

pub static STOP: AtomicBool = AtomicBool::new(false);

pub fn build_info() -> Value {
    json!({
        "version": env!("CARGO_PKG_VERSION"),
        "build_id": env!("DIFFREEL_BUILD_ID"),
        "target": env!("DIFFREEL_TARGET"),
        "protocol": 4,
    })
}

extern "C" fn stop_signal(_: i32) {
    STOP.store(true, Ordering::Relaxed);
}

enum Message {
    Rpc(Value),
    Event(notify::Result<notify::Event>, Instant),
    End,
}

#[derive(Default)]
struct Pending {
    paths: BTreeSet<String>,
    full: bool,
    reason: String,
    first: Option<Instant>,
    due: Option<Instant>,
}

impl Pending {
    fn event(&mut self, repo: &mut Repository, event: notify::Result<notify::Event>, at: Instant) {
        match event {
            Err(_) => {
                self.full = true;
                self.reason = "rescan".into();
            }
            Ok(event) => {
                if matches!(event.kind, notify::EventKind::Access(_)) {
                    return;
                }
                if event.need_rescan() || event.paths.is_empty() {
                    self.full = true;
                    self.reason = "rescan".into();
                }
                let mut relevant = self.full;
                for path in event.paths {
                    if let Some(relative) = path
                        .strip_prefix(&repo.git_dir)
                        .ok()
                        .or_else(|| path.strip_prefix(&repo.common_dir).ok())
                    {
                        let name = relative.to_string_lossy();
                        if matches!(name.as_ref(), "HEAD" | "index" | "packed-refs" | "config")
                            || name.starts_with("refs/")
                            || name.starts_with("info/")
                        {
                            self.full = true;
                            self.reason = "metadata".into();
                            relevant = true;
                        }
                    } else if let Ok(relative) = path.strip_prefix(&repo.root) {
                        let Some(name) = relative.to_str() else {
                            self.full = true;
                            self.reason = "encoding".into();
                            relevant = true;
                            continue;
                        };
                        if name == ".git" || name.starts_with(".git/") {
                            continue;
                        }
                        if name == ".gitignore"
                            || name.ends_with("/.gitignore")
                            || name == ".gitattributes"
                            || name.ends_with("/.gitattributes")
                        {
                            self.full = true;
                            self.reason = "config".into();
                        } else if !self.full {
                            self.paths.insert(name.into());
                        }
                        relevant = true;
                    }
                }
                if !relevant {
                    return;
                }
            }
        }
        if self.paths.len() > 4096 {
            self.paths.clear();
            self.full = true;
            self.reason = "overflow".into();
        }
        repo.invalidate();
        let first = *self.first.get_or_insert(at);
        let due = (at + Duration::from_millis(100)).min(first + Duration::from_millis(250));
        // Once a batch requires full reconciliation, later events must not push its deadline back.
        self.due = Some(match self.due {
            Some(existing) if self.full => existing.min(due),
            _ => due,
        });
    }

    fn full(&mut self, reason: &str) {
        self.full = true;
        self.reason = reason.into();
        self.due = Some(Instant::now());
    }
}

fn partial_paths(
    repo: &Repository,
    id: &str,
    changed: &BTreeSet<String>,
) -> Result<Option<Vec<String>>> {
    let comparison = repo.comparisons.get(id).ok_or("Unknown comparison")?;
    if comparison.right != "worktree"
        || comparison.has_index()
        || !comparison.paths.is_empty()
        || comparison.file.is_some()
    {
        return Ok(None);
    }
    let mut paths = Vec::new();
    for path in changed {
        if !model::safe_path(path) {
            return Ok(None);
        }
        let stat = match std::fs::symlink_metadata(repo.root.join(path)) {
            Ok(stat) => Some(stat),
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::NotFound | std::io::ErrorKind::NotADirectory
                ) =>
            {
                None
            }
            Err(e) => return Err(e.into()),
        };
        let entry = repo.tree_entry(&comparison.left, path)?;
        let previous = comparison.entries.get(path);
        if stat.is_none() && entry.is_none() && previous.is_none() {
            continue;
        }
        if !stat.is_some_and(|s| s.is_file())
            || !entry.is_some_and(|e| e.0.starts_with("100"))
            || previous.is_some_and(|e| e.status != "modified" && e.status != "metadata")
            || comparison
                .entries
                .values()
                .any(|e| e.old_path.as_deref() == Some(path))
        {
            return Ok(None);
        }
        paths.push(path.clone());
    }
    Ok(Some(paths))
}

fn reconcilable(repo: &mut Repository, changed: &BTreeSet<String>) -> BTreeSet<String> {
    // check-ignore aborts the whole batch for paths beyond a symlink, so failures keep every path.
    match repo.ignored(changed) {
        Ok(ignored) => changed.difference(&ignored).cloned().collect(),
        Err(_) => changed.clone(),
    }
}

fn reopened(
    repo: &Repository,
    method: &str,
    visible_before: &BTreeSet<String>,
    interval: Duration,
) -> bool {
    // A view update for an already-visible comparison is covered by its pending batch and the
    // periodic timer. An open returns `updating` to a new view, which an ignored-only batch
    // would never clear.
    repo.visible().iter().any(|id| {
        let comparison = &repo.comparisons[id];
        (method == "comparison/open" || !visible_before.contains(id))
            && (comparison.stale || comparison.checked_at.elapsed() >= interval)
    })
}

fn write_pr_events(
    output: &mut impl std::io::Write,
    repo: &mut Repository,
    pr_jobs: &mut pr::Jobs,
) -> Result<()> {
    for (method, params) in pr_jobs.poll() {
        if method == "pr/prepared" {
            repo.git = gix::discover(&repo.root)?;
            repo.git.object_cache_size(Some(67108864));
        }
        rpc::write_message(
            output,
            &json!({"jsonrpc":"2.0","method":method,"params":params}),
        )?;
    }
    Ok(())
}

fn write_notifications(output: &mut impl std::io::Write, repo: &mut Repository) -> Result<()> {
    for (method, params) in repo.notifications.drain(..) {
        rpc::write_message(
            output,
            &json!({"jsonrpc":"2.0","method":method,"params":params}),
        )?;
    }
    Ok(())
}

fn serve(root: &Path, watch: bool, interval: Duration, max_bytes: usize) -> Result<()> {
    let mut repo = Repository::new(root, max_bytes)?;
    let mut pr_jobs = pr::Jobs::new(&repo.root, &repo.common_dir, &repo.session_id);
    let (sender, receiver) = mpsc::sync_channel(4096);
    let overflow = Arc::new(AtomicBool::new(false));
    let input = sender.clone();
    let stopping = repo.stopping.clone();
    std::thread::spawn(move || {
        let mut reader = BufReader::new(std::io::stdin());
        loop {
            match rpc::read_message(&mut reader) {
                Ok(Some(value)) => {
                    if input.send(Message::Rpc(value)).is_err() {
                        break;
                    }
                }
                Ok(None) => break,
                Err(error) => {
                    eprintln!("{error}");
                    break;
                }
            }
        }
        stopping.store(true, Ordering::Relaxed);
        let _ = input.send(Message::End);
    });
    let mut watcher = if watch {
        let events = sender.clone();
        let overflow = overflow.clone();
        let mut watcher = notify::recommended_watcher(move |event| {
            if matches!(
                events.try_send(Message::Event(event, Instant::now())),
                Err(mpsc::TrySendError::Full(_))
            ) {
                overflow.store(true, Ordering::Relaxed);
            }
        })?;
        let roots = [&repo.root, &repo.git_dir, &repo.common_dir]
            .into_iter()
            .cloned()
            .collect::<BTreeSet<_>>();
        for path in roots {
            watcher.watch(&path, RecursiveMode::Recursive)?;
        }
        Some(watcher)
    } else {
        None
    };
    let mut output = BufWriter::new(std::io::stdout());
    let mut pending = Pending::default();
    let mut periodic: Option<Instant> = None;
    'serve: loop {
        if STOP.load(Ordering::Relaxed) || repo.stopping.load(Ordering::Relaxed) {
            break;
        }
        if overflow.swap(false, Ordering::Relaxed) {
            repo.invalidate();
            pending.full("overflow");
        }
        let deadline = if repo.visible().is_empty() {
            None
        } else {
            [pending.due, periodic].into_iter().flatten().min()
        };
        let timeout = deadline.map_or(Duration::from_millis(50), |due| {
            due.saturating_duration_since(Instant::now())
                .min(Duration::from_millis(50))
        });
        let mut message = match receiver.recv_timeout(timeout) {
            Ok(message) => Some(message),
            Err(mpsc::RecvTimeoutError::Timeout) => None,
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        };
        // Handling one message per iteration turns a backlog of old events into one due batch each.
        let drain_started = Instant::now();
        while let Some(current) = message.take() {
            match current {
                Message::Rpc(value) => {
                    let id = value.get("id").cloned();
                    let method = value.get("method").and_then(Value::as_str).unwrap_or("");
                    let params = value.get("params").cloned().unwrap_or(json!({}));
                    let visible_before = repo.visible();
                    let result = if method.starts_with("pr/") && !repo.initialized {
                        Err("Backend is not initialized".into())
                    } else if value.get("jsonrpc") == Some(&json!("2.0")) {
                        match method {
                            "pr/prepare" => pr_jobs.start(&params),
                            "pr/cancel" => pr_jobs.cancel(&params),
                            "pr/restore" => pr_jobs.restore(&params).and_then(|_| {
                                repo.git = gix::discover(&repo.root)?;
                                repo.git.object_cache_size(Some(67108864));
                                let mut comparison = json!({
                                    "view_id":params["view_id"], "left":params["snapshot"]["merge_base"],
                                    "right":params["snapshot"]["head"], "untracked":false,
                                });
                                for name in ["paths", "file"] {
                                    if let Some(value) = params["comparison"].get(name) {
                                        comparison[name] = value.clone();
                                    }
                                }
                                repo.handle("comparison/open", &comparison)
                            }),
                            "pr/cache-clear" => pr_jobs.clear(),
                            "pr/release" => {
                                pr_jobs.release(params["view_id"].as_str().unwrap_or(""));
                                Ok(json!({}))
                            }
                            "comparison/close" => {
                                pr_jobs.release(params["view_id"].as_str().unwrap_or(""));
                                repo.handle(method, &params)
                            }
                            _ => repo.handle(method, &params),
                        }
                    } else {
                        Err("Invalid JSON-RPC request".into())
                    };
                    if let Some(id) = id {
                        let response = match result {
                            Ok(result) => json!({"jsonrpc":"2.0","id":id,"result":result}),
                            Err(error) => {
                                json!({"jsonrpc":"2.0","id":id,"error":{"code":-32000,"message":error.to_string()}})
                            }
                        };
                        rpc::write_message(&mut output, &response)?;
                    }
                    if watch
                        && matches!(method, "view/update" | "comparison/open")
                        && reopened(&repo, method, &visible_before, interval)
                    {
                        pending.full("reopen");
                    }
                    write_pr_events(&mut output, &mut repo, &mut pr_jobs)?;
                    write_notifications(&mut output, &mut repo)?;
                }
                Message::Event(event, at) => pending.event(&mut repo, event, at),
                Message::End => break 'serve,
            }
            if STOP.load(Ordering::Relaxed)
                || repo.stopping.load(Ordering::Relaxed)
                || drain_started.elapsed() >= Duration::from_millis(50)
            {
                break;
            }
            message = receiver.try_recv().ok();
        }
        write_pr_events(&mut output, &mut repo, &mut pr_jobs)?;
        let visible = repo.visible();
        if !watch || visible.is_empty() {
            periodic = None;
        } else {
            if periodic.is_none() {
                periodic = Some(Instant::now() + interval);
            }
            if periodic.is_some_and(|due| due <= Instant::now()) {
                repo.invalidate();
                pending.full("timer");
                periodic = Some(Instant::now() + interval);
            }
            if pending.due.is_some_and(|due| due <= Instant::now()) {
                let work = std::mem::take(&mut pending);
                let changed = if work.full {
                    BTreeSet::new()
                } else {
                    reconcilable(&mut repo, &work.paths)
                };
                for id in visible {
                    let result = (|| -> Result<()> {
                        if !work.full && changed.is_empty() {
                            repo.comparisons
                                .get_mut(&id)
                                .ok_or("Unknown comparison")?
                                .stale = false;
                            return Ok(());
                        }
                        let paths = if work.full {
                            None
                        } else {
                            partial_paths(&repo, &id, &changed)?
                        };
                        if paths.as_ref().is_some_and(Vec::is_empty) {
                            let c = repo.comparisons.get_mut(&id).ok_or("Unknown comparison")?;
                            c.stale = false;
                            c.generation += 1;
                            repo.notifications
                                .push(("comparison/updated".into(), repo.snapshot(&id)?));
                            return Ok(());
                        }
                        rpc::write_message(
                            &mut output,
                            &json!({"jsonrpc":"2.0","method":"comparison/progress","params":{
                                "session_id":repo.session_id,"comparison_id":id,"updating":true
                            }}),
                        )?;
                        let reason = if paths.is_some() {
                            "paths"
                        } else if work.reason.is_empty() {
                            "structural"
                        } else {
                            &work.reason
                        };
                        repo.refresh(&id, reason, paths.as_deref())?;
                        Ok(())
                    })();
                    if let Err(error) = result {
                        if let Some(c) = repo.comparisons.get_mut(&id) {
                            c.error = Some(error.to_string());
                            c.stale = false;
                        }
                        repo.notifications
                            .push(("comparison/updated".into(), repo.snapshot(&id)?));
                    }
                }
            }
        }
        write_notifications(&mut output, &mut repo)?;
    }
    drop(watcher.take());
    Ok(())
}

fn run() -> Result<()> {
    let mut root: Option<PathBuf> = None;
    let mut watch = true;
    let mut interval = 30000;
    let mut max_bytes = 1048576;
    let mut pr_worker = false;
    let mut pr_clear = false;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--pr-worker" => pr_worker = true,
            "--pr-cache-clear" => pr_clear = true,
            "--root" => root = Some(args.next().ok_or("Missing root")?.into()),
            "--no-watch" => watch = false,
            "--reconcile-ms" => interval = args.next().ok_or("Missing interval")?.parse()?,
            "--max-bytes" => max_bytes = args.next().ok_or("Missing byte limit")?.parse()?,
            "--version" => {
                println!("diffreel-daemon {}", env!("CARGO_PKG_VERSION"));
                return Ok(());
            }
            "--build-info" => {
                println!("{}", build_info());
                return Ok(());
            }
            _ => return Err(format!("Unknown argument: {arg}").into()),
        }
    }
    if interval == 0 || max_bytes == 0 {
        return Err("Limits must be positive".into());
    }
    // Default termination bypasses cleanup of Git process groups.
    unsafe {
        libc::signal(
            libc::SIGTERM,
            stop_signal as *const () as libc::sighandler_t,
        );
        libc::signal(libc::SIGINT, stop_signal as *const () as libc::sighandler_t);
    }
    if pr_worker {
        return pr::worker(&root.ok_or("--root is required")?);
    }
    if pr_clear {
        let repo = Repository::new(&root.ok_or("--root is required")?, max_bytes)?;
        let jobs = pr::Jobs::new(&repo.root, &repo.common_dir, &repo.session_id);
        println!("{}", jobs.clear()?);
        return Ok(());
    }
    let served = serve(
        &root.ok_or("--root is required")?,
        watch,
        Duration::from_millis(interval),
        max_bytes,
    );
    if let Err(error) = &served {
        // The client only sees stdout; stderr goes to the editor's LSP log, so without this
        // the view can only report that the backend closed.
        let _ = rpc::write_message(
            &mut std::io::stdout(),
            &json!({"jsonrpc": "2.0", "method": "daemon/failed", "params": {"message": error.to_string()}}),
        );
    }
    served
}

fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn replaced_parent_requires_full_reconciliation() {
        let root = tempfile::tempdir().unwrap();
        assert!(
            std::process::Command::new("git")
                .args(["init", "-q"])
                .current_dir(root.path())
                .status()
                .unwrap()
                .success()
        );
        std::fs::create_dir(root.path().join("src")).unwrap();
        std::fs::write(root.path().join("src/file.txt"), "before\n").unwrap();
        let mut repo = Repository::new(root.path(), 1048576).unwrap();
        repo.handle("initialize", &json!({"protocol":4})).unwrap();
        let snapshot = repo
            .handle("comparison/open", &json!({"view_id":"one"}))
            .unwrap();
        std::fs::remove_file(root.path().join("src/file.txt")).unwrap();
        std::fs::remove_dir(root.path().join("src")).unwrap();
        std::fs::write(root.path().join("src"), "replacement\n").unwrap();
        let paths = partial_paths(
            &repo,
            snapshot["comparison_id"].as_str().unwrap(),
            &BTreeSet::from(["src/file.txt".into()]),
        );
        assert!(matches!(paths, Ok(None)), "{paths:?}");
    }

    fn git(root: &Path, args: &[&str]) {
        let status = std::process::Command::new("git")
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
            .status()
            .unwrap();
        assert!(status.success());
    }

    fn paths(names: &[&str]) -> BTreeSet<String> {
        names.iter().map(|name| (*name).into()).collect()
    }

    #[test]
    fn ignored_events_do_not_require_reconciliation() {
        let root = tempfile::tempdir().unwrap();
        let root = root.path();
        git(root, &["init", "-q"]);
        std::fs::write(root.join(".gitignore"), "build/\n*.log\n").unwrap();
        std::fs::create_dir_all(root.join("build/tracked")).unwrap();
        std::fs::write(root.join("build/tracked/keep.txt"), "tracked\n").unwrap();
        std::fs::write(root.join("kept.log"), "tracked\n").unwrap();
        std::fs::write(root.join("edited.log"), "tracked\n").unwrap();
        git(root, &["add", ".gitignore"]);
        git(
            root,
            &[
                "add",
                "-f",
                "build/tracked/keep.txt",
                "kept.log",
                "edited.log",
            ],
        );
        git(root, &["commit", "-qm", "baseline"]);
        std::fs::write(root.join("build/out.o"), "object\n").unwrap();
        std::fs::write(root.join("debug.log"), "log\n").unwrap();
        std::fs::write(root.join("new.txt"), "untracked\n").unwrap();
        std::fs::write(root.join("edited.log"), "changed\n").unwrap();
        let mut repo = Repository::new(root, 1048576).unwrap();
        repo.handle("initialize", &json!({"protocol":4})).unwrap();
        repo.handle("comparison/open", &json!({"view_id":"one"}))
            .unwrap();
        std::fs::write(root.join(":foo.log"), "after status\n").unwrap();
        let changed = paths(&[
            ":foo.log",
            "build/out.o",
            "debug.log",
            "new.txt",
            "build",
            "build/tracked",
            "build/tracked/keep.txt",
            "kept.log",
            "edited.log",
        ]);
        assert_eq!(
            reconcilable(&mut repo, &changed),
            paths(&[
                ":foo.log",
                "new.txt",
                "build",
                "build/tracked",
                "build/tracked/keep.txt",
                "kept.log",
                "edited.log",
            ])
        );
    }

    #[test]
    fn ignored_query_keeps_pinned_and_submodule_paths() {
        let root = tempfile::tempdir().unwrap();
        let module = tempfile::tempdir().unwrap();
        git(module.path(), &["init", "-q"]);
        std::fs::write(module.path().join("file.txt"), "module\n").unwrap();
        git(module.path(), &["add", "."]);
        git(module.path(), &["commit", "-qm", "module"]);
        let root = root.path();
        git(root, &["init", "-q"]);
        std::fs::write(root.join(".gitignore"), "*.o\n").unwrap();
        git(root, &["add", "."]);
        git(
            root,
            &[
                "-c",
                "protocol.file.allow=always",
                "submodule",
                "add",
                "-q",
                module.path().to_str().unwrap(),
                "module",
            ],
        );
        git(root, &["commit", "-qm", "baseline"]);
        std::fs::write(root.join("module/out.o"), "object\n").unwrap();
        std::fs::write(root.join("pinned.o"), "object\n").unwrap();
        let mut repo = Repository::new(root, 1048576).unwrap();
        repo.handle("initialize", &json!({"protocol":4})).unwrap();
        repo.handle(
            "comparison/open",
            &json!({"view_id":"one","file":"pinned.o"}),
        )
        .unwrap();
        let changed = paths(&["module/out.o", "pinned.o"]);
        assert_eq!(reconcilable(&mut repo, &changed), changed);
    }

    #[test]
    fn view_updates_reopen_only_newly_visible_stale_comparisons() {
        let root = tempfile::tempdir().unwrap();
        git(root.path(), &["init", "-q"]);
        std::fs::write(root.path().join("file.txt"), "changed\n").unwrap();
        let mut repo = Repository::new(root.path(), 1048576).unwrap();
        repo.handle("initialize", &json!({"protocol":4})).unwrap();
        let snapshot = repo
            .handle(
                "comparison/open",
                &json!({"view_id":"one","untracked":true}),
            )
            .unwrap();
        let id = snapshot["comparison_id"].as_str().unwrap();
        let interval = Duration::from_secs(30);
        let visible = repo.visible();
        assert!(visible.contains(id));
        assert!(!reopened(&repo, "view/update", &visible, interval));
        assert!(!reopened(&repo, "comparison/open", &visible, interval));
        repo.invalidate();
        assert!(!reopened(&repo, "view/update", &visible, interval));
        assert!(reopened(&repo, "comparison/open", &visible, interval));
        assert!(reopened(&repo, "view/update", &BTreeSet::new(), interval));
        repo.handle(
            "view/update",
            &json!({"view_id":"one","comparison_id":id,"visible":false}),
        )
        .unwrap();
        let hidden = repo.visible();
        repo.handle(
            "view/update",
            &json!({"view_id":"one","comparison_id":id,"visible":true}),
        )
        .unwrap();
        assert!(reopened(&repo, "view/update", &hidden, interval));
    }

    #[test]
    fn events_extend_batches_but_never_delay_a_queued_full_reconciliation() {
        let root = tempfile::tempdir().unwrap();
        git(root.path(), &["init", "-q"]);
        let mut repo = Repository::new(root.path(), 1048576).unwrap();
        let file = repo.root.join("file.txt");
        let event = || {
            Ok(
                notify::Event::new(notify::EventKind::Modify(notify::event::ModifyKind::Any))
                    .add_path(file.clone()),
            )
        };
        let start = Instant::now();
        let mut pending = Pending::default();
        pending.event(&mut repo, event(), start);
        assert_eq!(pending.due, Some(start + Duration::from_millis(100)));
        pending.event(&mut repo, event(), start + Duration::from_millis(80));
        assert_eq!(pending.due, Some(start + Duration::from_millis(180)));
        pending.event(&mut repo, event(), start + Duration::from_millis(200));
        assert_eq!(pending.due, Some(start + Duration::from_millis(250)));
        let mut pending = Pending::default();
        pending.full("reopen");
        let due = pending.due.unwrap();
        pending.event(&mut repo, event(), Instant::now());
        assert_eq!(pending.due, Some(due));
        let index = repo.git_dir.join("index");
        let mut pending = Pending::default();
        pending.event(&mut repo, event(), start);
        pending.event(
            &mut repo,
            Ok(
                notify::Event::new(notify::EventKind::Modify(notify::event::ModifyKind::Any))
                    .add_path(index),
            ),
            start + Duration::from_millis(90),
        );
        assert!(pending.full);
        assert_eq!(pending.due, Some(start + Duration::from_millis(100)));
    }

    #[test]
    fn failed_ignore_query_keeps_every_path() {
        let root = tempfile::tempdir().unwrap();
        let root = root.path();
        git(root, &["init", "-q"]);
        std::fs::write(root.join(".gitignore"), "*.o\n").unwrap();
        std::fs::create_dir(root.join("real")).unwrap();
        std::os::unix::fs::symlink("real", root.join("link")).unwrap();
        git(root, &["add", "."]);
        git(root, &["commit", "-qm", "baseline"]);
        std::fs::write(root.join("real/out.o"), "object\n").unwrap();
        let mut repo = Repository::new(root, 1048576).unwrap();
        repo.handle("initialize", &json!({"protocol":4})).unwrap();
        repo.handle("comparison/open", &json!({"view_id":"one"}))
            .unwrap();
        let changed = paths(&["link/out.o", "real/out.o"]);
        assert!(repo.ignored(&changed).is_err());
        assert_eq!(reconcilable(&mut repo, &changed), changed);
        let id = repo.comparisons.keys().next().unwrap().clone();
        assert!(repo.comparisons[&id].error.is_none());
    }
}
