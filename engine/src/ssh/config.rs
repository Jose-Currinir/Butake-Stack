//! Import of `~/.ssh/config` into the SSH terminal: an own parser (no `ssh -G`, nothing runs) of
//! the directives Stack keeps — Host, HostName, User, Port, IdentityFile, ProxyJump and the three
//! kinds of forwards — with `Include`, wildcard blocks (`Host *`) applied as ssh does (the first
//! value obtained wins) and `Match` blocks skipped. The file is only read, never written; the
//! app shows a preview and imports only what the user selects.
use crate::{
    core::store::Store,
    core::validate,
    ssh::hosts::{self, Forward, Host},
};
use anyhow::{Result, bail, ensure};
use serde::Serialize;
use std::path::{Path, PathBuf};

const MAX_FILE: u64 = 1024 * 1024;
const MAX_FILES: usize = 64;

/// One `Host` section (or the lines before the first one, which apply to every host).
#[derive(Debug, Default)]
struct Block {
    patterns: Vec<String>,
    /// `Match` sections are not evaluated: their lines are ignored.
    skipped: bool,
    options: Vec<(String, Vec<String>)>,
}

/// Splits a line into its keyword (lowercase) and arguments: `Key value`, `Key=value`, and
/// double-quoted arguments. Comments and empty lines give nothing.
fn tokenize(line: &str) -> Option<(String, Vec<String>)> {
    let line = line.trim();
    if line.is_empty() || line.starts_with('#') {
        return None;
    }
    let split = line
        .find(|c: char| c.is_whitespace() || c == '=')
        .unwrap_or(line.len());
    let key = line[..split].to_lowercase();
    let mut rest = line[split..].trim_start();
    if let Some(stripped) = rest.strip_prefix('=') {
        rest = stripped.trim_start();
    }
    let mut args = vec![];
    let mut current = String::new();
    let mut quoted = false;
    let mut started = false;
    for c in rest.chars() {
        match c {
            '"' => {
                quoted = !quoted;
                started = true;
            }
            c if c.is_whitespace() && !quoted => {
                if started {
                    args.push(std::mem::take(&mut current));
                    started = false;
                }
            }
            '#' if !quoted && !started => break,
            c => {
                current.push(c);
                started = true;
            }
        }
    }
    if started {
        args.push(current);
    }
    Some((key, args))
}

/// `~` and `~/…` against the home folder; relative paths are taken from `base`.
fn expand(path: &str, home: &Path, base: &Path) -> PathBuf {
    if path == "~" {
        home.to_path_buf()
    } else if let Some(rest) = path.strip_prefix("~/") {
        home.join(rest)
    } else if path.starts_with('/') {
        PathBuf::from(path)
    } else {
        base.join(path)
    }
}

/// Shell-like `*` and `?` matching (ssh's host patterns), ignoring case.
fn glob(pattern: &str, text: &str) -> bool {
    fn inner(p: &[char], t: &[char]) -> bool {
        match (p.first(), t.first()) {
            (None, None) => true,
            (Some('*'), _) => inner(&p[1..], t) || (!t.is_empty() && inner(p, &t[1..])),
            (Some('?'), Some(_)) => inner(&p[1..], &t[1..]),
            (Some(a), Some(b)) => a == b && inner(&p[1..], &t[1..]),
            _ => false,
        }
    }
    let p: Vec<char> = pattern.to_lowercase().chars().collect();
    let t: Vec<char> = text.to_lowercase().chars().collect();
    inner(&p, &t)
}

/// Whether a `Host` line applies to an alias: one pattern matches and no `!pattern` does.
fn matches(patterns: &[String], alias: &str) -> bool {
    let mut hit = false;
    for pattern in patterns {
        if let Some(negated) = pattern.strip_prefix('!') {
            if glob(negated, alias) {
                return false;
            }
        } else if glob(pattern, alias) {
            hit = true;
        }
    }
    hit
}

struct Reader<'a> {
    home: &'a Path,
    ssh_dir: PathBuf,
    files: usize,
    blocks: Vec<Block>,
}

impl Reader<'_> {
    fn read(&mut self, path: &Path, depth: usize) -> Result<()> {
        ensure!(
            depth <= 8 && self.files < MAX_FILES,
            "ssh_config_unreadable"
        );
        self.files += 1;
        let meta = std::fs::metadata(path).map_err(|_| anyhow::anyhow!("ssh_config_unreadable"))?;
        ensure!(
            meta.is_file() && meta.len() <= MAX_FILE,
            "ssh_config_unreadable"
        );
        let text =
            std::fs::read_to_string(path).map_err(|_| anyhow::anyhow!("ssh_config_unreadable"))?;
        for line in text.lines() {
            let Some((key, args)) = tokenize(line) else {
                continue;
            };
            match key.as_str() {
                "host" => self.blocks.push(Block {
                    patterns: args,
                    ..Default::default()
                }),
                "match" => self.blocks.push(Block {
                    skipped: true,
                    ..Default::default()
                }),
                "include" => {
                    // What an included file says belongs to the block that includes it; afterwards
                    // the including block goes on.
                    let resume = self.blocks.last().map(|b| (b.patterns.clone(), b.skipped));
                    for pattern in &args {
                        for file in self.include_targets(pattern) {
                            // A missing or unreadable include is skipped, as ssh does.
                            let _ = self.read(&file, depth + 1);
                        }
                    }
                    if let Some((patterns, skipped)) = resume {
                        self.blocks.push(Block {
                            patterns,
                            skipped,
                            ..Default::default()
                        });
                    }
                }
                _ => {
                    if self.blocks.is_empty() {
                        self.blocks.push(Block {
                            patterns: vec!["*".into()],
                            ..Default::default()
                        });
                    }
                    if let Some(block) = self.blocks.last_mut() {
                        block.options.push((key, args));
                    }
                }
            }
        }
        Ok(())
    }

    /// Files an `Include` names: relative to ~/.ssh, with `*` / `?` in the file name only.
    fn include_targets(&self, pattern: &str) -> Vec<PathBuf> {
        let path = expand(pattern, self.home, &self.ssh_dir);
        let name = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        if !name.contains(['*', '?']) {
            return vec![path];
        }
        let Some(dir) = path.parent() else {
            return vec![];
        };
        let mut found: Vec<PathBuf> = std::fs::read_dir(dir)
            .map(|entries| {
                entries
                    .filter_map(|e| e.ok())
                    .map(|e| e.path())
                    .filter(|p| {
                        p.file_name()
                            .is_some_and(|n| glob(&name, &n.to_string_lossy()))
                    })
                    .collect()
            })
            .unwrap_or_default();
        found.sort();
        found
    }
}

/// What the preview shows for one `Host` alias.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Candidate {
    pub alias: String,
    pub host: Host,
    /// Alias (in this file) or saved host id of the jump, as written.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub jump_alias: Option<String>,
    /// Codes of what could not be kept (the app explains each).
    pub warnings: Vec<String>,
    pub importable: bool,
    /// A saved host with the same server, port and user.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub existing: Option<String>,
}

fn port_of(text: &str) -> Option<u16> {
    text.parse::<u16>().ok().filter(|p| *p > 0)
}

/// "[bind:]port" → port, warning when the bind address is not a loopback one (Stack always
/// binds to 127.0.0.1).
fn listen_of(text: &str, warnings: &mut Vec<String>) -> Option<u16> {
    let (bind, port) = match text.rfind(':') {
        Some(i) => (&text[..i], &text[i + 1..]),
        None => ("", text),
    };
    let bind = bind.trim_matches(['[', ']']);
    if !bind.is_empty() && !matches!(bind, "localhost" | "127.0.0.1" | "::1") {
        warnings.push("forward_bind_loopback".into());
    }
    port_of(port)
}

/// "host:port" or "[v6]:port".
fn target_of(text: &str) -> Option<(String, u16)> {
    if let Some(rest) = text.strip_prefix('[') {
        let (host, port) = rest.split_once("]:")?;
        return Some((host.to_string(), port_of(port)?));
    }
    let (host, port) = text.rsplit_once(':')?;
    Some((host.to_string(), port_of(port)?))
}

/// `%h`, `%r`, `%u`, `%d`, `%%` in HostName and IdentityFile; anything else makes it unusable.
fn tokens(text: &str, host: &str, user: &str, home: &Path) -> Option<String> {
    let mut out = String::new();
    let mut chars = text.chars();
    while let Some(c) = chars.next() {
        if c != '%' {
            out.push(c);
            continue;
        }
        match chars.next()? {
            'h' => out.push_str(host),
            'r' | 'u' => out.push_str(user),
            'd' => out.push_str(&home.to_string_lossy()),
            '%' => out.push('%'),
            _ => return None,
        }
    }
    Some(out)
}

/// A private key file inside `<home>/.ssh` (canonicalized: no way out through links), as the
/// hosts require when they are saved.
fn inside_ssh(path: &Path, ssh_dir: &Path) -> Result<PathBuf> {
    let dir = ssh_dir.canonicalize()?;
    let path = path.canonicalize()?;
    ensure!(path.starts_with(&dir) && path.is_file(), "invalid_ssh");
    Ok(path)
}

fn local_user() -> String {
    std::env::var("USER")
        .ok()
        .filter(|u| validate::user(u))
        .unwrap_or_else(|| "root".into())
}

/// The effective settings of one alias, as ssh would compute them from these blocks.
fn resolve(blocks: &[Block], alias: &str, home: &Path, saved: &[Host]) -> Candidate {
    let mut single: std::collections::HashMap<&str, &Vec<String>> =
        std::collections::HashMap::new();
    let mut identities: Vec<&String> = vec![];
    let mut forwards: Vec<(&str, &Vec<String>)> = vec![];
    for block in blocks
        .iter()
        .filter(|b| !b.skipped && matches(&b.patterns, alias))
    {
        for (key, args) in &block.options {
            match key.as_str() {
                "identityfile" => identities.extend(args.first()),
                "localforward" | "remoteforward" | "dynamicforward" => {
                    forwards.push((key.as_str(), args))
                }
                "hostname" | "user" | "port" | "proxyjump" | "proxycommand" => {
                    single.entry(key.as_str()).or_insert(args);
                }
                _ => {}
            }
        }
    }
    let first = |key: &str| single.get(key).and_then(|a| a.first()).cloned();
    let mut warnings: Vec<String> = vec![];
    let user = first("user").unwrap_or_else(local_user);
    let hostname = first("hostname")
        .and_then(|h| tokens(&h, alias, &user, home))
        .unwrap_or_else(|| alias.to_string());
    let port = match first("port") {
        Some(text) => port_of(&text).unwrap_or_else(|| {
            warnings.push("port_invalid".into());
            22
        }),
        None => 22,
    };
    if first("proxycommand").is_some_and(|c| !c.eq_ignore_ascii_case("none")) {
        warnings.push("proxy_command_ignored".into());
    }
    let ssh_dir = home.join(".ssh");
    let mut identity = None;
    if let Some(raw) = identities.first() {
        match tokens(raw, &hostname, &user, home)
            .map(|p| expand(&p, home, home))
            .map(|p| inside_ssh(&p, &ssh_dir))
        {
            Some(Ok(path)) => identity = Some(path),
            _ => warnings.push("identity_unusable".into()),
        }
        if identities.len() > 1 {
            warnings.push("identity_extra".into());
        }
    }
    let mut jump_alias = None;
    if let Some(value) = first("proxyjump").filter(|v| !v.eq_ignore_ascii_case("none")) {
        if value.contains(',') {
            warnings.push("jump_multi_hop".into());
        } else {
            jump_alias = Some(value);
        }
    }
    let mut list = vec![];
    let mut taken: Vec<String> = vec![];
    for (kind, args) in forwards {
        let kind = match kind {
            "localforward" => "local",
            "remoteforward" => "remote",
            _ => "dynamic",
        };
        let parsed = match (kind, args.as_slice()) {
            ("dynamic", [listen, ..]) => {
                listen_of(listen, &mut warnings).map(|p| (p, String::new(), 0))
            }
            (_, [listen, target, ..]) if !listen.contains('/') && !target.contains('/') => {
                listen_of(listen, &mut warnings)
                    .zip(target_of(target))
                    .map(|(p, (h, t))| (p, h, t))
            }
            _ => None,
        };
        match parsed {
            Some((listen, target_host, target_port))
                if listen >= 1024 && (kind == "dynamic" || validate::host(&target_host)) =>
            {
                let id = hosts::unique(format!("{kind}-{listen}"), |id| {
                    taken.iter().any(|t| t == id)
                });
                taken.push(id.clone());
                list.push(Forward {
                    id,
                    name: String::new(),
                    kind: kind.into(),
                    listen_port: listen,
                    target_host,
                    target_port,
                    autostart: false,
                    keep_alive: false,
                });
            }
            _ => warnings.push("forward_skipped".into()),
        }
    }
    warnings.sort();
    warnings.dedup();
    let host = Host {
        id: String::new(),
        name: alias.chars().take(80).collect(),
        description: String::new(),
        group: String::new(),
        tags: vec!["ssh_config".into()],
        host: hostname,
        port,
        user,
        key: None,
        identity,
        jump: None,
        forwards: list,
    };
    let importable = validate::host(&host.host)
        && validate::user(&host.user)
        && !host.name.chars().any(char::is_control);
    let existing = saved
        .iter()
        .find(|s| {
            s.host.eq_ignore_ascii_case(&host.host) && s.port == host.port && s.user == host.user
        })
        .map(|s| s.id.clone());
    Candidate {
        alias: alias.to_string(),
        host,
        jump_alias,
        warnings,
        importable,
        existing,
    }
}

/// The config file to read: the one given (absolute, a regular file) or ~/.ssh/config.
fn source(path: &str) -> Result<(PathBuf, PathBuf)> {
    let home = Store::home().ok_or_else(|| anyhow::anyhow!("ssh_config_unreadable"))?;
    let path = if path.is_empty() {
        home.join(".ssh").join("config")
    } else {
        PathBuf::from(path)
    };
    ensure!(path.is_absolute(), "ssh_config_unreadable");
    let path = path
        .canonicalize()
        .map_err(|_| anyhow::anyhow!("ssh_config_unreadable"))?;
    Ok((path, home))
}

fn parse(path: &Path, home: &Path) -> Result<Vec<Block>> {
    let mut reader = Reader {
        home,
        ssh_dir: home.join(".ssh"),
        files: 0,
        blocks: vec![],
    };
    reader.read(path, 0)?;
    Ok(reader.blocks)
}

/// Every concrete alias of the file (patterns with wildcards or `!` only give defaults).
pub fn preview_file(path: &Path, home: &Path, saved: &[Host]) -> Result<Vec<Candidate>> {
    let blocks = parse(path, home)?;
    let mut aliases: Vec<String> = vec![];
    for block in blocks.iter().filter(|b| !b.skipped) {
        for pattern in &block.patterns {
            if !pattern.contains(['*', '?', '!']) && !aliases.contains(pattern) {
                aliases.push(pattern.clone());
            }
        }
    }
    Ok(aliases
        .iter()
        .take(500)
        .map(|alias| resolve(&blocks, alias, home, saved))
        .collect())
}

pub fn preview(store: &Store, path: &str) -> Result<Vec<Candidate>> {
    let (path, home) = source(path)?;
    preview_file(&path, &home, &hosts::list(store)?)
}

/// Saves the selected aliases as hosts. Jumps point to an alias imported now or to a saved host
/// with the same server; hosts are saved after the hosts they jump through.
pub fn import(store: &Store, path: &str, aliases: &[String]) -> Result<serde_json::Value> {
    ensure!(
        !aliases.is_empty() && aliases.len() <= 500,
        "invalid_request"
    );
    let candidates = preview(store, path)?;
    let mut chosen: Vec<&Candidate> = candidates
        .iter()
        .filter(|c| aliases.contains(&c.alias) && c.importable)
        .collect();
    chosen.sort_by_key(|c| c.jump_alias.is_some());
    let mut ids: std::collections::HashMap<String, String> = std::collections::HashMap::new();
    let mut imported = vec![];
    let mut skipped = vec![];
    for candidate in chosen {
        let mut host = candidate.host.clone();
        if let Some(jump) = &candidate.jump_alias {
            let target = jump.rsplit('@').next().unwrap_or(jump);
            let bare = target.split(':').next().unwrap_or(target);
            let found = ids
                .get(jump)
                .cloned()
                .or_else(|| {
                    candidates
                        .iter()
                        .find(|c| &c.alias == jump)
                        .and_then(|c| c.existing.clone())
                })
                .or_else(|| {
                    hosts::list(store)
                        .ok()?
                        .into_iter()
                        .find(|h| h.host.eq_ignore_ascii_case(bare))
                        .map(|h| h.id)
                });
            match found {
                Some(id) => host.jump = Some(id),
                None => {
                    skipped.push(
                        serde_json::json!({"alias": candidate.alias, "reason": "jump_unknown"}),
                    );
                    continue;
                }
            }
        }
        match hosts::save(store, host) {
            Ok(saved) => {
                ids.insert(candidate.alias.clone(), saved.id.clone());
                imported.push(saved.id);
            }
            Err(error) => skipped
                .push(serde_json::json!({"alias": candidate.alias, "reason": error.to_string()})),
        }
    }
    Ok(serde_json::json!({"imported": imported, "skipped": skipped}))
}

pub fn dispatch(
    store: &Store,
    method: &str,
    request: &serde_json::Value,
) -> Result<serde_json::Value> {
    let path = request["path"].as_str().unwrap_or("");
    match method {
        "sshConfigPreview" => Ok(serde_json::to_value(preview(store, path)?)?),
        "sshConfigImport" => {
            let aliases: Vec<String> =
                serde_json::from_value(request["aliases"].clone()).unwrap_or_default();
            import(store, path, &aliases)
        }
        _ => bail!("invalid_request"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tokenizes_like_ssh() {
        assert_eq!(
            tokenize("  HostName=db.interna "),
            Some(("hostname".into(), vec!["db.interna".into()]))
        );
        assert_eq!(
            tokenize("IdentityFile \"~/.ssh/mi clave\" # nota"),
            Some(("identityfile".into(), vec!["~/.ssh/mi clave".into()]))
        );
        assert_eq!(tokenize("# comentario"), None);
        assert!(matches(&["*.cl".into(), "!prod.cl".into()], "web.cl"));
        assert!(!matches(&["*.cl".into(), "!prod.cl".into()], "PROD.cl"));
        assert!(glob("web-?", "web-1") && !glob("web-?", "web-10"));
    }

    #[test]
    fn previews_hosts_with_defaults_includes_jumps_and_forwards() {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path().join("home");
        let ssh = home.join(".ssh");
        std::fs::create_dir_all(ssh.join("conf.d")).unwrap();
        std::fs::write(ssh.join("id_web"), "x").unwrap();
        std::fs::write(home.join("outside"), "x").unwrap();
        std::fs::write(
            ssh.join("conf.d/extra.conf"),
            "Host extra\n  HostName extra.ejemplo.cl\n",
        )
        .unwrap();
        let config = ssh.join("config");
        std::fs::write(
            &config,
            "\
User global
Include conf.d/*.conf

Host bastion
  HostName bastion.ejemplo.cl
  Port 2222
  IdentityFile ~/.ssh/id_web

Host web web-alias
  HostName %h.interna
  User deploy
  ProxyJump bastion
  LocalForward 15432 db.interna:5432
  LocalForward 0.0.0.0:16000 [::1]:6000
  RemoteForward 80 localhost:8080
  DynamicForward 18080
  IdentityFile ~/outside

Host *.cl !prod.cl
  User wildcard

Match host foo
  User matched

Host *
  User fallback
  Port 22
",
        )
        .unwrap();
        let list = preview_file(&config, &home, &[]).unwrap();
        let aliases: Vec<&str> = list.iter().map(|c| c.alias.as_str()).collect();
        assert_eq!(aliases, vec!["extra", "bastion", "web", "web-alias"]);
        let bastion = &list[1];
        assert_eq!(
            (
                bastion.host.host.as_str(),
                bastion.host.port,
                bastion.host.user.as_str()
            ),
            ("bastion.ejemplo.cl", 2222, "global")
        );
        assert!(
            bastion
                .host
                .identity
                .as_ref()
                .unwrap()
                .ends_with(".ssh/id_web")
                && bastion.warnings.is_empty()
        );
        let web = &list[2];
        assert_eq!(
            (web.host.host.as_str(), web.host.user.as_str()),
            ("web.interna", "global")
        );
        assert_eq!(web.jump_alias.as_deref(), Some("bastion"));
        assert_eq!(web.host.forwards.len(), 3);
        assert_eq!(web.host.forwards[1].target_host, "::1");
        assert!(
            web.host
                .forwards
                .iter()
                .any(|f| f.kind == "dynamic" && f.listen_port == 18080)
        );
        assert!(web.host.identity.is_none());
        assert_eq!(
            web.warnings,
            vec![
                "forward_bind_loopback",
                "forward_skipped",
                "identity_unusable"
            ]
        );
        assert_eq!(list[0].host.host, "extra.ejemplo.cl");
    }

    #[test]
    fn imports_selected_hosts_after_their_jump_without_touching_the_file() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::new(temp.path().join("store")).unwrap();
        let config = temp.path().join("config");
        let text = "Host interno\n  HostName 10.0.0.5\n  User app\n  ProxyJump bastion\nHost bastion\n  HostName bastion.ejemplo.cl\n  User ops\nHost huerfano\n  HostName 10.0.0.9\n  User app\n  ProxyJump otro\nHost malo\n  HostName -oProxyCommand=x\n";
        std::fs::write(&config, text).unwrap();
        let path = config.to_string_lossy().into_owned();
        let preview = preview(&store, &path).unwrap();
        assert!(
            !preview
                .iter()
                .find(|c| c.alias == "malo")
                .unwrap()
                .importable
        );
        let result = import(
            &store,
            &path,
            &[
                "interno".into(),
                "bastion".into(),
                "huerfano".into(),
                "malo".into(),
            ],
        )
        .unwrap();
        assert_eq!(
            result["imported"],
            serde_json::json!(["bastion", "interno"])
        );
        assert_eq!(result["skipped"][0]["reason"], "jump_unknown");
        let hosts = hosts::list(&store).unwrap();
        assert_eq!(
            hosts
                .iter()
                .find(|h| h.id == "interno")
                .unwrap()
                .jump
                .as_deref(),
            Some("bastion")
        );
        assert_eq!(std::fs::read_to_string(&config).unwrap(), text);
        // A second preview recognizes what is already saved.
        assert_eq!(
            preview_file(&config, temp.path(), &hosts).unwrap()[1]
                .existing
                .as_deref(),
            Some("bastion")
        );
    }
}
