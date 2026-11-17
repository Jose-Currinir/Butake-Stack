//! Progress of a long operation (installing a utility or a version) as the app follows it: marker
//! lines in the operation's log, the same log the app already reads with `stepLog` while a
//! project is created.
//!
//! - `@step <code>` starts a step (stable codes the app translates); `@step <code> fixed` is one
//!   that cannot be stopped halfway (placing what was checked), so the app disables «Cancelar».
//! - `@bytes <done> <total|->` is a download's progress (the last one counts).
//! - Every other line is the operation's own output (make, the installer's notes), never secrets.
//!
//! The app stops an operation by sending SIGTERM to its engine (or by disappearing): children run
//! through [`run`] in their own process group and end with it, and the operation's error paths
//! remove what it left half done (`install_cancelled`).

use super::watch;
use anyhow::{Result, bail};
use std::{
    fs::OpenOptions,
    io::Write,
    path::{Path, PathBuf},
    process::{Child, Command, ExitStatus},
    sync::{
        Mutex,
        atomic::{AtomicI32, Ordering},
    },
    time::{Duration, Instant},
};

static LOG: Mutex<Option<PathBuf>> = Mutex::new(None);
/// Tests that follow an operation, or that run one that reports, take turns: what is followed is
/// global to the process.
#[cfg(test)]
pub static TEST_TURN: Mutex<()> = Mutex::new(());
/// The parent the engine had when the operation began (0: nothing follows this process).
static PARENT: AtomicI32 = AtomicI32::new(0);

/// From now on this process reports to `log` and stops when the app asks (see the module).
pub fn begin(log: &Path) {
    if let Ok(mut current) = LOG.lock() {
        *current = Some(log.to_path_buf());
    }
    PARENT.store(watch::listen(), Ordering::SeqCst);
}

/// Nothing follows this process any more (tests that began one).
#[cfg(test)]
pub fn end() {
    if let Ok(mut current) = LOG.lock() {
        *current = None;
    }
    PARENT.store(0, Ordering::SeqCst);
    watch::clear_stop();
}

fn write(line: &str) {
    let Some(path) = LOG.lock().ok().and_then(|l| l.clone()) else {
        return;
    };
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(file, "{line}");
    }
}

/// Where a child's output goes: the followed operation's log, or nowhere.
pub fn output() -> std::process::Stdio {
    LOG.lock()
        .ok()
        .and_then(|l| l.clone())
        .and_then(|path| OpenOptions::new().create(true).append(true).open(path).ok())
        .map_or_else(std::process::Stdio::null, std::process::Stdio::from)
}

/// A step that can be stopped halfway.
pub fn step(code: &str) {
    write(&format!("@step {code}"));
}

/// A step that, once started, finishes (it places what was checked).
pub fn fixed_step(code: &str) {
    write(&format!("@step {code} fixed"));
}

/// A download's bytes so far and its size when known.
pub fn bytes(done: u64, total: Option<u64>) {
    write(&format!(
        "@bytes {done} {}",
        total.map_or("-".to_string(), |t| t.to_string())
    ));
}

/// Someone follows this operation (the app).
pub fn followed() -> bool {
    PARENT.load(Ordering::SeqCst) != 0
}

/// The app asked to stop (or is gone).
pub fn stopped() -> bool {
    let parent = PARENT.load(Ordering::SeqCst);
    parent != 0 && watch::stop_requested(parent)
}

/// Between steps: a stop asked for ends the operation here.
pub fn check() -> Result<()> {
    if stopped() {
        bail!("install_cancelled");
    }
    Ok(())
}

/// Runs `command` in its own process group until it ends; `tick` runs every 200 ms meanwhile. A
/// stop ends the whole group and answers `install_cancelled`.
pub fn run(command: &mut Command, mut tick: impl FnMut()) -> Result<ExitStatus> {
    use std::os::unix::process::CommandExt;
    let mut child: Child = command.process_group(0).spawn()?;
    let group = i32::try_from(child.id()).unwrap_or(0);
    let mut last = Instant::now();
    loop {
        if let Some(status) = child.try_wait()? {
            if watch::group_alive(group) {
                watch::end_group(group);
            }
            return Ok(status);
        }
        if stopped() {
            watch::end_group(group);
            let _ = child.wait();
            bail!("install_cancelled");
        }
        if last.elapsed() >= Duration::from_millis(200) {
            tick();
            last = Instant::now();
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// What the app shows of a followed operation, read from its log: the steps started (in order),
/// whether the current one can still be stopped, the last download progress, and the last 200
/// lines of output (control codes removed, the home folder written as `~`).
pub fn read(text: &str, home: Option<&Path>) -> serde_json::Value {
    let mut steps: Vec<String> = vec![];
    let mut fixed = false;
    let mut bytes = serde_json::Value::Null;
    let mut lines: Vec<String> = vec![];
    let home = home
        .map(|h| h.to_string_lossy().into_owned())
        .filter(|h| h.len() > 1);
    for line in text.lines() {
        if let Some(step) = line.strip_prefix("@step ") {
            let mut words = step.split_whitespace();
            steps.push(words.next().unwrap_or("").to_string());
            fixed = words.next() == Some("fixed");
            bytes = serde_json::Value::Null;
        } else if let Some(rest) = line.strip_prefix("@bytes ") {
            let mut words = rest.split_whitespace();
            let done = words.next().and_then(|w| w.parse::<u64>().ok());
            let total = words.next().and_then(|w| w.parse::<u64>().ok());
            bytes = serde_json::json!({"done": done, "total": total});
        } else {
            let line = line.rsplit('\r').next().unwrap_or(line);
            let mut clean: String = line
                .chars()
                .filter(|c| !c.is_control() || *c == '\t')
                .collect();
            if let Some(home) = &home {
                clean = clean.replace(home.as_str(), "~");
            }
            lines.push(clean.chars().take(400).collect());
        }
    }
    let start = lines.len().saturating_sub(200);
    serde_json::json!({"steps": steps, "fixed": fixed, "bytes": bytes, "lines": &lines[start..]})
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_child_runs_reports_and_is_not_stopped_when_nobody_follows() {
        let _turn = TEST_TURN.lock().unwrap_or_else(|e| e.into_inner());
        let mut ticks = 0;
        let status = run(Command::new("/bin/sleep").arg("0.5"), || ticks += 1).unwrap();
        assert!(status.success() && ticks >= 1);
        assert!(!followed() && !stopped() && check().is_ok());
        let read = read(
            "@step download\n@bytes 10 100\n/Users/ana/x listo\n@step verifySum\n@step install fixed\n",
            Some(Path::new("/Users/ana")),
        );
        assert_eq!(
            read["steps"],
            serde_json::json!(["download", "verifySum", "install"])
        );
        assert_eq!(read["fixed"], true);
        assert_eq!(read["lines"], serde_json::json!(["~/x listo"]));
        let read = super::read("@step download\n@bytes 10 100\n", None);
        assert_eq!(read["bytes"]["done"], 10);
        assert_eq!(read["bytes"]["total"], 100);
        assert_eq!(read["fixed"], false);
    }
}
