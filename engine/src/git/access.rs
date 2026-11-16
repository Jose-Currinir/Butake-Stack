//! What a clone over SSH needs on this Mac before Git runs: the server among the known hosts and
//! a key to offer. Git's own `ssh` cannot ask (no terminal), so the app reads this, shows the
//! server's fingerprints and adds them to `~/.ssh/known_hosts` only once the user accepts them.
//! Nothing here reads a private key or sends anything but a key scan to the server.
use super::remotes::validate_clone_url;
use super::runner::{error, Result};
use crate::core::validate;
use serde::Serialize;
use std::{
    ffi::OsStr,
    io::Write,
    path::Path,
    process::{Command, Stdio},
};

/// The SHA-256 fingerprints each provider publishes for its SSH host keys (GitHub: «GitHub's SSH
/// key fingerprints» and `api.github.com/meta`; Bitbucket Cloud: `bitbucket.org/site/ssh`). A
/// server that answers for one of these names with any other key is refused.
const OFFICIAL: &[(&str, &[&str])] = &[
    (
        "github.com",
        &[
            "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU",
            "SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM",
            "SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s",
        ],
    ),
    (
        "bitbucket.org",
        &[
            "SHA256:ybgmFkzwOSotHTHLJgHO0QN8L0xErw6vd0VhFA9m3SM",
            "SHA256:FC73VB6C4OQLSCrjEayhMp9UMxS97caD/Yyi2bhW/J0",
            "SHA256:46OSHA1Rmj8E8ERTC6xkNcmGOw9oFxYr0WF6zWW8l1E",
        ],
    ),
];

/// The private keys `ssh` offers on its own, in `~/.ssh`.
const DEFAULT_IDENTITIES: &[&str] = &[
    "id_ed25519",
    "id_ecdsa",
    "id_rsa",
    "id_ed25519_sk",
    "id_ecdsa_sk",
];

/// What the app shows before cloning: for an HTTPS address only `ssh: false`.
#[derive(Debug, Default, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SshAccess {
    pub ssh: bool,
    pub host: String,
    pub port: u16,
    /// The server is in `~/.ssh/known_hosts` (or the system's list): `ssh` will not have to ask.
    pub host_known: bool,
    /// There is a key to offer: one loaded in the agent or a default one in `~/.ssh`.
    pub identities: bool,
}

/// The fingerprints a server presents now, as the user must see them before trusting it.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HostFingerprints {
    pub host: String,
    pub port: u16,
    pub fingerprints: Vec<String>,
    /// Every one is among those the provider publishes for this name.
    pub official: bool,
}

/// Host and port of an SSH clone address (`git@host:path`, `ssh://[user@]host[:port]/path`); None
/// for any other transport.
pub fn ssh_endpoint(url: &str) -> Option<(String, u16)> {
    let (authority, default_port) = if let Some(rest) = url.strip_prefix("ssh://") {
        (&rest[..rest.find('/').unwrap_or(rest.len())], true)
    } else if url.starts_with("git@") {
        (&url[..url.find(':')?], false)
    } else {
        return None;
    };
    let host = authority.rsplit_once('@').map_or(authority, |(_, h)| h);
    let (host, port) = match host.rsplit_once(':') {
        Some((name, port)) if default_port => (name, port.parse().ok()?),
        _ => (host, 22),
    };
    let host = host.to_ascii_lowercase();
    (validate::host(&host) && !host.contains(':') && port > 0).then_some((host, port))
}

/// The name `ssh` looks a server up by in a known hosts file.
fn known_name(host: &str, port: u16) -> String {
    if port == 22 {
        host.to_string()
    } else {
        format!("[{host}]:{port}")
    }
}

fn host_known(home: &Path, host: &str, port: u16) -> bool {
    let name = known_name(host, port);
    [
        home.join(".ssh/known_hosts"),
        "/etc/ssh/ssh_known_hosts".into(),
    ]
    .iter()
    .filter(|file| file.is_file())
    .any(|file| {
        Command::new("/usr/bin/ssh-keygen")
            .args(["-F", &name, "-f"])
            .arg(file)
            .env_clear()
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output()
            .is_ok_and(|out| out.status.success() && !out.stdout.is_empty())
    })
}

fn identities(home: &Path, agent: Option<&OsStr>) -> bool {
    DEFAULT_IDENTITIES
        .iter()
        .any(|name| home.join(".ssh").join(name).is_file())
        || agent.is_some_and(|socket| {
            Command::new("/usr/bin/ssh-add")
                .arg("-l")
                .env_clear()
                .env("SSH_AUTH_SOCK", socket)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .is_ok_and(|status| status.success())
        })
}

/// What cloning `url` over SSH would find on this Mac. `agent` is the SSH agent's socket.
pub fn ssh_access(home: &Path, agent: Option<&OsStr>, url: &str) -> Result<SshAccess> {
    validate_clone_url(url)?;
    let Some((host, port)) = ssh_endpoint(url) else {
        return Ok(SshAccess::default());
    };
    Ok(SshAccess {
        ssh: true,
        host_known: host_known(home, &host, port),
        identities: identities(home, agent),
        host,
        port,
    })
}

fn sha256_of(fingerprint: &str) -> &str {
    fingerprint
        .split_whitespace()
        .find(|part| part.starts_with("SHA256:"))
        .unwrap_or("")
}

/// The fingerprints the provider publishes for `host`, when it is one Stack knows (port 22 only).
fn official(host: &str, port: u16) -> Option<&'static [&'static str]> {
    OFFICIAL
        .iter()
        .find(|(name, _)| *name == host && port == 22)
        .map(|(_, prints)| *prints)
}

fn all_official(host: &str, port: u16, prints: &[String]) -> Option<bool> {
    official(host, port).map(|list| {
        !prints.is_empty() && prints.iter().all(|print| list.contains(&sha256_of(print)))
    })
}

fn endpoint(url: &str) -> Result<(String, u16)> {
    validate_clone_url(url)?;
    ssh_endpoint(url).ok_or_else(|| {
        error(
            "invalid_url",
            "Esa dirección no usa SSH: no hay servidor en el que confiar.",
        )
    })
}

fn scan(host: &str, port: u16) -> Result<(Vec<String>, String)> {
    crate::ssh::common::ssh_fingerprints(host, port).map_err(|_| {
        error(
            "ssh_unreachable",
            format!("No se pudo leer la huella de {host}. Revisa tu conexión y vuelve a intentar."),
        )
    })
}

/// The fingerprints the server of `url` presents now.
pub fn host_fingerprints(url: &str) -> Result<HostFingerprints> {
    let (host, port) = endpoint(url)?;
    let (fingerprints, _) = scan(&host, port)?;
    Ok(HostFingerprints {
        official: all_official(&host, port, &fingerprints).unwrap_or(false),
        host,
        port,
        fingerprints,
    })
}

/// Scans the server of `url` again and adds its keys to `~/.ssh/known_hosts` when they are still
/// the ones the user saw (`seen`).
pub fn trust_host(home: &Path, url: &str, seen: &[String]) -> Result<()> {
    let (host, port) = endpoint(url)?;
    let (prints, keys) = scan(&host, port)?;
    trust_scanned(home, &host, port, &prints, &keys, seen)
}

/// Adds scanned known-hosts lines of `host` to `~/.ssh/known_hosts`. Refused when a fingerprint is
/// not one the user saw, when a provider Stack knows presents a key it does not publish, or when
/// a line is not a plain key of that host.
pub fn trust_scanned(
    home: &Path,
    host: &str,
    port: u16,
    prints: &[String],
    keys: &str,
    seen: &[String],
) -> Result<()> {
    let changed = || {
        error(
            "ssh_host_changed",
            format!(
                "{host} presenta ahora otra huella. No se agregó a los servidores de confianza."
            ),
        )
    };
    if prints.is_empty() || !prints.iter().all(|print| seen.contains(print)) {
        return Err(changed());
    }
    if all_official(host, port, prints) == Some(false) {
        return Err(error(
            "ssh_host_changed",
            format!("{host} presenta una huella que su proveedor no publica. No se agregó a los servidores de confianza: puede haber alguien entre este Mac y el servidor."),
        ));
    }
    let name = known_name(host, port);
    let lines: Vec<&str> = keys
        .lines()
        .filter(|line| !line.starts_with('#') && !line.trim().is_empty())
        .collect();
    let plain = |line: &&str| {
        let parts: Vec<&str> = line.split(' ').collect();
        parts.len() == 3
            && parts[0] == name
            && matches!(
                parts[1],
                "ssh-ed25519"
                    | "ssh-rsa"
                    | "ecdsa-sha2-nistp256"
                    | "ecdsa-sha2-nistp384"
                    | "ecdsa-sha2-nistp521"
            )
            && !parts[2].is_empty()
            && parts[2]
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'+' | b'/' | b'='))
    };
    if lines.is_empty() || !lines.iter().all(plain) {
        return Err(changed());
    }
    append_known_hosts(home, &lines).map_err(|_| {
        error(
            "invalid_path",
            "No se pudo escribir en ~/.ssh/known_hosts. Revisa los permisos de esa carpeta.",
        )
    })
}

/// `~/.ssh` (0700) and `known_hosts` (0600) are created when missing; an existing file only gets
/// the lines it does not have yet.
fn append_known_hosts(home: &Path, lines: &[&str]) -> std::io::Result<()> {
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
    let dir = home.join(".ssh");
    if !dir.is_dir() {
        std::fs::DirBuilder::new().mode(0o700).create(&dir)?;
    }
    let path = dir.join("known_hosts");
    let current = std::fs::read_to_string(&path).unwrap_or_default();
    let mut text = String::new();
    if !current.is_empty() && !current.ends_with('\n') {
        text.push('\n');
    }
    for line in lines {
        if !current.lines().any(|known| known == *line) {
            text.push_str(line);
            text.push('\n');
        }
    }
    std::fs::OpenOptions::new()
        .append(true)
        .create(true)
        .mode(0o600)
        .open(&path)?
        .write_all(text.as_bytes())
}
