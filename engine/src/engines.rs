//! Engine recipes: every service the stack can run directly, with its type, default port and how
//! to initialize, configure and launch it. Adding an engine means adding a recipe here and its
//! catalog source in `tools.rs`; nothing else hard-codes engine names.
use crate::{model::StackConfig, services::write_private, store::Store};
use anyhow::{ensure, Result};
use std::{collections::BTreeMap, fs, path::Path, path::PathBuf, process::Command, process::Stdio};

pub struct Recipe {
    pub id: &'static str,
    pub category: &'static str,
    pub port: u16,
    pub stop_timeout: u64,
}

pub const RECIPES: &[Recipe] = &[
    Recipe { id: "mysql", category: "database", port: 3306, stop_timeout: 120 },
    Recipe { id: "mariadb", category: "database", port: 3307, stop_timeout: 120 },
    Recipe { id: "postgres", category: "database", port: 5432, stop_timeout: 60 },
    Recipe { id: "mongodb", category: "database", port: 27017, stop_timeout: 60 },
    Recipe { id: "redis", category: "cache", port: 6379, stop_timeout: 60 },
    Recipe { id: "valkey", category: "cache", port: 6380, stop_timeout: 60 },
    Recipe { id: "meilisearch", category: "search", port: 7700, stop_timeout: 30 },
    Recipe { id: "typesense", category: "search", port: 8108, stop_timeout: 30 },
    Recipe { id: "rustfs", category: "storage", port: 9100, stop_timeout: 30 },
];

pub fn recipe(id: &str) -> Option<&'static Recipe> {
    RECIPES.iter().find(|r| r.id == id)
}

/// Port of an engine: the instance's own, the legacy global setting (MySQL, Redis) or the default.
pub fn port(config: &StackConfig, id: &str) -> u16 {
    if let Some(port) = config.engines.get(id).and_then(|e| e.port) {
        return port;
    }
    match id {
        "mysql" => config.ports.mysql,
        "redis" => config.ports.redis,
        _ => recipe(id).map(|r| r.port).unwrap_or(0),
    }
}

pub struct Launch {
    pub executable: PathBuf,
    pub args: Vec<String>,
    pub environment: BTreeMap<String, String>,
}

fn clean(path: &Path) -> Result<String> {
    let text = path.to_string_lossy().into_owned();
    ensure!(
        !text.chars().any(|c| c.is_control() || c == '"' || c == '#' || c == ';'),
        "invalid_engine_path"
    );
    Ok(text)
}

fn quiet(command: &mut Command) -> Result<()> {
    let status = command.env_clear().stdout(Stdio::null()).stderr(Stdio::null()).status()?;
    ensure!(status.success(), "engine_init_failed");
    Ok(())
}

pub fn datadir(store: &Store, id: &str) -> Result<PathBuf> {
    Ok(store.directory("data")?.join(id))
}

/// A random secret kept in `config/<engine>/<name>` (0600) for engines that require one.
fn secret(store: &Store, engine: &str, name: &str) -> Result<String> {
    let dir = store.directory("config")?.join(engine);
    fs::create_dir_all(&dir)?;
    let path = dir.join(name);
    if let Ok(value) = fs::read_to_string(&path) {
        if value.len() >= 24 {
            return Ok(value.trim().to_string());
        }
    }
    let mut bytes = [0u8; 24];
    fs::File::open("/dev/urandom").and_then(|mut f| std::io::Read::read_exact(&mut f, &mut bytes))?;
    let value: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    write_private(&path, &value)?;
    Ok(value)
}

/// Writes the engine's config, initializes an empty datadir the first time and returns how to
/// run it in the foreground on 127.0.0.1.
pub fn launch(store: &Store, config: &StackConfig, id: &str, base: &Path) -> Result<Launch> {
    let port = port(config, id);
    let data = datadir(store, id)?;
    let run = store.directory("run")?;
    let none = BTreeMap::new();
    let bin = |name: &str| base.join("bin").join(name);
    Ok(match id {
        "mysql" | "mariadb" => {
            let cnf = crate::services::mysql_config(store, config, base, id, port)?;
            Launch { executable: bin(if id == "mysql" { "mysqld" } else { "mariadbd" }), args: vec![format!("--defaults-file={}", cnf.display()), "--console".into()], environment: none }
        }
        "redis" | "valkey" => {
            let conf = crate::services::redis_config(store, id, port)?;
            Launch { executable: bin(if id == "redis" { "redis-server" } else { "valkey-server" }), args: vec![conf.to_string_lossy().into_owned()], environment: none }
        }
        "postgres" => {
            if !data.join("PG_VERSION").exists() {
                fs::create_dir_all(&data)?;
                quiet(Command::new(bin("initdb")).args(["--encoding=UTF8", "--locale=C", "--auth=trust", "--username=postgres", "-D"]).arg(&data))?;
            }
            Launch {
                executable: bin("postgres"),
                args: vec!["-D".into(), clean(&data)?, "-p".into(), port.to_string(), "-h".into(), "127.0.0.1".into(), "-k".into(), clean(&run)?],
                environment: none,
            }
        }
        "mongodb" => {
            fs::create_dir_all(&data)?;
            Launch {
                executable: bin("mongod"),
                args: vec!["--dbpath".into(), clean(&data)?, "--port".into(), port.to_string(), "--bind_ip".into(), "127.0.0.1".into(), "--quiet".into()],
                environment: none,
            }
        }
        "meilisearch" => {
            fs::create_dir_all(&data)?;
            let key = secret(store, id, "master.key")?;
            Launch {
                executable: bin("meilisearch"),
                args: vec!["--db-path".into(), clean(&data.join("data.ms"))?, "--dump-dir".into(), clean(&data.join("dumps"))?, "--snapshot-dir".into(), clean(&data.join("snapshots"))?, "--http-addr".into(), format!("127.0.0.1:{port}"), "--env".into(), "development".into(), "--no-analytics".into()],
                environment: [("MEILI_MASTER_KEY".into(), key)].into(),
            }
        }
        "typesense" => {
            fs::create_dir_all(&data)?;
            let key = secret(store, id, "api.key")?;
            Launch {
                executable: bin("typesense-server"),
                args: vec!["--data-dir".into(), clean(&data)?, "--api-port".into(), port.to_string(), "--listen-address".into(), "127.0.0.1".into(), "--enable-cors".into()],
                environment: [("TYPESENSE_API_KEY".into(), key)].into(),
            }
        }
        "rustfs" => {
            fs::create_dir_all(&data)?;
            let password = secret(store, id, "secret.key")?;
            Launch {
                executable: bin("rustfs"),
                args: vec!["server".into(), "--address".into(), format!("127.0.0.1:{port}"), "--console-enable".into(), "--console-address".into(), format!("127.0.0.1:{}", port + 1), clean(&data)?],
                environment: [("RUSTFS_ACCESS_KEY".into(), "butake".into()), ("RUSTFS_SECRET_KEY".into(), password)].into(),
            }
        }
        _ => anyhow::bail!("unknown_engine"),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn recipes_have_unique_ids_and_ports() {
        let mut ids: Vec<_> = RECIPES.iter().map(|r| r.id).collect();
        let mut ports: Vec<_> = RECIPES.iter().map(|r| r.port).collect();
        ids.sort();
        ids.dedup();
        ports.sort();
        ports.dedup();
        assert_eq!(ids.len(), RECIPES.len());
        assert_eq!(ports.len(), RECIPES.len());
        let config = StackConfig::default();
        assert_eq!(port(&config, "mysql"), 3306);
        assert_eq!(port(&config, "postgres"), 5432);
        assert!(recipe("sqlite").is_none());
    }
}
