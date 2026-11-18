//! Forwards of a host: started in their own process group, kept alive with a growing wait, stopped and healed after a restart.

use super::*;

#[derive(Serialize, Deserialize)]
pub(super) struct ForwardState {
    /// 0 while a kept-alive forward waits for its next attempt.
    pid: i32,
    spec: String,
    started: u64,
    #[serde(default)]
    failures: u32,
    #[serde(default)]
    retry_at: u64,
    #[serde(default)]
    error: String,
}

pub(super) fn state_file(store: &Store, host: &str, forward: &str) -> Result<PathBuf> {
    ensure!(
        validate::id(host, MAX_ID) && validate::id(forward, MAX_ID),
        "invalid_forward"
    );
    Ok(store
        .directory("run")?
        .join(format!("forward-{host}--{forward}.json")))
}

pub(super) fn read_state(store: &Store, host: &str, forward: &str) -> Option<ForwardState> {
    let path = state_file(store, host, forward).ok()?;
    serde_json::from_slice(&std::fs::read(path).ok()?).ok()
}

pub fn stop_forward(store: &Store, host: &str, forward: &str) {
    if let Some(state) = read_state(store, host, forward)
        && alive(state.pid)
        && is_forward_process(state.pid)
    {
        // SAFETY: `alive` guarantees `pid > 0`, so this signals one process only, and
        // `is_forward_process` that it is a forward's own ssh and not a reused pid.
        unsafe { libc::kill(state.pid, libc::SIGTERM) };
    }
    if let Ok(path) = state_file(store, host, forward) {
        let _ = std::fs::remove_file(path.with_extension("log"));
        let _ = std::fs::remove_file(path);
    }
}

pub fn stop_all(store: &Store) {
    for host in list(store).unwrap_or_default() {
        for forward in &host.forwards {
            stop_forward(store, &host.id, &forward.id);
        }
    }
}

/// Starts a saved forward with `ssh -N` (BatchMode: nothing is asked on a terminal; a key with a
/// passphrase works once it is in the agent). Local and dynamic forwards are ready once their
/// port answers; a remote one once ssh stays up (with ExitOnForwardFailure it exits if the server
/// refuses the port).
pub fn start_forward(store: &Store, host_id: &str, forward_id: &str) -> Result<u64> {
    let host = find(store, host_id)?;
    let forward = host
        .forwards
        .iter()
        .find(|f| f.id == forward_id)
        .ok_or_else(|| anyhow::anyhow!("invalid_forward"))?;
    forward.validate()?;
    let jump = jump_of(store, &host)?;
    let spec = serde_json::to_string(&(
        &host.host,
        host.port,
        &host.user,
        &host.key,
        &host.identity,
        forward,
        jump.as_ref()
            .map(|j| (&j.host, j.port, &j.user, &j.key, &j.identity)),
    ))?;
    if let Some(state) = read_state(store, host_id, forward_id) {
        if state.spec == spec && alive(state.pid) && is_forward_process(state.pid) {
            return Ok(state.started);
        }
        stop_forward(store, host_id, forward_id);
    }
    if forward.kind != "remote" {
        ensure!(!port_open(forward.listen_port), "forward_port_busy");
    }
    let log = store
        .directory("run")?
        .join(format!("forward-{host_id}--{forward_id}.log"));
    let log_file = private_log(&log)?;
    let (flag, value) = forward.argument();
    let mut command = Command::new(SSH);
    command
        .args(["-N", "-T", "-o", "ExitOnForwardFailure=yes"])
        .args(connection_options(store, &host, true)?)
        .args(["-p", &host.port.to_string()])
        .args([flag, value])
        .arg("--")
        .arg(host.destination());
    ssh_environment(&mut command);
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(log_file)
        .spawn()?;
    let started = Instant::now();
    loop {
        if child.try_wait()?.is_some() {
            let text = std::fs::read_to_string(&log).unwrap_or_default();
            let _ = std::fs::remove_file(&log);
            bail!(ssh_error(&text));
        }
        let ready = match forward.kind.as_str() {
            "remote" => started.elapsed() > Duration::from_millis(2500),
            _ => port_open(forward.listen_port),
        };
        if ready {
            break;
        }
        if started.elapsed() > Duration::from_secs(20) {
            let _ = child.kill();
            let _ = std::fs::remove_file(&log);
            bail!("ssh_failed");
        }
        std::thread::sleep(Duration::from_millis(150));
    }
    let now = now_secs();
    let state = ForwardState {
        pid: child.id() as i32,
        spec,
        started: now,
        failures: 0,
        retry_at: 0,
        error: String::new(),
    };
    write_private(
        &state_file(store, host_id, forward_id)?,
        &serde_json::to_string(&state)?,
    )?;
    Ok(now)
}

/// Pause before the next attempt of a dropped forward: 15 s, doubling, at most 5 minutes.
pub(super) fn backoff(failures: u32) -> u64 {
    (15u64 << failures.min(5)).min(300)
}

/// Starts again the kept-alive forwards whose ssh exited on its own (the user's "Stop" removes
/// the state, so those are never restarted). The app calls this periodically.
pub fn heal(store: &Store) -> Result<serde_json::Value> {
    let mut restarted = vec![];
    for host in list(store)? {
        for forward in host.forwards.iter().filter(|f| f.keep_alive) {
            let Some(state) = read_state(store, &host.id, &forward.id) else {
                continue;
            };
            if (alive(state.pid) && is_forward_process(state.pid)) || state.retry_at > now_secs() {
                continue;
            }
            match start_forward(store, &host.id, &forward.id) {
                Ok(_) => {
                    restarted.push(serde_json::json!({"host": host.id, "forward": forward.id}))
                }
                Err(error) => {
                    let failures = state.failures + 1;
                    let code = error.to_string();
                    let waiting = ForwardState {
                        pid: 0,
                        spec: state.spec,
                        started: state.started,
                        failures,
                        retry_at: now_secs() + backoff(failures),
                        error: code,
                    };
                    write_private(
                        &state_file(store, &host.id, &forward.id)?,
                        &serde_json::to_string(&waiting)?,
                    )?;
                }
            }
        }
    }
    Ok(serde_json::json!({"restarted": restarted}))
}

/// Hosts with the state of each forward, for the app: running ones and dropped ones (with the
/// next automatic attempt when they are kept alive).
pub fn overview(store: &Store) -> Result<serde_json::Value> {
    let hosts = list(store)?;
    let mut active = vec![];
    let mut down = vec![];
    for host in &hosts {
        for forward in &host.forwards {
            let Some(state) = read_state(store, &host.id, &forward.id) else {
                continue;
            };
            if alive(state.pid) && is_forward_process(state.pid) {
                active.push(serde_json::json!({"host": host.id, "forward": forward.id, "since": state.started}));
            } else {
                down.push(serde_json::json!({"host": host.id, "forward": forward.id, "failures": state.failures, "retryAt": state.retry_at, "error": state.error, "keepAlive": forward.keep_alive}));
            }
        }
    }
    Ok(serde_json::json!({"hosts": hosts, "active": active, "down": down}))
}
