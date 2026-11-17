//! Restoring an SQL file (plain or gzip) into a database.

use super::*;
use std::io::BufRead;

/// How much of the script is read to say what it would replace.
const SCAN_LIMIT: u64 = 16 << 20;
/// Most statements listed for the confirmation.
const SCAN_LISTED: usize = 50;

/// What a script would touch besides the table rows: the tables it drops and the databases it
/// names (a dump of several databases, or `pg_dump --create`, writes into those, not only into the
/// one the user chose). Read from the start of the script, line by line.
#[derive(Debug, Default, PartialEq, Eq)]
struct Reach {
    /// The statements found, normalized (drops of tables and databases, creates, `USE`, `\connect`).
    statements: Vec<String>,
    tables: Vec<String>,
    databases: Vec<String>,
    /// The whole script was read (otherwise there may be more).
    complete: bool,
}

/// The first word of `rest` without quotes, `;` or (unless `keep_schema`) the schema of a name.
fn object_name(rest: &str, keep_schema: bool) -> Option<String> {
    let word = rest.split_whitespace().next()?;
    let word = word.trim_end_matches([';', ',']).trim_end_matches("*/");
    let name = if keep_schema {
        word
    } else {
        word.rsplit('.').next().unwrap_or(word)
    };
    let name = name.trim_matches(['`', '"', '\'']);
    (!name.is_empty()).then(|| name.to_string())
}

/// `rest` without a leading `words` (case-insensitive), when it starts with them.
fn after_words<'a>(rest: &'a str, words: &str) -> &'a str {
    match rest.get(..words.len()) {
        Some(head) if head.eq_ignore_ascii_case(words) => rest[words.len()..].trim_start(),
        _ => rest,
    }
}

fn scan(reader: impl Read, limit: u64) -> Reach {
    let mut reach = Reach::default();
    let mut lines = std::io::BufReader::new(reader.take(limit));
    let mut raw = Vec::new();
    let mut read = 0u64;
    loop {
        raw.clear();
        match lines.read_until(b'\n', &mut raw) {
            Ok(0) => {
                // `take` also ends at the limit: only a script shorter than it was read whole.
                reach.complete = read < limit;
                break;
            }
            Ok(n) => read += n as u64,
            Err(_) => break,
        }
        let text = String::from_utf8_lossy(&raw);
        let mut line = text.trim();
        // `/*!40000 ... */`: a statement that only some servers run.
        if let Some(rest) = line.strip_prefix("/*!") {
            line = rest.trim_start_matches(|c: char| c.is_ascii_digit()).trim();
        }
        let upper = line.to_ascii_uppercase();
        let after = |prefix: &str| {
            upper
                .starts_with(prefix)
                .then(|| line[prefix.len()..].trim_start())
        };
        // (statement text, whether it names a table, the name)
        let found = if let Some(rest) = after("DROP TABLE") {
            let rest = after_words(rest, "IF EXISTS");
            object_name(rest, true).map(|full| {
                let short = object_name(rest, false).unwrap_or_else(|| full.clone());
                (format!("DROP TABLE {full}"), true, short)
            })
        } else if let Some(rest) = after("DROP DATABASE").or_else(|| after("DROP SCHEMA")) {
            let rest = after_words(rest, "IF EXISTS");
            object_name(rest, true).map(|n| (format!("DROP DATABASE {n}"), false, n))
        } else if let Some(rest) = after("CREATE DATABASE").or_else(|| after("CREATE SCHEMA")) {
            let rest = after_words(rest, "IF NOT EXISTS");
            object_name(rest, true).map(|n| (format!("CREATE DATABASE {n}"), false, n))
        } else if let Some(rest) = after("USE ") {
            object_name(rest, true).map(|n| (format!("USE {n}"), false, n))
        } else if let Some(rest) = line
            .strip_prefix("\\connect ")
            .or_else(|| line.strip_prefix("\\c "))
        {
            object_name(rest, true).map(|n| (format!("\\connect {n}"), false, n))
        } else {
            None
        };
        if let Some((statement, table, name)) = found {
            if reach.statements.len() < SCAN_LISTED && !reach.statements.contains(&statement) {
                reach.statements.push(statement);
            }
            let list = if table {
                &mut reach.tables
            } else {
                &mut reach.databases
            };
            if list.len() < 200 && !list.contains(&name) {
                list.push(name);
            }
        }
    }
    reach
}

/// Whether `source` is a gzip file that decompresses to its end: a truncated or corrupt one would
/// hand the client half a script, which it would run until it stopped, with the data already changed.
fn gzip_is_sound(source: &Path) -> Result<bool> {
    Ok(Command::new("/usr/bin/gzip")
        .arg("-t")
        .arg(source)
        .env_clear()
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map_err(|_| anyhow::anyhow!("restore_failed"))?
        .success())
}

/// The start of what the file says, decompressed when it is gzip.
fn read_reach(source: &Path, compressed: bool) -> Result<Reach> {
    let file = std::fs::File::open(source)?;
    if !compressed {
        return Ok(scan(file, SCAN_LIMIT));
    }
    let mut child = Command::new("/usr/bin/gzip")
        .arg("-dc")
        .env_clear()
        .stdin(Stdio::from(file))
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    let out = child
        .stdout
        .take()
        .ok_or_else(|| anyhow::anyhow!("restore_failed"))?;
    let reach = scan(out, SCAN_LIMIT);
    let _ = child.kill();
    let _ = child.wait();
    Ok(reach)
}

fn is_gzip(source: &Path) -> bool {
    let mut magic = [0u8; 2];
    std::fs::File::open(source).is_ok_and(|mut f| f.read_exact(&mut magic).is_ok())
        && magic == [0x1f, 0x8b]
}

/// Runs an SQL file (plain or .gz) into a database with the engine's client; stops at the first
/// error. Needs confirmation: it changes the target database.
pub fn restore(store: &Store, target: &Target, request: &Value) -> Result<Value> {
    let d = dialect(target)?;
    ensure!(d != Dialect::Sqlite, "unsupported_engine");
    let database = text(request, "database");
    valid_name(database)?;
    let source = PathBuf::from(text(request, "path"));
    ensure!(source.is_absolute() && source.is_file(), "invalid_file");
    let compressed = is_gzip(&source);
    ensure!(!compressed || gzip_is_sound(&source)?, "invalid_file");
    if !confirmed(target, request) {
        // What the script replaces is said before anything runs: tables dropped and the other
        // databases it writes into. PostgreSQL runs it in one transaction; MySQL commits every
        // drop/create by itself, so what ran before an error stays (`atomic: false`).
        let reach = read_reach(&source, compressed)?;
        let mut statements = vec![format!(
            "{} → {database}",
            source.file_name().unwrap_or_default().to_string_lossy()
        )];
        statements.extend(reach.statements.iter().cloned());
        return Ok(json!({
            "needsConfirmation": true,
            "statements": statements,
            "replaces": {
                "tables": reach.tables,
                "databases": reach.databases,
                "complete": reach.complete,
            },
            "atomic": d == Dialect::Postgres,
            "production": target.connection.production,
        }));
    }
    if request["create"] == true {
        let exists = databases(target)?
            .as_array()
            .is_some_and(|l| l.iter().any(|d| d["name"] == database));
        if !exists {
            create_database(target, &json!({"name": database, "confirmed": true}))?;
        }
    }
    let total = std::fs::metadata(&source)?.len();
    let mut progress = Progress::new(store, text(request, "progress"), total)?;
    let secret = if d == Dialect::MySql {
        Some(target.mysql_options()?)
    } else {
        None
    };
    let mut client = match d {
        Dialect::MySql => {
            let mut c = target.command("mysql", database, secret.as_ref())?;
            c.arg("--batch");
            c
        }
        _ => {
            let mut c = target.command("psql", database, None)?;
            // One transaction: an error leaves the database as it was.
            c.args([
                "-X",
                "-q",
                "-1",
                "-v",
                "ON_ERROR_STOP=1",
                "-v",
                "VERBOSITY=verbose",
                "-f",
                "-",
            ]);
            c
        }
    };
    let mut gunzip = None;
    if compressed {
        let mut child = Command::new("/usr/bin/gzip")
            .arg("-dc")
            .env_clear()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        client.stdin(Stdio::from(
            child
                .stdout
                .take()
                .ok_or_else(|| anyhow::anyhow!("restore_failed"))?,
        ));
        gunzip = Some(child);
    } else {
        client.stdin(Stdio::piped());
    }
    let mut child = client
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|_| anyhow::anyhow!("client_not_installed"))?;
    let mut errors = child
        .stderr
        .take()
        .ok_or_else(|| anyhow::anyhow!("restore_failed"))?;
    let reader = std::thread::spawn(move || {
        let mut text = String::new();
        let _ = (&mut errors).take(64 * 1024).read_to_string(&mut text);
        // Keep draining: a client that fills the pipe would block forever.
        let _ = std::io::copy(&mut errors, &mut std::io::sink());
        text
    });
    let mut sink: Box<dyn Write> = match gunzip.as_mut() {
        Some(g) => Box::new(
            g.stdin
                .take()
                .ok_or_else(|| anyhow::anyhow!("restore_failed"))?,
        ),
        None => Box::new(
            child
                .stdin
                .take()
                .ok_or_else(|| anyhow::anyhow!("restore_failed"))?,
        ),
    };
    let mut input = std::fs::File::open(&source)?;
    let mut buffer = vec![0u8; 256 * 1024];
    let mut done = 0u64;
    loop {
        let n = input.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        // The client stops reading at the first error: its exit status says what happened.
        if sink.write_all(&buffer[..n]).is_err() {
            break;
        }
        done += n as u64;
        progress.report(done, database, false);
    }
    drop(sink);
    // A truncated or corrupt .gz hands the client half a script that it still runs to the end.
    let gunzip_ok = match gunzip {
        Some(mut g) => g.wait().map(|s| s.success()).unwrap_or(false),
        None => true,
    };
    let status = child.wait()?;
    let stderr = reader.join().unwrap_or_default();
    drop(secret);
    progress.report(done, database, true);
    if !status.success() {
        return Err(client::db_error(
            &client::clean_error(&stderr).unwrap_or_else(|| "restore_failed".into()),
        ));
    }
    ensure!(gunzip_ok, "restore_failed");
    Ok(json!({"bytes": done}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn connection(kind: &str) -> client::Connection {
        client::Connection {
            id: "remota".into(),
            name: "Remota".into(),
            kind: kind.into(),
            host: "db.example.com".into(),
            port: 5432,
            user: "app".into(),
            database: "app".into(),
            path: None,
            tls: "prefer".into(),
            ssh: None,
            builtin: false,
            has_password: true,
            stack_password: false,
            production: false,
            read_only: false,
        }
    }

    /// A folder with a fake client that records its arguments and what it read, and exits `code`.
    fn fake(tool: &str, code: i32) -> (tempfile::TempDir, Target) {
        let temp = tempfile::tempdir().unwrap();
        let bin = temp.path().join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        let program = bin.join(tool);
        std::fs::write(
            &program,
            format!(
                "#!/bin/sh\nprintf '%s\\n' \"$@\" > '{0}/args'\ncat > '{0}/input'\necho 'ERROR: boom' >&2\nexit {code}\n",
                temp.path().display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o755)).unwrap();
        let run = temp.path().join("run");
        std::fs::create_dir_all(&run).unwrap();
        let kind = if tool == "psql" { "postgres" } else { "mysql" };
        let target = Target::for_tests(connection(kind), bin, run);
        (temp, target)
    }

    fn request(path: &Path, confirmed: bool) -> Value {
        json!({"database": "app", "path": path, "confirmed": confirmed})
    }

    #[test]
    fn the_script_reach_lists_drops_and_other_databases() {
        let script = b"-- dump\nDROP TABLE IF EXISTS `users`;\nCREATE TABLE users (id int);\n/*!40000 DROP DATABASE IF EXISTS other */;\nCREATE DATABASE IF NOT EXISTS other;\nUSE other;\n\\connect third\nDROP TABLE public.orders;\n";
        let reach = scan(&script[..], 1 << 20);
        assert_eq!(reach.tables, ["users", "orders"]);
        assert_eq!(reach.databases, ["other", "third"]);
        assert!(reach
            .statements
            .contains(&"DROP TABLE public.orders".to_string()));
        assert!(reach.complete);
        // Only the start is read of a very long script.
        assert!(!scan(&script[..], 20).complete);
    }

    #[test]
    fn a_truncated_gzip_never_reaches_the_client() {
        let (temp, target) = fake("psql", 0);
        let plain = temp.path().join("dump.sql");
        std::fs::write(&plain, "INSERT INTO t VALUES (1);\n".repeat(2000)).unwrap();
        assert!(Command::new("/usr/bin/gzip")
            .arg("-kf")
            .arg(&plain)
            .status()
            .unwrap()
            .success());
        let gz = temp.path().join("dump.sql.gz");
        let bytes = std::fs::read(&gz).unwrap();
        std::fs::write(&gz, &bytes[..bytes.len() / 2]).unwrap();
        let store = Store::new(temp.path().join("store")).unwrap();
        for confirmed in [false, true] {
            let error = restore(&store, &target, &request(&gz, confirmed)).unwrap_err();
            assert_eq!(error.to_string(), "invalid_file");
        }
        assert!(!temp.path().join("args").exists(), "the client never ran");
    }

    #[test]
    fn postgres_restores_in_one_transaction_and_says_what_it_replaces() {
        let (temp, target) = fake("psql", 0);
        let file = temp.path().join("dump.sql");
        std::fs::write(
            &file,
            "DROP TABLE public.t;\nCREATE TABLE public.t (id int);\n",
        )
        .unwrap();
        let store = Store::new(temp.path().join("store")).unwrap();
        let plan = restore(&store, &target, &request(&file, false)).unwrap();
        assert_eq!(plan["needsConfirmation"], true);
        assert_eq!(plan["replaces"]["tables"], json!(["t"]));
        assert_eq!(plan["atomic"], true);
        assert!(
            !temp.path().join("args").exists(),
            "nothing ran before confirming"
        );
        restore(&store, &target, &request(&file, true)).unwrap();
        let args = std::fs::read_to_string(temp.path().join("args")).unwrap();
        assert!(args.lines().any(|a| a == "-1") && args.lines().any(|a| a == "ON_ERROR_STOP=1"));
        assert!(
            !args.contains("centinela-clave"),
            "the password is no argument"
        );
        assert!(std::fs::read_to_string(temp.path().join("input"))
            .unwrap()
            .contains("CREATE TABLE"));
    }

    #[test]
    fn a_failing_client_is_an_error_without_the_password_and_leaves_no_options_file() {
        let (temp, target) = fake("mysql", 1);
        let file = temp.path().join("dump.sql");
        std::fs::write(&file, "SELECT 1;\n").unwrap();
        let store = Store::new(temp.path().join("store")).unwrap();
        let plan = restore(&store, &target, &request(&file, false)).unwrap();
        assert_eq!(plan["atomic"], false);
        let error = restore(&store, &target, &request(&file, true)).unwrap_err();
        assert!(!format!("{error:#}").contains("centinela-clave"));
        let leftovers: Vec<_> = std::fs::read_dir(target.run_dir())
            .unwrap()
            .flatten()
            .collect();
        assert!(leftovers.is_empty(), "{leftovers:?}");
    }
}
