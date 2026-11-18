//! Host keys: what a host presents, checked against Stack's known_hosts (also through a jump host) and trusted only when the user accepts it.

use super::*;

/// (type, base64 key) pairs from known_hosts-style lines, ignoring the host field.
pub(super) fn key_pairs(text: &str) -> Vec<(String, String)> {
    text.lines()
        .filter(|l| !l.starts_with('#') && !l.trim().is_empty())
        .filter_map(|l| {
            let parts: Vec<&str> = l.split_whitespace().collect();
            // "@cert-authority host type key" / "@revoked …" are skipped: only plain entries count.
            (parts.len() >= 3 && !parts[0].starts_with('@'))
                .then(|| (parts[1].to_string(), parts[2].to_string()))
        })
        .collect()
}

/// Entries for a host in one known_hosts file (`ssh-keygen -F` also matches hashed names).
pub(super) fn known_keys(path: &std::path::Path, host: &str, port: u16) -> Vec<(String, String)> {
    if !path.is_file() {
        return vec![];
    }
    let name = if port == 22 {
        host.to_string()
    } else {
        format!("[{host}]:{port}")
    };
    Command::new("/usr/bin/ssh-keygen")
        .args(["-F", &name, "-f"])
        .arg(path)
        .env_clear()
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .map(|o| key_pairs(&String::from_utf8_lossy(&o.stdout)))
        .unwrap_or_default()
}

/// The environment ssh gets from Stack: the home folder and the agent socket, nothing else.
pub(super) fn ssh_environment(command: &mut Command) {
    command.env_clear();
    if let Some(home) = Store::home() {
        command.env("HOME", home);
    }
    if let Some(agent) = std::env::var_os("SSH_AUTH_SOCK") {
        command.env("SSH_AUTH_SOCK", agent);
    }
}

/// Keys a host behind a jump presents, seen through the jump: a throwaway known_hosts records
/// the key on first contact (`accept-new`) and no authentication is attempted on the target.
/// The jump itself is verified strictly, as in any session.
pub(super) fn scan_via_jump(
    store: &Store,
    host: &Host,
    jump: &Host,
) -> Result<(Vec<String>, String)> {
    let token = now_nanos();
    let scratch = store
        .directory("run")?
        .join(format!("scan-{}-{token:x}.known", host.id));
    let text = scratch.to_string_lossy().into_owned();
    ensure!(
        !text.contains('"') && !text.chars().any(char::is_control),
        "invalid_ssh"
    );
    let mut command = Command::new(SSH);
    command
        .args([
            "-F",
            "/dev/null",
            "-T",
            "-o",
            "BatchMode=yes",
            "-o",
            "StrictHostKeyChecking=accept-new",
        ])
        .args([
            "-o",
            "GlobalKnownHostsFile=/dev/null",
            "-o",
            "HashKnownHosts=no",
            "-o",
            "UpdateHostKeys=no",
            "-o",
            "ControlMaster=no",
            "-o",
            "ConnectTimeout=10",
        ])
        .args([
            "-o",
            "PubkeyAuthentication=no",
            "-o",
            "PasswordAuthentication=no",
            "-o",
            "KbdInteractiveAuthentication=no",
        ])
        .args([
            "-o",
            "GSSAPIAuthentication=no",
            "-o",
            "HostbasedAuthentication=no",
        ])
        .arg("-o")
        .arg(format!("UserKnownHostsFile=\"{text}\""))
        .arg("-o")
        .arg(proxy_command(store, jump, true)?)
        .args([
            "-p",
            &host.port.to_string(),
            "--",
            &host.destination(),
            "true",
        ]);
    ssh_environment(&mut command);
    let out = command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output()?;
    let keys = std::fs::read_to_string(&scratch).unwrap_or_default();
    let _ = std::fs::remove_file(&scratch);
    let _ = std::fs::remove_file(scratch.with_extension("known.old"));
    if keys.trim().is_empty() {
        bail!(match ssh_error(&String::from_utf8_lossy(&out.stderr)) {
            "ssh_failed" => "ssh_unreachable",
            code => code,
        });
    }
    Ok((fingerprints_of(&keys)?, keys))
}

/// The keys a host presents now (directly, or through its jump host).
pub(super) fn scan(store: &Store, host: &Host) -> Result<(Vec<String>, String)> {
    match jump_of(store, host)? {
        Some(jump) => scan_via_jump(store, host, &jump),
        None => {
            ssh_fingerprints(&host.host, host.port).map_err(|_| anyhow::anyhow!("ssh_unreachable"))
        }
    }
}

/// "known", "unknown" or "changed" for what a host presents.
pub(super) fn state_of(store: &Store, host: &Host, scanned: &str) -> Result<&'static str> {
    let home = Store::home().ok_or_else(|| anyhow::anyhow!("invalid_ssh"))?;
    let mut known = known_keys(&home.join(".ssh/known_hosts"), &host.host, host.port);
    known.extend(known_keys(&known_hosts(store)?, &host.host, host.port));
    let presented = key_pairs(scanned);
    Ok(if known.is_empty() {
        "unknown"
    } else if presented.iter().any(|k| known.contains(k)) {
        "known"
    } else {
        "changed"
    })
}

/// Compares the keys the server presents now with the known ones: "known", "unknown" (the user
/// compares the fingerprints and trusts them) or "changed" (never connect). A host behind a jump
/// needs its jump known first: until then the answer is about the jump (`host` says which).
pub fn check(store: &Store, id: &str) -> Result<serde_json::Value> {
    let host = find(store, id)?;
    if let Some(jump) = jump_of(store, &host)? {
        let (prints, scanned) = scan(store, &jump)?;
        let state = state_of(store, &jump, &scanned)?;
        if state != "known" {
            return Ok(
                serde_json::json!({"state": state, "fingerprints": prints, "host": jump.id}),
            );
        }
    }
    let (prints, scanned) = scan(store, &host)?;
    let state = state_of(store, &host, &scanned)?;
    Ok(serde_json::json!({"state": state, "fingerprints": prints, "host": host.id}))
}

/// Trusts what a host presents now, only if it is what the user compared.
pub fn trust(store: &Store, id: &str, seen: &[String]) -> Result<()> {
    let host = find(store, id)?;
    let (prints, keys) = scan(store, &host)?;
    trust_scanned(store, &prints, &keys, seen)
}
