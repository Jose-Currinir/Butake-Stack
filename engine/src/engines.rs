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

/// A database and its own login role in the stack's PostgreSQL (running), for a site: the role
/// owns the database and is not a superuser and cannot bypass row security. Names are validated
/// identifiers; the password is random. Returns the connection details (the app stores the
/// password in the Keychain at once).
pub fn create_postgres_database(store: &Store, config: &StackConfig, name: &str) -> anyhow::Result<serde_json::Value> {
    anyhow::ensure!(
        !name.is_empty() && name.len() <= 40 && name.bytes().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'_')
            && !name.as_bytes()[0].is_ascii_digit(),
        "invalid_database_name"
    );
    let base = crate::services::engine_dir(store, config, "postgres").ok_or_else(|| anyhow::anyhow!("postgres_not_installed"))?;
    let port = port(config, "postgres");
    let secret = || -> anyhow::Result<String> {
        let mut bytes = [0u8; 24];
        fs::File::open("/dev/urandom").and_then(|mut f| std::io::Read::read_exact(&mut f, &mut bytes))?;
        Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
    };
    let (app_password, owner_password) = (secret()?, secret()?);
    // Two roles: the owner runs migrations (owns the schema, may create the roles migrations need);
    // migrations may seed tables under forced RLS, so it bypasses RLS (never superuser). The app role
    // only reads and writes rows, and row-level security always applies to it.
    let (owner, user) = (format!("{name}_migration"), format!("{name}_app"));
    // The SQL goes through stdin, never argv, so passwords don't show in the process list.
    let psql = |sql: &str, db: &str| -> anyhow::Result<String> {
        let mut child = Command::new(base.join("bin/psql"))
            .args(["-h", "127.0.0.1", "-p", &port.to_string(), "-U", "postgres", "-d", db, "-v", "ON_ERROR_STOP=1", "-tA", "-f", "-"])
            .env_clear()
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()?;
        std::io::Write::write_all(child.stdin.as_mut().ok_or_else(|| anyhow::anyhow!("postgres_command_failed"))?, sql.as_bytes())?;
        drop(child.stdin.take());
        let out = child.wait_with_output()?;
        anyhow::ensure!(out.status.success(), "postgres_command_failed");
        Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
    };
    let role = |role: &str, attributes: &str, password: &str| {
        format!("DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '{role}') THEN CREATE ROLE {role} {attributes} PASSWORD '{password}'; ELSE ALTER ROLE {role} {attributes} PASSWORD '{password}'; END IF; END $$;\n")
    };
    // Identifiers are validated above and passwords are hex: nothing user-typed reaches SQL.
    psql(&(role(&owner, "LOGIN NOSUPERUSER NOCREATEDB CREATEROLE BYPASSRLS", &owner_password)
        + &role(&user, "LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS", &app_password)), "postgres")?;
    if psql(&format!("SELECT 1 FROM pg_database WHERE datname = '{name}';"), "postgres")?.is_empty() {
        psql(&format!("CREATE DATABASE {name} OWNER {owner} ENCODING 'UTF8';"), "postgres")?;
    }
    psql(&format!(
        "ALTER SCHEMA public OWNER TO {owner};\n\
         REVOKE ALL ON DATABASE {name} FROM PUBLIC;\n\
         GRANT CONNECT ON DATABASE {name} TO {user};\n\
         GRANT USAGE ON SCHEMA public TO {user};\n\
         ALTER DEFAULT PRIVILEGES FOR ROLE {owner} IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO {user};\n\
         ALTER DEFAULT PRIVILEGES FOR ROLE {owner} IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO {user};\n\
         ALTER DEFAULT PRIVILEGES FOR ROLE {owner} IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO {user};\n"
    ), name)?;
    let jdbc = format!("jdbc:postgresql://127.0.0.1:{port}/{name}");
    Ok(serde_json::json!({
        "host": "127.0.0.1", "port": port, "database": name, "jdbc": jdbc,
        "user": user, "password": app_password,
        "migrationUser": owner, "migrationPassword": owner_password,
    }))
}
