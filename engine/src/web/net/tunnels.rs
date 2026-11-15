//! Fixed public addresses (P-35): a named Cloudflare tunnel per project, on a domain of the user's
//! own (`salud-test.example.com`), that stays the same between sessions.
//!
//! Security model (R16 in `.compliance/`):
//! - Connecting is the user's step in the browser (`cloudflared tunnel login`). Stack only checks
//!   that the origin certificate exists; it never reads, shows or copies it.
//! - Each tunnel's credentials live in `tunnels/` of Stack's data folder, mode 600, outside the
//!   environment export (`app::backup`), and never reach logs, responses or the interface.
//! - What `cloudflared` prints is never passed on: failures become fixed codes.
//! - Sharing is always an explicit action and lives in the daemon's memory: a restarted Stack or a
//!   stopped project keeps its fixed address configured but shares nothing.
use crate::core::{
    fsutil::write_private,
    json,
    model::{validate_id, Project},
    process,
    store::Store,
};
use anyhow::{bail, ensure, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    process::Command,
    time::Duration,
};

/// A project's fixed address and the tunnel that serves it.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Address {
    pub hostname: String,
    /// The tunnel's id (not a secret: without its credentials it opens nothing).
    pub tunnel: String,
    /// The Cloudflare zone the address is in.
    pub zone: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
struct Tunnels {
    /// The last zone used, to propose the next address.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    zone: Option<String>,
    #[serde(default)]
    addresses: BTreeMap<String, Address>,
}

/// `cloudflared` and the home whose `.cloudflared/cert.pem` holds the connection.
pub struct Cloudflared {
    pub executable: PathBuf,
    pub home: PathBuf,
}

impl Cloudflared {
    pub fn find() -> Option<Self> {
        Some(Self {
            executable: crate::runtimes::utilities::catalog::user_tool("cloudflared")?,
            home: Store::home()?,
        })
    }

    /// Runs one `tunnel` command and returns what it printed on stdout. A failure is a fixed
    /// code (see [`classify`]); nothing it printed leaves this function.
    fn run(&self, args: &[&str]) -> Result<String> {
        let mut command = Command::new(&self.executable);
        command.arg("tunnel").args(args);
        process::minimal_environment(&mut command, &self.home, "/usr/bin:/bin:/usr/sbin:/sbin");
        let done = process::capture_watched(
            command,
            256 * 1024,
            Duration::from_secs(90),
            "cloudflared_missing",
            None,
        )?;
        ensure!(!done.timed_out, "tunnel_offline");
        ensure!(!done.cancelled, "cancelled");
        if !done.success {
            bail!(classify(&format!("{}\n{}", done.stdout, done.stderr)));
        }
        Ok(done.stdout)
    }

    fn cert_flag(&self) -> Result<String> {
        let cert = cert_path(&self.home);
        ensure!(cert.is_file(), "cloudflare_not_connected");
        Ok(cert.to_string_lossy().into_owned())
    }
}

/// Where `cloudflared tunnel login` leaves the connection (its origin certificate).
pub fn cert_path(home: &Path) -> PathBuf {
    home.join(".cloudflared/cert.pem")
}

/// Whether there is a connection with Cloudflare (only that the file exists; it is never read).
pub fn connected() -> bool {
    Store::home().is_some_and(|home| cert_path(&home).is_file())
}

/// The cause of a failed `cloudflared` command, as a code the app explains.
pub fn classify(output: &str) -> &'static str {
    let text = output.to_ascii_lowercase();
    let has = |words: &[&str]| words.iter().any(|w| text.contains(w));
    if has(&[
        "cannot determine default origin certificate",
        "origin certificate",
        "cert.pem",
    ]) {
        "cloudflare_not_connected"
    } else if has(&["tunnel with name already exists"]) {
        "tunnel_name_taken"
    } else if has(&["record with that host already exists", "already exists"]) {
        "public_hostname_taken"
    } else if has(&[
        "dial tcp",
        "no such host",
        "i/o timeout",
        "network is unreachable",
        "connection refused",
        "tls handshake timeout",
    ]) {
        "tunnel_offline"
    } else if !has(&["zone"]) && has(&["not found", "does not exist"]) {
        "tunnel_not_found"
    } else if has(&[
        "zone",
        "authentication error",
        "not authorized",
        "unauthorized",
        "forbidden",
    ]) {
        "zone_not_authorized"
    } else {
        "tunnel_failed"
    }
}

fn dir(store: &Store) -> Result<PathBuf> {
    store.directory("tunnels")
}

fn load(store: &Store) -> Result<Tunnels> {
    let file = dir(store)?.join("addresses.json");
    if !file.exists() {
        return Ok(Tunnels::default());
    }
    json::read_regular(&file, Some(1_048_576))
}

fn save(store: &Store, tunnels: &Tunnels) -> Result<()> {
    json::write(&dir(store)?.join("addresses.json"), tunnels)
}

/// Project id → fixed host name, for `{public:<id>}`.
pub fn addresses(store: &Store) -> BTreeMap<String, String> {
    load(store)
        .map(|t| {
            t.addresses
                .into_iter()
                .map(|(id, a)| (id, a.hostname))
                .collect()
        })
        .unwrap_or_default()
}

pub fn address(store: &Store, id: &str) -> Option<Address> {
    load(store).ok()?.addresses.remove(id)
}

fn credentials(store: &Store, id: &str) -> Result<PathBuf> {
    validate_id(id)?;
    Ok(dir(store)?.join(format!("{id}.json")))
}

fn config_file(store: &Store, id: &str) -> Result<PathBuf> {
    validate_id(id)?;
    Ok(dir(store)?.join(format!("{id}.yml")))
}

fn label(value: &str) -> bool {
    crate::core::validate::id(value, 63) && !value.starts_with('-') && !value.ends_with('-')
}

/// A Cloudflare zone: two or more labels, never one of Stack's local domains.
pub fn validate_zone(zone: &str, local: &[String]) -> Result<()> {
    let parts: Vec<_> = zone.split('.').collect();
    ensure!(
        zone.len() <= 200
            && parts.len() >= 2
            && parts.iter().all(|p| label(p))
            && !local
                .iter()
                .any(|t| Some(t.as_str()) == parts.last().copied()),
        "invalid_zone"
    );
    Ok(())
}

/// A host name inside `zone`. `Ok(true)` when it sits two or more levels under the zone
/// (`app.test.example.com`): Cloudflare's universal certificate covers only `*.zone`, so it needs an
/// advanced certificate.
pub fn validate_hostname(hostname: &str, zone: &str, local: &[String]) -> Result<bool> {
    validate_zone(zone, local)?;
    let parts: Vec<_> = hostname.split('.').collect();
    ensure!(
        hostname.len() <= 253 && parts.iter().all(|p| label(p)),
        "invalid_public_hostname"
    );
    let prefix = hostname
        .strip_suffix(zone)
        .and_then(|p| p.strip_suffix('.'))
        .filter(|p| !p.is_empty())
        .ok_or_else(|| anyhow::anyhow!("public_hostname_outside_zone"))?;
    Ok(prefix.contains('.'))
}

/// The id `cloudflared tunnel create` printed (as JSON with `--output json`, or in its sentence).
pub fn created_id(output: &str) -> Option<String> {
    let uuid = |text: &str| -> bool {
        text.len() == 36
            && text.bytes().enumerate().all(|(i, c)| {
                if [8, 13, 18, 23].contains(&i) {
                    c == b'-'
                } else {
                    c.is_ascii_hexdigit()
                }
            })
    };
    if let Ok(value) = serde_json::from_str::<Value>(output.trim()) {
        if let Some(id) = value["id"].as_str().filter(|id| uuid(id)) {
            return Some(id.to_ascii_lowercase());
        }
    }
    output
        .split(|c: char| !(c.is_ascii_hexdigit() || c == '-'))
        .find(|word| uuid(word))
        .map(str::to_ascii_lowercase)
}

/// The tunnel's configuration: the address to Stack's HTTP proxy with the project's local domain
/// as its Host header (the same entrance as the temporary address), and 404 for the rest.
pub fn ingress(address: &Address, credentials: &Path, http_port: u16, domain: &str) -> String {
    let quote = |text: &str| serde_json::to_string(text).unwrap_or_default();
    format!(
        "tunnel: {tunnel}\ncredentials-file: {credentials}\nno-autoupdate: true\ningress:\n  - hostname: {hostname}\n    service: http://127.0.0.1:{http_port}\n    originRequest:\n      httpHostHeader: {domain}\n  - service: http_status:404\n",
        tunnel = quote(&address.tunnel),
        credentials = quote(&credentials.to_string_lossy()),
        hostname = quote(&address.hostname),
        domain = quote(domain),
    )
}

/// Arguments of a fixed address's run.
pub fn run_arguments(config: &Path, tunnel: &str) -> Vec<String> {
    vec![
        "tunnel".into(),
        "--no-autoupdate".into(),
        "--config".into(),
        config.to_string_lossy().into_owned(),
        "run".into(),
        tunnel.into(),
    ]
}

/// The configuration of `project`'s tunnel, written for this run (the HTTP port or the local domain
/// may have changed). `None` when it has no fixed address or no local domain.
pub fn prepare_run(
    store: &Store,
    project: &Project,
    http_port: u16,
) -> Result<Option<(Address, PathBuf, String)>> {
    let (Some(address), Some(domain)) = (address(store, &project.id), project.domains.first())
    else {
        return Ok(None);
    };
    let file = config_file(store, &project.id)?;
    let content = ingress(
        &address,
        &credentials(store, &project.id)?,
        http_port,
        domain,
    );
    write_private(&file, &content)?;
    Ok(Some((address, file, content)))
}

/// Creates the tunnel `stack-<id>`, points `hostname` at it and keeps its credentials (0600).
/// Anything that fails after the tunnel exists removes it again.
pub fn configure(
    store: &Store,
    tool: &Cloudflared,
    id: &str,
    hostname: &str,
    zone: &str,
) -> Result<Value> {
    store.get(id)?;
    let advanced = validate_hostname(hostname, zone, &store.config()?.tld)?;
    let mut tunnels = load(store)?;
    ensure!(!tunnels.addresses.contains_key(id), "public_address_exists");
    ensure!(
        !tunnels.addresses.values().any(|a| a.hostname == hostname),
        "public_hostname_taken"
    );
    let cert = tool.cert_flag()?;
    let creds = credentials(store, id)?;
    let _ = std::fs::remove_file(&creds);
    let name = format!("stack-{id}");
    let creds_text = creds.to_string_lossy().into_owned();
    let output = tool.run(&[
        "--origincert",
        &cert,
        "create",
        "--credentials-file",
        &creds_text,
        "--output",
        "json",
        &name,
    ])?;
    let tunnel = created_id(&output).ok_or_else(|| anyhow::anyhow!("tunnel_failed"));
    let routed = tunnel.and_then(|tunnel| {
        ensure!(
            std::fs::symlink_metadata(&creds).is_ok_and(|m| m.is_file()),
            "tunnel_failed"
        );
        set_private(&creds)?;
        tool.run(&["--origincert", &cert, "route", "dns", &tunnel, hostname])?;
        Ok(tunnel)
    });
    let tunnel = match routed {
        Ok(tunnel) => tunnel,
        Err(error) => {
            // The tunnel without its address is no use: it goes, with its credentials.
            if let Some(tunnel) = created_id(&output) {
                let _ = tool.run(&["--origincert", &cert, "delete", "-f", &tunnel]);
            }
            let _ = std::fs::remove_file(&creds);
            return Err(error);
        }
    };
    tunnels.zone = Some(zone.to_string());
    tunnels.addresses.insert(
        id.to_string(),
        Address {
            hostname: hostname.to_string(),
            tunnel,
            zone: zone.to_string(),
        },
    );
    save(store, &tunnels)?;
    Ok(json!({"hostname": hostname, "advancedCertificate": advanced}))
}

/// Points the project's tunnel at a new host name. The old DNS record stays (Stack cannot delete
/// it): the answer names it so the app can say so.
pub fn change(store: &Store, tool: &Cloudflared, id: &str, hostname: &str) -> Result<Value> {
    let mut tunnels = load(store)?;
    let current = tunnels
        .addresses
        .get(id)
        .cloned()
        .ok_or_else(|| anyhow::anyhow!("public_address_missing"))?;
    let advanced = validate_hostname(hostname, &current.zone, &store.config()?.tld)?;
    ensure!(hostname != current.hostname, "public_hostname_unchanged");
    ensure!(
        !tunnels
            .addresses
            .iter()
            .any(|(other, a)| other != id && a.hostname == hostname),
        "public_hostname_taken"
    );
    let cert = tool.cert_flag()?;
    tool.run(&[
        "--origincert",
        &cert,
        "route",
        "dns",
        &current.tunnel,
        hostname,
    ])?;
    if let Some(entry) = tunnels.addresses.get_mut(id) {
        entry.hostname = hostname.to_string();
    }
    save(store, &tunnels)?;
    Ok(
        json!({"hostname": hostname, "previous": current.hostname, "zone": current.zone,
              "advancedCertificate": advanced}),
    )
}

/// Deletes the project's tunnel and its local credentials. A tunnel Cloudflare no longer has is
/// already gone; any other failure keeps everything so the user can try again. The DNS record
/// stays: the answer names it.
pub fn remove(store: &Store, tool: &Cloudflared, id: &str) -> Result<Value> {
    let mut tunnels = load(store)?;
    let current = tunnels
        .addresses
        .get(id)
        .cloned()
        .ok_or_else(|| anyhow::anyhow!("public_address_missing"))?;
    let cert = tool.cert_flag()?;
    match tool.run(&["--origincert", &cert, "delete", "-f", &current.tunnel]) {
        Err(error) if error.to_string() != "tunnel_not_found" => return Err(error),
        _ => {}
    }
    let _ = std::fs::remove_file(credentials(store, id)?);
    let _ = std::fs::remove_file(config_file(store, id)?);
    tunnels.addresses.remove(id);
    save(store, &tunnels)?;
    Ok(json!({"hostname": current.hostname, "zone": current.zone}))
}

/// Whether anything of the tunnels is kept under `id` (an address or its credentials).
pub fn holds(store: &Store, id: &str) -> bool {
    address(store, id).is_some() || credentials(store, id).is_ok_and(|file| file.exists())
}

/// A project renamed (P-41): its fixed address and its tunnel's credentials go to the new id. The
/// tunnel keeps its id and its name at Cloudflare (`stack-<from>`): the address keeps working and
/// nothing changes outside the Mac. The run configuration is written again at the next run.
/// Whether the project had a fixed address.
pub fn rename_project(
    journal: &mut crate::core::journal::Journal,
    store: &Store,
    from: &str,
    to: &str,
) -> Result<bool> {
    ensure!(!holds(store, to), "id_in_use");
    let mut tunnels = load(store)?;
    let had = match tunnels.addresses.remove(from) {
        Some(address) => {
            tunnels.addresses.insert(to.to_string(), address);
            journal.write_json(&dir(store)?.join("addresses.json"), &tunnels)?;
            true
        }
        None => false,
    };
    let credentials_file = credentials(store, from)?;
    if credentials_file.exists() {
        journal.rename(&credentials_file, &credentials(store, to)?)?;
    }
    journal.remove(&config_file(store, from)?)?;
    Ok(had)
}

fn set_private(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    Ok(())
}

/// What the app shows: whether `cloudflared` is there, the connection, the last zone and each
/// project's fixed address. Never a credential or the certificate's content.
pub fn status(store: &Store) -> Result<Value> {
    let tunnels = load(store)?;
    let local = store.config()?.tld;
    let addresses: serde_json::Map<String, Value> = tunnels
        .addresses
        .iter()
        .map(|(id, a)| {
            let advanced = validate_hostname(&a.hostname, &a.zone, &local).unwrap_or(false);
            (
                id.clone(),
                json!({"hostname": a.hostname, "zone": a.zone, "advancedCertificate": advanced}),
            )
        })
        .collect();
    Ok(json!({
        "installed": crate::runtimes::utilities::catalog::user_tool("cloudflared").is_some(),
        "connected": connected(),
        "certificate": "~/.cloudflared/cert.pem",
        "zone": tunnels.zone,
        "addresses": addresses,
    }))
}

/// Requests of fixed public addresses; `None` when `method` is not one of them.
pub fn dispatch(store: &Store, method: &str, request: &Value) -> Result<Option<Value>> {
    let id = request["id"].as_str().unwrap_or("");
    let tool = || Cloudflared::find().ok_or_else(|| anyhow::anyhow!("cloudflared_missing"));
    let actor = request["actor"].as_str().unwrap_or("");
    let result = match method {
        "tunnelStatus" => status(store),
        // `cloudflared tunnel login` runs in the daemon: cancellable and never orphaned.
        "tunnelConnect" => {
            let on = request["on"] == true;
            if on {
                tool()?;
            }
            crate::daemon::request_sync(store, "cloudflareLogin", json!({"on": on}), false)
        }
        "tunnelConfigure" => {
            let done = configure(
                store,
                &tool()?,
                id,
                request["hostname"].as_str().unwrap_or(""),
                request["zone"].as_str().unwrap_or(""),
            )?;
            refresh(store, id, actor, done)
        }
        "tunnelChange" => {
            let done = change(
                store,
                &tool()?,
                id,
                request["hostname"].as_str().unwrap_or(""),
            )?;
            // A shared tunnel picks the new name up from its configuration.
            let _ = crate::daemon::request_sync(store, "reload", json!({}), false);
            refresh(store, id, actor, done)
        }
        "tunnelRemove" => {
            ensure!(request["confirmed"] == true, "confirmation_required");
            validate_id(id)?;
            let _ = crate::daemon::request_sync(
                store,
                "sharePublic",
                json!({"id": id, "on": false}),
                false,
            );
            let done = remove(store, &tool()?, id)?;
            refresh(store, id, actor, done)
        }
        "tunnelShare" => {
            let on = request["on"] == true;
            validate_id(id)?;
            if on {
                ensure!(request["confirmed"] == true, "confirmation_required");
                ensure!(store.get(id)?.enabled, "site_off");
                tool()?;
                ensure!(address(store, id).is_some(), "public_address_missing");
            }
            crate::daemon::request_sync(store, "sharePublic", json!({"id": id, "on": on}), false)
        }
        _ => return Ok(None),
    };
    result.map(Some)
}

/// After an address appears, changes or goes: the `.env` of the projects that name it with
/// `{public:<id>}` is written again (or marked out of date), as with `{port:<id>}`.
fn refresh(store: &Store, id: &str, actor: &str, mut done: Value) -> Result<Value> {
    let dependents = crate::web::projects::envs::refresh_port_dependents(store, id, actor)?;
    done["portDependents"] = serde_json::to_value(dependents)?;
    Ok(done)
}

#[cfg(test)]
#[path = "tunnels_tests.rs"]
mod tests;
