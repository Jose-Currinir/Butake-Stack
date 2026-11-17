//! Backups: dumps of a database to a file, with progress.

use super::*;

/// Dumps databases (or some tables of one) with the engine's own tool into a file the user chose,
/// optionally gzip-compressed, reporting the bytes written as it goes.
pub fn dump(store: &Store, target: &Target, request: &Value) -> Result<Value> {
    let d = dialect(target)?;
    ensure!(d != Dialect::Sqlite, "unsupported_engine");
    let databases: Vec<String> = request["databases"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|v| v.as_str().map(str::to_string))
        .collect();
    let tables: Vec<String> = request["tables"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|v| v.as_str().map(str::to_string))
        .collect();
    ensure!(
        !databases.is_empty() && databases.len() <= 100,
        "invalid_request"
    );
    for name in &databases {
        valid_name(name)?;
    }
    ensure!(tables.is_empty() || databases.len() == 1, "invalid_request");
    ensure!(
        tables.iter().all(|t| !t.is_empty()
            && t.len() <= 128
            && !t.starts_with('-')
            && !t.chars().any(char::is_control)),
        "invalid_request"
    );
    let path = destination(text(request, "path"))?;
    let compress = request["compress"] == true;
    // What goes in: structure (tables, indexes, views, keys) and data, only one of them, and the
    // server-side code (procedures and functions, triggers, MySQL events) on demand.
    let content = match text(request, "content") {
        "" | "all" => "all",
        "schema" => "schema",
        "data" => "data",
        _ => bail!("invalid_request"),
    };
    let flag = |key: &str| request[key].as_bool().unwrap_or(true);
    let mut progress = Progress::new(store, text(request, "progress"), 0)?;
    let secret = if d == Dialect::MySql {
        Some(target.mysql_options()?)
    } else {
        None
    };
    // One command per database for PostgreSQL (pg_dump takes one), a single one for MySQL.
    let mut commands = vec![];
    // Views left out because they no longer work (`skipBrokenViews`, a whole-database backup).
    let mut skipped: Vec<String> = vec![];
    match d {
        Dialect::MySql => {
            let mut c = target.command("mysqldump", "", secret.as_ref())?;
            c.args([
                "--single-transaction",
                "--quick",
                "--hex-blob",
                "--no-tablespaces",
                "--default-character-set=utf8mb4",
            ]);
            match content {
                "schema" => {
                    c.arg("--no-data");
                }
                "data" => {
                    c.args(["--no-create-info", "--skip-triggers"]);
                }
                _ => {}
            }
            if content != "data" {
                c.arg(if flag("routines") {
                    "--routines"
                } else {
                    "--skip-routines"
                });
                c.arg(if flag("triggers") {
                    "--triggers"
                } else {
                    "--skip-triggers"
                });
                c.arg(if flag("events") {
                    "--events"
                } else {
                    "--skip-events"
                });
            }
            if target.connection.kind == "mysql" {
                c.arg("--set-gtid-purged=OFF");
            }
            if request["skipBrokenViews"] == true && tables.is_empty() {
                skipped = broken_views(target, &databases)?;
                for view in &skipped {
                    c.arg(format!("--ignore-table={view}"));
                }
            }
            // One database goes without CREATE DATABASE / USE, so it restores into whichever
            // database the user picks; several keep their names.
            if databases.len() > 1 {
                c.arg("--databases").args(&databases);
            } else {
                c.arg("--").arg(&databases[0]).args(&tables);
            }
            commands.push(c);
        }
        Dialect::Postgres => {
            for name in &databases {
                let mut c = target.command("pg_dump", name, None)?;
                c.args(["--no-owner", "--no-privileges", "--encoding=UTF8"]);
                match content {
                    "schema" => {
                        c.arg("--schema-only");
                    }
                    "data" => {
                        c.arg("--data-only");
                    }
                    _ => {}
                }
                // pg_dump has no switch for functions alone; triggers can be left out of the data.
                if content == "data" && !flag("triggers") {
                    c.arg("--disable-triggers");
                }
                if databases.len() > 1 {
                    c.arg("--create");
                }
                for table in &tables {
                    let (schema, table) = table.split_once('.').unwrap_or(("public", table));
                    c.arg("-t")
                        .arg(format!("{}.{}", ident(d, schema), ident(d, table)));
                }
                commands.push(c);
            }
        }
        Dialect::Sqlite => unreachable!(),
    }
    // Written beside the destination and renamed over it only when everything succeeded.
    let (partial, file) = crate::db::export::Partial::create(&path)?;
    let mut gzip = if compress {
        Some(
            Command::new("/usr/bin/gzip")
                .arg("-c")
                .env_clear()
                .stdin(Stdio::piped())
                .stdout(file.try_clone()?)
                .stderr(Stdio::null())
                .spawn()?,
        )
    } else {
        None
    };
    let mut sink: Box<dyn Write> = match gzip.as_mut() {
        Some(child) => Box::new(
            child
                .stdin
                .take()
                .ok_or_else(|| anyhow::anyhow!("dump_failed"))?,
        ),
        None => Box::new(file),
    };
    let mut written = 0u64;
    let mut failure = None;
    for (index, mut command) in commands.into_iter().enumerate() {
        let step = databases.get(index).cloned().unwrap_or_default();
        let mut child = command
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|_| anyhow::anyhow!("client_not_installed"))?;
        let mut errors = child
            .stderr
            .take()
            .ok_or_else(|| anyhow::anyhow!("dump_failed"))?;
        let reader = std::thread::spawn(move || {
            let mut text = String::new();
            let _ = (&mut errors).take(64 * 1024).read_to_string(&mut text);
            // Keep draining: a client that fills the pipe would block forever.
            let _ = std::io::copy(&mut errors, &mut std::io::sink());
            text
        });
        let mut out = child
            .stdout
            .take()
            .ok_or_else(|| anyhow::anyhow!("dump_failed"))?;
        let mut buffer = vec![0u8; 256 * 1024];
        let copied = (|| -> Result<()> {
            loop {
                let n = out.read(&mut buffer)?;
                if n == 0 {
                    return Ok(());
                }
                sink.write_all(&buffer[..n])?;
                written += n as u64;
                progress.report(written, &step, false);
            }
        })();
        if let Err(error) = copied {
            // Never leave the client running after a failed write.
            let _ = child.kill();
            let _ = child.wait();
            let _ = reader.join();
            return Err(error);
        }
        let status = child.wait()?;
        let stderr = reader.join().unwrap_or_default();
        if !status.success() {
            failure = Some(client::clean_error(&stderr).unwrap_or_else(|| "dump_failed".into()));
            break;
        }
    }
    drop(sink);
    if let Some(mut child) = gzip {
        if !child.wait()?.success() && failure.is_none() {
            failure = Some("dump_failed".into());
        }
    }
    drop(secret);
    progress.report(written, "", true);
    if let Some(error) = failure {
        // Dropping the guard deletes only the partial file.
        return Err(client::db_error(&error));
    }
    partial.commit()?;
    let size = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
    Ok(json!({"path": path, "bytes": written, "size": size, "skippedViews": skipped}))
}

/// MySQL views that no longer work (a table, column, function or definer they use is gone), as
/// `database.view`: mysqldump stops at the first one, so a full backup leaves them out and says
/// which. `CHECK TABLE` reports each with an «Error» row and changes nothing.
fn broken_views(target: &Target, databases: &[String]) -> Result<Vec<String>> {
    let d = Dialect::MySql;
    let mut broken: Vec<String> = vec![];
    for database in databases {
        let sql = format!(
            "SELECT TABLE_NAME FROM information_schema.VIEWS WHERE TABLE_SCHEMA = {}",
            literal(d, database)
        );
        let views: Vec<String> = query(target, "", &sql)?
            .rows
            .iter()
            .filter_map(|row| row.first().cloned().flatten())
            .collect();
        for chunk in views.chunks(50) {
            let list = chunk
                .iter()
                .map(|view| format!("{}.{}", ident(d, database), ident(d, view)))
                .collect::<Vec<_>>()
                .join(", ");
            for row in query(target, "", &format!("CHECK TABLE {list}"))?.rows {
                let error = row
                    .get(2)
                    .and_then(|kind| kind.as_deref())
                    .is_some_and(|kind| kind.eq_ignore_ascii_case("error"));
                if let Some(name) = row.first().cloned().flatten().filter(|_| error) {
                    if !broken.contains(&name) {
                        broken.push(name);
                    }
                }
            }
        }
    }
    Ok(broken)
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

    /// A target whose `pg_dump` is a local double that prints a dump (or fails with `code`).
    fn fake(code: i32) -> (tempfile::TempDir, Target) {
        let temp = tempfile::tempdir().unwrap();
        let bin = temp.path().join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        let program = bin.join("pg_dump");
        std::fs::write(
            &program,
            format!(
                "#!/bin/sh\nprintf '%s\\n' \"$@\" > '{}/args'\necho 'CREATE TABLE t (id int);'\necho 'ERROR: boom' >&2\nexit {code}\n",
                temp.path().display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o755)).unwrap();
        let run = temp.path().join("run");
        std::fs::create_dir_all(&run).unwrap();
        let target = Target::for_tests(connection("postgres"), bin, run);
        (temp, target)
    }

    fn request(path: &Path, compress: bool) -> Value {
        json!({"databases": ["app"], "path": path, "compress": compress})
    }

    #[test]
    fn a_dump_is_written_whole_and_the_password_is_not_an_argument() {
        let (temp, target) = fake(0);
        let store = Store::new(temp.path().join("store")).unwrap();
        for compress in [false, true] {
            let out = temp
                .path()
                .join(if compress { "a.sql.gz" } else { "a.sql" });
            dump(&store, &target, &request(&out, compress)).unwrap();
            let bytes = if compress {
                let plain = Command::new("/usr/bin/gzip")
                    .arg("-dc")
                    .arg(&out)
                    .output()
                    .unwrap();
                assert!(plain.status.success());
                plain.stdout
            } else {
                std::fs::read(&out).unwrap()
            };
            assert!(String::from_utf8_lossy(&bytes).contains("CREATE TABLE t"));
        }
        let args = std::fs::read_to_string(temp.path().join("args")).unwrap();
        assert!(!args.contains("centinela-clave"));
    }

    #[test]
    fn a_failed_dump_leaves_no_file_at_the_destination() {
        let (temp, target) = fake(1);
        let store = Store::new(temp.path().join("store")).unwrap();
        let out = temp.path().join("b.sql");
        assert!(dump(&store, &target, &request(&out, false)).is_err());
        let names: Vec<String> = std::fs::read_dir(temp.path())
            .unwrap()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();
        assert!(!names.iter().any(|n| n.starts_with("b.sql")), "{names:?}");
    }

    #[test]
    fn the_mysql_options_file_is_private_holds_the_password_and_goes_away() {
        let temp = tempfile::tempdir().unwrap();
        let run = temp.path().join("run");
        std::fs::create_dir_all(&run).unwrap();
        let target = Target::for_tests(connection("mysql"), temp.path().into(), run.clone());
        let secret = target.mysql_options().unwrap();
        let files: Vec<_> = std::fs::read_dir(&run).unwrap().flatten().collect();
        assert_eq!(files.len(), 1);
        let meta = files[0].metadata().unwrap();
        assert_eq!(meta.permissions().mode() & 0o777, 0o600);
        let text = std::fs::read_to_string(files[0].path()).unwrap();
        assert!(text.contains("centinela-clave-9f3"));
        drop(secret);
        assert_eq!(std::fs::read_dir(&run).unwrap().count(), 0);
    }
}
