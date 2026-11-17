//! SFTP browser of the SSH terminal: `/usr/bin/sftp` in batch mode with the same verified
//! options as the sessions (StrictHostKeyChecking=yes, Stack's known_hosts, the chosen key, the
//! jump host). Batch mode never asks anything, so it works with keys and the agent.
//!
//! Paths travel inside sftp's own command language, never a shell. Every remote path is
//! absolute (so none can be read as an option) and is escaped character by character for how
//! sftp reads each command: commands that expand wildcards (`ls`, `get`, `put`, `rm`) keep `*`,
//! `?`, `[` and `\` escaped so they stay literal; the others (`rename`, `mkdir`, `rmdir`) cannot
//! express a backslash, so such names are refused.
use crate::core::time::now_nanos;
use crate::{
    core::fsutil::write_private,
    core::store::Store,
    ssh::common::ssh_error,
    ssh::hosts::{self, Host},
};
use anyhow::{bail, ensure, Result};
use serde::Serialize;
use std::{
    io::Write,
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

pub const SFTP: &str = "/usr/bin/sftp";
const MAX_ENTRIES: usize = 5000;

/// A remote path: absolute, printable, reasonable length; "." and ".." are resolved away.
fn remote(path: &str) -> Result<String> {
    ensure!(
        path.starts_with('/') && path.len() <= 4096 && !path.chars().any(char::is_control),
        "sftp_unsupported_name"
    );
    let mut parts: Vec<&str> = vec![];
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            part => parts.push(part),
        }
    }
    Ok(format!("/{}", parts.join("/")))
}

fn join(dir: &str, name: &str) -> String {
    if dir.ends_with('/') {
        format!("{dir}{name}")
    } else {
        format!("{dir}/{name}")
    }
}

/// For commands that expand wildcards: every ASCII punctuation or space escaped (sftp keeps
/// `\*`, `\?`, `\[`, `\\` for the wildcard step, which makes them literal).
fn glob_arg(path: &str) -> String {
    let mut out = String::with_capacity(path.len() + 8);
    for c in path.chars() {
        if c.is_ascii() && !c.is_ascii_alphanumeric() && !matches!(c, '/' | '.' | '_' | '-') {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

/// For commands that take the path as it is: wildcards stay unescaped (they are literal there),
/// the rest of the punctuation is escaped; a backslash cannot be expressed.
fn plain_arg(path: &str) -> Result<String> {
    ensure!(!path.contains('\\'), "sftp_unsupported_name");
    let mut out = String::with_capacity(path.len() + 8);
    for c in path.chars() {
        if c.is_ascii()
            && !c.is_ascii_alphanumeric()
            && !matches!(c, '/' | '.' | '_' | '-' | '*' | '?' | '[')
        {
            out.push('\\');
        }
        out.push(c);
    }
    Ok(out)
}

/// `user@host` for sftp (an IPv6 address goes in brackets).
fn destination(host: &Host) -> String {
    if host.host.contains(':') {
        format!("{}@[{}]", host.user, host.host)
    } else {
        host.destination()
    }
}

/// Every argument before `-b`: the verified options of the host and its port.
fn arguments(store: &Store, host: &Host) -> Result<Vec<String>> {
    host.validate()?;
    let mut args = hosts::connection_options(store, host, true)?;
    args.extend(["-P".into(), host.port.to_string()]);
    Ok(args)
}

fn environment(command: &mut Command) {
    command.env_clear();
    if let Some(home) = Store::home() {
        command.env("HOME", home);
    }
    if let Some(agent) = std::env::var_os("SSH_AUTH_SOCK") {
        command.env("SSH_AUTH_SOCK", agent);
    }
}

/// The error code for what sftp (or its ssh) wrote.
fn sftp_error(text: &str) -> &'static str {
    match ssh_error(text) {
        "ssh_failed" | "ssh_auth_failed" if !text.contains("Permission denied (") => {
            if text.contains("No such file") || text.contains("not found") {
                "sftp_not_found"
            } else if text.contains("Permission denied") {
                "sftp_denied"
            } else {
                "sftp_failed"
            }
        }
        code => code,
    }
}

/// Runs a batch on stdin (`-b -`) and returns stdout. A failing command stops the batch.
fn run(store: &Store, host: &Host, batch: &str) -> Result<String> {
    let mut command = Command::new(SFTP);
    command
        .args(arguments(store, host)?)
        .args(["-b", "-", "--"])
        .arg(destination(host));
    environment(&mut command);
    let mut child = command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| anyhow::anyhow!("sftp_failed"))?;
    // Written from its own thread: sftp echoes every command to stdout, and a big batch would
    // fill both pipes with each side waiting for the other.
    let batch = batch.to_string();
    let writer = std::thread::spawn(move || {
        let _ = stdin.write_all(batch.as_bytes());
    });
    let out = child.wait_with_output()?;
    let _ = writer.join();
    if !out.status.success() {
        bail!(sftp_error(&String::from_utf8_lossy(&out.stderr)));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub name: String,
    /// "dir", "file" or "link".
    pub kind: String,
    pub size: u64,
    /// "2026-11-12 21:01" (or only the date for older files), in this Mac's time zone.
    pub modified: String,
    pub mode: String,
}

/// "Nov 12 21:01" (this year or the last one) or "Nov 12 2024" → "2026-11-12 21:01" / "2024-11-12".
fn modified(month: &str, day: &str, last: &str, today: (i64, u32, u32)) -> String {
    const MONTHS: [&str; 12] = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ];
    let Some(m) = MONTHS
        .iter()
        .position(|n| *n == month)
        .map(|i| i as u32 + 1)
    else {
        return format!("{month} {day} {last}");
    };
    let d: u32 = day.parse().unwrap_or(1);
    if last.contains(':') {
        let year = if (m, d) > (today.1, today.2) {
            today.0 - 1
        } else {
            today.0
        };
        format!("{year}-{m:02}-{d:02} {last}")
    } else {
        format!("{last}-{m:02}-{d:02}")
    }
}

/// Entries of `ls -lna <dir>` (sftp prints each with the directory in front).
fn parse_listing(text: &str, dir: &str, today: (i64, u32, u32)) -> Vec<Entry> {
    let prefix = if dir == "/" {
        "/".to_string()
    } else {
        format!("{dir}/")
    };
    let mut entries = vec![];
    for line in text.lines().filter(|l| !l.starts_with("sftp>")) {
        // Fields with their offsets: the path starts at the ninth and runs to the end of the line
        // (names may hold spaces).
        let mut fields: Vec<&str> = vec![];
        let mut offsets: Vec<usize> = vec![];
        let mut start: Option<usize> = None;
        for (i, c) in line
            .char_indices()
            .chain(std::iter::once((line.len(), ' ')))
        {
            match (c.is_whitespace(), start) {
                (true, Some(s)) => {
                    fields.push(&line[s..i]);
                    offsets.push(s);
                    start = None;
                }
                (false, None) => start = Some(i),
                _ => {}
            }
            if fields.len() == 9 {
                break;
            }
        }
        if fields.len() < 9 || fields[0].len() < 10 {
            continue;
        }
        let path = &line[offsets[8]..];
        let name = path.strip_prefix(&prefix).unwrap_or(path);
        if name.is_empty() || name == "." || name == ".." || name.contains('/') {
            continue;
        }
        let kind = match fields[0].chars().next() {
            Some('d') => "dir",
            Some('l') => "link",
            _ => "file",
        };
        entries.push(Entry {
            name: name.to_string(),
            kind: kind.into(),
            size: fields[4].parse().unwrap_or(0),
            modified: modified(fields[5], fields[6], fields[7], today),
            mode: fields[0].to_string(),
        });
    }
    entries.sort_by_key(|e| (e.kind != "dir", e.name.to_lowercase()));
    entries
}

fn today() -> (i64, u32, u32) {
    let mut now: libc::time_t = 0;
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    unsafe {
        libc::time(&mut now);
        libc::localtime_r(&now, &mut tm);
    }
    (
        tm.tm_year as i64 + 1900,
        tm.tm_mon as u32 + 1,
        tm.tm_mday as u32,
    )
}

/// The folder (the home folder when `path` is empty) and its entries.
pub fn list(store: &Store, host: &Host, path: &str) -> Result<serde_json::Value> {
    let batch = if path.is_empty() {
        "pwd\n".to_string()
    } else {
        format!("cd {}\npwd\n", plain_arg(&remote(path)?)?)
    };
    let out = run(store, host, &batch)?;
    let dir = out
        .lines()
        .find_map(|l| l.strip_prefix("Remote working directory: "))
        .map(str::to_string)
        .ok_or_else(|| anyhow::anyhow!("sftp_failed"))?;
    let dir = remote(&dir)?;
    let out = run(store, host, &format!("ls -lna {}\n", glob_arg(&dir)))?;
    let entries = parse_listing(&out, &dir, today());
    ensure!(entries.len() <= MAX_ENTRIES, "sftp_too_many");
    Ok(serde_json::json!({"path": dir, "entries": entries}))
}

pub fn mkdir(store: &Store, host: &Host, path: &str) -> Result<()> {
    run(
        store,
        host,
        &format!("mkdir {}\n", plain_arg(&remote(path)?)?),
    )
    .map(|_| ())
}

pub fn rename(store: &Store, host: &Host, from: &str, to: &str) -> Result<()> {
    run(
        store,
        host,
        &format!(
            "rename {} {}\n",
            plain_arg(&remote(from)?)?,
            plain_arg(&remote(to)?)?
        ),
    )
    .map(|_| ())
}

/// Removes a file, a link or (only with `recursive`) a folder and everything inside it. Links
/// are removed, never followed.
pub fn delete(store: &Store, host: &Host, path: &str, kind: &str, recursive: bool) -> Result<()> {
    let path = remote(path)?;
    ensure!(path != "/", "sftp_denied");
    if kind != "dir" {
        return run(store, host, &format!("rm {}\n", glob_arg(&path))).map(|_| ());
    }
    if !recursive {
        return run(store, host, &format!("rmdir {}\n", plain_arg(&path)?))
            .map(|_| ())
            .map_err(|e| match e.to_string().as_str() {
                "sftp_failed" => anyhow::anyhow!("sftp_not_empty"),
                _ => e,
            });
    }
    // Walk level by level (one connection per level), then remove files and folders deepest first.
    let mut files: Vec<String> = vec![];
    let mut dirs: Vec<String> = vec![path.clone()];
    let mut level = vec![path];
    while !level.is_empty() {
        let batch: String = level
            .iter()
            .map(|d| format!("ls -lna {}\n", glob_arg(d)))
            .collect();
        let out = run(store, host, &batch)?;
        let mut next = vec![];
        // Each `ls` output follows its echoed command.
        let mut chunks: Vec<(String, String)> = vec![];
        for line in out.lines() {
            if line.starts_with("sftp> ls ") {
                chunks.push((String::new(), String::new()));
            } else if let Some(chunk) = chunks.last_mut() {
                chunk.1.push_str(line);
                chunk.1.push('\n');
            }
        }
        for (dir, (_, text)) in level.iter().zip(chunks) {
            for entry in parse_listing(&text, dir, today()) {
                let child = join(dir, &entry.name);
                if entry.kind == "dir" {
                    next.push(child.clone());
                    dirs.push(child);
                } else {
                    files.push(child);
                }
            }
        }
        ensure!(files.len() + dirs.len() <= MAX_ENTRIES, "sftp_too_many");
        level = next;
    }
    for dir in &dirs {
        plain_arg(dir)?;
    }
    let mut batch: String = files
        .iter()
        .map(|f| format!("rm {}\n", glob_arg(f)))
        .collect();
    batch.extend(
        dirs.iter()
            .rev()
            .map(|d| format!("rmdir {}\n", plain_arg(d).unwrap_or_default())),
    );
    run(store, host, &batch).map(|_| ())
}

fn batch_dir(store: &Store) -> Result<PathBuf> {
    store.directory("run")
}

/// Prepares a download (`get`) or upload (`put`) with a progress meter: the app runs the
/// returned program in a pseudo-terminal (where sftp shows its meter) and calls `done` after.
/// Folders go recursively. A download never replaces a local file unless `overwrite`.
pub fn transfer(
    store: &Store,
    host: &Host,
    direction: &str,
    remote_path: &str,
    local: &str,
    overwrite: bool,
) -> Result<serde_json::Value> {
    let remote_path = remote(remote_path)?;
    let local = PathBuf::from(local);
    ensure!(
        local.is_absolute() && !local.to_string_lossy().chars().any(char::is_control),
        "sftp_unsupported_name"
    );
    let command = match direction {
        // get <remote> <local folder>/
        "get" => {
            let folder = local
                .canonicalize()
                .map_err(|_| anyhow::anyhow!("sftp_not_found"))?;
            ensure!(folder.is_dir(), "sftp_not_found");
            let name = remote_path.rsplit('/').next().unwrap_or("");
            ensure!(
                !name.is_empty() && name != "." && name != "..",
                "sftp_unsupported_name"
            );
            ensure!(overwrite || !folder.join(name).exists(), "sftp_exists");
            let target = format!("{}/", folder.to_string_lossy().trim_end_matches('/'));
            format!(
                "get -R {} {}\n",
                glob_arg(&remote_path),
                plain_arg(&target)?
            )
        }
        // put <local file or folder> <remote folder>/
        "put" => {
            let source = local
                .canonicalize()
                .map_err(|_| anyhow::anyhow!("sftp_not_found"))?;
            ensure!(source.exists(), "sftp_not_found");
            format!(
                "put -R {} {}/\n",
                glob_arg(&source.to_string_lossy()),
                plain_arg(remote_path.trim_end_matches('/'))?
            )
        }
        _ => bail!("invalid_request"),
    };
    let token = now_nanos();
    let batch = batch_dir(store)?.join(format!("sftp-{token:x}.batch"));
    write_private(&batch, &format!("progress\n{command}"))?;
    let mut args = arguments(store, host)?;
    args.extend([
        "-b".into(),
        batch.to_string_lossy().into_owned(),
        "--".into(),
        destination(host),
    ]);
    Ok(serde_json::json!({"executable": SFTP, "args": args, "batch": batch}))
}

/// Removes a prepared batch once its transfer ended (only Stack's own batch files).
pub fn done(store: &Store, batch: &str) -> Result<()> {
    let path = Path::new(batch);
    let dir = batch_dir(store)?;
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    ensure!(
        path.parent() == Some(dir.as_path())
            && name.starts_with("sftp-")
            && name.ends_with(".batch"),
        "invalid_request"
    );
    let _ = std::fs::remove_file(path);
    Ok(())
}

pub fn dispatch(
    store: &Store,
    method: &str,
    request: &serde_json::Value,
) -> Result<serde_json::Value> {
    let text = |key: &str| request[key].as_str().unwrap_or("").to_string();
    if method == "sshSftpDone" {
        done(store, &text("batch"))?;
        return Ok(serde_json::json!(true));
    }
    let host = hosts::find(store, &text("id"))?;
    match method {
        "sshSftpList" => list(store, &host, &text("path")),
        "sshSftpMkdir" => {
            mkdir(store, &host, &text("path"))?;
            Ok(serde_json::json!(true))
        }
        "sshSftpRename" => {
            rename(store, &host, &text("from"), &text("to"))?;
            Ok(serde_json::json!(true))
        }
        "sshSftpDelete" => {
            ensure!(request["confirmed"] == true, "confirmation_required");
            delete(
                store,
                &host,
                &text("path"),
                &text("kind"),
                request["recursive"] == true,
            )?;
            Ok(serde_json::json!(true))
        }
        "sshSftpTransfer" => transfer(
            store,
            &host,
            &text("direction"),
            &text("remote"),
            &text("local"),
            request["overwrite"] == true,
        ),
        _ => bail!("invalid_request"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn paths_are_absolute_and_escaped_for_each_kind_of_command() {
        assert_eq!(remote("/home/app/../ops/./x").unwrap(), "/home/ops/x");
        assert_eq!(remote("/..").unwrap(), "/");
        assert!(remote("relativo").is_err() && remote("/a\nb").is_err());
        assert_eq!(
            glob_arg("/srv/a*b? [x] #'\"\\ñ.txt"),
            "/srv/a\\*b\\?\\ \\[x\\]\\ \\#\\'\\\"\\\\ñ.txt"
        );
        assert_eq!(
            plain_arg("/srv/a*b? #\"x\"").unwrap(),
            "/srv/a*b?\\ \\#\\\"x\\\""
        );
        assert_eq!(
            plain_arg("/srv/a\\b").unwrap_err().to_string(),
            "sftp_unsupported_name"
        );
        assert_eq!(join("/", "etc"), "/etc");
    }

    #[test]
    fn parses_listings_with_any_name() {
        let text = "\
sftp> ls -lna /srv/app
drwxr-xr-x    ? 501      0             256 Nov 12 21:01 /srv/app/.
drwxr-xr-x    ? 501      0             416 Nov 12 21:01 /srv/app/..
-rw-r--r--    ? 501      0               5 Nov 12 21:01 /srv/app/a*b?.txt
-rw-r--r--    ? 501      0               2 Dec 24  2024 /srv/app/#hash 'q'.txt
drwxr-xr-x    ? 501      0              64 Jan  3 09:15 /srv/app/dir con  espacio
lrwxr-xr-x    ? 501      0               8 Nov 12 21:01 /srv/app/enlace
";
        let entries = parse_listing(text, "/srv/app", (2026, 11, 12));
        let names: Vec<&str> = entries.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(
            names,
            vec!["dir con  espacio", "#hash 'q'.txt", "a*b?.txt", "enlace"]
        );
        assert_eq!(entries[0].kind, "dir");
        assert_eq!(entries[0].modified, "2026-01-03 09:15");
        assert_eq!(entries[1].modified, "2024-12-24");
        assert_eq!(entries[2].size, 5);
        assert_eq!(entries[3].kind, "link");
        // A date later than today belongs to last year.
        assert_eq!(
            modified("Dec", "30", "10:00", (2026, 11, 12)),
            "2025-12-30 10:00"
        );
    }

    #[test]
    fn errors_say_what_failed() {
        assert_eq!(
            sftp_error("remote open(\"/x\"): No such file or directory"),
            "sftp_not_found"
        );
        assert_eq!(
            sftp_error("remote mkdir \"/root/x\": Permission denied"),
            "sftp_denied"
        );
        assert_eq!(
            sftp_error("user@h: Permission denied (publickey)."),
            "ssh_auth_failed"
        );
        assert_eq!(
            sftp_error("Host key verification failed."),
            "ssh_host_unknown"
        );
    }
}
