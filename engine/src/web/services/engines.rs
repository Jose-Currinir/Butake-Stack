//! Engine recipes: every service the stack can run directly, with its type, default port and how
//! to initialize, configure and launch it. Adding an engine means adding a recipe here and its
//! catalog source in `runtimes/utilities/catalog/mod.rs`; nothing else hard-codes engine names.
use crate::core::rand::random_hex;
use crate::{
    core::fsutil::write_private, core::model::StackConfig, core::store::Store,
    runtimes::utilities::catalog,
};
use anyhow::{Result, ensure};
use std::{collections::BTreeMap, fs, path::Path, path::PathBuf, process::Command, process::Stdio};

pub struct Recipe {
    pub id: &'static str,
    pub category: &'static str,
    pub port: u16,
    pub stop_timeout: u64,
}

pub const RECIPES: &[Recipe] = &[
    Recipe {
        id: "mysql",
        category: "database",
        port: 3306,
        stop_timeout: 120,
    },
    Recipe {
        id: "mariadb",
        category: "database",
        port: 3307,
        stop_timeout: 120,
    },
    Recipe {
        id: "postgres",
        category: "database",
        port: 5432,
        stop_timeout: 60,
    },
    Recipe {
        id: "mongodb",
        category: "database",
        port: 27017,
        stop_timeout: 60,
    },
    Recipe {
        id: "redis",
        category: "cache",
        port: 6379,
        stop_timeout: 60,
    },
    Recipe {
        id: "valkey",
        category: "cache",
        port: 6380,
        stop_timeout: 60,
    },
    Recipe {
        id: "meilisearch",
        category: "search",
        port: 7700,
        stop_timeout: 30,
    },
    Recipe {
        id: "typesense",
        category: "search",
        port: 8108,
        stop_timeout: 30,
    },
    Recipe {
        id: "rustfs",
        category: "storage",
        port: 9100,
        stop_timeout: 30,
    },
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
        !text
            .chars()
            .any(|c| c.is_control() || c == '"' || c == '#' || c == ';'),
        "invalid_engine_path"
    );
    Ok(text)
}

pub fn datadir(store: &Store, id: &str) -> Result<PathBuf> {
    Ok(store.directory("data")?.join(id))
}

/// A random secret kept in `config/<engine>/<name>` (0600) for engines that require one.
pub(crate) fn secret(store: &Store, engine: &str, name: &str) -> Result<String> {
    let dir = store.directory("config")?.join(engine);
    fs::create_dir_all(&dir)?;
    let path = dir.join(name);
    if let Ok(value) = fs::read_to_string(&path)
        && value.len() >= 24
    {
        return Ok(value.trim().to_string());
    }
    let value = random_hex(24)?;
    write_private(&path, &value)?;
    Ok(value)
}

/// Engine folder for the wanted version, if the engine is enabled and installed.
pub fn engine_dir(store: &Store, config: &StackConfig, name: &str) -> Option<PathBuf> {
    let engine = config.engines.get(name).filter(|e| e.enabled)?;
    catalog::resolve(store, name, &engine.version)
}

/// Writes my.cnf for MySQL or MariaDB and initializes an empty datadir the first time.
pub fn mysql_config(
    store: &Store,
    _config: &StackConfig,
    base: &Path,
    id: &str,
    port: u16,
) -> Result<PathBuf> {
    let datadir = datadir(store, id)?;
    let run = store.directory("run")?;
    let directory = store.directory("config")?.join(id);
    fs::create_dir_all(&directory)?;
    let socket = run.join(format!("{id}.sock"));
    let extra = if id == "mysql" {
        "mysqlx=OFF\ncollation-server=utf8mb4_0900_ai_ci\n"
    } else {
        "collation-server=utf8mb4_unicode_ci\n"
    };
    let cnf = format!(
        "[mysqld]\nbasedir={}\ndatadir={}\nport={port}\nbind-address=127.0.0.1\n\
         socket={}\npid-file={}\nskip-log-bin\ninnodb_buffer_pool_size=512M\n\
         character-set-server=utf8mb4\n{extra}\n[client]\nport={port}\nsocket={}\n",
        clean(base)?,
        clean(&datadir)?,
        clean(&socket)?,
        clean(&run.join(format!("{id}.pid")))?,
        clean(&socket)?,
    );
    let path = directory.join("my.cnf");
    write_private(&path, &cnf)?;
    if !datadir.exists() {
        let mut command = if id == "mysql" {
            let mut c = Command::new(base.join("bin/mysqld"));
            c.arg(format!("--defaults-file={}", path.display()))
                .arg("--initialize-insecure");
            c
        } else {
            let mut c = Command::new(base.join("scripts/mariadb-install-db"));
            c.arg(format!("--defaults-file={}", path.display()))
                .arg(format!("--basedir={}", base.display()))
                .arg("--auth-root-authentication-method=normal");
            c
        };
        // The first start of a database initializes its folder: bounded in time, and its output
        // kept in a private log (no secrets: the account has no password yet) so a failure can be
        // diagnosed. A half-made folder would pass for an initialized one next time: remove it.
        let log = store.directory("logs")?.join(format!("{id}-init.log"));
        let output = crate::core::process::append_log(&log)?;
        use std::os::unix::process::CommandExt;
        let mut child = command
            .env_clear()
            .stdin(Stdio::null())
            .stdout(output.try_clone()?)
            .stderr(output)
            .process_group(0)
            .spawn()
            .map_err(|_| anyhow::anyhow!("mysql_init_failed"))?;
        let group = i32::try_from(child.id()).unwrap_or(0);
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(300);
        let success = loop {
            if let Some(status) = child.try_wait()? {
                break status.success();
            }
            if std::time::Instant::now() >= deadline {
                crate::core::watch::end_group(group);
                let _ = child.wait();
                break false;
            }
            std::thread::sleep(std::time::Duration::from_millis(100));
        };
        if !success {
            let _ = fs::remove_dir_all(&datadir);
        }
        ensure!(success, "mysql_init_failed");
    }
    Ok(path)
}

/// redis.conf for Redis or Valkey (same format).
pub fn redis_config(store: &Store, id: &str, port: u16) -> Result<PathBuf> {
    let dir = datadir(store, id)?;
    fs::create_dir_all(&dir)?;
    let directory = store.directory("config")?.join(id);
    fs::create_dir_all(&directory)?;
    let conf = format!(
        "bind 127.0.0.1\nport {port}\nprotected-mode yes\ndaemonize no\ndir \"{}\"\n\
         dbfilename dump.rdb\nsave 3600 1 300 100 60 10000\nappendonly no\nlogfile \"\"\n",
        clean(&dir)?
    );
    let path = directory.join(if id == "redis" {
        "redis.conf"
    } else {
        "valkey.conf"
    });
    write_private(&path, &conf)?;
    Ok(path)
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
            let cnf = mysql_config(store, config, base, id, port)?;
            Launch {
                executable: bin(if id == "mysql" { "mysqld" } else { "mariadbd" }),
                args: vec![
                    format!("--defaults-file={}", cnf.display()),
                    "--console".into(),
                ],
                environment: none,
            }
        }
        "redis" | "valkey" => {
            let conf = redis_config(store, id, port)?;
            Launch {
                executable: bin(if id == "redis" {
                    "redis-server"
                } else {
                    "valkey-server"
                }),
                args: vec![conf.to_string_lossy().into_owned()],
                environment: none,
            }
        }
        "postgres" => {
            // Only a new cluster is initialized, and it asks for a password. One that exists is
            // never touched here (a `trust` one stays so until the user asks; postgres_auth.rs).
            if !data.join("PG_VERSION").exists() {
                fs::create_dir_all(&data)?;
                crate::web::services::postgres_auth::initdb(store, &bin("initdb"), &data)?;
            }
            Launch {
                executable: bin("postgres"),
                args: vec![
                    "-D".into(),
                    clean(&data)?,
                    "-p".into(),
                    port.to_string(),
                    "-h".into(),
                    "127.0.0.1".into(),
                    "-k".into(),
                    clean(&run)?,
                ],
                environment: none,
            }
        }
        "mongodb" => {
            fs::create_dir_all(&data)?;
            Launch {
                executable: bin("mongod"),
                args: vec![
                    "--dbpath".into(),
                    clean(&data)?,
                    "--port".into(),
                    port.to_string(),
                    "--bind_ip".into(),
                    "127.0.0.1".into(),
                    "--quiet".into(),
                ],
                environment: none,
            }
        }
        "meilisearch" => {
            fs::create_dir_all(&data)?;
            let key = secret(store, id, "master.key")?;
            Launch {
                executable: bin("meilisearch"),
                args: vec![
                    "--db-path".into(),
                    clean(&data.join("data.ms"))?,
                    "--dump-dir".into(),
                    clean(&data.join("dumps"))?,
                    "--snapshot-dir".into(),
                    clean(&data.join("snapshots"))?,
                    "--http-addr".into(),
                    format!("127.0.0.1:{port}"),
                    "--env".into(),
                    "development".into(),
                    "--no-analytics".into(),
                ],
                environment: [("MEILI_MASTER_KEY".into(), key)].into(),
            }
        }
        "typesense" => {
            fs::create_dir_all(&data)?;
            let key = secret(store, id, "api.key")?;
            Launch {
                executable: bin("typesense-server"),
                args: vec![
                    "--data-dir".into(),
                    clean(&data)?,
                    "--api-port".into(),
                    port.to_string(),
                    "--listen-address".into(),
                    "127.0.0.1".into(),
                    "--enable-cors".into(),
                ],
                environment: [("TYPESENSE_API_KEY".into(), key)].into(),
            }
        }
        "rustfs" => {
            fs::create_dir_all(&data)?;
            let password = secret(store, id, "secret.key")?;
            Launch {
                executable: bin("rustfs"),
                args: vec![
                    "server".into(),
                    "--address".into(),
                    format!("127.0.0.1:{port}"),
                    "--console-enable".into(),
                    "--console-address".into(),
                    format!("127.0.0.1:{}", port + 1),
                    clean(&data)?,
                ],
                environment: [
                    ("RUSTFS_ACCESS_KEY".into(), "butake".into()),
                    ("RUSTFS_SECRET_KEY".into(), password),
                ]
                .into(),
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
