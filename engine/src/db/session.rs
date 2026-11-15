//! Persistent sessions: one `mysql`, `psql` (or `sqlite3`, for transactions) kept open per
//! connection, database and password, behind a private Unix socket in `run/`.
//!
//! Read sessions: browsing (databases, tables, rows, structure, users, processes) and read-only
//! queries reuse them, so a remote server is not asked for a new TCP connection, TLS handshake and
//! login on every click. They open with the connection's mode (a read-only connection's session
//! is read-only on the server too) and end after a few idle minutes, when their client exits or on
//! `dbDisconnect`. Writes never go through them: they run one-shot and stop at the first error.
//!
//! Transaction sessions: the manual mode of the SQL editor. `BEGIN` opens one; each request runs
//! inside the same transaction, statement by statement, stopping at the first error; `COMMIT` or
//! `ROLLBACK` ends it. If the session dies (idle, quit, crash) the server rolls the transaction
//! back, and the next request says so instead of running outside it.
use crate::core::fsutil::write_private;
use crate::core::rand::random_u64;
use crate::{
    core::store::Store,
    db::client::{self, RunOutput, Target, MAX_ROWS},
    db::sql::{self, Dialect, ResultSet},
};
use anyhow::{bail, ensure, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    io::{BufRead, BufReader, Read, Write},
    os::unix::net::{UnixListener, UnixStream},
    path::PathBuf,
    process::{Child, ChildStdin, Stdio},
    sync::mpsc,
    time::{Duration, Instant},
};

/// A read session closes after this long without requests.
const IDLE: Duration = Duration::from_secs(10 * 60);
/// A transaction left alone this long is rolled back (its session ends).
const IDLE_TRANSACTION: Duration = Duration::from_secs(30 * 60);
/// A request that takes longer ends the session (the next one starts a fresh client).
const REQUEST_TIMEOUT: Duration = Duration::from_secs(120);
const NULL_MARK: &str = "\u{1}NULL\u{1}";
const RESULT_MARK: &str = "\u{2}BUTAKE-END\u{2}";

#[derive(Serialize, Deserialize)]
struct Spec {
    connection: String,
    password: Option<String>,
    database: String,
    /// A transaction session (manual mode) instead of a read session.
    #[serde(default)]
    write: bool,
}

#[derive(Serialize, Deserialize)]
struct Request {
    statements: Vec<String>,
    max_rows: usize,
}

/// Socket of the session for a target and database: the name hashes everything that makes two
/// sessions different (the read-only mode and the password too, so a change starts a new one).
fn socket(target: &Target, database: &str, write: bool) -> Result<PathBuf> {
    let c = &target.connection;
    let mut hash = Sha256::new();
    hash.update(serde_json::to_string(&(
        &c.id,
        &c.kind,
        &c.host,
        c.port,
        &c.user,
        &c.tls,
        &c.ssh,
        &c.path,
        c.read_only,
        &target.host,
        target.port,
        database,
    ))?);
    hash.update(target.password.as_deref().unwrap_or(""));
    // Short on purpose: a Unix socket path must fit in 104 bytes. The connection id goes in a
    // companion `.conn` file.
    let key: String = hash
        .finalize()
        .iter()
        .take(8)
        .map(|b| format!("{b:02x}"))
        .collect();
    Ok(target
        .run_dir()
        .join(format!("{}-{key}.sock", if write { "dbt" } else { "dbs" })))
}

/// Runs read-only statements in the connection's persistent session, starting it if needed.
/// Any failure of the session itself falls back to a one-shot client.
pub fn read(
    target: &Target,
    database: &str,
    statements: &[String],
    max_rows: usize,
) -> Result<RunOutput> {
    if target.dialect() == Some(Dialect::Sqlite)
        || std::env::var_os("BUTAKE_STACK_NO_SESSIONS").is_some()
    {
        return client::run_sql(target, database, statements, max_rows);
    }
    let path = socket(target, database, false)?;
    if let Ok(output) = ask(&path, statements, max_rows) {
        return Ok(output);
    }
    // Not running yet (or gone): start it and ask once more, else run one-shot.
    if UnixStream::connect(&path).is_err() && start(target, database, &path, false).is_ok() {
        if let Ok(output) = ask(&path, statements, max_rows) {
            return Ok(output);
        }
    }
    client::run_sql(target, database, statements, max_rows)
}

fn ask(path: &PathBuf, statements: &[String], max_rows: usize) -> Result<RunOutput> {
    let mut stream = UnixStream::connect(path)?;
    stream.set_read_timeout(Some(
        REQUEST_TIMEOUT * statements.len().max(1) as u32 + Duration::from_secs(5),
    ))?;
    let mut line = serde_json::to_string(&Request {
        statements: statements.to_vec(),
        max_rows,
    })?;
    line.push('\n');
    stream.write_all(line.as_bytes())?;
    let mut answer = String::new();
    BufReader::new(stream).read_line(&mut answer)?;
    let value: serde_json::Value = serde_json::from_str(&answer)?;
    ensure!(value["ok"] == true, "session_failed");
    Ok(serde_json::from_value(value["value"].clone())?)
}

/// Whether a manual transaction is open for this connection and database.
pub fn transaction_open(target: &Target, database: &str) -> bool {
    socket(target, database, true).is_ok_and(|p| UnixStream::connect(p).is_ok())
}

fn begin_statement(dialect: Dialect) -> &'static str {
    if dialect == Dialect::MySql {
        "START TRANSACTION"
    } else {
        "BEGIN"
    }
}

/// Opens a manual transaction (a session of its own that starts with BEGIN).
pub fn begin(target: &Target, database: &str) -> Result<()> {
    ensure!(!target.connection.read_only, "read_only_connection");
    let dialect = target
        .dialect()
        .ok_or_else(|| anyhow::anyhow!("unsupported_engine"))?;
    let path = socket(target, database, true)?;
    ensure!(UnixStream::connect(&path).is_err(), "transaction_open");
    start(target, database, &path, true)?;
    let out = ask(&path, &[begin_statement(dialect).to_string()], 1)?;
    if let Some(error) = out.error {
        quit(&path);
        return Err(client::db_error(&error));
    }
    Ok(())
}

/// Runs statements inside the open transaction; never outside it.
pub fn in_transaction(
    target: &Target,
    database: &str,
    statements: &[String],
    max_rows: usize,
) -> Result<RunOutput> {
    let path = socket(target, database, true)?;
    ensure!(UnixStream::connect(&path).is_ok(), "transaction_lost");
    ask(&path, statements, max_rows).map_err(|_| anyhow::anyhow!("transaction_lost"))
}

/// COMMIT or ROLLBACK, then the session ends.
pub fn finish(target: &Target, database: &str, commit: bool) -> Result<RunOutput> {
    let path = socket(target, database, true)?;
    ensure!(UnixStream::connect(&path).is_ok(), "transaction_lost");
    let out = ask(
        &path,
        &[if commit { "COMMIT" } else { "ROLLBACK" }.to_string()],
        1,
    );
    quit(&path);
    let out = out.map_err(|_| anyhow::anyhow!("transaction_lost"))?;
    if let Some(error) = &out.error {
        return Err(client::db_error(error));
    }
    Ok(out)
}

fn quit(path: &PathBuf) {
    if let Ok(mut stream) = UnixStream::connect(path) {
        let _ = stream.write_all(b"{\"quit\":true}\n");
    }
    let _ = std::fs::remove_file(path);
    let _ = std::fs::remove_file(path.with_extension("conn"));
}

/// Starts `butake-stack dbsession` in the background with the spec on stdin and waits for its socket.
fn start(target: &Target, database: &str, path: &PathBuf, write: bool) -> Result<()> {
    let spec = Spec {
        connection: target.connection.id.clone(),
        password: target.password.clone(),
        database: database.into(),
        write,
    };
    let mut command = std::process::Command::new(std::env::current_exe()?);
    command
        .arg("dbsession")
        .stdin(Stdio::piped())
        .stdout(Stdio::null());
    // Diagnostics only on demand, to a private log next to the socket.
    if std::env::var_os("BUTAKE_STACK_DEBUG").is_some() {
        command.stderr(std::fs::File::create(path.with_extension("log"))?);
    } else {
        command.stderr(Stdio::null());
    }
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    let mut child = command.spawn()?;
    child
        .stdin
        .take()
        .ok_or_else(|| anyhow::anyhow!("session_failed"))?
        .write_all(serde_json::to_string(&spec)?.as_bytes())?;
    let started = Instant::now();
    while started.elapsed() < Duration::from_secs(25) {
        if UnixStream::connect(path).is_ok() {
            // Reaped by whoever outlives it; the child keeps running on its own.
            std::mem::forget(child);
            return Ok(());
        }
        if child.try_wait()?.is_some() {
            bail!("session_failed");
        }
        std::thread::sleep(Duration::from_millis(40));
    }
    let _ = child.kill();
    bail!("session_failed")
}

/// Sessions as (socket, connection id).
fn sessions(store: &Store) -> Vec<(PathBuf, String)> {
    let Ok(run) = store.directory("run") else {
        return vec![];
    };
    std::fs::read_dir(run)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| {
            let path = e.path();
            let name = path.file_name()?.to_string_lossy().into_owned();
            ((name.starts_with("dbs-") || name.starts_with("dbt-")) && name.ends_with(".sock"))
                .then_some(())?;
            let id = std::fs::read_to_string(path.with_extension("conn")).ok()?;
            Some((path, id.trim().to_string()))
        })
        .collect()
}

/// Closes every session of a connection (on disconnect; an open transaction is rolled back).
pub fn close(store: &Store, connection: &str) {
    for (path, id) in sessions(store) {
        if id == connection {
            quit(&path);
        }
    }
}

/// Every session's connection id (for "disconnect all").
pub fn connections(store: &Store) -> Vec<String> {
    sessions(store).into_iter().map(|(_, id)| id).collect()
}

// ---------------------------------------------------------------------------------------------
// The session process
// ---------------------------------------------------------------------------------------------

struct Client {
    child: Child,
    stdin: ChildStdin,
    out: mpsc::Receiver<Vec<u8>>,
    err: mpsc::Receiver<Vec<u8>>,
    dialect: Dialect,
}

fn reader(mut pipe: impl Read + Send + 'static) -> mpsc::Receiver<Vec<u8>> {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let mut buffer = vec![0u8; 64 * 1024];
        loop {
            match pipe.read(&mut buffer) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if tx.send(buffer[..n].to_vec()).is_err() {
                        break;
                    }
                }
            }
        }
    });
    rx
}

fn open(target: &Target, database: &str, write: bool) -> Result<(Client, Option<client::Secret>)> {
    let dialect = target
        .dialect()
        .ok_or_else(|| anyhow::anyhow!("invalid_connection"))?;
    let (mut command, secret) = match dialect {
        Dialect::MySql => {
            let secret = target.mysql_options()?;
            let mut c = target.command("mysql", database, Some(&secret))?;
            // --force: an error in one statement must not end the session (a transaction runs
            // statement by statement and stops itself at the first error).
            c.args([
                "--xml",
                "--binary-as-hex",
                "--quick",
                "--batch",
                "--force",
                "--unbuffered",
            ]);
            (c, Some(secret))
        }
        Dialect::Postgres => {
            let mut c = target.command("psql", database, None)?;
            c.args([
                "-X",
                "-q",
                "--csv",
                "-v",
                "ON_ERROR_STOP=0",
                "-v",
                "VERBOSITY=verbose",
                "-P",
                &format!("null={NULL_MARK}"),
                "-f",
                "-",
            ]);
            (c, None)
        }
        Dialect::Sqlite if write => (target.sqlite_session()?, None),
        Dialect::Sqlite => bail!("unsupported_engine"),
    };
    let mut child = command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| anyhow::anyhow!("session_failed"))?;
    if dialect == Dialect::Sqlite {
        stdin.write_all(format!(".headers on\n.mode csv\n.nullvalue {NULL_MARK}\n").as_bytes())?;
    }
    let out = reader(
        child
            .stdout
            .take()
            .ok_or_else(|| anyhow::anyhow!("session_failed"))?,
    );
    let err = reader(
        child
            .stderr
            .take()
            .ok_or_else(|| anyhow::anyhow!("session_failed"))?,
    );
    Ok((
        Client {
            child,
            stdin,
            out,
            err,
            dialect,
        },
        secret,
    ))
}

impl Client {
    /// Sends one request and reads until its end mark.
    fn run(&mut self, database: &str, request: &Request) -> Result<RunOutput> {
        let started = Instant::now();
        let nonce = format!(
            "{:x}",
            started.elapsed().as_nanos()
                ^ (std::process::id() as u128) << 20
                ^ random_u64()? as u128
        );
        let mut script = String::new();
        match self.dialect {
            Dialect::MySql => {
                // A previous query may have switched databases: every request starts in its own.
                if !database.is_empty() {
                    script.push_str(&format!("USE {};\n", sql::ident(Dialect::MySql, database)));
                }
                for (i, statement) in request.statements.iter().enumerate() {
                    script.push_str(statement);
                    script.push_str(&format!(
                        "\n;\nSELECT ROW_COUNT() AS __butake_affected, {i} AS __butake_marker;\n"
                    ));
                }
                script.push_str(&format!("SELECT '{nonce}' AS __butake_end;\n"));
            }
            Dialect::Postgres => {
                for statement in &request.statements {
                    script.push_str(statement);
                    script.push_str(&format!("\n;\n\\echo {RESULT_MARK} :ROW_COUNT\n"));
                }
                script.push_str(&format!("\\echo {RESULT_MARK}END {nonce}\n"));
            }
            Dialect::Sqlite => {
                for statement in &request.statements {
                    script.push_str(statement);
                    script.push_str(&format!("\n;\n.print {RESULT_MARK} -1\n"));
                }
                script.push_str(&format!(".print {RESULT_MARK}END {nonce}\n"));
            }
        }
        // Drop anything left over from an earlier request.
        while self.err.try_recv().is_ok() {}
        self.stdin.write_all(script.as_bytes())?;
        self.stdin.flush()?;
        let end_mysql = format!("<field name=\"__butake_end\">{nonce}</field>");
        let end_marked = format!("{RESULT_MARK}END {nonce}\n");
        let mut text = Vec::new();
        loop {
            let remaining = REQUEST_TIMEOUT
                .checked_sub(started.elapsed())
                .ok_or_else(|| anyhow::anyhow!("session_timeout"))?;
            let chunk = self
                .out
                .recv_timeout(remaining)
                .map_err(|_| anyhow::anyhow!("session_failed"))?;
            text.extend_from_slice(&chunk);
            ensure!(text.len() < 96 * 1024 * 1024, "result_too_large");
            let view =
                String::from_utf8_lossy(&text[text.len().saturating_sub(chunk.len() + 200)..])
                    .into_owned();
            let done = match self.dialect {
                Dialect::MySql => {
                    view.contains(&end_mysql)
                        && String::from_utf8_lossy(&text)
                            .trim_end()
                            .ends_with("</resultset>")
                }
                _ => view.contains(&end_marked),
            };
            if done {
                break;
            }
        }
        // Errors were written before the end mark; give the stderr thread a moment to pass them on.
        std::thread::sleep(Duration::from_millis(3));
        let mut errors = Vec::new();
        while let Ok(chunk) = self.err.try_recv() {
            errors.extend_from_slice(&chunk);
        }
        let stdout = String::from_utf8_lossy(&text).into_owned();
        let mut output = RunOutput::default();
        match self.dialect {
            Dialect::MySql => {
                let mut pending: Option<ResultSet> = None;
                for set in sql::parse_mysql_xml(&stdout, request.max_rows) {
                    if set.columns.first().map(String::as_str) == Some("__butake_end") {
                        continue;
                    }
                    if set.columns.len() == 2 && set.columns[1] == "__butake_marker" {
                        let index: usize = set
                            .rows
                            .first()
                            .and_then(|r| r[1].as_deref())
                            .and_then(|v| v.parse().ok())
                            .unwrap_or(output.results.len());
                        let affected = set
                            .rows
                            .first()
                            .and_then(|r| r[0].as_deref())
                            .and_then(|v| v.parse::<i64>().ok());
                        let mut result = pending.take().unwrap_or_default();
                        result.statement =
                            request.statements.get(index).cloned().unwrap_or_default();
                        result.affected = if result.columns.is_empty() && result.rows.is_empty() {
                            affected.filter(|a| *a >= 0)
                        } else {
                            Some(result.rows.len() as i64)
                        };
                        output.results.push(result);
                    } else if pending.is_none() {
                        pending = Some(set);
                    }
                }
            }
            _ => {
                let body = stdout.split(&end_marked).next().unwrap_or("");
                output.results = client::split_marked(body, &request.statements, request.max_rows);
            }
        }
        output.error = client::clean_error(&String::from_utf8_lossy(&errors));
        output.duration_ms = started.elapsed().as_millis();
        Ok(output)
    }

    /// A transaction's request: one statement at a time, stopping at the first error (the
    /// statements after it never run; the user decides between COMMIT and ROLLBACK).
    fn run_each(&mut self, database: &str, request: &Request) -> Result<RunOutput> {
        let started = Instant::now();
        let mut output = RunOutput::default();
        for statement in &request.statements {
            let one = self.run(
                database,
                &Request {
                    statements: vec![statement.clone()],
                    max_rows: request.max_rows,
                },
            )?;
            output.results.extend(one.results);
            if one.error.is_some() {
                output.error = one.error;
                break;
            }
        }
        output.duration_ms = started.elapsed().as_millis();
        Ok(output)
    }
}

/// `butake-stack dbsession`: serves one connection's reads (or its open transaction) until it is
/// idle, its client exits or someone asks it to quit.
pub fn serve() -> Result<()> {
    let mut input = String::new();
    std::io::stdin()
        .take(64 * 1024)
        .read_to_string(&mut input)?;
    let spec: Spec = serde_json::from_str(&input)?;
    let store = Store::from_environment()?;
    let connection = client::find(&store, &spec.connection)?;
    ensure!(
        !(spec.write && connection.read_only),
        "read_only_connection"
    );
    let target = client::target(&store, connection, spec.password.clone())?;
    let path = socket(&target, &spec.database, spec.write)?;
    let (mut client, secret) = open(&target, &spec.database, spec.write)?;
    // The first round trip proves the login works before anyone is told the session exists.
    let probe = client.run(
        &spec.database,
        &Request {
            statements: vec!["SELECT 1".into()],
            max_rows: 1,
        },
    )?;
    drop(secret);
    ensure!(
        probe.results.len() == 1 && probe.results[0].rows.len() == 1,
        "session_failed"
    );
    let _ = std::fs::remove_file(&path);
    let listener = UnixListener::bind(&path)?;
    write_private(&path.with_extension("conn"), &spec.connection)?;
    std::fs::set_permissions(&path, std::os::unix::fs::PermissionsExt::from_mode(0o600))?;
    listener.set_nonblocking(true)?;
    let idle = if spec.write { IDLE_TRANSACTION } else { IDLE };
    let mut last = Instant::now();
    let result = loop {
        if last.elapsed() > idle
            || client.child.try_wait().ok().flatten().is_some()
            || !path.exists()
        {
            if std::env::var_os("BUTAKE_STACK_DEBUG").is_some() {
                eprintln!(
                    "session end: idle={} child={:?} path={}",
                    last.elapsed() > idle,
                    client.child.try_wait().ok().flatten(),
                    path.exists()
                );
            }
            break Ok(());
        }
        let stream = match listener.accept() {
            Ok((stream, _)) => stream,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(25));
                continue;
            }
            Err(e) => break Err(e.into()),
        };
        last = Instant::now();
        // A peer that already left (a liveness probe) makes these fail on macOS: skip it.
        if stream.set_nonblocking(false).is_err()
            || stream
                .set_read_timeout(Some(Duration::from_secs(10)))
                .is_err()
        {
            continue;
        }
        let mut line = String::new();
        let Ok(clone) = stream.try_clone() else {
            continue;
        };
        let mut reader = BufReader::new(clone);
        if reader.read_line(&mut line).is_err() {
            continue;
        }
        let value: serde_json::Value = serde_json::from_str(&line).unwrap_or_default();
        if value["quit"] == true {
            break Ok(());
        }
        let Ok(request) = serde_json::from_value::<Request>(value) else {
            continue;
        };
        let max_rows = request.max_rows.clamp(1, 100_000);
        let request = Request {
            max_rows,
            ..request
        };
        let answer = if spec.write {
            client.run_each(&spec.database, &request)
        } else {
            client.run(&spec.database, &request)
        };
        let answer = match answer {
            Ok(output) => serde_json::json!({"ok": true, "value": output}),
            Err(_) => {
                // The client is in an unknown state: answer with a failure and end the session.
                let _ = (&stream).write_all(b"{\"ok\":false}\n");
                break Ok(());
            }
        };
        let mut writer = &stream;
        let _ = writer.write_all(format!("{answer}\n").as_bytes());
        last = Instant::now();
    };
    let _ = std::fs::remove_file(&path);
    let _ = std::fs::remove_file(path.with_extension("conn"));
    let _ = std::fs::remove_file(path.with_extension("log"));
    // Killing the client ends its server session: an open transaction is rolled back.
    let _ = client.child.kill();
    let _ = MAX_ROWS;
    result
}

#[cfg(test)]
mod tests {
    #[test]
    fn socket_paths_fit_in_sun_path_even_in_the_real_store() {
        // The old folder (still used until its data is moved) is the longer of the two names.
        let home = std::path::Path::new("/Users/un-usuario-largo");
        for root in [
            crate::core::store::Store::old_data_folder(home),
            crate::core::store::Store::data_folder(home),
        ] {
            let longest = root.join("run/dbs-0123456789abcdef.sock");
            assert!(longest.as_os_str().len() < 104);
        }
    }
}
