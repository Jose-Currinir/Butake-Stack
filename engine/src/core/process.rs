//! Child processes: executable and arguments always separate (never a shell line), a small
//! explicit environment, and output that cannot grow without bound.

use super::watch;
use anyhow::Result;
use std::{
    ffi::OsStr,
    fs::{File, OpenOptions},
    io::{Read, Write},
    os::unix::process::CommandExt,
    path::Path,
    process::{Command, Stdio},
    sync::{atomic::Ordering, mpsc},
    time::{Duration, Instant},
};

/// Output of one captured run.
pub struct Captured {
    pub stdout: String,
    /// At most 64 KiB of what the process wrote on stderr.
    pub stderr: String,
    /// The process exited with success and its output was not cut.
    pub success: bool,
    /// The exit code (`None` when a signal ended it).
    pub code: Option<i32>,
    /// Stdout reached `max_output` and the process was killed.
    pub cut: bool,
    /// The run passed its time limit and its process group was ended (see [`capture_watched`]).
    pub timed_out: bool,
    /// The app stopped the request and the process group was ended (see [`capture_watched`]).
    pub cancelled: bool,
}

/// Keeps the first 64 KiB of a stderr pipe (lossy UTF-8) and discards the rest, so a chatty child
/// never blocks on a full pipe.
fn read_stderr(stderr: &mut impl Read) -> String {
    let mut bytes = Vec::new();
    let _ = stderr.take(64 * 1024).read_to_end(&mut bytes);
    let _ = std::io::copy(stderr, &mut std::io::sink());
    String::from_utf8_lossy(&bytes).into_owned()
}

/// Runs `command` with `input` on stdin and reads at most `max_output` bytes of stdout; past
/// that the process is killed and the run reports `cut`. `not_installed` is the error when the
/// program cannot be started.
pub fn capture(
    command: Command,
    input: &[u8],
    max_output: u64,
    not_installed: &'static str,
) -> Result<Captured> {
    capture_limited(command, input, max_output, None, not_installed)
}

/// [`capture`] with a time limit: past `limit` the process is killed and the run reports
/// `timed_out` (a server that does not answer, a statement waiting for a lock).
pub fn capture_limited(
    mut command: Command,
    input: &[u8],
    max_output: u64,
    limit: Option<Duration>,
    not_installed: &'static str,
) -> Result<Captured> {
    let mut child = command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|_| anyhow::anyhow!(not_installed))?;
    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| anyhow::anyhow!("invalid_request"))?;
    let finished = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let expired = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    if let (Some(limit), Ok(pid)) = (limit, i32::try_from(child.id())) {
        let (finished, expired) = (finished.clone(), expired.clone());
        std::thread::spawn(move || {
            let deadline = Instant::now() + limit;
            while !finished.load(Ordering::SeqCst) {
                if Instant::now() >= deadline {
                    expired.store(true, Ordering::SeqCst);
                    // SAFETY: `kill` takes two integers and touches no memory; `pid` is the
                    // child's, still not reaped because `finished` is only set after `wait`.
                    unsafe { libc::kill(pid, libc::SIGKILL) };
                    return;
                }
                std::thread::sleep(Duration::from_millis(50));
            }
        });
    }
    let input = input.to_vec();
    let writer = std::thread::spawn(move || {
        let _ = stdin.write_all(&input);
    });
    let mut stderr = child
        .stderr
        .take()
        .ok_or_else(|| anyhow::anyhow!("invalid_request"))?;
    let errors = std::thread::spawn(move || read_stderr(&mut stderr));
    let mut out = Vec::new();
    let mut stdout = child
        .stdout
        .take()
        .ok_or_else(|| anyhow::anyhow!("invalid_request"))?;
    // One byte past the limit tells "cut" from "exactly the limit".
    let read = (&mut stdout)
        .take(max_output.saturating_add(1))
        .read_to_end(&mut out);
    let cut = out.len() as u64 > max_output;
    out.truncate(usize::try_from(max_output).unwrap_or(usize::MAX));
    if cut || read.is_err() {
        let _ = child.kill();
    }
    drop(stdout);
    let status = child.wait();
    finished.store(true, Ordering::SeqCst);
    let timed_out = expired.load(Ordering::SeqCst);
    let _ = writer.join();
    let stderr = errors.join().unwrap_or_default();
    read?;
    let status = status?;
    Ok(Captured {
        stdout: String::from_utf8_lossy(&out).into_owned(),
        stderr,
        success: status.success() && !cut && !timed_out,
        code: status.code(),
        cut,
        timed_out,
        cancelled: false,
    })
}

/// Runs `command` with nothing on stdin, in a process group of its own, until it ends, `limit`
/// passes (`timed_out`) or the app stops the request (`cancelled`: SIGTERM to this engine, or the
/// app is gone; see [`watch`](super::watch)). Either way the whole group is ended before this
/// returns. While it runs, a record in `records` lets a later request end the group if this
/// engine dies first. Stdout keeps at most `max_output` bytes and stderr 64 KiB.
pub fn capture_watched(
    command: Command,
    max_output: u64,
    limit: Duration,
    not_installed: &'static str,
    records: Option<&Path>,
) -> Result<Captured> {
    let parent = watch::listen();
    capture_until(command, max_output, limit, not_installed, records, &|| {
        watch::stop_requested(parent)
    })
}

fn capture_until(
    mut command: Command,
    max_output: u64,
    limit: Duration,
    not_installed: &'static str,
    records: Option<&Path>,
    stop: &dyn Fn() -> bool,
) -> Result<Captured> {
    if let Some(folder) = records {
        watch::reap(folder);
    }
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0)
        .spawn()
        .map_err(|_| anyhow::anyhow!(not_installed))?;
    // The group is the child's own (process_group(0)): its pid.
    let group = i32::try_from(child.id()).unwrap_or(0);
    let record = records.and_then(|folder| watch::Record::write(folder, group).ok());
    let mut stdout = child
        .stdout
        .take()
        .ok_or_else(|| anyhow::anyhow!("invalid_request"))?;
    let mut stderr = child
        .stderr
        .take()
        .ok_or_else(|| anyhow::anyhow!("invalid_request"))?;
    let (out_sender, out_receiver) = mpsc::channel();
    std::thread::spawn(move || {
        let mut out = Vec::new();
        let _ = (&mut stdout)
            .take(max_output.saturating_add(1))
            .read_to_end(&mut out);
        let _ = out_sender.send(out);
    });
    let (err_sender, err_receiver) = mpsc::channel();
    std::thread::spawn(move || {
        let _ = err_sender.send(read_stderr(&mut stderr));
    });
    let deadline = Instant::now() + limit;
    let (mut timed_out, mut cancelled) = (false, false);
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        timed_out = Instant::now() >= deadline;
        cancelled = !timed_out && stop();
        if timed_out || cancelled {
            watch::end_group(group);
            break child.wait()?;
        }
        std::thread::sleep(Duration::from_millis(50));
    };
    // What the child left running in its group ends with it.
    if watch::group_alive(group) {
        watch::end_group(group);
    }
    if let Some(record) = record {
        let _ = std::fs::remove_file(record);
    }
    // A grandchild that kept the pipes open does not hold the caller.
    let mut out = out_receiver
        .recv_timeout(Duration::from_secs(2))
        .unwrap_or_default();
    let stderr = err_receiver
        .recv_timeout(Duration::from_secs(2))
        .unwrap_or_default();
    let cut = out.len() as u64 > max_output;
    out.truncate(usize::try_from(max_output).unwrap_or(usize::MAX));
    // A stop that arrived while the child was ending is still a stop: the caller must not go on
    // to the next step as if nothing had been asked.
    let cancelled = cancelled || (!timed_out && stop());
    Ok(Captured {
        stdout: String::from_utf8_lossy(&out).into_owned(),
        stderr,
        success: status.success() && !cut && !timed_out && !cancelled,
        code: status.code(),
        cut,
        timed_out,
        cancelled,
    })
}

/// A log file opened for appending (created when missing), to receive a child's output.
pub fn append_log(path: &Path) -> Result<File> {
    Ok(OpenOptions::new().create(true).append(true).open(path)?)
}

/// Clears the environment of `command` and gives it only `HOME`, `PATH` and a UTF-8 locale.
pub fn minimal_environment(
    command: &mut Command,
    home: impl AsRef<OsStr>,
    path: impl AsRef<OsStr>,
) {
    command
        .env_clear()
        .env("HOME", home)
        .env("PATH", path)
        .env("LANG", "en_US.UTF-8");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn captures_output_input_and_failure() {
        let mut cat = Command::new("/bin/cat");
        cat.env_clear();
        let done = capture(cat, b"hola", 1024, "missing").unwrap();
        assert_eq!(
            (done.stdout.as_str(), done.success, done.cut),
            ("hola", true, false)
        );
        let mut fail = Command::new("/bin/sh");
        fail.args(["-c", "echo bad >&2; exit 3"]).env_clear();
        let done = capture(fail, b"", 1024, "missing").unwrap();
        assert!(!done.success && done.stderr.trim() == "bad");
    }

    #[test]
    fn a_chatty_stderr_does_not_block_the_run_and_exact_output_is_not_cut() {
        let mut noisy = Command::new("/bin/sh");
        noisy
            .args([
                "-c",
                "head -c 300000 /dev/zero | tr '\\0' e >&2; printf abc",
            ])
            .env_clear();
        let done = capture(noisy, b"", 3, "missing").unwrap();
        assert_eq!(done.stdout, "abc");
        assert!(done.success && !done.cut);
        assert_eq!(done.stderr.len(), 64 * 1024);
    }

    #[test]
    fn a_run_past_its_limit_is_killed_and_says_so() {
        let mut slow = Command::new("/bin/sleep");
        slow.arg("30").env_clear();
        let start = Instant::now();
        let done =
            capture_limited(slow, b"", 1024, Some(Duration::from_millis(300)), "missing").unwrap();
        assert!(done.timed_out && !done.success);
        assert!(start.elapsed() < Duration::from_secs(5));
        let mut quick = Command::new("/bin/echo");
        quick.arg("ok").env_clear();
        let done =
            capture_limited(quick, b"", 1024, Some(Duration::from_secs(30)), "missing").unwrap();
        assert!(done.success && !done.timed_out);
    }

    #[test]
    fn output_is_cut_and_missing_programs_report_the_given_code() {
        let mut yes = Command::new("/usr/bin/yes");
        yes.env_clear();
        let done = capture(yes, b"", 1000, "missing").unwrap();
        assert!(done.cut && !done.success && done.stdout.len() == 1000);
        let error = capture(Command::new("/nonexistent/x"), b"", 10, "missing");
        assert_eq!(error.err().unwrap().to_string(), "missing");
    }

    /// Pids of a fake that starts a child and waits: `<pid of sh> <pid of its child>`.
    fn waiting_fake(pids: &Path) -> Command {
        let mut sh = Command::new("/bin/sh");
        sh.args([
            "-c",
            &format!("/bin/sleep 30 & echo $$ $! > '{}'; wait", pids.display()),
        ])
        .env_clear();
        sh
    }

    fn pids(path: &Path) -> Vec<i32> {
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            let text = std::fs::read_to_string(path).unwrap_or_default();
            let pids: Vec<i32> = text
                .split_whitespace()
                .filter_map(|p| p.parse().ok())
                .collect();
            if pids.len() == 2 || Instant::now() > deadline {
                return pids;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    fn alive(pid: i32) -> bool {
        // A process that ended and was not reaped yet (a zombie) has no start time.
        // SAFETY: `kill` with signal 0 sends nothing; it only reports whether `pid` exists.
        watch::started(pid).is_some() && unsafe { libc::kill(pid, 0) } == 0
    }

    #[test]
    fn a_stop_that_arrives_as_the_child_ends_is_reported() {
        let temp = tempfile::tempdir().unwrap();
        let flag = temp.path().join("stop");
        let mut quick = Command::new("/bin/sh");
        quick
            .args(["-c", &format!("sleep 0.1; : > '{}'", flag.display())])
            .env_clear();
        let done = capture_until(
            quick,
            1024,
            Duration::from_secs(5),
            "missing",
            None,
            &|| flag.exists(),
        )
        .unwrap();
        assert!(done.cancelled && !done.success && !done.timed_out);
    }

    #[test]
    fn watched_runs_end_at_their_limit_or_when_stopped_and_leave_nothing() {
        let temp = tempfile::tempdir().unwrap();
        let mut echo = Command::new("/bin/echo");
        echo.arg("listo").env_clear();
        let done = capture_until(
            echo,
            1024,
            Duration::from_secs(5),
            "missing",
            Some(temp.path()),
            &|| false,
        )
        .unwrap();
        assert!(
            done.success && !done.timed_out && !done.cancelled && done.stdout.trim() == "listo"
        );

        // The limit: the fake and its child end, with their own flag.
        let file = temp.path().join("a.pids");
        let start = Instant::now();
        let done = capture_until(
            waiting_fake(&file),
            1024,
            Duration::from_millis(400),
            "missing",
            Some(temp.path()),
            &|| false,
        )
        .unwrap();
        assert!(done.timed_out && !done.cancelled && !done.success);
        assert!(start.elapsed() < Duration::from_secs(5));
        let ended = pids(&file);
        assert_eq!(ended.len(), 2);
        assert!(ended.iter().all(|pid| !alive(*pid)), "{ended:?}");

        // Stopped by the app: the same, with `cancelled`.
        let file = temp.path().join("b.pids");
        let since = Instant::now();
        let stop = || since.elapsed() > Duration::from_millis(300);
        let done = capture_until(
            waiting_fake(&file),
            1024,
            Duration::from_secs(30),
            "missing",
            Some(temp.path()),
            &stop,
        )
        .unwrap();
        assert!(done.cancelled && !done.timed_out && !done.success);
        let ended = pids(&file);
        assert_eq!(ended.len(), 2);
        assert!(ended.iter().all(|pid| !alive(*pid)), "{ended:?}");
        // No record is left behind.
        assert!(!std::fs::read_dir(temp.path()).unwrap().any(|e| e
            .unwrap()
            .path()
            .extension()
            .is_some_and(|x| x == "json")));

        let error = capture_until(
            Command::new("/nonexistent/x"),
            10,
            Duration::from_secs(1),
            "missing",
            None,
            &|| false,
        );
        assert_eq!(error.err().unwrap().to_string(), "missing");
    }

    #[test]
    fn the_environment_is_only_what_was_given() {
        let mut env = Command::new("/usr/bin/env");
        minimal_environment(&mut env, "/h", "/usr/bin");
        env.env("SECRET", "x");
        let done = capture(env, b"", 4096, "missing").unwrap();
        let lines: std::collections::BTreeSet<_> = done.stdout.lines().collect();
        assert!(lines.contains("HOME=/h") && lines.contains("PATH=/usr/bin"));
        assert!(lines.contains("SECRET=x"));
        assert!(!lines.iter().any(|l| l.starts_with("USER=")));
    }
}
