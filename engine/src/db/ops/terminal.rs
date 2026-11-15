//! The terminal script of a connection and the stack's MySQL root password.

use super::*;

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

/// Opens the engine's own client in Terminal. The password goes in a private file that the
/// script removes as soon as the client has read it; nothing lands in the shell history.
pub fn terminal(store: &Store, target: &Target, request: &Value) -> Result<Value> {
    let database = text(request, "database");
    let run = store.directory("run")?;
    let token = format!("{:x}", now_nanos());
    let script = run.join(format!("terminal-{token}.command"));
    let tool = match target.connection.kind.as_str() {
        "mysql" | "mariadb" => "mysql",
        "postgres" => "psql",
        "redis" | "valkey" => "redis-cli",
        _ => "sqlite3",
    };
    let mut lines = vec!["#!/bin/zsh".to_string(), "rm -f -- \"$0\"".into()];
    let secret = if tool == "mysql" {
        Some(target.mysql_options()?)
    } else {
        None
    };
    let command = target.command(tool, database, secret.as_ref())?;
    if let Some(secret) = secret {
        let path = secret.keep();
        lines.push(format!(
            "( sleep 5; rm -f -- {} ) &!",
            shell_quote(&path.to_string_lossy())
        ));
    }
    let program = command.get_program().to_string_lossy().into_owned();
    let args: Vec<String> = command
        .get_args()
        .map(|a| a.to_string_lossy().into_owned())
        .collect();
    for (key, value) in command.get_envs() {
        if let (Some(value), key) = (value, key.to_string_lossy()) {
            lines.push(format!(
                "export {}={}",
                key,
                shell_quote(&value.to_string_lossy())
            ));
        }
    }
    lines.push(format!(
        "exec {} {}",
        shell_quote(&program),
        args.iter()
            .map(|a| shell_quote(a))
            .collect::<Vec<_>>()
            .join(" ")
    ));
    write_private(&script, &(lines.join("\n") + "\n"))?;
    std::fs::set_permissions(&script, std::os::unix::fs::PermissionsExt::from_mode(0o700))?;
    let status = Command::new("/usr/bin/open")
        .args(["-a", "Terminal"])
        .arg(&script)
        .env_clear()
        .status()?;
    ensure!(status.success(), "terminal_failed");
    Ok(json!(true))
}

/// Sets a password on every `root` account of the stack's MySQL (it starts without one). The app
/// keeps it in the Keychain and sends it with every request that connects as root.
pub fn set_root_password(target: &Target, request: &Value) -> Result<Value> {
    ensure!(
        target.connection.id == "stack-mysql" || target.connection.id == "stack-mariadb",
        "invalid_connection"
    );
    let password = text(request, "newPassword");
    valid_password(password)?;
    let hosts = query(
        target,
        "",
        "SELECT Host FROM mysql.user WHERE User = 'root'",
    )?;
    ensure!(!hosts.rows.is_empty(), "invalid_request");
    let statements: Vec<String> = hosts
        .rows
        .iter()
        .map(|r| {
            format!(
                "ALTER USER 'root'@{} IDENTIFIED BY '{password}'",
                account_part(r[0].as_deref().unwrap_or(""))
            )
        })
        .collect();
    if !confirmed(target, request) {
        return Ok(
            json!({"needsConfirmation": true, "statements": statements.iter().map(|s| s.replace(password, "••••••")).collect::<Vec<_>>()}),
        );
    }
    let out = run_sql(target, "", &statements, 1)?;
    if let Some(error) = out.error {
        return Err(client::db_error(&error));
    }
    Ok(json!({"accounts": hosts.rows.len()}))
}
