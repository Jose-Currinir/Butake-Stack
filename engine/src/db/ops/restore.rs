//! Restoring an SQL file (plain or gzip) into a database.

use super::*;

/// Runs an SQL file (plain or .gz) into a database with the engine's client; stops at the first
/// error. Needs confirmation: it changes the target database.
pub fn restore(store: &Store, target: &Target, request: &Value) -> Result<Value> {
    let d = dialect(target)?;
    ensure!(d != Dialect::Sqlite, "unsupported_engine");
    let database = text(request, "database");
    valid_name(database)?;
    let source = PathBuf::from(text(request, "path"));
    ensure!(source.is_absolute() && source.is_file(), "invalid_file");
    if !confirmed(target, request) {
        return Ok(
            json!({"needsConfirmation": true, "statements": [format!("{} → {database}", source.file_name().unwrap_or_default().to_string_lossy())]}),
        );
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
    let compressed = {
        let mut magic = [0u8; 2];
        std::fs::File::open(&source)?.read_exact(&mut magic).is_ok() && magic == [0x1f, 0x8b]
    };
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
            c.args([
                "-X",
                "-q",
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
    if let Some(mut g) = gunzip {
        let _ = g.wait();
    }
    let status = child.wait()?;
    let stderr = reader.join().unwrap_or_default();
    drop(secret);
    progress.report(done, database, true);
    if !status.success() {
        return Err(client::db_error(
            &client::clean_error(&stderr).unwrap_or_else(|| "restore_failed".into()),
        ));
    }
    Ok(json!({"bytes": done}))
}
