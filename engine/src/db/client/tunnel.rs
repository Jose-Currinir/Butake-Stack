//! SSH tunnels of a connection: one `ssh -N -L` per connection in its own process group, reused while it answers.

use super::*;

#[derive(Serialize, Deserialize)]
pub(super) struct TunnelState {
    pid: i32,
    port: u16,
    spec: String,
}

pub(super) fn tunnel_file(store: &Store, id: &str) -> Result<PathBuf> {
    Ok(store.directory("run")?.join(format!("tunnel-{id}.json")))
}

pub fn close_tunnel(store: &Store, id: &str) {
    let Ok(path) = tunnel_file(store, id) else {
        return;
    };
    if let Ok(state) = std::fs::read(&path)
        .map_err(anyhow::Error::from)
        .and_then(|d| Ok(serde_json::from_slice::<TunnelState>(&d)?))
    {
        if alive(state.pid) && is_ssh(state.pid) {
            unsafe { libc::kill(state.pid, libc::SIGTERM) };
        }
    }
    let _ = std::fs::remove_file(path);
}

/// Opens (or reuses) `ssh -N -L 127.0.0.1:<local>:<host>:<port>` for a connection and returns the
/// local port. Host keys are always verified (`StrictHostKeyChecking=yes`, BatchMode: nothing
/// is asked on a terminal); an unknown key is an error the app turns into a fingerprint check.
pub fn tunnel(store: &Store, connection: &Connection) -> Result<u16> {
    let ssh = connection
        .ssh
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("invalid_ssh"))?;
    let spec = serde_json::to_string(&(ssh, &connection.host, connection.port))?;
    let path = tunnel_file(store, &connection.id)?;
    if let Ok(state) = std::fs::read(&path)
        .map_err(anyhow::Error::from)
        .and_then(|d| Ok(serde_json::from_slice::<TunnelState>(&d)?))
    {
        if state.spec == spec && alive(state.pid) && port_open(state.port) {
            return Ok(state.port);
        }
        close_tunnel(store, &connection.id);
    }
    let local = std::net::TcpListener::bind(("127.0.0.1", 0))?
        .local_addr()?
        .port();
    let log = store
        .directory("run")?
        .join(format!("tunnel-{}.log", connection.id));
    let log_file = private_log(&log)?;
    let target = if connection.host.contains(':') {
        format!("[{}]", connection.host)
    } else {
        connection.host.clone()
    };
    let mut command = Command::new("/usr/bin/ssh");
    command
        .args([
            "-N",
            "-T",
            "-o",
            "BatchMode=yes",
            "-o",
            "StrictHostKeyChecking=yes",
            "-o",
            "ExitOnForwardFailure=yes",
        ])
        .args([
            "-o",
            "ServerAliveInterval=30",
            "-o",
            "ServerAliveCountMax=3",
            "-o",
            "ConnectTimeout=10",
            "-o",
            "ControlMaster=no",
        ])
        .args(["-o", &known_hosts_option(store)?])
        .args([
            "-L",
            &format!("127.0.0.1:{local}:{target}:{}", connection.port),
        ])
        .args(["-p", &ssh.port.to_string()]);
    if let Some(key) = &ssh.key {
        command
            .arg("-i")
            .arg(crate::ssh::keys::path(store, key)?)
            .args(["-o", "IdentitiesOnly=yes"]);
    } else if let Some(identity) = &ssh.identity {
        command
            .arg("-i")
            .arg(identity_file(identity)?)
            .args(["-o", "IdentitiesOnly=yes"]);
    }
    command.arg("--").arg(format!("{}@{}", ssh.user, ssh.host));
    // The agent socket is the only variable ssh needs from the session.
    command.env_clear();
    if let Some(home) = Store::home() {
        command.env("HOME", home);
    }
    if let Some(agent) = std::env::var_os("SSH_AUTH_SOCK") {
        command.env("SSH_AUTH_SOCK", agent);
    }
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
        if let Some(_status) = child.try_wait()? {
            let text = std::fs::read_to_string(&log).unwrap_or_default();
            let _ = std::fs::remove_file(&log);
            bail!(ssh_error(&text));
        }
        if port_open(local) {
            break;
        }
        if started.elapsed() > Duration::from_secs(20) {
            let _ = child.kill();
            bail!("ssh_failed");
        }
        std::thread::sleep(Duration::from_millis(150));
    }
    write_private(
        &path,
        &serde_json::to_string(&TunnelState {
            pid: child.id() as i32,
            port: local,
            spec,
        })?,
    )?;
    Ok(local)
}
