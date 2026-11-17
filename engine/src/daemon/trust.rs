//! What macOS must know for `.test` sites to work in a browser: a resolver file per local TLD
//! (`/etc/resolver/<tld>` → the stack's DNS) and the local certificate authority of Caddy trusted
//! for SSL in the login keychain. Both changes need the user's authorization: macOS asks for it in
//! its own dialog (administrator for `/etc`, the trust settings prompt for the keychain); Stack
//! never sees or keeps a password.
//!
//! With an isolated store (`BUTAKE_STACK_HOME`, QA and tests) nothing system-wide is read or
//! changed: `/etc/resolver` and the trust are simulated inside the store (`simulated/`).
use crate::core::fsutil::write_private;
use crate::{core::model::StackConfig, core::store::Store};
use anyhow::{ensure, Result};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

/// QA and tests: privileged actions are simulated inside the store.
pub fn simulated() -> bool {
    cfg!(test) || std::env::var_os("BUTAKE_STACK_HOME").is_some()
}

fn resolver_dir(store: &Store) -> PathBuf {
    if simulated() {
        store.root().join("simulated/etc/resolver")
    } else {
        PathBuf::from("/etc/resolver")
    }
}

/// Root certificate of Caddy's local authority (made by Caddy the first time it serves HTTPS).
pub fn root_certificate(store: &Store) -> Result<PathBuf> {
    Ok(store
        .directory("data")?
        .join("caddy/pki/authorities/local/root.crt"))
}

/// What a resolver file must say for the stack's DNS.
pub fn resolver_content(port: u16) -> String {
    format!("# Stack: dominios locales\nnameserver 127.0.0.1\nport {port}\n")
}

/// State of one resolver file: `ok`, `missing` or `different` (it points elsewhere).
pub fn resolver_state(text: Option<&str>, port: u16) -> &'static str {
    let Some(text) = text else { return "missing" };
    let mut nameserver = None;
    let mut file_port = 53u16;
    for line in text.lines() {
        let mut words = line.split_whitespace();
        match (words.next(), words.next()) {
            (Some("nameserver"), Some(value)) if nameserver.is_none() => {
                nameserver = Some(value.to_string())
            }
            (Some("port"), Some(value)) => file_port = value.parse().unwrap_or(0),
            _ => {}
        }
    }
    if nameserver.as_deref() == Some("127.0.0.1") && file_port == port {
        "ok"
    } else {
        "different"
    }
}

fn resolvers(store: &Store, config: &StackConfig) -> Vec<Value> {
    let dir = resolver_dir(store);
    config
        .tld
        .iter()
        .map(|tld| {
            let path = dir.join(tld);
            let text = fs::read(&path).ok().filter(|t| t.len() <= 4096).map(|t| String::from_utf8_lossy(&t).into_owned());
            json!({"tld": tld, "path": path, "state": resolver_state(text.as_deref(), config.ports.dns), "port": config.ports.dns})
        })
        .collect()
}

/// Decodes the first PEM block of a certificate file.
pub fn pem_der(text: &str) -> Option<Vec<u8>> {
    let start = text.find("-----BEGIN CERTIFICATE-----")? + "-----BEGIN CERTIFICATE-----".len();
    let end = start + text[start..].find("-----END CERTIFICATE-----")?;
    crate::core::codec::base64_decode(&text[start..end])
}

pub fn fingerprint(der: &[u8]) -> String {
    Sha256::digest(der)
        .iter()
        .map(|b| format!("{b:02X}"))
        .collect::<Vec<_>>()
        .join(":")
}

fn simulated_trust(store: &Store) -> PathBuf {
    store.root().join("simulated/trusted-ca.sha256")
}

/// Whether macOS trusts the certificate for SSL: `security verify-cert` evaluates it with the
/// user's and the system's trust settings (no network).
fn trusted(store: &Store, path: &Path, print: &str) -> bool {
    if simulated() {
        return fs::read_to_string(simulated_trust(store)).is_ok_and(|t| t.trim() == print);
    }
    Command::new("/usr/bin/security")
        .args(["verify-cert", "-q", "-L", "-p", "ssl", "-c"])
        .arg(path)
        .env_clear()
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

fn authority(store: &Store) -> Result<Value> {
    let path = root_certificate(store)?;
    let Some(der) = fs::read(&path)
        .ok()
        .filter(|t| t.len() <= 65_536)
        .and_then(|t| pem_der(&String::from_utf8_lossy(&t)))
    else {
        return Ok(json!({"exists": false, "trusted": false, "path": path}));
    };
    let print = fingerprint(&der);
    Ok(
        json!({"exists": true, "trusted": trusted(store, &path, &print), "fingerprint": print, "path": path}),
    )
}

pub fn status(store: &Store) -> Result<Value> {
    let config = store.config()?;
    Ok(
        json!({"resolvers": resolvers(store, &config), "authority": authority(store)?, "simulated": simulated()}),
    )
}

/// Writes `/etc/resolver/<tld>` for every local TLD through macOS's administrator dialog
/// (`osascript … with administrator privileges`). The content travels in the command itself, built
/// from the validated port: no file in the user's reach is read as root after the dialog. The only
/// shell text is fixed, every value goes through AppleScript's `quoted form of` and is validated.
pub fn install_resolvers(store: &Store, confirmed: bool) -> Result<Value> {
    ensure!(confirmed, "confirmation_required");
    let config = store.config()?;
    config.validate()?;
    let content = resolver_content(config.ports.dns);
    if simulated() {
        let staging = store.directory("config")?.join("resolver");
        write_private(&staging, &content)?;
        let dir = resolver_dir(store);
        fs::create_dir_all(&dir)?;
        for tld in &config.tld {
            fs::copy(&staging, dir.join(tld))?;
        }
        return Ok(json!({"applied": true, "simulated": true}));
    }
    let arguments = resolver_arguments(&content, &config.tld)?;
    let status = Command::new("/usr/bin/osascript")
        .args(&arguments)
        .env_clear()
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()?;
    // Cancelling macOS's dialog is not a failure of Stack.
    ensure!(status.success(), "authorization_cancelled");
    Ok(json!({"applied": true, "simulated": false}))
}

/// Arguments for osascript: a fixed script, then the file content and each TLD as `argv` items.
pub fn resolver_arguments(content: &str, tlds: &[String]) -> Result<Vec<String>> {
    ensure!(
        !content.is_empty()
            && content.len() <= 1024
            && content.chars().all(|c| c == '\n' || !c.is_control()),
        "invalid_path"
    );
    ensure!(
        !tlds.is_empty()
            && tlds.iter().all(|t| !t.is_empty()
                && t.len() <= 63
                && t.bytes()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-')),
        "invalid_tld"
    );
    let script = [
        "on run argv",
        "set body to quoted form of item 1 of argv",
        "set command to \"/bin/mkdir -p /etc/resolver\"",
        "repeat with index from 2 to count of argv",
        "set target to quoted form of (\"/etc/resolver/\" & item index of argv)",
        "set command to command & \" && /usr/bin/printf %s \" & body & \" > \" & target & \" && /usr/sbin/chown root:wheel \" & target & \" && /bin/chmod 0644 \" & target",
        "end repeat",
        "do shell script command with administrator privileges with prompt \"Stack necesita permiso para que macOS envíe los dominios locales a su DNS.\"",
        "end run",
    ];
    let mut arguments: Vec<String> = script
        .iter()
        .flat_map(|line| ["-e".to_string(), line.to_string()])
        .collect();
    arguments.push(content.into());
    arguments.extend(tlds.iter().cloned());
    Ok(arguments)
}

/// Adds Caddy's root to the login keychain, trusted for SSL. Without `-d` the trust goes to the
/// user's settings and macOS asks for the user's password in its own dialog.
pub fn trust_authority(store: &Store, confirmed: bool) -> Result<Value> {
    ensure!(confirmed, "confirmation_required");
    let path = root_certificate(store)?;
    let der = fs::read(&path)
        .ok()
        .filter(|t| t.len() <= 65_536)
        .and_then(|t| pem_der(&String::from_utf8_lossy(&t)))
        .ok_or_else(|| anyhow::anyhow!("authority_missing"))?;
    let print = fingerprint(&der);
    if simulated() {
        let file = simulated_trust(store);
        fs::create_dir_all(file.parent().unwrap())?;
        fs::write(file, &print)?;
        return Ok(json!({"applied": true, "simulated": true, "fingerprint": print}));
    }
    let keychain = Store::home()
        .ok_or_else(|| anyhow::anyhow!("home_unavailable"))?
        .join("Library/Keychains/login.keychain-db");
    let status = Command::new("/usr/bin/security")
        .args(trust_arguments(&path, &keychain))
        .env_clear()
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()?;
    ensure!(status.success(), "authorization_cancelled");
    Ok(json!({"applied": true, "simulated": false, "fingerprint": print}))
}

pub fn trust_arguments(certificate: &Path, keychain: &Path) -> Vec<std::ffi::OsString> {
    let mut arguments: Vec<std::ffi::OsString> =
        ["add-trusted-cert", "-r", "trustRoot", "-p", "ssl", "-k"]
            .iter()
            .map(Into::into)
            .collect();
    arguments.push(keychain.into());
    arguments.push(certificate.into());
    arguments
}

#[cfg(test)]
mod tests {
    use super::*;
    const CERT: &str = "-----BEGIN CERTIFICATE-----\nAQIDBA==\n-----END CERTIFICATE-----\n";

    #[test]
    fn resolver_states() {
        assert_eq!(resolver_state(None, 53), "missing");
        assert_eq!(resolver_state(Some("nameserver 127.0.0.1"), 53), "ok");
        assert_eq!(resolver_state(Some(&resolver_content(1053)), 1053), "ok");
        assert_eq!(
            resolver_state(Some("nameserver 127.0.0.1\nport 2053\n"), 53),
            "different"
        );
        assert_eq!(
            resolver_state(Some("nameserver 10.0.0.1\n"), 53),
            "different"
        );
    }

    #[test]
    fn osascript_gets_values_as_arguments_only() {
        let content = resolver_content(1053);
        let args = resolver_arguments(&content, &["test".into(), "dev".into()]).unwrap();
        let script: Vec<&String> = args.iter().skip(1).step_by(2).take(9).collect();
        assert!(script
            .iter()
            .all(|line| !line.contains("1053") && !line.contains("test")));
        assert!(args
            .iter()
            .any(|a| a.contains("quoted form of item 1 of argv")));
        assert_eq!(&args[args.len() - 3..], [content.as_str(), "test", "dev"]);
        // No file of the user's is named, so none can change after the dialog.
        assert!(!args.iter().any(|a| a.contains("/install ")));
        assert!(resolver_arguments(&content, &["te st".into()]).is_err());
        assert!(resolver_arguments(&content, &["a\"; rm".into()]).is_err());
        assert!(resolver_arguments("", &["test".into()]).is_err());
        assert!(resolver_arguments("a\u{7}b", &["test".into()]).is_err());
        let trust = trust_arguments(Path::new("/s/root.crt"), Path::new("/k/login.keychain-db"));
        assert!(
            !trust.iter().any(|a| a == "-d"),
            "user trust settings, never the admin domain"
        );
        assert_eq!(trust.last().unwrap(), "/s/root.crt");
    }

    #[test]
    fn simulated_flow_never_touches_the_system() {
        // Under test everything is simulated inside the temporary store.
        let temp = tempfile::tempdir().unwrap();
        let store = Store::new(temp.path().join("store")).unwrap();
        assert_eq!(fingerprint(&[1, 2, 3, 4]).len(), 32 * 3 - 1);
        assert_eq!(pem_der(CERT).unwrap(), vec![1, 2, 3, 4]);
        let status = status(&store).unwrap();
        assert_eq!(status["resolvers"][0]["state"], "missing");
        assert_eq!(status["authority"]["exists"], false);
        assert!(install_resolvers(&store, false).is_err());
        install_resolvers(&store, true).unwrap();
        assert_eq!(
            super::status(&store).unwrap()["resolvers"][0]["state"],
            "ok"
        );
        assert!(trust_authority(&store, true).is_err(), "no authority yet");
        let cert = root_certificate(&store).unwrap();
        fs::create_dir_all(cert.parent().unwrap()).unwrap();
        fs::write(&cert, CERT).unwrap();
        assert_eq!(
            super::status(&store).unwrap()["authority"]["trusted"],
            false
        );
        trust_authority(&store, true).unwrap();
        assert_eq!(super::status(&store).unwrap()["authority"]["trusted"], true);
        assert!(store.root().join("simulated/etc/resolver/test").is_file());
    }
}
