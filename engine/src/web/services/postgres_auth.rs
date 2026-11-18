//! How the stack's PostgreSQL lets people in.
//!
//! A cluster Stack creates now asks for a password on every connection (`scram-sha-256` over TCP
//! on 127.0.0.1/::1 and on the Unix socket, which only the user can open). Its superuser
//! `postgres` gets a random password that Stack keeps like the other services' credentials: a
//! private file (0600) in `config/postgres/`, read only by the engine to administer the server
//! (create databases, the database client) and never shown, logged or returned.
//!
//! A cluster created before (`trust`: any local process gets in as any role) is left exactly as
//! it is. Asking for a password is an explicit action (`require_password`), which keeps the old
//! `pg_hba.conf` next to the new one so `allow_trust` can put it back.
use crate::core::fsutil::write_private;
use crate::web::services::databases::Postgres;
use crate::web::services::engines::{datadir, secret};
use crate::{core::model::StackConfig, core::store::Store};
use anyhow::{Result, ensure};
use serde_json::{Value, json};
use std::{fs, path::Path, process::Command, process::Stdio};

const PASSWORD_FILE: &str = "superuser.password";
/// The `pg_hba.conf` a `trust` cluster had before Stack asked for passwords.
const TRUST_BACKUP: &str = "pg_hba.conf.stack-trust";

/// What Stack writes in `pg_hba.conf` when it asks for a password (the same lines `initdb` writes
/// with `--auth=scram-sha-256`).
const HBA_PASSWORD: &str = "# Escrito por Stack: toda conexión pide contraseña (scram-sha-256).\n\
local   all             all                                     scram-sha-256\n\
host    all             all             127.0.0.1/32            scram-sha-256\n\
host    all             all             ::1/128                 scram-sha-256\n\
local   replication     all                                     scram-sha-256\n\
host    replication     all             127.0.0.1/32            scram-sha-256\n\
host    replication     all             ::1/128                 scram-sha-256\n";

/// The superuser's password, when Stack has one (a cluster it created, or one it was told to
/// protect). Never created here.
pub fn superuser_password(store: &Store) -> Option<String> {
    let path = store
        .directory("config")
        .ok()?
        .join("postgres")
        .join(PASSWORD_FILE);
    let meta = fs::symlink_metadata(&path).ok()?;
    if !meta.is_file() || meta.len() > 256 {
        return None;
    }
    let value = fs::read_to_string(path).ok()?.trim().to_string();
    (value.len() >= 24).then_some(value)
}

/// `trust` (some line lets people in without a password), `password`, `none` (no cluster yet) or
/// `other` (methods Stack does not write, edited by hand).
pub fn state(store: &Store) -> Result<&'static str> {
    let data = datadir(store, "postgres")?;
    if !data.join("PG_VERSION").exists() {
        return Ok("none");
    }
    let text = fs::read_to_string(data.join("pg_hba.conf")).unwrap_or_default();
    let methods: Vec<&str> = text
        .lines()
        .map(|l| l.split('#').next().unwrap_or("").trim())
        .filter(|l| !l.is_empty())
        .filter_map(|l| {
            let fields: Vec<&str> = l.split_whitespace().collect();
            // local DATABASE USER METHOD; host DATABASE USER ADDRESS [MASK] METHOD.
            let at = if fields.first() == Some(&"local") {
                3
            } else {
                4
            };
            fields
                .get(at)
                .filter(|m| !m.contains('.') && !m.contains(':'))
                .or(fields.get(at + 1))
                .copied()
        })
        .collect();
    Ok(if methods.contains(&"trust") {
        "trust"
    } else if methods
        .iter()
        .all(|m| ["scram-sha-256", "md5", "password"].contains(m))
        && !methods.is_empty()
    {
        "password"
    } else {
        "other"
    })
}

/// Initializes a new cluster that asks for a password: the superuser's password goes to `initdb`
/// in a private file removed right after, and the socket is opened only to the user.
pub fn initdb(store: &Store, initdb: &Path, data: &Path) -> Result<()> {
    let password = secret(store, "postgres", PASSWORD_FILE)?;
    let pwfile = store
        .directory("config")?
        .join("postgres")
        .join(format!("initdb-{}.pw", crate::core::rand::random_hex(8)?));
    write_private(&pwfile, &password)?;
    let status = Command::new(initdb)
        .args([
            "--encoding=UTF8",
            "--locale=C",
            "--auth-local=scram-sha-256",
            "--auth-host=scram-sha-256",
            "--username=postgres",
        ])
        .arg(format!("--pwfile={}", pwfile.display()))
        .arg("-D")
        .arg(data)
        .env_clear()
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    let _ = fs::remove_file(&pwfile);
    ensure!(status?.success(), "engine_init_failed");
    let conf = data.join("postgresql.conf");
    let mut text = fs::read_to_string(&conf)?;
    text.push_str(
        "\n# Stack: solo el usuario abre el socket local.\nunix_socket_permissions = 0700\n",
    );
    write_private(&conf, &text)?;
    Ok(())
}

fn running(config: &StackConfig) -> bool {
    let port = crate::web::services::engines::port(config, "postgres");
    std::net::TcpStream::connect_timeout(
        &([127, 0, 0, 1], port).into(),
        std::time::Duration::from_millis(500),
    )
    .is_ok()
}

/// Login roles that have no password: they stop getting in once the cluster asks for one.
fn roles_without_password(pg: &Postgres) -> Result<Vec<String>> {
    Ok(pg
        .run(
            "SELECT rolname FROM pg_authid WHERE rolcanlogin AND rolpassword IS NULL AND rolname <> 'postgres' ORDER BY 1;",
            "postgres",
        )?
        .lines()
        .map(str::to_string)
        .collect())
}

/// `postgresAuth`: the cluster's state and, for a `trust` one that is running, the roles that
/// would stop working.
pub fn describe(store: &Store, config: &StackConfig) -> Result<Value> {
    let state = state(store)?;
    let data = datadir(store, "postgres")?;
    let affected = if state == "trust" && running(config) {
        roles_without_password(&Postgres::new(store, config)?).unwrap_or_default()
    } else {
        vec![]
    };
    Ok(json!({
        "state": state,
        "running": running(config),
        "canUndo": state == "password" && data.join(TRUST_BACKUP).is_file(),
        "rolesWithoutPassword": affected,
    }))
}

/// «Exigir contraseña…» on a `trust` cluster (running): the superuser gets a password Stack
/// keeps, `pg_hba.conf` asks for one everywhere (the old file stays as `pg_hba.conf.stack-trust`)
/// and the server reloads it without restarting. Checked before returning: with the password it
/// gets in, without it it does not; otherwise the old file is put back.
pub fn require_password(store: &Store, config: &StackConfig) -> Result<Value> {
    ensure!(state(store)? == "trust", "postgres_not_trust");
    ensure!(running(config), "postgres_not_running");
    let data = datadir(store, "postgres")?;
    let hba = data.join("pg_hba.conf");
    let backup = data.join(TRUST_BACKUP);
    let original = fs::read_to_string(&hba)?;
    let password = secret(store, "postgres", PASSWORD_FILE)?;
    // Hex: nothing typed reaches SQL. Through stdin, never argv.
    let pg = Postgres::new(store, config)?;
    pg.run(
        &format!("ALTER ROLE postgres PASSWORD '{password}';"),
        "postgres",
    )?;
    write_private(&backup, &original)?;
    write_private(&hba, HBA_PASSWORD)?;
    pg.run("SELECT pg_reload_conf();", "postgres")?;
    let works = pg.run("SELECT 1;", "postgres").is_ok()
        && pg.without_password().run("SELECT 1;", "postgres").is_err();
    if !works {
        write_private(&hba, &original)?;
        let _ = pg.run("SELECT pg_reload_conf();", "postgres");
        let _ = fs::remove_file(&backup);
        anyhow::bail!("postgres_command_failed");
    }
    describe(store, config)
}

/// Undoes `require_password`: the `pg_hba.conf` the cluster had goes back and the server reloads
/// it. The superuser keeps its password (harmless with `trust`).
pub fn allow_trust(store: &Store, config: &StackConfig) -> Result<Value> {
    let data = datadir(store, "postgres")?;
    let backup = data.join(TRUST_BACKUP);
    ensure!(backup.is_file(), "postgres_no_backup");
    ensure!(running(config), "postgres_not_running");
    let original = fs::read_to_string(&backup)?;
    write_private(&data.join("pg_hba.conf"), &original)?;
    Postgres::new(store, config)?.run("SELECT pg_reload_conf();", "postgres")?;
    fs::remove_file(&backup)?;
    describe(store, config)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cluster(store: &Store, hba: &str) {
        let data = datadir(store, "postgres").unwrap();
        fs::create_dir_all(&data).unwrap();
        fs::write(data.join("PG_VERSION"), "16\n").unwrap();
        fs::write(data.join("pg_hba.conf"), hba).unwrap();
    }

    /// After an update, a `trust` cluster made by an earlier Stack starts exactly as before: no
    /// `initdb`, the same arguments, its `pg_hba.conf` untouched, and no password anywhere.
    #[test]
    fn an_existing_trust_cluster_is_left_as_it_was() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::new(temp.path().join("store")).unwrap();
        let hba =
            "local all all trust\nhost all all 127.0.0.1/32 trust\nhost all all ::1/128 trust\n";
        cluster(&store, hba);
        let data = datadir(&store, "postgres").unwrap();
        let mut config = StackConfig::default();
        config.engines.entry("postgres".into()).or_default().port = Some(55439);
        // No binaries at all: running initdb would fail the launch.
        let base = temp.path().join("no-postgres-here");
        let launch =
            crate::web::services::engines::launch(&store, &config, "postgres", &base).unwrap();
        let run = store.directory("run").unwrap();
        assert_eq!(launch.executable, base.join("bin/postgres"));
        assert_eq!(
            launch.args,
            [
                "-D".to_string(),
                data.to_string_lossy().into_owned(),
                "-p".into(),
                "55439".into(),
                "-h".into(),
                "127.0.0.1".into(),
                "-k".into(),
                run.to_string_lossy().into_owned(),
            ]
        );
        assert!(launch.environment.is_empty());
        assert_eq!(fs::read_to_string(data.join("pg_hba.conf")).unwrap(), hba);
        assert_eq!(state(&store).unwrap(), "trust");
        assert!(superuser_password(&store).is_none());
        assert!(
            !store
                .directory("config")
                .unwrap()
                .join("postgres")
                .join(PASSWORD_FILE)
                .exists()
        );
        assert!(!data.join(TRUST_BACKUP).exists());
    }

    #[test]
    fn states_are_read_from_pg_hba() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::new(temp.path().join("store")).unwrap();
        assert_eq!(state(&store).unwrap(), "none");
        cluster(
            &store,
            "# comment trust\nlocal all all trust\nhost all all 127.0.0.1/32 trust\n",
        );
        assert_eq!(state(&store).unwrap(), "trust");
        cluster(&store, HBA_PASSWORD);
        assert_eq!(state(&store).unwrap(), "password");
        cluster(
            &store,
            "host all all 127.0.0.1 255.255.255.255 trust\nlocal all all scram-sha-256\n",
        );
        assert_eq!(state(&store).unwrap(), "trust");
        cluster(&store, "local all all peer\n");
        assert_eq!(state(&store).unwrap(), "other");
        assert!(superuser_password(&store).is_none());
    }
}
