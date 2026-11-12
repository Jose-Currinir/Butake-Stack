use crate::{
    logs::{self, Logs, LOG_LIMIT},
    model::validate_id,
};
use anyhow::{ensure, Result};
use serde::Serialize;
use serde_json::{json, Value};
use std::os::unix::process::CommandExt;
use std::{
    collections::{BTreeMap, VecDeque},
    path::PathBuf,
    process::Stdio,
    sync::{Arc, Mutex as StdMutex},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use tokio::{
    process::{Child, Command},
    sync::{broadcast, watch, Mutex},
    task::JoinHandle,
};

#[derive(Clone, Serialize)]
pub struct ProcessSpec {
    pub id: String,
    pub executable: PathBuf,
    pub args: Vec<String>,
    pub cwd: PathBuf,
    pub autostart: bool,
    pub restart_on_exit: bool,
    pub environment: BTreeMap<String, String>,
    /// Descriptors handed to the child as 3, 4, … (sockets from launchd for Caddy).
    #[serde(skip)]
    pub inherit: Vec<i32>,
    /// Seconds to wait after SIGTERM before SIGKILL (databases need time to flush).
    pub stop_timeout: u64,
}

impl ProcessSpec {
    /// Same command, environment and descriptors: a running process can be kept on reload.
    fn same_as(&self, other: &ProcessSpec) -> bool {
        self.inherit == other.inherit
            && serde_json::to_value(self).ok() == serde_json::to_value(other).ok()
    }
}
#[derive(Clone, Serialize)]
pub struct ProcessState {
    pub id: String,
    pub state: String,
    pub pid: Option<u32>,
    pub restarts: u32,
    pub started: Option<u64>,
}
struct Entry {
    spec: ProcessSpec,
    state: Arc<Mutex<ProcessState>>,
    logs: Arc<StdMutex<Logs>>,
    stop: Option<watch::Sender<bool>>,
    task: Option<JoinHandle<()>>,
}
pub struct Supervisor {
    entries: BTreeMap<String, Entry>,
    order: Vec<String>,
    log_dir: PathBuf,
    pub events: broadcast::Sender<Value>,
}
pub fn validate_process_id(id: &str) -> Result<()> {
    let parts: Vec<_> = id.split('.').collect();
    ensure!(parts.len() == 2, "invalid_process_id");
    for part in parts {
        validate_id(part)?;
    }
    Ok(())
}

impl Supervisor {
    pub fn new(log_dir: PathBuf) -> Self {
        Self {
            entries: BTreeMap::new(),
            order: vec![],
            log_dir,
            events: broadcast::channel(4096).0,
        }
    }
    pub async fn reload(&mut self, specs: Vec<ProcessSpec>) -> Result<()> {
        let spec_order: Vec<String> = specs.iter().map(|s| s.id.clone()).collect();
        let mut ids = std::collections::HashSet::new();
        for spec in &specs {
            validate_process_id(&spec.id)?;
            ensure!(ids.insert(&spec.id), "duplicate_process");
            if spec.autostart {
                ensure!(
                    spec.executable.canonicalize()?.is_file(),
                    "invalid_executable"
                );
                ensure!(spec.cwd.canonicalize()?.is_dir(), "invalid_path");
            }
        }
        // Keep unchanged processes running; stop only what changed or disappeared, in reverse
        // start order, so editing one site never restarts the others.
        let mut keep = std::collections::HashSet::new();
        for spec in &specs {
            if let Some(entry) = self.entries.get(&spec.id) {
                if entry.spec.same_as(spec) {
                    keep.insert(spec.id.clone());
                }
            }
        }
        for id in self.order.clone().into_iter().rev() {
            if !keep.contains(&id) {
                let _ = self.stop(&id).await;
            }
        }
        self.order.retain(|id| keep.contains(id));
        let mut entries = BTreeMap::new();
        for spec in specs {
            if keep.contains(&spec.id) {
                if let Some(entry) = self.entries.remove(&spec.id) {
                    entries.insert(spec.id.clone(), entry);
                    continue;
                }
            }
            let state = Arc::new(Mutex::new(ProcessState {
                id: spec.id.clone(),
                state: "stopped".into(),
                pid: None,
                restarts: 0,
                started: None,
            }));
            let logs = Arc::new(StdMutex::new(Logs::new(
                self.log_dir.join(format!("{}.log", spec.id)),
                LOG_LIMIT,
            )?));
            entries.insert(
                spec.id.clone(),
                Entry {
                    spec,
                    state,
                    logs,
                    stop: None,
                    task: None,
                },
            );
        }
        self.entries = entries;
        // Specs arrive in dependency order (engines, php-fpm, Caddy, then sites).
        let autostart: Vec<_> = spec_order
            .into_iter()
            .filter(|id| !keep.contains(id))
            .filter(|id| self.entries.get(id).is_some_and(|e| e.spec.autostart))
            .collect();
        for id in autostart {
            self.start(&id).await?;
        }
        Ok(())
    }
    pub async fn status(&self) -> Vec<Value> {
        let mut states = vec![];
        for entry in self.entries.values() {
            // The environment can carry the site's secrets (from its .env): it never leaves the daemon.
            let mut spec = serde_json::to_value(&entry.spec).unwrap_or_default();
            if let Some(object) = spec.as_object_mut() {
                object.remove("environment");
            }
            states.push(json!({"spec":spec,"status":entry.state.lock().await.clone()}));
        }
        states
    }
    pub async fn start(&mut self, id: &str) -> Result<()> {
        validate_process_id(id)?;
        let entry = self
            .entries
            .get_mut(id)
            .ok_or_else(|| anyhow::anyhow!("unknown_process"))?;
        if entry.task.as_ref().is_some_and(|task| !task.is_finished()) {
            return Ok(());
        }
        let executable = entry.spec.executable.canonicalize()?;
        ensure!(executable.is_file(), "invalid_executable");
        let cwd = entry.spec.cwd.canonicalize()?;
        ensure!(cwd.is_dir(), "invalid_path");
        let mut spec = entry.spec.clone();
        spec.executable = executable;
        spec.cwd = cwd;
        let (tx, rx) = watch::channel(false);
        entry.stop = Some(tx);
        let state = entry.state.clone();
        let logs = entry.logs.clone();
        let events = self.events.clone();
        entry.task = Some(tokio::spawn(async move {
            supervise(spec, state, logs, events, rx).await;
        }));
        self.order.retain(|key| key != id);
        self.order.push(id.into());
        Ok(())
    }
    pub async fn stop(&mut self, id: &str) -> Result<()> {
        validate_process_id(id)?;
        let entry = self
            .entries
            .get_mut(id)
            .ok_or_else(|| anyhow::anyhow!("unknown_process"))?;
        if let Some(stop) = entry.stop.take() {
            let _ = stop.send(true);
        }
        if let Some(task) = entry.task.take() {
            task.await?;
        }
        transition(&entry.state, &self.events, "stopped", None).await;
        Ok(())
    }
    pub async fn restart(&mut self, id: &str) -> Result<()> {
        self.stop(id).await?;
        self.start(id).await
    }
    pub fn logs(&self, id: &str, tail: usize) -> Result<Vec<String>> {
        validate_process_id(id)?;
        let entry = self
            .entries
            .get(id)
            .ok_or_else(|| anyhow::anyhow!("unknown_process"))?;
        let logs = entry.logs.lock().map_err(|_| anyhow::anyhow!("log_lock"))?;
        Ok(logs.tail(tail))
    }
    pub async fn shutdown(&mut self) {
        for id in self.order.clone().into_iter().rev() {
            let _ = self.stop(&id).await;
        }
        self.order.clear();
    }
}
async fn transition(
    state: &Arc<Mutex<ProcessState>>,
    events: &broadcast::Sender<Value>,
    next: &str,
    pid: Option<u32>,
) {
    let mut state = state.lock().await;
    state.state = next.into();
    state.pid = pid;
    if next == "running" {
        state.started = Some(
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs(),
        );
    }
    let _ = events.send(json!({"event":"process.state","value":state.clone()}));
}
/// Where the daemon notes the processes it started (`run/pids/<id>`: pid and executable image).
/// If the daemon dies without stopping them (launchd's SIGKILL on restart or update), the next one
/// finds them here and stops them before starting its own, so no stale MySQL, Caddy or php-fpm
/// keeps a port or a datadir.
pub static PID_DIR: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();

fn image(pid: u32) -> Option<String> {
    let mut buffer = vec![0u8; 4096];
    let length = unsafe { libc::proc_pidpath(pid as i32, buffer.as_mut_ptr().cast(), buffer.len() as u32) };
    (length > 0).then(|| String::from_utf8_lossy(&buffer[..length as usize]).into_owned())
}
fn alive(pid: u32) -> bool {
    unsafe { libc::kill(pid as i32, 0) == 0 }
}
fn record(id: &str, pid: u32) {
    if let (Some(dir), Some(image)) = (PID_DIR.get(), image(pid)) {
        let _ = std::fs::create_dir_all(dir);
        let _ = std::fs::write(dir.join(id), format!("{pid}\n{image}\n"));
    }
}
fn forget(id: &str) {
    if let Some(dir) = PID_DIR.get() {
        let _ = std::fs::remove_file(dir.join(id));
    }
}
/// Stops what a previous daemon left running. A pid only counts if it still runs the same image,
/// so a recycled pid of an unrelated program is never touched.
pub async fn reap_orphans() {
    let Some(dir) = PID_DIR.get() else { return };
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    let mut orphans = vec![];
    for entry in entries.flatten() {
        let text = std::fs::read_to_string(entry.path()).unwrap_or_default();
        let mut lines = text.lines();
        if let (Some(Ok(pid)), Some(recorded)) = (lines.next().map(str::parse::<u32>), lines.next()) {
            if pid > 1 && alive(pid) && image(pid).as_deref() == Some(recorded) {
                kill_group(pid, libc::SIGTERM);
                orphans.push(pid);
            }
        }
        let _ = std::fs::remove_file(entry.path());
    }
    // Databases flush on SIGTERM; give them the same grace as a normal stop.
    let deadline = Instant::now() + Duration::from_secs(30);
    while orphans.iter().any(|pid| alive(*pid)) && Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    for pid in orphans {
        kill_group(pid, libc::SIGKILL);
    }
}
fn kill_group(pid: u32, signal: i32) {
    unsafe {
        libc::kill(-(pid as i32), signal);
    }
}
async fn terminate(child: &mut Child, pid: u32, grace: u64) {
    kill_group(pid, libc::SIGTERM);
    if tokio::time::timeout(Duration::from_secs(grace.max(1)), child.wait())
        .await
        .is_err()
    {
        kill_group(pid, libc::SIGKILL);
        let _ = child.wait().await;
    }
    // The group leader may exit while descendants ignore SIGTERM.
    kill_group(pid, libc::SIGKILL);
}
async fn supervise(
    spec: ProcessSpec,
    state: Arc<Mutex<ProcessState>>,
    logs: Arc<StdMutex<Logs>>,
    events: broadcast::Sender<Value>,
    mut stop: watch::Receiver<bool>,
) {
    let mut crashes = VecDeque::new();
    let mut delay = 1;
    loop {
        if *stop.borrow() {
            break;
        }
        transition(&state, &events, "starting", None).await;
        let mut command = Command::new(&spec.executable);
        command
            .args(&spec.args)
            .current_dir(&spec.cwd)
            .env_clear()
            .env("HOME", dirs::home_dir().unwrap_or_else(|| spec.cwd.clone()))
            .env("LANG", "en_US.UTF-8")
            .env("PATH", spec.executable.parent().unwrap())
            .envs(&spec.environment)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        command.as_std_mut().process_group(0);
        if !spec.inherit.is_empty() {
            let fds = spec.inherit.clone();
            // Safety: only async-signal-safe calls (fcntl/dup2) between fork and exec.
            unsafe {
                command.as_std_mut().pre_exec(move || {
                    let mut high = Vec::with_capacity(fds.len());
                    for fd in &fds {
                        let copy = libc::fcntl(*fd, libc::F_DUPFD, 100);
                        if copy < 0 {
                            return Err(std::io::Error::last_os_error());
                        }
                        high.push(copy);
                    }
                    for (index, fd) in high.iter().enumerate() {
                        if libc::dup2(*fd, 3 + index as i32) < 0 {
                            return Err(std::io::Error::last_os_error());
                        }
                    }
                    Ok(())
                });
            }
        }
        if let Ok(mut child) = command.spawn() {
            let pid = child.id().unwrap();
            record(&spec.id, pid);
            transition(&state, &events, "running", Some(pid)).await;
            let out = tokio::spawn(logs::capture(
                child.stdout.take().unwrap(),
                spec.id.clone(),
                logs.clone(),
                events.clone(),
            ));
            let err = tokio::spawn(logs::capture(
                child.stderr.take().unwrap(),
                spec.id.clone(),
                logs.clone(),
                events.clone(),
            ));
            let (stopping, success) = tokio::select! { biased;
                _ = stop.changed() => (true, false),
                result = child.wait() => (false, result.is_ok_and(|status| status.success())),
            };
            if stopping {
                transition(&state, &events, "stopping", Some(pid)).await;
                terminate(&mut child, pid, spec.stop_timeout).await;
            } else {
                kill_group(pid, libc::SIGKILL);
            }
            forget(&spec.id);
            let _ = out.await;
            let _ = err.await;
            if stopping {
                break;
            }
            if !spec.restart_on_exit {
                transition(
                    &state,
                    &events,
                    if success { "stopped" } else { "crashed" },
                    None,
                )
                .await;
                return;
            }
        }
        if !spec.restart_on_exit {
            transition(&state, &events, "crashed", None).await;
            return;
        }
        let now = Instant::now();
        crashes.push_back(now);
        while crashes
            .front()
            .is_some_and(|t| now.duration_since(*t) > Duration::from_secs(60))
        {
            crashes.pop_front();
        }
        transition(&state, &events, "crashed", None).await;
        if crashes.len() >= 5 {
            return;
        }
        tokio::select! { biased;
            _ = stop.changed() => break,
            _ = tokio::time::sleep(Duration::from_secs(delay)) => {},
        }
        state.lock().await.restarts += 1;
        delay = (delay * 2).min(30);
    }
    transition(&state, &events, "stopped", None).await;
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn one_shot_jobs_do_not_restart() {
        let temp = tempfile::tempdir().unwrap();
        let mut supervisor = Supervisor::new(temp.path().into());
        supervisor
            .reload(vec![ProcessSpec {
                id: "job.once".into(),
                executable: "/usr/bin/true".into(),
                args: vec![],
                cwd: temp.path().into(),
                autostart: true,
                restart_on_exit: false,
                environment: BTreeMap::new(),
                inherit: vec![],
                stop_timeout: 10,
            }])
            .await
            .unwrap();
        let entry = supervisor.entries.get("job.once").unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while !entry.task.as_ref().unwrap().is_finished() {
            assert!(Instant::now() < deadline);
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        let state = entry.state.lock().await.clone();
        assert_eq!(state.state, "stopped");
        assert_eq!(state.restarts, 0);
        supervisor.shutdown().await;
    }
    #[tokio::test]
    async fn reload_keeps_unchanged_processes() {
        let temp = tempfile::tempdir().unwrap();
        let mut supervisor = Supervisor::new(temp.path().into());
        let spec = |id: &str, arg: &str| ProcessSpec {
            id: id.into(),
            executable: "/bin/sleep".into(),
            args: vec![arg.into()],
            cwd: temp.path().into(),
            autostart: true,
            restart_on_exit: true,
            environment: BTreeMap::new(),
            inherit: vec![],
            stop_timeout: 2,
        };
        supervisor.reload(vec![spec("a.one", "60"), spec("a.two", "60")]).await.unwrap();
        tokio::time::sleep(Duration::from_millis(300)).await;
        let pid = |s: &Supervisor, id: &str| {
            let state = s.entries.get(id).unwrap().state.clone();
            async move { state.lock().await.pid }
        };
        let one = pid(&supervisor, "a.one").await;
        let two = pid(&supervisor, "a.two").await;
        assert!(one.is_some() && two.is_some());
        supervisor.reload(vec![spec("a.one", "60"), spec("a.two", "61")]).await.unwrap();
        tokio::time::sleep(Duration::from_millis(300)).await;
        assert_eq!(pid(&supervisor, "a.one").await, one, "unchanged process keeps running");
        assert_ne!(pid(&supervisor, "a.two").await, two, "changed process restarts");
        supervisor.reload(vec![spec("a.one", "60")]).await.unwrap();
        assert!(supervisor.entries.get("a.two").is_none());
        supervisor.shutdown().await;
    }
}
