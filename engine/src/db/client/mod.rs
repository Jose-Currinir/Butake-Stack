//! Database client: saved connections (never their passwords, which the app keeps in the
//! Keychain and sends per request), the stack's own engines as connections of their own, SSH
//! tunnels with `/usr/bin/ssh -L` and verified host keys, and statements run through the engines'
//! own clients (`mysql`, `psql`, `redis-cli`, `sqlite3`) with machine-readable output.
mod run;
mod tunnel;

pub use run::*;
pub use tunnel::*;

use crate::core::fsutil::private_log;
use crate::core::json;
use crate::core::process::{self, Captured};
use crate::core::rand::random_hex;
use crate::core::validate;
use crate::ssh::common::{alive, identity_file, is_ssh, known_hosts_option, port_open, ssh_error};
use crate::{
    core::fsutil::write_private,
    core::store::Store,
    db::sql::{self, Dialect, ResultSet},
    runtimes::utilities::catalog,
    web::services::engines,
};
use anyhow::{bail, ensure, Result};
use serde::{Deserialize, Serialize};
use std::{
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{Duration, Instant},
};

/// Engines the client speaks to.
pub const KINDS: &[&str] = &["mysql", "mariadb", "postgres", "redis", "valkey", "sqlite"];
/// Rows kept per result; more are counted, not sent.
pub const MAX_ROWS: usize = 1000;
/// Client output read at most (a query without LIMIT on a huge table must not fill the memory).
const MAX_OUTPUT: u64 = 96 * 1024 * 1024;
/// Marks the absence of a value in CSV output; no real value carries these control characters.
const NULL_MARK: &str = "\u{1}NULL\u{1}";
const RESULT_MARK: &str = "\u{2}BUTAKE-END\u{2}";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Ssh {
    pub host: String,
    #[serde(default = "ssh_port")]
    pub port: u16,
    pub user: String,
    /// A private key inside ~/.ssh; none = the SSH agent and the user's default keys.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub identity: Option<PathBuf>,
    /// A key imported into Stack (see `dbkeys`), by id; it wins over `identity`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key: Option<String>,
}
fn ssh_port() -> u16 {
    22
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Connection {
    pub id: String,
    pub name: String,
    pub kind: String,
    #[serde(default)]
    pub host: String,
    #[serde(default)]
    pub port: u16,
    #[serde(default)]
    pub user: String,
    #[serde(default)]
    pub database: String,
    /// SQLite file.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<PathBuf>,
    /// off, prefer, require or verify (certificate and host name).
    #[serde(default = "tls_default")]
    pub tls: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ssh: Option<Ssh>,
    /// Stack's own engine (not saved; derived from the configuration).
    #[serde(default)]
    pub builtin: bool,
    /// Whether the app keeps a password for it in the Keychain.
    #[serde(default)]
    pub has_password: bool,
    /// Stack's PostgreSQL that asks for a password: the engine supplies the superuser's, which it
    /// keeps itself (`web/services/postgres_auth.rs`); the app never has it.
    #[serde(default)]
    pub stack_password: bool,
    /// A production server: every change asks for the connection's name typed again.
    #[serde(default)]
    pub production: bool,
    /// Only reads: the clients open read-only sessions and the engine refuses every change.
    #[serde(default)]
    pub read_only: bool,
}
fn tls_default() -> String {
    "prefer".into()
}

impl Connection {
    pub fn dialect(&self) -> Option<Dialect> {
        match self.kind.as_str() {
            "mysql" | "mariadb" => Some(Dialect::MySql),
            "postgres" => Some(Dialect::Postgres),
            "sqlite" => Some(Dialect::Sqlite),
            _ => None,
        }
    }
    pub fn is_redis(&self) -> bool {
        matches!(self.kind.as_str(), "redis" | "valkey")
    }

    pub fn validate_keys(&self, store: &Store) -> Result<()> {
        if let Some(key) = self.ssh.as_ref().and_then(|s| s.key.as_ref()) {
            crate::ssh::keys::path(store, key).map_err(|_| anyhow::anyhow!("unknown_ssh_key"))?;
        }
        Ok(())
    }

    pub fn validate(&self) -> Result<()> {
        ensure!(
            !self.id.is_empty()
                && self.id.len() <= 40
                && self
                    .id
                    .bytes()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-')
                && !self.id.starts_with("stack-"),
            "invalid_connection"
        );
        ensure!(
            !self.name.trim().is_empty()
                && self.name.len() <= 80
                && !self.name.chars().any(char::is_control),
            "invalid_connection"
        );
        ensure!(KINDS.contains(&self.kind.as_str()), "invalid_connection");
        ensure!(
            ["off", "prefer", "require", "verify"].contains(&self.tls.as_str()),
            "invalid_connection"
        );
        ensure!(
            self.database.len() <= 64 && !self.database.chars().any(char::is_control),
            "invalid_connection"
        );
        ensure!(
            self.user.len() <= 80 && !self.user.chars().any(|c| c.is_control()),
            "invalid_connection"
        );
        if self.kind == "sqlite" {
            let path = self
                .path
                .as_ref()
                .ok_or_else(|| anyhow::anyhow!("invalid_connection"))?;
            ensure!(
                path.is_absolute() && self.ssh.is_none(),
                "invalid_connection"
            );
        } else {
            ensure!(
                validate::host(&self.host) && self.port > 0,
                "invalid_connection"
            );
        }
        if let Some(ssh) = &self.ssh {
            ensure!(
                validate::host(&ssh.host) && ssh.port > 0 && validate::user(&ssh.user),
                "invalid_ssh"
            );
            if let Some(identity) = &ssh.identity {
                identity_file(identity)?;
            }
        }
        Ok(())
    }
}

fn file(store: &Store) -> Result<PathBuf> {
    Ok(store.directory("config")?.join("connections.json"))
}

pub fn saved(store: &Store) -> Result<Vec<Connection>> {
    let path = file(store)?;
    if !path.exists() {
        return Ok(vec![]);
    }
    json::read_regular(&path, None)
}

fn write_saved(store: &Store, list: &[Connection]) -> Result<()> {
    json::write(&file(store)?, list)
}

/// The stack's engines that are installed, as connections: local address, default user and
/// no password unless the user set one (MySQL root, kept in the Keychain).
pub fn builtin(store: &Store) -> Result<Vec<Connection>> {
    let config = store.config()?;
    let mut out = vec![];
    for kind in ["mysql", "mariadb", "postgres", "redis", "valkey"] {
        let wanted = config
            .engines
            .get(kind)
            .map(|e| e.version.clone())
            .unwrap_or_default();
        if catalog::resolve(store, kind, &wanted).is_none() {
            continue;
        }
        let user = match kind {
            "mysql" | "mariadb" => "root",
            "postgres" => "postgres",
            _ => "",
        };
        out.push(Connection {
            id: format!("stack-{kind}"),
            name: kind.into(),
            kind: kind.into(),
            host: "127.0.0.1".into(),
            port: engines::port(&config, kind),
            user: user.into(),
            database: if kind == "postgres" {
                "postgres".into()
            } else {
                String::new()
            },
            path: None,
            // MySQL 8 generates its own certificate: with "prefer" root's caching_sha2 login works.
            tls: "prefer".into(),
            ssh: None,
            builtin: true,
            has_password: false,
            stack_password: kind == "postgres"
                && crate::web::services::postgres_auth::superuser_password(store).is_some(),
            production: false,
            read_only: false,
        });
    }
    Ok(out)
}

pub fn list(store: &Store) -> Result<Vec<Connection>> {
    let mut all = builtin(store)?;
    all.extend(saved(store)?);
    Ok(all)
}

pub fn find(store: &Store, id: &str) -> Result<Connection> {
    list(store)?
        .into_iter()
        .find(|c| c.id == id)
        .ok_or_else(|| anyhow::anyhow!("unknown_connection"))
}

pub fn save(store: &Store, mut connection: Connection) -> Result<Connection> {
    connection.builtin = false;
    connection.stack_password = false;
    connection.validate()?;
    connection.validate_keys(store)?;
    let mut list = saved(store)?;
    list.retain(|c| c.id != connection.id);
    list.push(connection.clone());
    list.sort_by_key(|a| a.name.to_lowercase());
    write_saved(store, &list)?;
    close_tunnel(store, &connection.id);
    // Open sessions keep the old settings (read-only mode among them): the next request starts anew.
    crate::db::session::close(store, &connection.id);
    Ok(connection)
}

pub fn delete(store: &Store, id: &str) -> Result<()> {
    let mut list = saved(store)?;
    let before = list.len();
    list.retain(|c| c.id != id);
    ensure!(list.len() < before, "unknown_connection");
    close_tunnel(store, id);
    write_saved(store, &list)?;
    // Its SQL history and query tabs go with it.
    crate::db::history::forget(store, id)
}

#[cfg(test)]
mod tests;
