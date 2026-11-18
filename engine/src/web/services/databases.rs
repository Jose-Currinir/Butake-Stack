//! Databases of a project in the stack's own PostgreSQL or MySQL: the database and its login
//! accounts. An account that already exists keeps its password: creating again never rotates it.
//! Changing a password is its own explicit request (`rotate_*`), and the projects whose
//! environments name that account are listed first so the user knows who must be updated.
//!
//! Names are validated identifiers and generated passwords are hex, so nothing user-typed reaches
//! SQL as text. SQL goes through stdin, never argv, so passwords don't show in the process list.
use crate::core::rand::random_hex;
use crate::web::services::engines::{engine_dir, port};
use crate::{core::model::StackConfig, core::store::Store};
use anyhow::{Result, anyhow, ensure};
use serde_json::{Value, json};
use std::process::{Command, Stdio};

/// How a new PostgreSQL database is reached.
#[derive(Debug, Clone, PartialEq)]
pub enum Accounts {
    /// One login that owns the database (runs migrations and the app).
    Single(String),
    /// `<base>_migration` owns the schema and bypasses RLS; `<base>_app` only reads and writes
    /// rows, always under row-level security.
    Split,
}

impl Accounts {
    /// `mode` and `user` of a request; the single user defaults to the database's name.
    pub fn from_request(request: &Value, database: &str) -> Self {
        match request["mode"].as_str() {
            Some("split") => Accounts::Split,
            _ => Accounts::Single(
                request["user"]
                    .as_str()
                    .filter(|u| !u.is_empty())
                    .unwrap_or(database)
                    .to_string(),
            ),
        }
    }
}

/// Lowercase letters, digits and `_`, not starting with a digit.
fn identifier(name: &str, max: usize) -> bool {
    !name.is_empty()
        && name.len() <= max
        && name
            .bytes()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'_')
        && !name.as_bytes()[0].is_ascii_digit()
}

pub fn validate_database(name: &str) -> Result<()> {
    ensure!(identifier(name, 40), "invalid_database_name");
    Ok(())
}

/// An account Stack may create or change: never the server's own (`postgres`, `root`, `pg_*`,
/// `mysql.*`).
pub fn validate_account(name: &str) -> Result<()> {
    ensure!(
        identifier(name, 48) && !["postgres", "root"].contains(&name) && !name.starts_with("pg_"),
        "invalid_database_user"
    );
    Ok(())
}

/// `psql` of the stack's PostgreSQL as its superuser, over TCP on 127.0.0.1, with the
/// superuser's password when Stack keeps one (a cluster that asks for it; see `postgres_auth`).
pub(crate) struct Postgres {
    psql: std::path::PathBuf,
    port: u16,
    password: Option<String>,
}

impl Postgres {
    pub(crate) fn new(store: &Store, config: &StackConfig) -> Result<Self> {
        let base = engine_dir(store, config, "postgres")
            .ok_or_else(|| anyhow!("postgres_not_installed"))?;
        Ok(Self {
            psql: base.join("bin/psql"),
            port: port(config, "postgres"),
            password: crate::web::services::postgres_auth::superuser_password(store),
        })
    }

    /// The same server without the password (to check that it is now required).
    pub(crate) fn without_password(&self) -> Self {
        Self {
            psql: self.psql.clone(),
            port: self.port,
            password: None,
        }
    }

    pub(crate) fn run(&self, sql: &str, database: &str) -> Result<String> {
        let mut command = Command::new(&self.psql);
        command.env_clear();
        if let Some(password) = &self.password {
            command.env("PGPASSWORD", password);
        }
        let mut child = command
            .args([
                "-h",
                "127.0.0.1",
                "-p",
                &self.port.to_string(),
                "-U",
                "postgres",
            ])
            // -w: never prompt (a missing password fails instead of waiting).
            .args([
                "-d",
                database,
                "-v",
                "ON_ERROR_STOP=1",
                "-tA",
                "-w",
                "-f",
                "-",
            ])
            .env("PGPASSFILE", "/dev/null")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        std::io::Write::write_all(
            child
                .stdin
                .as_mut()
                .ok_or_else(|| anyhow!("postgres_command_failed"))?,
            sql.as_bytes(),
        )?;
        drop(child.stdin.take());
        let out = child.wait_with_output()?;
        ensure!(out.status.success(), "postgres_command_failed");
        Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
    }

    fn exists(&self, sql: &str) -> Result<bool> {
        Ok(!self.run(sql, "postgres")?.is_empty())
    }

    /// Creates the role with a new random password, or leaves an existing one exactly as it is.
    /// Returns the password only when the role is new.
    fn ensure_role(&self, role: &str, attributes: &str) -> Result<Option<String>> {
        if self.exists(&format!("SELECT 1 FROM pg_roles WHERE rolname = '{role}';"))? {
            return Ok(None);
        }
        let password = random_hex(24)?;
        self.run(
            &format!("CREATE ROLE {role} {attributes} PASSWORD '{password}';"),
            "postgres",
        )?;
        Ok(Some(password))
    }
}

/// A database in the stack's PostgreSQL (running) with its own login(s), for a project. Accounts
/// are never superusers. Returns the connection details; `password` (and `migrationPassword`) is
/// null when that account already existed, which keeps its password.
pub fn create_postgres(
    store: &Store,
    config: &StackConfig,
    name: &str,
    accounts: &Accounts,
) -> Result<Value> {
    validate_database(name)?;
    let pg = Postgres::new(store, config)?;
    let (owner, user) = match accounts {
        Accounts::Single(user) => (user.clone(), user.clone()),
        Accounts::Split => (format!("{name}_migration"), format!("{name}_app")),
    };
    validate_account(&owner)?;
    validate_account(&user)?;
    let (owner_password, user_password) = match accounts {
        Accounts::Single(_) => {
            let password = pg.ensure_role(
                &owner,
                "LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS",
            )?;
            (password.clone(), password)
        }
        // Migrations may create the roles they need and seed tables under forced RLS.
        Accounts::Split => (
            pg.ensure_role(&owner, "LOGIN NOSUPERUSER NOCREATEDB CREATEROLE BYPASSRLS")?,
            pg.ensure_role(
                &user,
                "LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS",
            )?,
        ),
    };
    let existed = pg.exists(&format!(
        "SELECT 1 FROM pg_database WHERE datname = '{name}';"
    ))?;
    if !existed {
        pg.run(
            &format!("CREATE DATABASE {name} OWNER {owner} ENCODING 'UTF8';"),
            "postgres",
        )?;
    }
    let mut sql = format!(
        "REVOKE ALL ON DATABASE {name} FROM PUBLIC;\n\
         GRANT CONNECT, TEMPORARY ON DATABASE {name} TO {owner};\n"
    );
    // A database Stack just made belongs to its owner, schema included. One that was already there
    // keeps its owners: the account only gets what it needs to work in it.
    sql.push_str(&if existed {
        format!("GRANT CREATE ON DATABASE {name} TO {owner};\nGRANT USAGE, CREATE ON SCHEMA public TO {owner};\n")
    } else {
        format!("ALTER SCHEMA public OWNER TO {owner};\n")
    });
    if user != owner {
        sql.push_str(&format!(
            "GRANT CONNECT ON DATABASE {name} TO {user};\n\
             GRANT USAGE ON SCHEMA public TO {user};\n\
             ALTER DEFAULT PRIVILEGES FOR ROLE {owner} IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO {user};\n\
             ALTER DEFAULT PRIVILEGES FOR ROLE {owner} IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO {user};\n\
             ALTER DEFAULT PRIVILEGES FOR ROLE {owner} IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO {user};\n"
        ));
    }
    pg.run(&sql, name)?;
    let port = pg.port;
    let mut out = json!({
        "engine": "postgres", "host": "127.0.0.1", "port": port, "database": name,
        "jdbc": format!("jdbc:postgresql://127.0.0.1:{port}/{name}"),
        "user": user, "password": user_password, "databaseExisted": existed,
    });
    if let Accounts::Split = accounts {
        out["migrationUser"] = json!(owner);
        out["migrationPassword"] = json!(owner_password);
    }
    Ok(out)
}

/// A new password for an existing account of the stack's PostgreSQL, which the app keeps in the
/// Keychain at once. Never for the server's own accounts.
pub fn rotate_postgres(store: &Store, config: &StackConfig, role: &str) -> Result<String> {
    validate_account(role)?;
    let pg = Postgres::new(store, config)?;
    ensure!(
        pg.exists(&format!("SELECT 1 FROM pg_roles WHERE rolname = '{role}';"))?,
        "unknown_database_user"
    );
    let password = random_hex(24)?;
    pg.run(
        &format!("ALTER ROLE {role} PASSWORD '{password}';"),
        "postgres",
    )?;
    Ok(password)
}

/// The stack's MySQL as root: the password the user set (Keychain, sent by the app), if any.
fn mysql(
    store: &Store,
    config: &StackConfig,
    root_password: Option<&str>,
) -> Result<crate::db::client::Target> {
    engine_dir(store, config, "mysql").ok_or_else(|| anyhow!("mysql_not_installed"))?;
    let connection = crate::db::client::find(store, "stack-mysql")?;
    crate::db::client::target(store, connection, root_password.map(str::to_string))
}

fn mysql_run(
    target: &crate::db::client::Target,
    statements: &[String],
) -> Result<crate::db::client::RunOutput> {
    let out = crate::db::client::run_sql(target, "", statements, 10)?;
    ensure!(out.error.is_none(), "mysql_command_failed");
    Ok(out)
}

fn mysql_account_exists(target: &crate::db::client::Target, user: &str) -> Result<bool> {
    let out = mysql_run(
        target,
        &[format!(
            "SELECT 1 FROM mysql.user WHERE User = '{user}' AND Host = 'localhost'"
        )],
    )?;
    Ok(out.results.first().is_some_and(|r| !r.rows.is_empty()))
}

/// A database in the stack's MySQL. Root starts without a password; once the user sets one the
/// database also gets its own account (`user`), so the project never logs in as root. An account
/// that already exists keeps its password (`password` null) and only gets the grant.
pub fn create_mysql(
    store: &Store,
    config: &StackConfig,
    name: &str,
    user: &str,
    root_password: Option<&str>,
) -> Result<Value> {
    validate_database(name)?;
    let root_password = root_password.filter(|p| !p.is_empty());
    let target = mysql(store, config, root_password)?;
    let mut statements = vec![format!(
        "CREATE DATABASE IF NOT EXISTS `{name}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
    )];
    let port = port(config, "mysql");
    let mut out = json!({"engine": "mysql", "host": "127.0.0.1", "port": port, "database": name});
    if root_password.is_none() {
        mysql_run(&target, &statements)?;
        out["user"] = json!("root");
        out["password"] = json!("");
        return Ok(out);
    }
    validate_account(user)?;
    let password = if mysql_account_exists(&target, user)? {
        None
    } else {
        let password = random_hex(18)?;
        statements.push(format!(
            "CREATE USER '{user}'@'localhost' IDENTIFIED BY '{password}'"
        ));
        Some(password)
    };
    statements.push(format!(
        "GRANT ALL PRIVILEGES ON `{name}`.* TO '{user}'@'localhost'"
    ));
    mysql_run(&target, &statements)?;
    out["user"] = json!(user);
    out["password"] = json!(password);
    Ok(out)
}

/// A new password for an existing account of the stack's MySQL (needs root's password).
pub fn rotate_mysql(
    store: &Store,
    config: &StackConfig,
    user: &str,
    root_password: Option<&str>,
) -> Result<String> {
    validate_account(user)?;
    let root_password = root_password.filter(|p| !p.is_empty());
    ensure!(root_password.is_some(), "mysql_root_password_required");
    let target = mysql(store, config, root_password)?;
    ensure!(
        mysql_account_exists(&target, user)?,
        "unknown_database_user"
    );
    let password = random_hex(18)?;
    mysql_run(
        &target,
        &[format!(
            "ALTER USER '{user}'@'localhost' IDENTIFIED BY '{password}'"
        )],
    )?;
    Ok(password)
}

/// Projects whose environments name `user` as a database login (a non-secret value of a key that
/// ends in `USER` or `USERNAME`), with the environments that do: who must be updated when its
/// password changes. Names only, never values of secrets.
pub fn account_users(store: &Store, user: &str) -> Result<Vec<Value>> {
    validate_account(user)?;
    let mut out = vec![];
    for project in store.list()? {
        let Ok(site) = crate::web::projects::envs::load(store, &project.id) else {
            continue;
        };
        let environments: Vec<&str> = site
            .environments
            .iter()
            .filter(|env| {
                env.entries.iter().any(|e| {
                    !e.secret
                        && e.value == user
                        && (e.key.ends_with("USER") || e.key.ends_with("USERNAME"))
                })
            })
            .map(|env| env.name.as_str())
            .collect();
        if !environments.is_empty() {
            out.push(json!({"id": project.id, "name": project.name, "environments": environments}));
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_and_modes() {
        for good in ["app_health", "a1", "salud"] {
            assert!(validate_account(good).is_ok(), "{good}");
        }
        for bad in [
            "postgres",
            "root",
            "pg_monitor",
            "1x",
            "a-b",
            "A",
            "",
            "x; drop",
        ] {
            assert!(validate_account(bad).is_err(), "{bad}");
        }
        assert!(validate_database("app_health").is_ok());
        assert!(validate_database("app health").is_err());
        assert_eq!(
            Accounts::from_request(&json!({}), "salud"),
            Accounts::Single("salud".into())
        );
        assert_eq!(
            Accounts::from_request(&json!({"mode": "single", "user": "lector"}), "salud"),
            Accounts::Single("lector".into())
        );
        assert_eq!(
            Accounts::from_request(&json!({"mode": "split"}), "salud"),
            Accounts::Split
        );
    }

    #[test]
    fn projects_that_name_an_account() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::new(temp.path().join("store")).unwrap();
        let folder = temp.path().join("demo");
        std::fs::create_dir_all(&folder).unwrap();
        store
            .save(
                serde_json::from_value(json!({
                    "id": "demo", "name": "Demo", "path": folder, "domains": ["demo.test"],
                    "https": false, "kind": "kmp", "runtime": {}, "docroot": ".", "services": [],
                    "databases": [], "processes": []}))
                .unwrap(),
            )
            .unwrap();
        let site: crate::web::projects::envs::SiteEnvironments = serde_json::from_value(json!({
            "environments": [
                {"id": "local", "name": "Local", "kind": "local", "entries": [
                    {"key": "DB_USERNAME", "value": "salud", "secret": false},
                    {"key": "DB_PASSWORD", "value": "", "secret": true}]},
                {"id": "testing", "name": "Pruebas", "kind": "testing", "entries": [
                    {"key": "APP_NAME", "value": "salud", "secret": false}]}]}))
        .unwrap();
        crate::web::projects::envs::save(&store, "demo", &site, "qa").unwrap();
        let users = account_users(&store, "salud").unwrap();
        assert_eq!(users.len(), 1);
        assert_eq!(users[0]["id"], "demo");
        assert_eq!(users[0]["environments"], json!(["Local"]));
        assert!(account_users(&store, "otro").unwrap().is_empty());
    }
}
