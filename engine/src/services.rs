//! Stack-level services: one php-fpm per PHP series in use and Caddy for the sites. Files are
//! generated from the model on every reload and never edited by hand.
use crate::{
    model::{Project, ProjectKind, StackConfig},
    runtimes,
    store::Store,
    tools,
};
use anyhow::{ensure, Result};
use std::{collections::BTreeSet, fs, io::Write, os::unix::fs::OpenOptionsExt, path::Path};

pub fn write_private(path: &Path, content: &str) -> Result<()> {
    let temporary = path.with_extension(format!("{}.tmp", std::process::id()));
    let _ = fs::remove_file(&temporary);
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temporary)?;
    file.write_all(content.as_bytes())?;
    file.sync_all()?;
    fs::rename(temporary, path)?;
    Ok(())
}

pub fn php_series(project: &Project, config: &StackConfig) -> Option<String> {
    matches!(project.kind, ProjectKind::Laravel | ProjectKind::Php).then(|| {
        project
            .runtime
            .get("php")
            .or_else(|| config.versions.get("php"))
            .cloned()
            .unwrap_or_else(|| "8.2".into())
    })
}

pub fn series_in_use(projects: &[Project], config: &StackConfig) -> BTreeSet<String> {
    projects
        .iter()
        .filter_map(|p| php_series(p, config))
        .collect()
}

pub fn fpm_socket(store: &Store, series: &str) -> Result<std::path::PathBuf> {
    Ok(store.directory("run")?.join(format!("php-{series}.sock")))
}

/// Writes php.ini and php-fpm.conf for a verified runtime; returns (fpm.conf, php.ini).
pub fn fpm_config(store: &Store, series: &str) -> Result<(std::path::PathBuf, std::path::PathBuf)> {
    let ini = runtimes::generate_ini(store, series)?;
    let socket = fpm_socket(store, series)?;
    let text = socket.to_string_lossy();
    ensure!(
        !text.chars().any(|c| c.is_control() || c == ';' || c == '"'),
        "invalid_fpm_path"
    );
    let conf = format!(
        "[global]\ndaemonize = no\nerror_log = /dev/stderr\nlog_level = notice\n\n\
         [butake]\nlisten = {text}\nlisten.mode = 0600\npm = ondemand\npm.max_children = 10\n\
         pm.process_idle_timeout = 30s\ncatch_workers_output = yes\ndecorate_workers_output = no\n"
    );
    let path = ini.parent().unwrap().join("php-fpm.conf");
    write_private(&path, &conf)?;
    Ok((path, ini))
}

fn quoted(value: &str) -> Result<String> {
    ensure!(
        !value
            .chars()
            .any(|c| c.is_control() || matches!(c, '"' | '\\' | '{' | '}' | '`')),
        "invalid_caddy_value"
    );
    Ok(format!("\"{value}\""))
}

/// Caddyfile for every PHP site. Sockets come from inherited descriptors: `fd/3` for HTTP and
/// `fd/4` for HTTPS, whether launchd or the daemon opened them.
pub fn caddyfile(
    store: &Store,
    projects: &[Project],
    config: &StackConfig,
    http3: bool,
) -> Result<String> {
    let data = store.directory("data")?.join("caddy");
    fs::create_dir_all(&data)?;
    let mut out = format!(
        "{{\n\tadmin off\n\tpersist_config off\n\tauto_https disable_redirects\n\tskip_install_trust\n\
         \tstorage file_system {}\n}}\n\n",
        quoted(&data.to_string_lossy())?
    );
    for project in projects {
        let Some(series) = php_series(project, config) else {
            continue;
        };
        let root = project.path.join(&project.docroot);
        let socket = fpm_socket(store, &series)?;
        let mut schemes = vec![("http", "fd/3")];
        if project.https {
            schemes.push(("https", "fd/4"));
        }
        for (scheme, bind) in schemes {
            let hosts: Vec<_> = project
                .domains
                .iter()
                .map(|d| format!("{scheme}://{d}"))
                .collect();
            out.push_str(&format!("{} {{\n", hosts.join(", ")));
            if !project.enabled {
                // Off sites answer at once instead of leaving the browser waiting.
                out.push_str(&format!("\tbind {bind}\n"));
                if scheme == "https" {
                    out.push_str("\ttls internal\n");
                }
                out.push_str("\theader Content-Type \"text/html; charset=utf-8\"\n\trespond \"<!doctype html><meta charset=utf-8><title>Sitio apagado</title><body style='font:16px -apple-system;display:grid;place-items:center;height:90vh;color:#555'><div><h2>Sitio apagado</h2><p>Enciéndelo en Butake Stack.</p></div>\" 503\n}\n\n");
                continue;
            }
            if scheme == "https" {
                // TLS 1.3 by default; HTTP/1.1 and HTTP/2 over TCP, HTTP/3 over QUIC.
                out.push_str(&format!("\tbind {bind} {{\n\t\tprotocols h1 h2\n\t}}\n"));
                if http3 {
                    out.push_str("\tbind fdgram/5 {\n\t\tprotocols h3\n\t}\n");
                }
                out.push_str("\ttls internal\n");
            } else {
                out.push_str(&format!("\tbind {bind} {{\n\t\tprotocols h1\n\t}}\n"));
            }
            out.push_str(&format!(
                "\troot * {}\n\tencode zstd gzip\n\tphp_fastcgi {}\n\tfile_server\n}}\n\n",
                quoted(&root.to_string_lossy())?,
                quoted(&format!("unix/{}", socket.to_string_lossy()))?
            ));
        }
    }
    Ok(out)
}

pub fn caddy_executable(store: &Store, config: &StackConfig) -> Option<std::path::PathBuf> {
    let wanted = config.versions.get("caddy").map(String::as_str).unwrap_or("");
    tools::resolve(store, "caddy", wanted).map(|dir| dir.join("caddy"))
}

/// Engine folder for the wanted version, if the engine is enabled and installed.
pub fn engine_dir(store: &Store, config: &StackConfig, name: &str) -> Option<std::path::PathBuf> {
    let engine = config.engines.get(name).filter(|e| e.enabled)?;
    tools::resolve(store, name, &engine.version)
}

fn clean_path(path: &Path) -> Result<String> {
    let text = path.to_string_lossy().into_owned();
    ensure!(
        !text.chars().any(|c| c.is_control() || c == '"' || c == '#' || c == ';'),
        "invalid_engine_path"
    );
    Ok(text)
}

/// MySQL datadir (one per stack; upgraded in place when the binary version changes).
pub fn mysql_datadir(store: &Store) -> Result<std::path::PathBuf> {
    crate::engines::datadir(store, "mysql")
}

/// Writes my.cnf for MySQL or MariaDB and initializes an empty datadir the first time.
pub fn mysql_config(store: &Store, _config: &StackConfig, base: &Path, id: &str, port: u16) -> Result<std::path::PathBuf> {
    let datadir = crate::engines::datadir(store, id)?;
    let run = store.directory("run")?;
    let directory = store.directory("config")?.join(id);
    fs::create_dir_all(&directory)?;
    let socket = run.join(format!("{id}.sock"));
    let extra = if id == "mysql" { "mysqlx=OFF\ncollation-server=utf8mb4_0900_ai_ci\n" } else { "collation-server=utf8mb4_unicode_ci\n" };
    let cnf = format!(
        "[mysqld]\nbasedir={}\ndatadir={}\nport={port}\nbind-address=127.0.0.1\n\
         socket={}\npid-file={}\nskip-log-bin\ninnodb_buffer_pool_size=512M\n\
         character-set-server=utf8mb4\n{extra}\n[client]\nport={port}\nsocket={}\n",
        clean_path(base)?,
        clean_path(&datadir)?,
        clean_path(&socket)?,
        clean_path(&run.join(format!("{id}.pid")))?,
        clean_path(&socket)?,
    );
    let path = directory.join("my.cnf");
    write_private(&path, &cnf)?;
    if !datadir.exists() {
        let mut command = if id == "mysql" {
            let mut c = std::process::Command::new(base.join("bin/mysqld"));
            c.arg(format!("--defaults-file={}", path.display())).arg("--initialize-insecure");
            c
        } else {
            let mut c = std::process::Command::new(base.join("scripts/mariadb-install-db"));
            c.arg(format!("--defaults-file={}", path.display())).arg(format!("--basedir={}", base.display())).arg("--auth-root-authentication-method=normal");
            c
        };
        let status = command.env_clear().stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).status()?;
        ensure!(status.success(), "mysql_init_failed");
    }
    Ok(path)
}

/// redis.conf for Redis or Valkey (same format).
pub fn redis_config(store: &Store, id: &str, port: u16) -> Result<std::path::PathBuf> {
    let dir = crate::engines::datadir(store, id)?;
    fs::create_dir_all(&dir)?;
    let directory = store.directory("config")?.join(id);
    fs::create_dir_all(&directory)?;
    let conf = format!(
        "bind 127.0.0.1\nport {port}\nprotected-mode yes\ndaemonize no\ndir \"{}\"\n\
         dbfilename dump.rdb\nsave 3600 1 300 100 60 10000\nappendonly no\nlogfile \"\"\n",
        clean_path(&dir)?
    );
    let path = directory.join(if id == "redis" { "redis.conf" } else { "valkey.conf" });
    write_private(&path, &conf)?;
    Ok(path)
}

/// Imports existing data into an engine that has none yet. MySQL takes a datadir (copied with
/// APFS clones, so it is instant and the source is never modified); Redis takes an RDB file.
pub fn import_engine_data(store: &Store, engine: &str, source: &Path) -> Result<()> {
    let source = source.canonicalize()?;
    match engine {
        "mysql" => {
            ensure!(
                source.join("ibdata1").is_file() && source.join("mysql.ibd").is_file(),
                "not_a_mysql_datadir"
            );
            ensure!(!source.join("mysqld.pid").exists() && fs::read_dir(&source)?.flatten().all(|e| {
                !e.file_name().to_string_lossy().ends_with(".pid")
            }), "source_engine_running");
            let target = mysql_datadir(store)?;
            ensure!(!target.exists(), "engine_has_data");
            let status = std::process::Command::new("/bin/cp")
                .args(["-cRp"])
                .arg(&source)
                .arg(&target)
                .env_clear()
                .status()?;
            ensure!(status.success(), "import_failed");
            // Runtime leftovers of the previous server (sockets, logs, launch files) are not data.
            for item in fs::read_dir(&target)?.flatten() {
                let name = item.file_name().to_string_lossy().into_owned();
                if [".pid", ".sock", ".lock", ".err", ".plist"].iter().any(|s| name.ends_with(s)) {
                    let _ = fs::remove_file(item.path());
                }
            }
            Ok(())
        }
        "redis" => {
            ensure!(source.is_file() && source.extension().is_some_and(|e| e == "rdb"), "not_an_rdb");
            let dir = store.directory("data")?.join("redis");
            fs::create_dir_all(&dir)?;
            let target = dir.join("dump.rdb");
            ensure!(!target.exists(), "engine_has_data");
            fs::copy(&source, &target)?;
            Ok(())
        }
        _ => anyhow::bail!("unknown_engine"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn caddyfile_quotes_paths_and_rejects_injection() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::new(temp.path().join("store")).unwrap();
        let site = temp.path().join("My Site");
        fs::create_dir_all(site.join("public")).unwrap();
        let mut project: Project = serde_json::from_value(serde_json::json!({
            "id":"demo","name":"Demo","path":site,"domains":["demo.test"],"https":true,
            "kind":"laravel","runtime":{"php":"8.2"},"docroot":"public","services":[],
            "databases":[],"processes":[],"enabled":true})).unwrap();
        let config = StackConfig::default();
        project.validate(&config).unwrap();
        let file = caddyfile(&store, &[project.clone()], &config, true).unwrap();
        assert!(file.contains("http://demo.test {\n\tbind fd/3 {\n\t\tprotocols h1\n"));
        assert!(file.contains("https://demo.test {\n\tbind fd/4 {\n\t\tprotocols h1 h2\n"));
        assert!(file.contains("\tbind fdgram/5 {\n\t\tprotocols h3\n\t}\n\ttls internal"));
        assert!(file.contains("My Site/public\""));
        assert!(file.contains("php_fastcgi \"unix/"));
        let evil = temp.path().join("x}\nimport");
        fs::create_dir_all(&evil).unwrap();
        project.path = evil;
        project.docroot = ".".into();
        assert!(caddyfile(&store, &[project], &config, true).is_err());
    }
}
