//! What every SSH user in the engine shares: the error codes for what `ssh` printed, the
//! identity files and host keys it may use, and the checks that a tunnel or session is alive.

use crate::core::store::Store;
use crate::core::{fsutil::write_private, validate};
use anyhow::{Result, bail, ensure};
use std::{
    io::Write,
    net::TcpStream,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::Duration,
};

/// A private key file inside ~/.ssh (canonicalized: no way out through links).
pub fn identity_file(path: &Path) -> Result<PathBuf> {
    let ssh_dir = Store::home()
        .ok_or_else(|| anyhow::anyhow!("invalid_ssh"))?
        .join(".ssh")
        .canonicalize()?;
    let path = path
        .canonicalize()
        .map_err(|_| anyhow::anyhow!("invalid_ssh"))?;
    ensure!(path.starts_with(&ssh_dir) && path.is_file(), "invalid_ssh");
    Ok(path)
}

pub fn known_hosts(store: &Store) -> Result<PathBuf> {
    let dir = store.directory("config")?.join("ssh");
    std::fs::create_dir_all(&dir)?;
    Ok(dir.join("known_hosts"))
}

/// Host keys come from the user's ~/.ssh/known_hosts and from the ones accepted in Stack.
pub fn known_hosts_option(store: &Store) -> Result<String> {
    let home = Store::home().ok_or_else(|| anyhow::anyhow!("invalid_ssh"))?;
    let files = [home.join(".ssh/known_hosts"), known_hosts(store)?];
    let quoted: Vec<String> = files
        .iter()
        .map(|p| {
            let text = p.to_string_lossy().into_owned();
            ensure!(
                !text.contains('"') && !text.chars().any(char::is_control),
                "invalid_ssh"
            );
            Ok(format!("\"{text}\""))
        })
        .collect::<Result<_>>()?;
    Ok(format!("UserKnownHostsFile={}", quoted.join(" ")))
}

pub fn alive(pid: i32) -> bool {
    // SAFETY: `kill` with signal 0 only checks that the process exists; `pid > 0` is checked first,
    // so it can never address a process group (0, negative) or every process (-1).
    pid > 0 && unsafe { libc::kill(pid, 0) } == 0
}

/// Only a process that is still an ssh is ours to stop (a recycled pid never is).
pub fn is_ssh(pid: i32) -> bool {
    Command::new("/bin/ps")
        .args(["-p", &pid.to_string(), "-o", "comm="])
        .env_clear()
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().ends_with("ssh"))
        .unwrap_or(false)
}

/// A forward's own `ssh -N`: an ssh that leads its process group (forwards start with
/// `process_group(0)`), which another ssh that was handed the same pid later never does.
pub fn is_forward_process(pid: i32) -> bool {
    is_ssh(pid) && leads_process_group(pid)
}

fn leads_process_group(pid: i32) -> bool {
    // SAFETY: `getpgid` only reads the process group of `pid` (no memory is passed); `pid > 0`
    // is checked first.
    pid > 0 && unsafe { libc::getpgid(pid) } == pid
}

pub fn port_open(port: u16) -> bool {
    TcpStream::connect_timeout(&([127, 0, 0, 1], port).into(), Duration::from_millis(300)).is_ok()
}

/// The error code for what `ssh` wrote on stderr before it exited.
pub fn ssh_error(text: &str) -> &'static str {
    if text.contains("IDENTIFICATION HAS CHANGED") {
        "ssh_host_changed"
    } else if text.contains("Host key verification failed") || text.contains("host key is known") {
        "ssh_host_unknown"
    } else if text.contains("Permission denied") {
        "ssh_auth_failed"
    } else if text.contains("Address already in use")
        || text.contains("cannot listen")
        || text.contains("remote port forwarding failed")
    {
        "forward_port_busy"
    } else if text.contains("Could not resolve hostname") {
        "ssh_host_not_found"
    } else if text.contains("Connection refused")
        || text.contains("timed out")
        || text.contains("No route to host")
    {
        "ssh_unreachable"
    } else {
        "ssh_failed"
    }
}

/// Fingerprints the SSH server presents now (`ssh-keyscan`, hashed with `ssh-keygen -l`).
pub fn ssh_fingerprints(host: &str, port: u16) -> Result<(Vec<String>, String)> {
    ensure!(validate::host(host) && port > 0, "invalid_ssh");
    let scan = Command::new("/usr/bin/ssh-keyscan")
        .args([
            "-T",
            "8",
            "-t",
            "ed25519,ecdsa,rsa",
            "-p",
            &port.to_string(),
            "--",
            host,
        ])
        .env_clear()
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()?;
    let keys = String::from_utf8_lossy(&scan.stdout).into_owned();
    ensure!(!keys.trim().is_empty(), "ssh_failed");
    Ok((fingerprints_of(&keys)?, keys))
}

/// "ED25519 SHA256:…" for each known_hosts-style line, sorted and without repeats.
pub fn fingerprints_of(keys: &str) -> Result<Vec<String>> {
    let mut child = Command::new("/usr/bin/ssh-keygen")
        .args(["-l", "-f", "-"])
        .env_clear()
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    child
        .stdin
        .take()
        .ok_or_else(|| anyhow::anyhow!("ssh_failed"))?
        .write_all(keys.as_bytes())?;
    let out = child.wait_with_output()?;
    let mut prints: Vec<String> = String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|l| {
            let parts: Vec<_> = l.split_whitespace().collect();
            (parts.len() >= 2).then(|| format!("{} {}", parts.last().unwrap_or(&""), parts[1]))
        })
        .collect();
    prints.sort();
    prints.dedup();
    Ok(prints)
}

/// Trusts a server's keys in Stack's own known_hosts, only if they are still the ones the user saw.
pub fn ssh_trust(store: &Store, host: &str, port: u16, seen: &[String]) -> Result<()> {
    let (prints, keys) = ssh_fingerprints(host, port)?;
    trust_scanned(store, &prints, &keys, seen)
}

/// The host name of a known_hosts line that is exactly `name keytype base64key`, with a key type
/// of the list below and nothing else on it. The one rule for every line Stack writes into a
/// trust file (its own and `~/.ssh/known_hosts`).
pub fn plain_known_host_line(line: &str) -> Option<&str> {
    let parts: Vec<&str> = line.split(' ').collect();
    let [name, kind, key] = parts.as_slice() else {
        return None;
    };
    let kind_ok = matches!(
        *kind,
        "ssh-ed25519"
            | "ssh-rsa"
            | "ecdsa-sha2-nistp256"
            | "ecdsa-sha2-nistp384"
            | "ecdsa-sha2-nistp521"
    );
    let key_ok = !key.is_empty()
        && key
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'+' | b'/' | b'='));
    let name_ok = !name.is_empty() && !name.chars().any(|c| c.is_control() || c.is_whitespace());
    (kind_ok && key_ok && name_ok).then_some(*name)
}

/// Adds scanned known_hosts lines to Stack's own file when every fingerprint is one the user saw.
pub fn trust_scanned(store: &Store, prints: &[String], keys: &str, seen: &[String]) -> Result<()> {
    // Every key the server shows now must be one the user saw (a scan may miss a key type).
    ensure!(
        !prints.is_empty() && prints.iter().all(|p| seen.contains(p)),
        "ssh_host_changed"
    );
    let path = known_hosts(store)?;
    // A file that exists and cannot be read as text is left alone: rewriting it would lose lines.
    let mut text = match std::fs::read_to_string(&path) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(_) => bail!("ssh_known_hosts_unreadable"),
    };
    if !text.is_empty() && !text.ends_with('\n') {
        text.push('\n');
    }
    let lines: Vec<&str> = keys
        .lines()
        .filter(|l| !l.starts_with('#') && !l.trim().is_empty())
        .collect();
    // `host keytype key`: nothing else is ever written into the trust file.
    ensure!(
        !lines.is_empty() && lines.iter().all(|l| plain_known_host_line(l).is_some()),
        "ssh_host_changed"
    );
    for line in lines {
        if !text.lines().any(|l| l == line) {
            text.push_str(line);
            text.push('\n');
        }
    }
    write_private(&path, &text)
}

#[cfg(test)]
mod known_line_tests {
    use super::plain_known_host_line;

    #[test]
    fn only_a_plain_key_line_is_written_into_a_trust_file() {
        assert_eq!(
            plain_known_host_line(
                "[git.example.invalid]:2222 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA+/="
            ),
            Some("[git.example.invalid]:2222")
        );
        for line in [
            "host ssh-ed25519",
            "host ssh-ed25519 AAAA extra",
            "host ssh-dss AAAA",
            "host ssh-ed25519 AAAA;rm",
            "host\tssh-ed25519 AAAA",
            "@cert-authority host ssh-ed25519 AAAA",
            "host ssh-ed25519 AAAA\u{7}",
            "",
        ] {
            assert!(plain_known_host_line(line).is_none(), "{line:?}");
        }
    }
}

#[cfg(test)]
mod forward_process_tests {
    use super::*;
    use std::os::unix::process::CommandExt;

    #[test]
    fn only_a_process_that_leads_its_group_can_be_a_forward() {
        let spawn = |own_group: bool| {
            let mut command = Command::new("/bin/sleep");
            command.arg("30");
            if own_group {
                command.process_group(0);
            }
            command.spawn().unwrap()
        };
        let (mut led, mut shared) = (spawn(true), spawn(false));
        assert!(leads_process_group(led.id() as i32));
        // In the group of the caller: a session of the user's, never a forward Stack started.
        assert!(!leads_process_group(shared.id() as i32));
        assert!(!leads_process_group(0) && !leads_process_group(-1));
        let _ = (led.kill(), shared.kill());
        let _ = (led.wait(), shared.wait());
    }
}
