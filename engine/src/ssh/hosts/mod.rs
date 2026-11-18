//! "Terminal SSH" plugin: saved hosts (name, description, group, tags, optional jump host), the
//! SSH keys Stack already keeps, host keys verified against ~/.ssh/known_hosts and Stack's own,
//! interactive sessions with `/usr/bin/ssh` (the app runs them in its embedded terminal from the
//! arguments built here, or in Terminal.app), and saved port forwards run in the background with
//! `ssh -N`, optionally restarted when they drop.

mod forwards;
mod known;

pub use forwards::*;
pub use known::*;

use crate::core::fsutil::private_log;
use crate::core::json;
use crate::core::time::{now_nanos, now_secs};
use crate::core::validate;
use crate::{
    core::fsutil::write_private,
    core::store::Store,
    ssh::common::{
        alive, fingerprints_of, identity_file, is_forward_process, known_hosts, known_hosts_option,
        port_open, ssh_error, ssh_fingerprints, trust_scanned,
    },
};
use anyhow::{Result, bail, ensure};
use serde::{Deserialize, Serialize};
use std::{
    path::PathBuf,
    process::{Command, Stdio},
    time::{Duration, Instant},
};

pub const SSH: &str = "/usr/bin/ssh";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Forward {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub name: String,
    /// local (-L), remote (-R) or dynamic (-D, SOCKS).
    pub kind: String,
    /// Port opened on 127.0.0.1 (local and dynamic) or on the server's loopback (remote).
    pub listen_port: u16,
    /// Where the traffic goes: seen from the server (local) or from this Mac (remote).
    #[serde(default)]
    pub target_host: String,
    #[serde(default)]
    pub target_port: u16,
    /// Opened together with the host's "Start forwards".
    #[serde(default)]
    pub autostart: bool,
    /// Started again (with a growing pause) when its ssh exits on its own.
    #[serde(default)]
    pub keep_alive: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Host {
    #[serde(default)]
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub group: String,
    /// Free labels besides the group ("producción", "aws", "cliente-x").
    #[serde(default)]
    pub tags: Vec<String>,
    pub host: String,
    #[serde(default = "ssh_port")]
    pub port: u16,
    pub user: String,
    /// A key imported into Stack, by id; it wins over `identity`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key: Option<String>,
    /// A private key inside ~/.ssh; none = the SSH agent and the user's default keys.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub identity: Option<PathBuf>,
    /// Another saved host to reach this one through (ProxyJump), by id. One hop.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub jump: Option<String>,
    #[serde(default)]
    pub forwards: Vec<Forward>,
}
fn ssh_port() -> u16 {
    22
}

/// Longest id of a host, forward or snippet.
pub(crate) const MAX_ID: usize = 48;

/// "Producción Ñuñoa" → "produccion-nunoa".
pub(crate) fn slug(name: &str, fallback: &str) -> String {
    let base: String = name
        .to_lowercase()
        .chars()
        .map(|c| match c {
            'á' | 'à' | 'ä' | 'â' => 'a',
            'é' | 'è' | 'ë' | 'ê' => 'e',
            'í' | 'ì' | 'ï' | 'î' => 'i',
            'ó' | 'ò' | 'ö' | 'ô' => 'o',
            'ú' | 'ù' | 'ü' | 'û' => 'u',
            'ñ' => 'n',
            c if c.is_ascii_alphanumeric() => c,
            _ => '-',
        })
        .collect();
    let base = base
        .split('-')
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join("-");
    if base.is_empty() {
        fallback.into()
    } else {
        base.chars()
            .take(32)
            .collect::<String>()
            .trim_end_matches('-')
            .to_string()
    }
}

pub(crate) fn unique(base: String, taken: impl Fn(&str) -> bool) -> String {
    let mut id = base.clone();
    let mut n = 2;
    while taken(&id) {
        id = format!("{base}-{n}");
        n += 1;
    }
    id
}

impl Forward {
    fn validate(&self) -> Result<()> {
        ensure!(
            validate::id(&self.id, MAX_ID)
                && validate::printable(&self.name, 80)
                && self.listen_port > 0,
            "invalid_forward"
        );
        match self.kind.as_str() {
            "local" | "remote" => ensure!(
                validate::host(&self.target_host) && self.target_port > 0,
                "invalid_forward"
            ),
            "dynamic" => {}
            _ => bail!("invalid_forward"),
        }
        // Ports under 1024 need root on this Mac; on the server, only root may bind them too.
        ensure!(self.listen_port >= 1024, "invalid_forward");
        Ok(())
    }
    /// The `-L` / `-R` / `-D` argument, always bound to a loopback address.
    fn argument(&self) -> (String, String) {
        let target = if self.target_host.contains(':') {
            format!("[{}]", self.target_host)
        } else {
            self.target_host.clone()
        };
        match self.kind.as_str() {
            "local" => (
                "-L".into(),
                format!(
                    "127.0.0.1:{}:{target}:{}",
                    self.listen_port, self.target_port
                ),
            ),
            "remote" => (
                "-R".into(),
                format!(
                    "127.0.0.1:{}:{target}:{}",
                    self.listen_port, self.target_port
                ),
            ),
            _ => ("-D".into(), format!("127.0.0.1:{}", self.listen_port)),
        }
    }
}

/// Trimmed, without repeats (ignoring case), at most 12 of up to 30 characters each.
fn clean_tags(tags: &[String]) -> Result<Vec<String>> {
    let mut out: Vec<String> = Vec::new();
    for tag in tags.iter().map(|t| t.trim()).filter(|t| !t.is_empty()) {
        ensure!(
            validate::printable(tag, 30) && !tag.contains(','),
            "invalid_ssh_host"
        );
        if !out.iter().any(|t| t.to_lowercase() == tag.to_lowercase()) {
            out.push(tag.to_string());
        }
    }
    ensure!(out.len() <= 12, "invalid_ssh_host");
    Ok(out)
}

impl Host {
    pub fn validate(&self) -> Result<()> {
        ensure!(validate::id(&self.id, MAX_ID), "invalid_ssh_host");
        ensure!(
            !self.name.trim().is_empty()
                && validate::printable(&self.name, 80)
                && validate::printable(&self.description, 400)
                && validate::printable(&self.group, 60),
            "invalid_ssh_host"
        );
        ensure!(
            validate::host(&self.host) && self.port > 0 && validate::user(&self.user),
            "invalid_ssh"
        );
        ensure!(clean_tags(&self.tags)? == self.tags, "invalid_ssh_host");
        if let Some(identity) = &self.identity {
            identity_file(identity)?;
        }
        if let Some(jump) = &self.jump {
            ensure!(
                validate::id(jump, MAX_ID) && jump != &self.id,
                "invalid_ssh_jump"
            );
        }
        let mut ids = std::collections::HashSet::new();
        for forward in &self.forwards {
            forward.validate()?;
            ensure!(ids.insert(&forward.id), "invalid_forward");
        }
        Ok(())
    }
    pub fn destination(&self) -> String {
        format!("{}@{}", self.user, self.host)
    }
}

fn file(store: &Store) -> Result<PathBuf> {
    let dir = store.directory("config")?.join("ssh");
    std::fs::create_dir_all(&dir)?;
    Ok(dir.join("hosts.json"))
}

pub fn list(store: &Store) -> Result<Vec<Host>> {
    let path = file(store)?;
    if !path.exists() {
        return Ok(vec![]);
    }
    json::read_regular(&path, None)
}

fn write(store: &Store, hosts: &mut [Host]) -> Result<()> {
    hosts.sort_by_key(|h| (h.group.to_lowercase(), h.name.to_lowercase()));
    json::write(&file(store)?, hosts)
}

pub fn find(store: &Store, id: &str) -> Result<Host> {
    list(store)?
        .into_iter()
        .find(|h| h.id == id)
        .ok_or_else(|| anyhow::anyhow!("unknown_ssh_host"))
}

/// The jump host of a host, if it has one (it must exist and must not jump itself).
fn jump_of(store: &Store, host: &Host) -> Result<Option<Host>> {
    let Some(id) = &host.jump else {
        return Ok(None);
    };
    let jump = find(store, id).map_err(|_| anyhow::anyhow!("invalid_ssh_jump"))?;
    ensure!(
        jump.jump.is_none() && jump.id != host.id,
        "invalid_ssh_jump"
    );
    jump.validate()?;
    Ok(Some(jump))
}

/// Saves a new host (empty id) or replaces one. Forwards whose definition changed are stopped.
pub fn save(store: &Store, host: Host) -> Result<Host> {
    let mut hosts = list(store)?;
    let (host, stale) = prepare(store, host, &hosts)?;
    for forward in &stale {
        stop_forward(store, &forward.0, &forward.1);
    }
    hosts.retain(|h| h.id != host.id);
    hosts.push(host.clone());
    write(store, &mut hosts)?;
    Ok(host)
}

/// Replaces several saved hosts at once (renaming, merging or deleting a group or a tag touches
/// many). Every host is validated first, each against the list as the others will leave it; if
/// any is refused, nothing is written and no forward is stopped.
pub fn update_many(store: &Store, changes: Vec<Host>) -> Result<Vec<Host>> {
    let mut hosts = list(store)?;
    let mut stale = Vec::new();
    let mut saved = Vec::new();
    for host in changes {
        ensure!(hosts.iter().any(|h| h.id == host.id), "unknown_ssh_host");
        let (host, stopped) = prepare(store, host, &hosts)?;
        stale.extend(stopped);
        hosts.retain(|h| h.id != host.id);
        hosts.push(host.clone());
        saved.push(host);
    }
    for forward in &stale {
        stop_forward(store, &forward.0, &forward.1);
    }
    write(store, &mut hosts)?;
    Ok(saved)
}

/// Normalizes and validates a host against the saved list. Returns it with the (host id,
/// forward id) pairs whose running forward no longer matches and must be stopped.
fn prepare(store: &Store, mut host: Host, hosts: &[Host]) -> Result<(Host, Vec<(String, String)>)> {
    host.name = host.name.trim().into();
    host.description = host.description.trim().into();
    host.group = host.group.trim().into();
    host.host = host.host.trim().into();
    host.user = host.user.trim().into();
    host.tags = clean_tags(&host.tags)?;
    host.jump = host.jump.filter(|j| !j.is_empty());
    if host.id.is_empty() {
        host.id = unique(slug(&host.name, "host"), |id| {
            hosts.iter().any(|h| h.id == id)
        });
    }
    let mut taken: Vec<String> = host
        .forwards
        .iter()
        .map(|f| f.id.clone())
        .filter(|id| !id.is_empty())
        .collect();
    for forward in host.forwards.iter_mut().filter(|f| f.id.is_empty()) {
        let base = slug(
            &forward.name,
            &format!("{}-{}", forward.kind, forward.listen_port),
        );
        forward.id = unique(base, |id| taken.iter().any(|t| t == id));
        taken.push(forward.id.clone());
    }
    host.validate()?;
    if let Some(key) = &host.key {
        crate::ssh::keys::path(store, key)?;
    }
    if let Some(jump) = &host.jump {
        // One hop: the jump host has no jump of its own, and a host others jump through gets none.
        let target = hosts
            .iter()
            .find(|h| &h.id == jump)
            .ok_or_else(|| anyhow::anyhow!("invalid_ssh_jump"))?;
        ensure!(target.jump.is_none(), "invalid_ssh_jump");
        ensure!(
            !hosts
                .iter()
                .any(|h| h.jump.as_deref() == Some(host.id.as_str())),
            "invalid_ssh_jump"
        );
    }
    let mut stale = Vec::new();
    if let Some(old) = hosts.iter().find(|h| h.id == host.id) {
        for forward in &old.forwards {
            let same = old.host == host.host
                && old.port == host.port
                && old.user == host.user
                && old.key == host.key
                && old.identity == host.identity
                && old.jump == host.jump
                && host.forwards.iter().any(|f| f == forward);
            if !same {
                stale.push((old.id.clone(), forward.id.clone()));
            }
        }
    }
    Ok((host, stale))
}

/// Removes a host, its forwards and its snippets. A host others jump through stays.
pub fn delete(store: &Store, id: &str) -> Result<()> {
    let mut hosts = list(store)?;
    let host = hosts
        .iter()
        .find(|h| h.id == id)
        .cloned()
        .ok_or_else(|| anyhow::anyhow!("unknown_ssh_host"))?;
    ensure!(
        !hosts.iter().any(|h| h.jump.as_deref() == Some(id)),
        "ssh_host_in_use"
    );
    for forward in &host.forwards {
        stop_forward(store, id, &forward.id);
    }
    hosts.retain(|h| h.id != id);
    write(store, &mut hosts)?;
    crate::ssh::snippets::delete_for_host(store, id)
}

pub fn delete_all(store: &Store) -> Result<()> {
    stop_all(store);
    write(store, &mut [])?;
    crate::ssh::snippets::delete_all(store)
}

/// Hosts that use a Stack key (it cannot be removed while they do).
pub fn users_of_key(store: &Store, key: &str) -> Vec<String> {
    list(store)
        .unwrap_or_default()
        .into_iter()
        .filter(|h| h.key.as_deref() == Some(key))
        .map(|h| h.name)
        .collect()
}

// ---------------------------------------------------------------------------------------------
// Arguments
// ---------------------------------------------------------------------------------------------

pub fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

/// Verified host keys (Stack's own known_hosts, strict), no shared master connection, keepalives
/// and the chosen key first (`IdentitiesOnly`). The user's own `~/.ssh/config` still applies to
/// everything these arguments do not set (extra `IdentityFile`s, `ProxyJump`, `ForwardAgent`…):
/// whether to ignore it (`-F`) is a product decision, see the audit (R-112).
fn verified_options(store: &Store, host: &Host) -> Result<Vec<String>> {
    let mut args: Vec<String> = [
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        "ControlMaster=no",
        "-o",
        "ServerAliveInterval=30",
        "-o",
        "ServerAliveCountMax=3",
        "-o",
        "ConnectTimeout=10",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    args.extend(["-o".into(), known_hosts_option(store)?]);
    if let Some(key) = &host.key {
        args.extend([
            "-i".into(),
            crate::ssh::keys::path(store, key)?
                .to_string_lossy()
                .into_owned(),
            "-o".into(),
            "IdentitiesOnly=yes".into(),
        ]);
    } else if let Some(identity) = &host.identity {
        args.extend([
            "-i".into(),
            identity_file(identity)?.to_string_lossy().into_owned(),
            "-o".into(),
            "IdentitiesOnly=yes".into(),
        ]);
    }
    Ok(args)
}

/// `ProxyCommand=…` that reaches the target through `jump` with the same verified options (the
/// jump's host key is checked strictly too). ssh runs it with /bin/sh, so every argument is
/// validated before and single-quoted here, and `%` is escaped except in `-W`'s own tokens.
fn proxy_command(store: &Store, jump: &Host, batch: bool) -> Result<String> {
    let mut argv = vec![SSH.to_string()];
    argv.extend(verified_options(store, jump)?);
    if batch {
        argv.extend(["-o".into(), "BatchMode=yes".into()]);
    }
    argv.extend(["-p".into(), jump.port.to_string()]);
    let mut command: Vec<String> = argv
        .iter()
        .map(|a| shell_quote(&a.replace('%', "%%")))
        .collect();
    command.push("-W".into());
    command.push("'[%h]:%p'".into());
    command.push("'--'".into());
    command.push(shell_quote(&jump.destination().replace('%', "%%")));
    Ok(format!("ProxyCommand={}", command.join(" ")))
}

/// Options for `/usr/bin/ssh` (and, with `-P`, sftp): verified keys, the key, the jump.
pub fn connection_options(store: &Store, host: &Host, batch: bool) -> Result<Vec<String>> {
    let mut args = verified_options(store, host)?;
    if batch {
        args.extend(["-o".into(), "BatchMode=yes".into()]);
    }
    if let Some(jump) = jump_of(store, host)? {
        args.extend(["-o".into(), proxy_command(store, &jump, batch)?]);
    }
    Ok(args)
}

/// Every argument of an interactive session, ending with `-- user@host`.
pub fn session_args(store: &Store, host: &Host) -> Result<Vec<String>> {
    host.validate()?;
    let mut args = connection_options(store, host, false)?;
    args.extend([
        "-p".into(),
        host.port.to_string(),
        "--".into(),
        host.destination(),
    ]);
    Ok(args)
}

/// A command the user can paste in any terminal: the same verified options, quoted.
pub fn command_line(store: &Store, host: &Host) -> Result<String> {
    Ok(std::iter::once(SSH.to_string())
        .chain(session_args(store, host)?)
        .map(|a| shell_quote(&a))
        .collect::<Vec<_>>()
        .join(" "))
}

/// The script Terminal.app runs: it removes itself and replaces the shell with ssh. Every value
/// is validated before and single-quoted here.
pub fn session_script(store: &Store, host: &Host) -> Result<String> {
    let title = format!("{} — {}", host.name, host.destination());
    Ok([
        "#!/bin/zsh".to_string(),
        "rm -f -- \"$0\"".into(),
        // Window title (OSC 0); the name is free text, so it goes through printf %s.
        format!("printf '\\033]0;%s\\007' {}", shell_quote(&title)),
        format!("exec {}", command_line(store, host)?),
    ]
    .join("\n")
        + "\n")
}

/// Opens an interactive session in Terminal.app (the secondary option; the app embeds its own).
pub fn open(store: &Store, id: &str) -> Result<()> {
    let host = find(store, id)?;
    host.validate()?;
    let token = format!("{:x}", now_nanos());
    let script = store.directory("run")?.join(format!("ssh-{token}.command"));
    write_private(&script, &session_script(store, &host)?)?;
    std::fs::set_permissions(&script, std::os::unix::fs::PermissionsExt::from_mode(0o700))?;
    if std::env::var_os("BUTAKE_STACK_NO_TERMINAL").is_some() {
        return Ok(());
    }
    let status = Command::new("/usr/bin/open")
        .args(["-a", "Terminal"])
        .arg(&script)
        .env_clear()
        .status()?;
    if !status.success() {
        let _ = std::fs::remove_file(&script);
        bail!("terminal_failed");
    }
    Ok(())
}

/// Request methods of the plugin (`ssh*`, except the base's `sshKey*`).
pub fn dispatch(
    store: &Store,
    method: &str,
    request: &serde_json::Value,
) -> Result<serde_json::Value> {
    crate::app::plugins::require(store, "ssh-terminal")?;
    if method.starts_with("sshSnippet") {
        return crate::ssh::snippets::dispatch(store, method, request);
    }
    if method.starts_with("sshConfig") {
        return crate::ssh::config::dispatch(store, method, request);
    }
    if method.starts_with("sshSftp") {
        return crate::ssh::sftp::dispatch(store, method, request);
    }
    let text = |key: &str| request[key].as_str().unwrap_or("").to_string();
    match method {
        "sshHosts" => overview(store),
        "sshSaveHost" => {
            let host: Host = serde_json::from_value(request["host"].clone())
                .map_err(|_| anyhow::anyhow!("invalid_ssh_host"))?;
            Ok(serde_json::to_value(save(store, host)?)?)
        }
        "sshUpdateHosts" => {
            let hosts: Vec<Host> = serde_json::from_value(request["hosts"].clone())
                .map_err(|_| anyhow::anyhow!("invalid_ssh_host"))?;
            Ok(serde_json::to_value(update_many(store, hosts)?)?)
        }
        "sshDeleteHost" => {
            delete(store, &text("id"))?;
            Ok(serde_json::json!(true))
        }
        "sshHostCheck" => check(store, &text("id")),
        "sshTrust" => {
            ensure!(request["confirmed"] == true, "confirmation_required");
            let seen: Vec<String> =
                serde_json::from_value(request["fingerprints"].clone()).unwrap_or_default();
            trust(store, &text("id"), &seen)?;
            Ok(serde_json::json!(true))
        }
        // The embedded terminal runs exactly this (the app adds only the environment).
        "sshSession" => {
            let host = find(store, &text("id"))?;
            Ok(serde_json::json!({
                "executable": SSH,
                "args": session_args(store, &host)?,
                "title": format!("{} — {}", host.name, host.destination()),
            }))
        }
        "sshCommand" => Ok(serde_json::json!(command_line(
            store,
            &find(store, &text("id"))?
        )?)),
        "sshOpen" => {
            open(store, &text("id"))?;
            Ok(serde_json::json!(true))
        }
        "sshForwardStart" => Ok(serde_json::json!(start_forward(
            store,
            &text("id"),
            &text("forward")
        )?)),
        "sshForwardStop" => {
            stop_forward(store, &text("id"), &text("forward"));
            Ok(serde_json::json!(true))
        }
        "sshHeal" => heal(store),
        _ => bail!("invalid_request"),
    }
}

#[cfg(test)]
mod tests;
