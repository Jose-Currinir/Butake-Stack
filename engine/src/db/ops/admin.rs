//! Administration: databases, users and the server's processes.

use super::*;

pub fn create_database(target: &Target, request: &Value) -> Result<Value> {
    let d = dialect(target)?;
    let name = text(request, "name");
    valid_name(name)?;
    let sql = match d {
        Dialect::MySql => format!(
            "CREATE DATABASE {} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci",
            ident(d, name)
        ),
        Dialect::Postgres => format!("CREATE DATABASE {} ENCODING 'UTF8'", ident(d, name)),
        Dialect::Sqlite => bail!("unsupported_engine"),
    };
    if !confirmed(target, request) {
        return Ok(json!({"needsConfirmation": true, "statements": [sql]}));
    }
    one_change(target, "", &sql)
}

/// Dropping needs the name typed again and never applies to the server's own databases.
pub fn drop_database(target: &Target, request: &Value) -> Result<Value> {
    let d = dialect(target)?;
    let name = text(request, "name");
    valid_name(name)?;
    ensure!(
        !SYSTEM_DATABASES
            .iter()
            .any(|system| system.eq_ignore_ascii_case(name)),
        "database_protected"
    );
    ensure!(d != Dialect::Sqlite, "unsupported_engine");
    let sql = format!("DROP DATABASE {}", ident(d, name));
    if !confirmed(target, request) || text(request, "typedName") != name {
        return Ok(json!({"needsConfirmation": true, "statements": [sql]}));
    }
    one_change(target, "", &sql)
}

fn one_change(target: &Target, database: &str, sql: &str) -> Result<Value> {
    let out = run_sql(target, database, &[sql.to_string()], 10)?;
    if let Some(error) = out.error {
        return Err(client::db_error(&error));
    }
    Ok(serde_json::to_value(out)?)
}

/// Accounts with their grants (MySQL) or attributes (PostgreSQL).
pub fn users(target: &Target) -> Result<Value> {
    let d = dialect(target)?;
    match d {
        Dialect::MySql => {
            let set = query(
                target,
                "",
                "SELECT User, Host, account_locked, plugin FROM mysql.user ORDER BY User, Host",
            )?;
            let grants: Vec<String> = set
                .rows
                .iter()
                .map(|r| {
                    format!(
                        "SHOW GRANTS FOR {}@{}",
                        account_part(r[0].as_deref().unwrap_or("")),
                        account_part(r[1].as_deref().unwrap_or(""))
                    )
                })
                .collect();
            let shown = if grants.is_empty() {
                vec![]
            } else {
                crate::db::session::read(target, "", &grants, 200)?.results
            };
            Ok(json!(set.rows.iter().enumerate().map(|(i, r)| json!({
                "name": cell(r, 0), "host": cell(r, 1), "locked": r[2].as_deref() == Some("Y"), "plugin": cell(r, 3),
                "grants": shown.get(i).map(|g| g.rows.iter().filter_map(|row| row[0].clone()).collect::<Vec<_>>()).unwrap_or_default(),
                "system": r[0].as_deref().is_some_and(|u| u.starts_with("mysql.") || u == "root"),
            })).collect::<Vec<_>>()))
        }
        Dialect::Postgres => {
            let set = query(
                target,
                "",
                "SELECT r.rolname, '', r.rolcanlogin, r.rolsuper, r.rolcreatedb, r.rolcreaterole, r.rolbypassrls, \
                COALESCE((SELECT string_agg(d.datname, ', ') FROM pg_database d WHERE has_database_privilege(r.rolname, d.datname, 'CREATE') AND NOT d.datistemplate), '') \
                FROM pg_roles r WHERE r.rolname !~ '^pg_' ORDER BY 1",
            )?;
            Ok(json!(set.rows.iter().map(|r| {
                let flag = |i: usize, name: &str| (r[i].as_deref() == Some("t")).then(|| name.to_string());
                let attributes: Vec<String> = [flag(2, "LOGIN"), flag(3, "SUPERUSER"), flag(4, "CREATEDB"), flag(5, "CREATEROLE"), flag(6, "BYPASSRLS")].into_iter().flatten().collect();
                let databases = r[7].clone().unwrap_or_default();
                json!({"name": cell(r, 0), "host": "", "locked": r[2].as_deref() != Some("t"), "plugin": "",
                       "grants": attributes.into_iter().chain((!databases.is_empty()).then(|| format!("CREATE: {databases}"))).collect::<Vec<_>>(),
                       "system": r[0].as_deref() == Some("postgres")})
            }).collect::<Vec<_>>()))
        }
        Dialect::Sqlite => Ok(json!([])),
    }
}

/// User or host in MySQL account syntax (where hex literals are not accepted).
pub(super) fn account_part(value: &str) -> String {
    format!("'{}'", value.replace('\\', "\\\\").replace('\'', "''"))
}

fn valid_account(name: &str, host: &str, password: &str) -> Result<()> {
    ensure!(
        !name.is_empty()
            && name.len() <= 32
            && name
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'_' | b'.' | b'-')),
        "invalid_user"
    );
    ensure!(host.len() <= 60 && host.bytes().all(|c| c.is_ascii_alphanumeric() || matches!(c, b'.' | b'%' | b'_' | b':' | b'-')), "invalid_user");
    valid_password(password)
}

/// Passwords the client accepts: 12 to 128 printable characters without quotes, backslash or spaces.
pub fn valid_password(password: &str) -> Result<()> {
    ensure!(
        (12..=128).contains(&password.len())
            && password
                .chars()
                .all(|c| c.is_ascii_graphic() && !matches!(c, '\'' | '"' | '\\' | '`')),
        "invalid_password"
    );
    Ok(())
}

/// A login with access to one database: everything, or read only.
pub fn create_user(target: &Target, request: &Value) -> Result<Value> {
    let d = dialect(target)?;
    let (name, password, database) = (
        text(request, "name"),
        text(request, "newPassword"),
        text(request, "database"),
    );
    let host = if text(request, "host").is_empty() {
        "%"
    } else {
        text(request, "host")
    };
    valid_account(name, host, password)?;
    let read_only = request["access"] == "read";
    let mut statements: Vec<(String, String)> = vec![];
    match d {
        Dialect::MySql => {
            let account = format!("'{name}'@'{host}'");
            statements.push((
                "".into(),
                format!("CREATE USER {account} IDENTIFIED BY '{password}'"),
            ));
            if !database.is_empty() {
                valid_name(database)?;
                let privileges = if read_only {
                    "SELECT, SHOW VIEW"
                } else {
                    "ALL PRIVILEGES"
                };
                statements.push((
                    "".into(),
                    format!(
                        "GRANT {privileges} ON {}.* TO {account}",
                        ident(d, database)
                    ),
                ));
            }
        }
        Dialect::Postgres => {
            let role = ident(d, name);
            statements.push((
                "".into(),
                format!("CREATE ROLE {role} LOGIN PASSWORD '{password}'"),
            ));
            if !database.is_empty() {
                valid_name(database)?;
                statements.push((
                    "".into(),
                    format!(
                        "GRANT CONNECT{} ON DATABASE {} TO {role}",
                        if read_only { "" } else { ", TEMPORARY" },
                        ident(d, database)
                    ),
                ));
                let tables = if read_only {
                    "SELECT"
                } else {
                    "SELECT, INSERT, UPDATE, DELETE"
                };
                for sql in [
                    format!("GRANT USAGE ON SCHEMA public TO {role}"),
                    format!("GRANT {tables} ON ALL TABLES IN SCHEMA public TO {role}"),
                    format!(
                        "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT {tables} ON TABLES TO {role}"
                    ),
                ] {
                    statements.push((database.into(), sql));
                }
                if !read_only {
                    statements.push((
                        database.into(),
                        format!("GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO {role}"),
                    ));
                }
            }
        }
        Dialect::Sqlite => bail!("unsupported_engine"),
    }
    if !confirmed(target, request) {
        // The password is never echoed back.
        return Ok(
            json!({"needsConfirmation": true, "statements": statements.iter().map(|(_, s)| s.replace(password, "••••••")).collect::<Vec<_>>()}),
        );
    }
    for (db, sql) in &statements {
        one_change(target, db, sql)?;
    }
    Ok(json!(true))
}

pub fn drop_user(target: &Target, request: &Value) -> Result<Value> {
    let d = dialect(target)?;
    let (name, host) = (text(request, "name"), text(request, "host"));
    ensure!(
        !["root", "postgres", "debian-sys-maint"]
            .iter()
            .any(|protected| protected.eq_ignore_ascii_case(name))
            && !name.to_ascii_lowercase().starts_with("mysql.")
            && !name.to_ascii_lowercase().starts_with("mariadb."),
        "user_protected"
    );
    let sql = match d {
        Dialect::MySql => format!("DROP USER {}@{}", account_part(name), account_part(host)),
        Dialect::Postgres => format!("DROP ROLE {}", ident(d, name)),
        Dialect::Sqlite => bail!("unsupported_engine"),
    };
    if !confirmed(target, request) {
        return Ok(json!({"needsConfirmation": true, "statements": [sql]}));
    }
    one_change(target, "", &sql)
}

/// Sessions on the server, longest-running first.
pub fn processes(target: &Target) -> Result<Value> {
    if target.connection.is_redis() {
        let list = client::redis(target, "", &["CLIENT".into(), "LIST".into()])?;
        let lines: Vec<Value> = list.as_str().unwrap_or("").lines().map(|line| {
            let field = |k: &str| line.split(' ').find_map(|p| p.strip_prefix(&format!("{k}="))).unwrap_or("").to_string();
            json!({"id": field("id"), "user": field("user"), "host": field("addr"), "database": field("db"), "state": field("cmd"), "seconds": field("age").parse::<i64>().ok(), "query": field("name")})
        }).collect();
        return Ok(json!(lines));
    }
    let d = dialect(target)?;
    let sql = match d {
        Dialect::MySql => {
            "SELECT ID, USER, HOST, DB, COMMAND, TIME, COALESCE(STATE, ''), LEFT(COALESCE(INFO, ''), 400) FROM information_schema.PROCESSLIST WHERE ID <> CONNECTION_ID() ORDER BY TIME DESC"
        }
        Dialect::Postgres => {
            "SELECT pid, usename, COALESCE(client_addr::text, 'local'), datname, COALESCE(state, backend_type), EXTRACT(EPOCH FROM now() - COALESCE(query_start, backend_start))::bigint, wait_event, left(query, 400) FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND backend_type = 'client backend' ORDER BY 6 DESC NULLS LAST"
        }
        Dialect::Sqlite => return Ok(json!([])),
    };
    let set = query(target, "", sql)?;
    Ok(json!(set.rows.iter().map(|r| json!({
        "id": cell(r, 0), "user": cell(r, 1), "host": cell(r, 2), "database": cell(r, 3), "state": cell(r, 4),
        "seconds": number(r, 5), "query": cell(r, 7),
    })).collect::<Vec<_>>()))
}

pub fn kill(target: &Target, request: &Value) -> Result<Value> {
    let id = text(request, "id");
    ensure!(
        !id.is_empty() && id.len() <= 20 && id.bytes().all(|c| c.is_ascii_digit()),
        "invalid_request"
    );
    if target.connection.is_redis() {
        ensure!(confirmed(target, request), "confirmation_required");
        client::redis(
            target,
            "",
            &["CLIENT".into(), "KILL".into(), "ID".into(), id.into()],
        )?;
        return Ok(json!(true));
    }
    let sql = match dialect(target)? {
        Dialect::MySql => format!("KILL {id}"),
        Dialect::Postgres => format!("SELECT pg_terminate_backend({id})"),
        Dialect::Sqlite => bail!("unsupported_engine"),
    };
    if !confirmed(target, request) {
        return Ok(json!({"needsConfirmation": true, "statements": [sql]}));
    }
    one_change(target, "", &sql)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn passwords_and_names_are_restricted() {
        assert!(valid_password("Abc123!@#xyz_").is_ok());
        for bad in [
            "short",
            "has space here!",
            "quote'inside12",
            "back\\slash1234",
        ] {
            assert!(valid_password(bad).is_err(), "{bad}");
        }
        assert!(
            valid_name("gestion_2").is_ok()
                && valid_name("-x").is_err()
                && valid_name("a b").is_err()
        );
        assert!(valid_account("app", "%", "Abc123!@#xyz_").is_ok());
        assert!(valid_account("app'", "%", "Abc123!@#xyz_").is_err());
    }
}
