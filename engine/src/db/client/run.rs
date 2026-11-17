//! Running the engines' clients: where and how to reach a server for one request, SQL and its results, Redis commands and the console's read-only guard.

use super::*;

/// Where and how to reach a server for one request.
pub struct Target {
    pub connection: Connection,
    pub host: String,
    pub port: u16,
    pub password: Option<String>,
    pub bin: PathBuf,
    run: PathBuf,
    /// Reached through an SSH tunnel: `host` is the tunnel's local end, not the server's name.
    tunneled: bool,
}

/// Client folder: the stack's own runtime of that engine (any installed version will do for a
/// remote server). The engine does not need to be running.
pub(super) fn client_dir(store: &Store, kind: &str) -> Result<PathBuf> {
    let config = store.config()?;
    let candidates: &[&str] = match kind {
        "mysql" => &["mysql", "mariadb"],
        "mariadb" => &["mariadb", "mysql"],
        "redis" => &["redis", "valkey"],
        "valkey" => &["valkey", "redis"],
        "postgres" => &["postgres"],
        _ => &[],
    };
    for tool in candidates {
        let wanted = config
            .engines
            .get(*tool)
            .map(|e| e.version.clone())
            .unwrap_or_default();
        if let Some(dir) =
            catalog::resolve(store, tool, &wanted).or_else(|| catalog::resolve(store, tool, ""))
        {
            return Ok(dir.join("bin"));
        }
    }
    bail!("client_not_installed")
}

pub fn target(store: &Store, connection: Connection, password: Option<String>) -> Result<Target> {
    let password = password.filter(|p| !p.is_empty()).or_else(|| {
        // Stack's own PostgreSQL: the superuser's password, when Stack keeps one.
        (connection.builtin && connection.stack_password)
            .then(|| crate::web::services::postgres_auth::superuser_password(store))
            .flatten()
    });
    if let Some(p) = &password {
        ensure!(
            p.len() <= 512 && !p.contains('\n') && !p.contains('\r') && !p.contains('\0'),
            "invalid_password"
        );
    }
    let bin = if connection.kind == "sqlite" {
        PathBuf::from("/usr/bin")
    } else {
        client_dir(store, &connection.kind)?
    };
    let (host, port, tunneled) = if connection.ssh.is_some() {
        ("127.0.0.1".to_string(), tunnel(store, &connection)?, true)
    } else {
        (connection.host.clone(), connection.port, false)
    };
    Ok(Target {
        connection,
        host,
        port,
        password,
        bin,
        run: store.directory("run")?,
        tunneled,
    })
}

/// A file of secrets for one client run (0600, removed when dropped).
pub struct Secret(PathBuf);
impl Secret {
    /// Leaves the file in place (the terminal script removes it once the client has read it).
    pub fn keep(self) -> PathBuf {
        let path = self.0.clone();
        std::mem::forget(self);
        path
    }
}
impl Drop for Secret {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

impl Target {
    /// A target whose clients are the programs in `bin` (local doubles) and whose secrets go to `run`.
    #[cfg(test)]
    pub(crate) fn for_tests(connection: Connection, bin: PathBuf, run: PathBuf) -> Self {
        Self {
            host: connection.host.clone(),
            port: connection.port,
            connection,
            password: Some("centinela-clave-9f3".into()),
            bin,
            run,
            tunneled: false,
        }
    }

    pub fn run_dir(&self) -> &Path {
        &self.run
    }

    pub fn dialect(&self) -> Option<Dialect> {
        self.connection.dialect()
    }

    /// MySQL options file: only this file is read (never ~/.my.cnf), with the password in it.
    pub fn mysql_options(&self) -> Result<Secret> {
        let path = self.run.join(format!("client-{}.cnf", random_hex(8)?));
        let mut text = String::from("[client]\n");
        if let Some(p) = &self.password {
            text.push_str(&format!(
                "password=\"{}\"\n",
                p.replace('\\', "\\\\").replace('"', "\\\"")
            ));
        }
        write_private(&path, &text)?;
        Ok(Secret(path))
    }

    /// `sqlite3` for a long-lived session: without -bail, so an error does not end it.
    pub fn sqlite_session(&self) -> Result<Command> {
        let c = &self.connection;
        let mut command = Command::new(self.bin.join("sqlite3"));
        command
            .env_clear()
            .env("LANG", "en_US.UTF-8")
            .stdin(Stdio::null())
            .arg("-batch");
        if c.read_only {
            command.arg("-readonly");
        }
        command.arg(
            c.path
                .as_ref()
                .ok_or_else(|| anyhow::anyhow!("invalid_connection"))?,
        );
        Ok(command)
    }

    /// The client command for a database (or the connection's default), without a shell.
    pub fn command(&self, tool: &str, database: &str, secret: Option<&Secret>) -> Result<Command> {
        ensure!(
            database.len() <= 64
                && !database.chars().any(char::is_control)
                && !database.starts_with('-'),
            "invalid_database_name"
        );
        let database = if database.is_empty() {
            self.connection.database.as_str()
        } else {
            database
        };
        let mut command = Command::new(self.bin.join(tool));
        command
            .env_clear()
            .env("LANG", "en_US.UTF-8")
            .stdin(Stdio::null());
        let c = &self.connection;
        match c.kind.as_str() {
            "mysql" | "mariadb" => {
                let secret = secret.ok_or_else(|| anyhow::anyhow!("invalid_request"))?;
                command.arg(format!("--defaults-file={}", secret.0.display()));
                command.args([
                    "--protocol=TCP",
                    "-h",
                    &self.host,
                    "-P",
                    &self.port.to_string(),
                    "-u",
                    &c.user,
                ]);
                if tool != "mysqldump" {
                    command.arg("--connect-timeout=10");
                }
                // Through a tunnel the client reaches 127.0.0.1, which never matches the server's
                // certificate, and the MySQL client cannot be told the real name: it verifies the
                // certificate's authority (the tunnel already verified the host by its SSH key).
                let mode = match c.tls.as_str() {
                    "off" => "DISABLED",
                    "require" => "REQUIRED",
                    "verify" if self.tunneled => "VERIFY_CA",
                    "verify" => "VERIFY_IDENTITY",
                    _ => "PREFERRED",
                };
                command.arg(format!("--ssl-mode={mode}"));
                if c.tls == "verify" {
                    command.arg("--ssl-ca=/etc/ssl/cert.pem");
                }
                if c.tls == "off" && c.kind == "mysql" {
                    // Without TLS, caching_sha2_password needs the server's RSA key to send the password.
                    command.arg("--get-server-public-key");
                }
                if c.read_only && tool == "mysql" {
                    // Every transaction of the session (autocommit statements too) is read-only.
                    command.arg("--init-command=SET SESSION TRANSACTION READ ONLY");
                }
                if tool == "mysql" {
                    command.arg("--default-character-set=utf8mb4");
                    if !database.is_empty() {
                        command.arg(format!("--database={database}"));
                    }
                }
            }
            "postgres" => {
                if self.tunneled {
                    // libpq connects to hostaddr (the tunnel) and checks the certificate against
                    // host (the server's real name), so verify-full works through SSH.
                    command.args(["-h", &c.host]).env("PGHOSTADDR", &self.host);
                } else {
                    command.args(["-h", &self.host]);
                }
                command.args(["-p", &self.port.to_string(), "-U", &c.user]);
                if c.read_only {
                    // The server refuses writes in every transaction of the session.
                    command.env("PGOPTIONS", "-c default_transaction_read_only=on");
                }
                if tool == "psql" || tool == "pg_dump" {
                    // libpq reads `host=… dbname=…` and `postgres://…` after -d as a whole
                    // connection: a database name must never be able to change the host.
                    ensure!(
                        !database.contains(['=', '\\']) && !database.contains("://"),
                        "invalid_database_name"
                    );
                    command.arg("-d").arg(if database.is_empty() {
                        "postgres"
                    } else {
                        database
                    });
                }
                command
                    .env("PGPASSFILE", "/dev/null")
                    .env("PGCONNECT_TIMEOUT", "10")
                    .env("PGAPPNAME", "Stack");
                let mode = match c.tls.as_str() {
                    "off" => "disable",
                    "require" => "require",
                    "verify" => "verify-full",
                    _ => "prefer",
                };
                command.env("PGSSLMODE", mode);
                if c.tls == "verify" {
                    command.env("PGSSLROOTCERT", "system");
                }
                if let Some(p) = &self.password {
                    command.env("PGPASSWORD", p);
                }
            }
            "redis" | "valkey" => {
                command.args(["-h", &self.host, "-p", &self.port.to_string()]);
                if !c.user.is_empty() {
                    command.args(["--user", &c.user]);
                }
                if matches!(c.tls.as_str(), "require" | "verify") {
                    command.arg("--tls");
                }
                if let Some(p) = &self.password {
                    command.env("REDISCLI_AUTH", p);
                }
                let db = if database.is_empty() { "0" } else { database };
                ensure!(db.parse::<u16>().is_ok(), "invalid_database_name");
                command.args(["-n", db]);
            }
            "sqlite" => {
                command.arg("-bail");
                if c.read_only {
                    command.arg("-readonly");
                }
                command.arg(
                    c.path
                        .as_ref()
                        .ok_or_else(|| anyhow::anyhow!("invalid_connection"))?,
                );
            }
            _ => bail!("invalid_connection"),
        }
        Ok(command)
    }
}

/// How long a one-shot client may take (a statement waiting for a lock, a server that does not
/// answer): longer than a slow query or an import chunk, short enough not to hang the request.
const CLIENT_TIMEOUT: Duration = Duration::from_secs(300);

/// Message of a client that was killed for taking longer than [`CLIENT_TIMEOUT`].
const CLIENT_TIMED_OUT: &str =
    "The server did not answer within 300 seconds; the request was cancelled.";

/// Runs a client with `input` on stdin, reading at most MAX_OUTPUT of stdout, for at most
/// [`CLIENT_TIMEOUT`].
pub(super) fn capture(command: Command, input: &[u8]) -> Result<Captured> {
    let mut captured = process::capture_limited(
        command,
        input,
        MAX_OUTPUT,
        Some(CLIENT_TIMEOUT),
        "client_not_installed",
    )?;
    // Every caller reports what the client said on stderr: a killed one says why.
    if captured.timed_out {
        captured.stderr = CLIENT_TIMED_OUT.into();
    }
    Ok(captured)
}

/// What a script run returns: one result per statement that ran, and the server's error if one
/// stopped it (the database's own message, which the user needs to fix the statement).
#[derive(Debug, Default, Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RunOutput {
    pub results: Vec<ResultSet>,
    pub error: Option<String>,
    pub duration_ms: u128,
}

pub fn clean_error(text: &str) -> Option<String> {
    let lines: Vec<&str> = text
        .lines()
        .map(str::trim)
        .filter(|l| {
            !l.is_empty()
                && !l.contains("Using a password on the command line")
                && !l.starts_with("mysql: [Warning]")
                && !l.contains("password file \"/dev/null\" is not a plain file")
                && !l.starts_with("LOCATION:")
        })
        .collect();
    // "at line N" counts lines of the script the client was given, not of the user's text.
    let lines: Vec<String> = lines
        .iter()
        .map(|l| match (l.find(" at line "), l.find(": ")) {
            (Some(at), Some(colon)) if at < colon => format!("{}{}", &l[..at], &l[colon..]),
            _ => l.to_string(),
        })
        .collect();
    (!lines.is_empty()).then(|| lines.join("\n").chars().take(2000).collect())
}

/// Codes the engine writes in place of a server message (when the client said nothing).
pub const CLIENT_CODES: &[&str] = &[
    "client_failed",
    "result_too_large",
    "query_failed",
    "dump_failed",
    "restore_failed",
    "export_failed",
    "session_failed",
    "session_timeout",
];

/// The error for a failed run: one of the engine's own codes as it is (the app has a message for
/// it), the server's text as `db:` detail otherwise.
pub fn db_error(text: &str) -> anyhow::Error {
    if CLIENT_CODES.contains(&text) {
        anyhow::anyhow!(text.to_string())
    } else {
        anyhow::anyhow!(format!("db:{text}"))
    }
}

/// Runs statements in one session (so `USE`, `SET` and temporary tables carry over) and returns
/// each statement's rows or affected count. The caller has already checked confirmation.
pub fn run_sql(
    target: &Target,
    database: &str,
    statements: &[String],
    max_rows: usize,
) -> Result<RunOutput> {
    let started = Instant::now();
    let dialect = target
        .dialect()
        .ok_or_else(|| anyhow::anyhow!("invalid_connection"))?;
    let mut output = RunOutput::default();
    match dialect {
        Dialect::MySql => {
            let secret = target.mysql_options()?;
            let mut command = target.command("mysql", database, Some(&secret))?;
            command.args(["--xml", "--binary-as-hex", "--quick", "--batch"]);
            let mut script = String::new();
            for (i, statement) in statements.iter().enumerate() {
                script.push_str(statement);
                script.push_str(&format!(
                    "\n;\nSELECT ROW_COUNT() AS __butake_affected, {i} AS __butake_marker;\n"
                ));
            }
            let captured = capture(command, script.as_bytes())?;
            let mut pending: Option<ResultSet> = None;
            for set in sql::parse_mysql_xml(&captured.stdout, max_rows) {
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
                    result.statement = statements.get(index).cloned().unwrap_or_default();
                    if result.columns.is_empty() && result.rows.is_empty() {
                        result.affected = affected.filter(|a| *a >= 0);
                    } else {
                        result.affected = Some(result.rows.len() as i64);
                    }
                    output.results.push(result);
                } else if pending.is_none() {
                    pending = Some(set);
                }
            }
            if !captured.success {
                output.error = clean_error(&captured.stderr).or(Some(if captured.cut {
                    "result_too_large".into()
                } else {
                    "client_failed".into()
                }));
            }
        }
        Dialect::Postgres => {
            let mut command = target.command("psql", database, None)?;
            command.args([
                "-X",
                "-q",
                "--csv",
                "-v",
                "ON_ERROR_STOP=1",
                "-v",
                "VERBOSITY=verbose",
                "-P",
                &format!("null={NULL_MARK}"),
                "-f",
                "-",
            ]);
            let mut script = String::new();
            for statement in statements {
                script.push_str(statement);
                script.push_str(&format!("\n;\n\\echo {RESULT_MARK} :ROW_COUNT\n"));
            }
            let captured = capture(command, script.as_bytes())?;
            output.results = split_marked(&captured.stdout, statements, max_rows);
            if !captured.success {
                output.error = clean_error(&captured.stderr).or(Some("client_failed".into()));
            }
        }
        Dialect::Sqlite => {
            let mut command = target.command("sqlite3", database, None)?;
            command.arg("-batch");
            let mut script = format!(".headers on\n.mode csv\n.nullvalue {NULL_MARK}\n");
            if target.connection.read_only {
                // Besides -readonly: no change to any file, attached ones included.
                script.push_str("PRAGMA query_only = ON;\n");
            }
            for statement in statements {
                script.push_str(statement);
                script.push_str(&format!("\n;\n.print {RESULT_MARK} -1\n"));
            }
            let captured = capture(command, script.as_bytes())?;
            output.results = split_marked(&captured.stdout, statements, max_rows);
            if !captured.success || !captured.stderr.trim().is_empty() {
                output.error = clean_error(&captured.stderr).or(if captured.success {
                    None
                } else {
                    Some("client_failed".into())
                });
            }
        }
    }
    output.duration_ms = started.elapsed().as_millis();
    Ok(output)
}

/// CSV blocks separated by `RESULT_MARK <row count>` lines (psql and sqlite3).
pub(crate) fn split_marked(stdout: &str, statements: &[String], max_rows: usize) -> Vec<ResultSet> {
    let mut results = vec![];
    let mut block = String::new();
    for line in stdout.split_inclusive('\n') {
        if let Some(rest) = line.strip_prefix(RESULT_MARK) {
            let count = rest.trim().parse::<i64>().ok().filter(|c| *c >= 0);
            let mut result = csv_result(&block, max_rows);
            result.statement = statements.get(results.len()).cloned().unwrap_or_default();
            result.affected = if result.columns.is_empty() {
                count
            } else {
                Some(count.unwrap_or(result.rows.len() as i64))
            };
            results.push(result);
            block.clear();
        } else {
            block.push_str(line);
        }
    }
    results
}

pub(super) fn csv_result(block: &str, max_rows: usize) -> ResultSet {
    let mut rows = sql::parse_csv(block).into_iter();
    let mut set = ResultSet::default();
    let Some(header) = rows.next() else {
        return set;
    };
    set.columns = header.into_iter().map(|(name, _)| name).collect();
    for (index, row) in rows.enumerate() {
        if index >= max_rows {
            set.truncated = true;
            continue;
        }
        set.rows.push(
            row.into_iter()
                .map(|(value, quoted)| (quoted || value != NULL_MARK).then_some(value))
                .collect(),
        );
    }
    set
}

/// One read-only query whose rows the client itself needs (catalog lookups).
pub fn query(target: &Target, database: &str, sql: &str) -> Result<ResultSet> {
    let out = crate::db::session::read(target, database, &[sql.to_string()], 100_000)?;
    if let Some(error) = out.error {
        return Err(db_error(&error));
    }
    out.results
        .into_iter()
        .next()
        .ok_or_else(|| anyhow::anyhow!("query_failed"))
}

/// Runs one Redis command (arguments as given, never through a shell) and returns its JSON reply.
pub fn redis(target: &Target, database: &str, args: &[String]) -> Result<serde_json::Value> {
    let mut command = target.command("redis-cli", database, None)?;
    command.args(["-3", "--json"]).args(args);
    let captured = capture(command, b"")?;
    let text = captured.stdout.trim();
    if let Some(error) = text.strip_prefix("error:") {
        let message: String = serde_json::from_str(error).unwrap_or_else(|_| error.to_string());
        bail!(format!("db:{message}"));
    }
    if !captured.success && text.is_empty() {
        return Err(db_error(
            &clean_error(&captured.stderr).unwrap_or_else(|| "client_failed".into()),
        ));
    }
    Ok(serde_json::from_str(text).unwrap_or(serde_json::Value::String(text.to_string())))
}

/// Text output of Redis commands typed in the console (one per line), as redis-cli shows them.
pub fn redis_console(target: &Target, database: &str, script: &str) -> Result<RunOutput> {
    let started = Instant::now();
    let mut output = RunOutput::default();
    for line in script
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
    {
        let mut one = target.command("redis-cli", database, None)?;
        one.arg("--no-raw");
        let captured = capture(one, format!("{line}\n").as_bytes())?;
        output.results.push(ResultSet {
            columns: vec!["reply".into()],
            rows: captured
                .stdout
                .lines()
                .map(|l| vec![Some(l.to_string())])
                .collect(),
            affected: None,
            statement: line.to_string(),
            truncated: captured.cut,
        });
        if !captured.success {
            output.error = clean_error(&captured.stderr);
            break;
        }
    }
    output.duration_ms = started.elapsed().as_millis();
    Ok(output)
}

/// Commands that only read; anything else typed in the Redis console needs confirmation.
pub fn redis_read_only(line: &str) -> bool {
    const READ: &[&str] = &[
        "get",
        "mget",
        "strlen",
        "getrange",
        "exists",
        "type",
        "ttl",
        "pttl",
        "keys",
        "scan",
        "hget",
        "hmget",
        "hgetall",
        "hkeys",
        "hvals",
        "hlen",
        "hexists",
        "hscan",
        "lrange",
        "llen",
        "lindex",
        "smembers",
        "scard",
        "sismember",
        "sscan",
        "zrange",
        "zrevrange",
        "zcard",
        "zscore",
        "zscan",
        "zrangebyscore",
        "xrange",
        "xrevrange",
        "xlen",
        "info",
        "dbsize",
        "ping",
        "echo",
        "time",
        "memory",
        "object",
        "client",
        "config",
        "slowlog",
        "lastsave",
        "role",
        "command",
        "randomkey",
    ];
    let words: Vec<String> = line
        .split_whitespace()
        .map(|w| w.to_ascii_lowercase())
        .collect();
    let Some(first) = words.first() else {
        return true;
    };
    if !READ.contains(&first.as_str()) {
        return false;
    }
    // Subcommands that change things.
    let sub = words.get(1).map(String::as_str).unwrap_or("");
    !match first.as_str() {
        "client" => !["list", "info", "getname", "id"].contains(&sub),
        "config" => sub != "get",
        "memory" => !["usage", "stats", "doctor"].contains(&sub),
        "slowlog" => sub == "reset",
        _ => false,
    }
}
