//! SSH keys kept by Stack for database tunnels: the user imports a private key (`.pem` or OpenSSH)
//! once, names it, describes it and files it in a group; connections then refer to it by id.
//! The key is copied into `config/ssh/keys/<id>` (0600, folder 0700) and its content never leaves
//! the engine: responses only carry the name, description, group, type and fingerprint.
use crate::core::fsutil::private_options;
use crate::core::json;
use crate::core::time::now_secs;
use crate::core::validate;
use crate::{core::fsutil::write_private, core::store::Store};
use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};
use std::{
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct SshKey {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub group: String,
    /// "RSA 2048", "ED25519 256"…
    #[serde(default)]
    pub kind: String,
    /// SHA256:… as `ssh-keygen -l` shows it (what servers' authorized_keys can be compared with).
    #[serde(default)]
    pub fingerprint: String,
    #[serde(default)]
    pub added: u64,
    /// Protected with a passphrase (kept by the app in the Keychain; used through the agent).
    #[serde(default)]
    pub encrypted: bool,
}

fn folder(store: &Store) -> Result<PathBuf> {
    let dir = store.directory("config")?.join("ssh").join("keys");
    std::fs::create_dir_all(&dir)?;
    std::fs::set_permissions(
        dir.parent().unwrap_or(&dir),
        std::fs::Permissions::from_mode(0o700),
    )?;
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700))?;
    Ok(dir)
}

fn index(store: &Store) -> Result<PathBuf> {
    Ok(folder(store)?.join("keys.json"))
}

pub fn list(store: &Store) -> Result<Vec<SshKey>> {
    let path = index(store)?;
    if !path.exists() {
        return Ok(vec![]);
    }
    json::read_regular(&path, None)
}

fn save_list(store: &Store, keys: &[SshKey]) -> Result<()> {
    json::write(&index(store)?, keys)
}

const MAX_ID: usize = 40;

/// Path of a stored key, for `ssh -i`.
pub fn path(store: &Store, id: &str) -> Result<PathBuf> {
    ensure!(
        validate::id(id, MAX_ID) && list(store)?.iter().any(|k| k.id == id),
        "unknown_ssh_key"
    );
    let path = folder(store)?.join(id);
    ensure!(
        path.is_file() && !std::fs::symlink_metadata(&path)?.file_type().is_symlink(),
        "unknown_ssh_key"
    );
    Ok(path)
}

/// Type, fingerprint and public key of a private key; with a passphrase it is answered through
/// the askpass helper (never on the command line).
fn inspect_with(path: &Path, passphrase: Option<&str>) -> Result<(String, String, String)> {
    let public = match passphrase {
        None => Command::new("/usr/bin/ssh-keygen")
            .args(["-y", "-P", "", "-f"])
            .arg(path)
            .env_clear()
            .stdin(Stdio::null())
            .stderr(Stdio::piped())
            .output()?,
        Some(passphrase) => {
            let mut command = Command::new("/usr/bin/ssh-keygen");
            command.args(["-y", "-f"]).arg(path);
            crate::ssh::askpass::run(command, passphrase, 1)?
        }
    };
    if !public.status.success() {
        let text = String::from_utf8_lossy(&public.stderr).to_lowercase();
        ensure!(
            !text.contains("passphrase") && !text.contains("incorrect"),
            "ssh_key_passphrase"
        );
        anyhow::bail!("ssh_key_invalid");
    }
    let (kind, fingerprint) = fingerprint_of(&public.stdout)?;
    Ok((
        kind,
        fingerprint,
        String::from_utf8_lossy(&public.stdout).trim().to_string(),
    ))
}

/// ("ED25519 256", "SHA256:…") of a public key.
fn fingerprint_of(public: &[u8]) -> Result<(String, String)> {
    let mut child = Command::new("/usr/bin/ssh-keygen")
        .args(["-l", "-f", "-"])
        .env_clear()
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    std::io::Write::write_all(
        child
            .stdin
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("ssh_key_invalid"))?,
        public,
    )?;
    drop(child.stdin.take());
    let out = child.wait_with_output()?;
    // "2048 SHA256:abc… comment (RSA)"
    let line = String::from_utf8_lossy(&out.stdout).trim().to_string();
    let parts: Vec<&str> = line.split_whitespace().collect();
    ensure!(parts.len() >= 2, "ssh_key_invalid");
    let kind = format!(
        "{} {}",
        parts
            .last()
            .unwrap_or(&"")
            .trim_matches(|c| c == '(' || c == ')'),
        parts[0]
    );
    Ok((kind, parts[1].to_string()))
}

fn sort(keys: &mut [SshKey]) {
    keys.sort_by_key(|k| (k.group.to_lowercase(), k.name.to_lowercase()));
}

/// A private (0600) temporary file inside the keys folder, removed again on any error.
fn temporary(dir: &Path, tag: &str) -> PathBuf {
    let path = dir.join(format!(".{tag}-{}-{}", std::process::id(), now_secs()));
    let _ = std::fs::remove_file(&path);
    let _ = std::fs::remove_file(path.with_extension("pub"));
    path
}

/// Moves an inspected private key into the store under a fresh id, with its public half beside it.
fn store_key(
    store: &Store,
    temporary: &Path,
    meta: (&str, &str, &str),
    inspected: (String, String, String),
    encrypted: bool,
) -> Result<SshKey> {
    let (name, description, group) = meta;
    let (kind, fingerprint, public) = inspected;
    let mut keys = list(store)?;
    if keys.iter().any(|k| k.fingerprint == fingerprint) {
        anyhow::bail!("ssh_key_exists");
    }
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
    let base: String = if base.is_empty() {
        "clave".into()
    } else {
        base.chars().take(30).collect()
    };
    let mut id = base.clone();
    let mut n = 2;
    while keys.iter().any(|k| k.id == id) || id == "keys.json" {
        id = format!("{base}-{n}");
        n += 1;
    }
    let dir = folder(store)?;
    // ssh finds the public half of `-i <id>` in `<id>.pub`: an encrypted key then works from the agent.
    write_private(&dir.join(format!("{id}.pub")), &format!("{public}\n"))?;
    std::fs::rename(temporary, dir.join(&id))?;
    let key = SshKey {
        id,
        name: name.to_string(),
        description: description.trim().to_string(),
        group: group.trim().to_string(),
        kind,
        fingerprint,
        added: now_secs(),
        encrypted,
    };
    keys.push(key.clone());
    sort(&mut keys);
    if let Err(error) = save_list(store, &keys) {
        // No entry in `keys.json`, no way to delete the files from the app: they go now.
        let _ = std::fs::remove_file(dir.join(&key.id));
        let _ = std::fs::remove_file(dir.join(format!("{}.pub", key.id)));
        return Err(error);
    }
    Ok(key)
}

/// Copies a private key file into Stack. The same key (same fingerprint) is never stored twice.
/// Without a passphrase; the requests go through `import_with` (kept for the tests).
#[cfg(test)]
pub fn import(
    store: &Store,
    source: &Path,
    name: &str,
    description: &str,
    group: &str,
) -> Result<SshKey> {
    import_with(store, source, name, description, group, None)
}

/// Like `import`, for a key that may be protected: without a passphrase an encrypted key fails
/// with `ssh_key_passphrase` (the app then asks for it); with one, it is checked through askpass.
pub fn import_with(
    store: &Store,
    source: &Path,
    name: &str,
    description: &str,
    group: &str,
    passphrase: Option<&str>,
) -> Result<SshKey> {
    ensure!(source.is_absolute() && source.is_file(), "ssh_key_invalid");
    let size = std::fs::metadata(source)?.len();
    ensure!(size > 0 && size <= 64 * 1024, "ssh_key_invalid");
    let content = std::fs::read(source)?;
    ensure!(
        String::from_utf8_lossy(&content).contains("PRIVATE KEY-----"),
        "ssh_key_invalid"
    );
    let fallback = source
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default();
    let name = if name.trim().is_empty() {
        fallback.as_str()
    } else {
        name.trim()
    };
    ensure!(
        !name.is_empty()
            && validate::printable(name, 80)
            && validate::printable(description, 400)
            && validate::printable(group, 60),
        "ssh_key_invalid"
    );
    let dir = folder(store)?;
    // Write first under a temporary name, so the file `ssh-keygen` inspects is already private.
    let temporary = temporary(&dir, "import");
    {
        let mut file = private_options().create_new(true).open(&temporary)?;
        std::io::Write::write_all(&mut file, &content)?;
        // ssh-keygen and ssh want a trailing newline.
        if !content.ends_with(b"\n") {
            std::io::Write::write_all(&mut file, b"\n")?;
        }
    }
    let passphrase = passphrase.filter(|p| !p.is_empty());
    let result =
        inspect_with(&temporary, None)
            .map(|i| (i, false))
            .or_else(|error| match passphrase {
                Some(passphrase) if error.to_string() == "ssh_key_passphrase" => {
                    inspect_with(&temporary, Some(passphrase)).map(|i| (i, true))
                }
                _ => Err(error),
            });
    let stored = result.and_then(|(inspected, encrypted)| {
        store_key(
            store,
            &temporary,
            (name, description, group),
            inspected,
            encrypted,
        )
    });
    if stored.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    stored
}

/// Comments written into generated keys: plain words (they travel inside the public key).
fn valid_comment(comment: &str) -> bool {
    comment.len() <= 64
        && comment
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'@' | b'.' | b'_' | b'-'))
}

/// Creates a new ed25519 key inside Stack (`ssh-keygen`, separate arguments). An optional
/// passphrase is set afterwards with `ssh-keygen -p` through askpass, never on the command line.
pub fn generate(
    store: &Store,
    name: &str,
    description: &str,
    group: &str,
    comment: &str,
    passphrase: Option<&str>,
) -> Result<SshKey> {
    let name = name.trim();
    ensure!(
        !name.is_empty()
            && validate::printable(name, 80)
            && validate::printable(description, 400)
            && validate::printable(group, 60)
            && valid_comment(comment),
        "ssh_key_invalid"
    );
    let dir = folder(store)?;
    let temporary = temporary(&dir, "generate");
    let comment = if comment.is_empty() {
        "butake-stack"
    } else {
        comment
    };
    let result = (|| -> Result<SshKey> {
        let status = Command::new("/usr/bin/ssh-keygen")
            .args(["-q", "-t", "ed25519", "-N", "", "-C", comment, "-f"])
            .arg(&temporary)
            .env_clear()
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()?;
        ensure!(status.success(), "ssh_key_invalid");
        std::fs::set_permissions(&temporary, std::fs::Permissions::from_mode(0o600))?;
        let _ = std::fs::remove_file(temporary.with_extension("pub"));
        let passphrase = passphrase.filter(|p| !p.is_empty());
        if let Some(passphrase) = passphrase {
            let mut command = Command::new("/usr/bin/ssh-keygen");
            command.args(["-p", "-f"]).arg(&temporary);
            // New passphrase and its confirmation.
            let out = crate::ssh::askpass::run(command, passphrase, 2)?;
            ensure!(out.status.success(), "ssh_key_invalid");
        }
        let inspected = inspect_with(&temporary, passphrase)?;
        store_key(
            store,
            &temporary,
            (name, description, group),
            inspected,
            passphrase.is_some(),
        )
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary);
        let _ = std::fs::remove_file(temporary.with_extension("pub"));
    }
    result
}

/// The public half (one `authorized_keys` line). Keys imported before it was kept are read once.
pub fn public_key(store: &Store, id: &str) -> Result<String> {
    let private = path(store, id)?;
    let file = folder(store)?.join(format!("{id}.pub"));
    if let Ok(text) = std::fs::read_to_string(&file)
        && !std::fs::symlink_metadata(&file)?.file_type().is_symlink()
    {
        return Ok(text.trim().to_string());
    }
    let (_, _, public) = inspect_with(&private, None)?;
    write_private(&file, &format!("{public}\n"))?;
    Ok(public)
}

/// Fingerprints the agent holds now (`ssh-add -l`), to know which keys are loaded.
fn agent_fingerprints() -> Vec<String> {
    let Some(agent) = std::env::var_os("SSH_AUTH_SOCK") else {
        return vec![];
    };
    let mut command = Command::new("/usr/bin/ssh-add");
    command
        .args(["-l", "-E", "sha256"])
        .env_clear()
        .env("SSH_AUTH_SOCK", agent)
        .stdin(Stdio::null())
        .stderr(Stdio::null());
    command
        .output()
        .map(|o| {
            String::from_utf8_lossy(&o.stdout)
                .lines()
                .filter_map(|l| l.split_whitespace().nth(1).map(str::to_string))
                .collect()
        })
        .unwrap_or_default()
}

/// Ids of the Stack keys loaded in the SSH agent.
pub fn agent_loaded(store: &Store) -> Result<Vec<String>> {
    let prints = agent_fingerprints();
    Ok(list(store)?
        .into_iter()
        .filter(|k| prints.contains(&k.fingerprint))
        .map(|k| k.id)
        .collect())
}

/// Loads a key into the user's SSH agent (BatchMode tunnels and forwards then use it). The
/// passphrase comes from the app (Keychain) per request and goes to ssh-add through askpass.
pub fn agent_load(store: &Store, id: &str, passphrase: Option<&str>) -> Result<()> {
    let path = path(store, id)?;
    let agent =
        std::env::var_os("SSH_AUTH_SOCK").ok_or_else(|| anyhow::anyhow!("ssh_agent_missing"))?;
    let key = list(store)?
        .into_iter()
        .find(|k| k.id == id)
        .ok_or_else(|| anyhow::anyhow!("unknown_ssh_key"))?;
    if agent_fingerprints().contains(&key.fingerprint) {
        return Ok(());
    }
    let mut command = Command::new("/usr/bin/ssh-add");
    command.arg("--").arg(&path);
    let passphrase = passphrase.filter(|p| !p.is_empty());
    let out = match passphrase {
        Some(passphrase) => crate::ssh::askpass::run(command, passphrase, 1)?,
        None => {
            ensure!(!key.encrypted, "ssh_key_passphrase");
            command
                .env_clear()
                .env("SSH_AUTH_SOCK", agent)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::piped())
                .output()?
        }
    };
    if !out.status.success() {
        let text = String::from_utf8_lossy(&out.stderr).to_lowercase();
        ensure!(
            !text.contains("could not open a connection") && !text.contains("agent refused"),
            "ssh_agent_missing"
        );
        // A refused passphrase makes ssh-add ask again; the helper answers once, so it just exits.
        ensure!(
            passphrase.is_none() && !text.contains("passphrase") && !text.contains("incorrect"),
            "ssh_key_passphrase"
        );
        anyhow::bail!("ssh_key_invalid");
    }
    Ok(())
}

/// Removes a key from the agent (by its public half, so no passphrase is needed).
pub fn agent_unload(store: &Store, id: &str) -> Result<()> {
    let public = public_key(store, id)?;
    let agent =
        std::env::var_os("SSH_AUTH_SOCK").ok_or_else(|| anyhow::anyhow!("ssh_agent_missing"))?;
    let file = folder(store)?.join(format!("{id}.pub"));
    ensure!(!public.is_empty() && file.is_file(), "unknown_ssh_key");
    let _ = Command::new("/usr/bin/ssh-add")
        .arg("-d")
        .arg("--")
        .arg(&file)
        .env_clear()
        .env("SSH_AUTH_SOCK", agent)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()?;
    Ok(())
}

/// Renames, describes or regroups a key (its content never changes).
pub fn update(
    store: &Store,
    id: &str,
    name: &str,
    description: &str,
    group: &str,
) -> Result<SshKey> {
    ensure!(
        !name.trim().is_empty()
            && validate::printable(name, 80)
            && validate::printable(description, 400)
            && validate::printable(group, 60),
        "ssh_key_invalid"
    );
    let mut keys = list(store)?;
    let key = keys
        .iter_mut()
        .find(|k| k.id == id)
        .ok_or_else(|| anyhow::anyhow!("unknown_ssh_key"))?;
    key.name = name.trim().into();
    key.description = description.trim().into();
    key.group = group.trim().into();
    let updated = key.clone();
    sort(&mut keys);
    save_list(store, &keys)?;
    Ok(updated)
}

/// Where a Stack key is used: saved SSH hosts and database connections, as "name (where)".
pub fn users(store: &Store, id: &str) -> Result<Vec<String>> {
    let connections = crate::db::client::saved(store)?
        .into_iter()
        .filter(|c| c.ssh.as_ref().and_then(|s| s.key.as_deref()) == Some(id))
        .map(|c| format!("{} (base de datos)", c.name));
    Ok(crate::ssh::hosts::users_of_key(store, id)
        .into_iter()
        .map(|name| format!("{name} (SSH)"))
        .chain(connections)
        .collect())
}

/// Removes a key nothing uses. Whoever asks, a key
/// a host or a connection depends on is refused with `ssh_key_in_use:<where it is used>`.
pub fn delete(store: &Store, id: &str) -> Result<()> {
    let used_by = users(store, id)?;
    ensure!(used_by.is_empty(), "ssh_key_in_use:{}", used_by.join(", "));
    let path = path(store, id)?;
    // Not overwritten first: on APFS (copy on write, SSD) that does not erase the old blocks, and
    // an unchecked overwrite would only look like a secure delete.
    std::fs::remove_file(&path)?;
    let _ = std::fs::remove_file(folder(store)?.join(format!("{id}.pub")));
    let mut keys = list(store)?;
    keys.retain(|k| k.id != id);
    save_list(store, &keys)
}

/// Request methods of the SSH keys (`sshKey*`). Keys belong to Stack's base: the database
/// client's tunnels and the SSH terminal share them, so no plugin gates these.
pub fn dispatch(
    store: &Store,
    method: &str,
    request: &serde_json::Value,
) -> Result<serde_json::Value> {
    let text = |key: &str| request[key].as_str().unwrap_or("").to_string();
    let passphrase = request["passphrase"]
        .as_str()
        .filter(|p| !p.is_empty())
        .map(str::to_string);
    let value = match method {
        "sshKeys" => serde_json::to_value(list(store)?)?,
        "sshKeyImport" => serde_json::to_value(import_with(
            store,
            Path::new(&text("path")),
            &text("name"),
            &text("description"),
            &text("group"),
            passphrase.as_deref(),
        )?)?,
        "sshKeyGenerate" => serde_json::to_value(generate(
            store,
            &text("name"),
            &text("description"),
            &text("group"),
            &text("comment"),
            passphrase.as_deref(),
        )?)?,
        "sshKeyUpdate" => serde_json::to_value(update(
            store,
            &text("id"),
            &text("name"),
            &text("description"),
            &text("group"),
        )?)?,
        "sshKeyDelete" => {
            delete(store, &text("id"))?;
            serde_json::json!(true)
        }
        "sshKeyPublic" => serde_json::json!(public_key(store, &text("id"))?),
        "sshKeyAgent" => {
            serde_json::json!({"available": std::env::var_os("SSH_AUTH_SOCK").is_some(), "loaded": agent_loaded(store)?})
        }
        "sshKeyAgentLoad" => {
            agent_load(store, &text("id"), passphrase.as_deref())?;
            serde_json::json!(true)
        }
        "sshKeyAgentUnload" => {
            agent_unload(store, &text("id"))?;
            serde_json::json!(true)
        }
        _ => anyhow::bail!("invalid_request"),
    };
    Ok(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn imports_names_and_removes_keys_without_exposing_them() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::new(temp.path().join("store")).unwrap();
        let source = temp.path().join("aws prod.pem");
        let status = Command::new("/usr/bin/ssh-keygen")
            .args(["-q", "-t", "rsa", "-b", "2048", "-m", "PEM", "-N", "", "-f"])
            .arg(&source)
            .status()
            .unwrap();
        assert!(status.success());
        let key = import(&store, &source, "", "Bastión de Gestión", "AWS").unwrap();
        assert_eq!(key.name, "aws prod");
        assert_eq!(key.id, "aws-prod");
        assert!(key.kind.starts_with("RSA") && key.fingerprint.starts_with("SHA256:"));
        let stored = path(&store, &key.id).unwrap();
        assert_eq!(
            std::fs::metadata(&stored).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert!(
            !serde_json::to_string(&list(&store).unwrap())
                .unwrap()
                .contains("PRIVATE KEY")
        );
        // Same key twice is refused; a passphrase-protected key too.
        assert!(
            import(&store, &source, "otra", "", "")
                .unwrap_err()
                .to_string()
                == "ssh_key_exists"
        );
        let locked = temp.path().join("locked");
        Command::new("/usr/bin/ssh-keygen")
            .args(["-q", "-t", "ed25519", "-N", "secreto", "-f"])
            .arg(&locked)
            .status()
            .unwrap();
        assert_eq!(
            import(&store, &locked, "x", "", "")
                .unwrap_err()
                .to_string(),
            "ssh_key_passphrase"
        );
        assert!(import(&store, &temp.path().join("aws prod.pem.pub"), "pub", "", "").is_err());
        let accented = temp.path().join("otra");
        Command::new("/usr/bin/ssh-keygen")
            .args(["-q", "-t", "ed25519", "-N", "", "-f"])
            .arg(&accented)
            .status()
            .unwrap();
        let second = import(&store, &accented, "EC2 Gestión Ñuñoa", "", "").unwrap();
        assert_eq!(second.id, "ec2-gestion-nunoa");
        delete(&store, &second.id).unwrap();
        let renamed = update(&store, &key.id, "Gestión", "EC2 bastión", "AWS producción").unwrap();
        assert_eq!(renamed.group, "AWS producción");
        delete(&store, &key.id).unwrap();
        assert!(list(&store).unwrap().is_empty() && !stored.exists());
    }

    #[test]
    fn a_key_in_use_is_refused_and_says_where() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::new(temp.path().join("store")).unwrap();
        let source = temp.path().join("llave");
        Command::new("/usr/bin/ssh-keygen")
            .args(["-q", "-t", "ed25519", "-N", "", "-f"])
            .arg(&source)
            .status()
            .unwrap();
        let key = import(&store, &source, "Bastión", "", "").unwrap();
        let host: crate::ssh::hosts::Host = serde_json::from_value(serde_json::json!({
            "name": "Servidor", "host": "srv.ejemplo.cl", "user": "deploy", "key": key.id
        }))
        .unwrap();
        let host = crate::ssh::hosts::save(&store, host).unwrap();
        let connection: crate::db::client::Connection = serde_json::from_value(serde_json::json!({
            "id": "aurora", "name": "Aurora", "kind": "mysql", "host": "db.ejemplo.cl",
            "port": 3306, "user": "app",
            "ssh": {"host": "srv.ejemplo.cl", "user": "deploy", "key": key.id}
        }))
        .unwrap();
        crate::db::client::save(&store, connection).unwrap();
        let request = serde_json::json!({"id": key.id});
        let used = dispatch(&store, "sshKeyDelete", &request).unwrap_err();
        assert_eq!(
            used.to_string(),
            "ssh_key_in_use:Servidor (SSH), Aurora (base de datos)"
        );
        assert!(path(&store, &key.id).is_ok());
        // Free it one place at a time: the host first, then the connection.
        crate::ssh::hosts::delete(&store, &host.id).unwrap();
        assert_eq!(
            delete(&store, &key.id).unwrap_err().to_string(),
            "ssh_key_in_use:Aurora (base de datos)"
        );
        crate::db::client::delete(&store, "aurora").unwrap();
        assert_eq!(dispatch(&store, "sshKeyDelete", &request).unwrap(), true);
        assert!(list(&store).unwrap().is_empty());
        // The update method renames without touching the content.
        assert_eq!(
            dispatch(&store, "sshKeyUpdate", &request)
                .unwrap_err()
                .to_string(),
            "ssh_key_invalid"
        );
    }
}
