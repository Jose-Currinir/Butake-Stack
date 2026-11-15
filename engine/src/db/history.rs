//! What the SQL editor keeps between launches, in private files of the store (0600 inside a 0700
//! folder): the history of statements run per connection and database, and the query tabs per
//! connection. Text that carries a password (CREATE USER … PASSWORD, IDENTIFIED BY, SET PASSWORD,
//! Redis AUTH…) is never written.
use crate::{core::fsutil::write_private, core::store::Store, db::sql};
use anyhow::{ensure, Result};
use serde::{Deserialize, Serialize};
use std::{collections::BTreeMap, path::PathBuf};

/// Entries kept per connection and database, newest first.
pub const LIMIT: usize = 100;
const MAX_ENTRY: usize = 256 * 1024;

fn valid_connection(id: &str) -> Result<()> {
    ensure!(crate::core::validate::id(id, 48), "invalid_connection");
    Ok(())
}

fn file(store: &Store, folder: &str, connection: &str) -> Result<PathBuf> {
    valid_connection(connection)?;
    let path = store.directory(folder)?.join(format!("{connection}.json"));
    ensure!(
        !std::fs::symlink_metadata(&path).is_ok_and(|m| m.file_type().is_symlink()),
        "unsafe_store_path"
    );
    Ok(path)
}

fn read_map<T: for<'a> Deserialize<'a> + Default>(path: &PathBuf) -> T {
    std::fs::read(path)
        .ok()
        .and_then(|d| serde_json::from_slice(&d).ok())
        .unwrap_or_default()
}

/// Statements run on a connection's database, newest first.
pub fn list(store: &Store, connection: &str, database: &str) -> Result<Vec<String>> {
    let map: BTreeMap<String, Vec<String>> = read_map(&file(store, "db-history", connection)?);
    Ok(map.get(database).cloned().unwrap_or_default())
}

/// Adds a statement on top (moving it up if it was there). Returns false when it was not kept
/// because it carries a password (or is empty or too long).
pub fn add(store: &Store, connection: &str, database: &str, sql: &str) -> Result<bool> {
    let text = sql.trim();
    if text.is_empty() || text.len() > MAX_ENTRY || sql::has_secret(text) {
        return Ok(false);
    }
    ensure!(
        database.len() <= 64 && !database.chars().any(char::is_control),
        "invalid_database_name"
    );
    let path = file(store, "db-history", connection)?;
    let mut map: BTreeMap<String, Vec<String>> = read_map(&path);
    let list = map.entry(database.to_string()).or_default();
    list.retain(|s| s != text);
    list.insert(0, text.to_string());
    list.truncate(LIMIT);
    write_private(&path, &serde_json::to_string(&map)?)?;
    Ok(true)
}

/// Forgets a database's history, or the whole connection's when `database` is None.
pub fn clear(store: &Store, connection: &str, database: Option<&str>) -> Result<()> {
    let path = file(store, "db-history", connection)?;
    match database {
        None => {
            let _ = std::fs::remove_file(&path);
        }
        Some(database) => {
            let mut map: BTreeMap<String, Vec<String>> = read_map(&path);
            map.remove(database);
            write_private(&path, &serde_json::to_string(&map)?)?;
        }
    }
    Ok(())
}

/// Forgets everything kept for a connection (its history and its query tabs): it was deleted.
pub fn forget(store: &Store, connection: &str) -> Result<()> {
    for folder in ["db-history", "db-tabs"] {
        let path = file(store, folder, connection)?;
        match std::fs::remove_file(&path) {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => return Err(error.into()),
            _ => {}
        }
    }
    Ok(())
}

/// Forgets the history and the query tabs of every connection («Eliminar datos» of the tool).
pub fn forget_all(store: &Store) -> Result<()> {
    for folder in ["db-history", "db-tabs"] {
        let path = store.root().join(folder);
        if std::fs::symlink_metadata(&path).is_ok() {
            std::fs::remove_dir_all(&path)?;
        }
    }
    Ok(())
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct QueryTab {
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub database: String,
    #[serde(default)]
    pub sql: String,
}

pub fn tabs(store: &Store, connection: &str) -> Result<Vec<QueryTab>> {
    Ok(read_map(&file(store, "db-tabs", connection)?))
}

/// Saves a connection's query tabs. A tab whose text carries a password is kept without its text.
pub fn save_tabs(store: &Store, connection: &str, tabs: Vec<QueryTab>) -> Result<Vec<QueryTab>> {
    ensure!(tabs.len() <= 30, "invalid_request");
    let tabs: Vec<QueryTab> = tabs
        .into_iter()
        .map(|mut t| {
            t.title = t
                .title
                .chars()
                .filter(|c| !c.is_control())
                .take(60)
                .collect();
            t.id =
                t.id.chars()
                    .filter(|c| c.is_ascii_alphanumeric() || *c == '-')
                    .take(40)
                    .collect();
            if t.sql.len() > MAX_ENTRY || sql::has_secret(&t.sql) {
                t.sql.clear();
            }
            t
        })
        .collect();
    write_private(
        &file(store, "db-tabs", connection)?,
        &serde_json::to_string(&tabs)?,
    )?;
    Ok(tabs)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn history_never_keeps_passwords_and_lives_in_a_private_file() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::new(temp.path().join("store")).unwrap();
        assert!(add(&store, "remota", "app", "SELECT * FROM users").unwrap());
        for secret in [
            "CREATE USER 'app'@'%' IDENTIFIED BY 'Secreta123!'",
            "ALTER USER app WITH PASSWORD 'x'",
            "create role lector login password 'abc'",
            "SET PASSWORD FOR 'root'@'localhost' = 'nueva'",
            "select 1; alter user root identified with mysql_native_password by 'x'",
            "CHANGE REPLICATION SOURCE TO SOURCE_PASSWORD = 'x'",
            "AUTH default s3creta",
            "ACL SETUSER app on >s3creta ~* +@all",
            "CONFIG SET requirepass s3creta",
            "UPDATE mysql.user SET authentication_string = 'x' WHERE User = 'root'",
        ] {
            assert!(!add(&store, "remota", "app", secret).unwrap(), "{secret}");
        }
        assert!(
            add(
                &store,
                "remota",
                "app",
                "SELECT password_hash FROM accounts"
            )
            .unwrap(),
            "reading a column named password is fine"
        );
        assert!(
            add(
                &store,
                "remota",
                "app",
                "UPDATE accounts SET password = 'x' WHERE id = 1"
            )
            .unwrap(),
            "app tables are data, not accounts"
        );
        let saved = list(&store, "remota", "app").unwrap();
        assert_eq!(saved.len(), 3);
        assert_eq!(
            saved.last().map(String::as_str),
            Some("SELECT * FROM users")
        );
        let path = store.directory("db-history").unwrap().join("remota.json");
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(!text.contains("Secreta123") && !text.contains("s3creta"));
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        // Moving to the top, the limit, and the other databases untouched.
        add(&store, "remota", "app", "SELECT * FROM users").unwrap();
        assert_eq!(
            list(&store, "remota", "app").unwrap()[0],
            "SELECT * FROM users"
        );
        for i in 0..150 {
            add(&store, "remota", "otra", &format!("SELECT {i}")).unwrap();
        }
        assert_eq!(list(&store, "remota", "otra").unwrap().len(), LIMIT);
        clear(&store, "remota", Some("otra")).unwrap();
        assert!(list(&store, "remota", "otra").unwrap().is_empty());
        assert_eq!(list(&store, "remota", "app").unwrap().len(), 3);
        assert!(add(&store, "../x", "app", "select 1").is_err());
    }

    /// Deleting a connection forgets its history and tabs; «Eliminar datos» of the tool forgets
    /// every connection's, Stack's own included. Other connections keep theirs until then.
    #[test]
    fn a_deleted_connection_takes_its_history_and_tabs_along() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::new(temp.path().join("store")).unwrap();
        let saved: crate::db::client::Connection = serde_json::from_value(serde_json::json!({
            "id": "remota", "name": "Remota", "kind": "mysql", "host": "db.example.com",
            "port": 3306, "user": "app", "database": "app"
        }))
        .unwrap();
        crate::db::client::save(&store, saved).unwrap();
        for connection in ["remota", "otra", "stack-mysql"] {
            add(&store, connection, "app", "select 1").unwrap();
            save_tabs(
                &store,
                connection,
                vec![QueryTab {
                    id: "a".into(),
                    title: "Consulta 1".into(),
                    database: "app".into(),
                    sql: "select 1".into(),
                }],
            )
            .unwrap();
        }
        let exists = |folder: &str, connection: &str| {
            store
                .root()
                .join(folder)
                .join(format!("{connection}.json"))
                .exists()
        };
        crate::db::client::delete(&store, "remota").unwrap();
        assert!(!exists("db-history", "remota") && !exists("db-tabs", "remota"));
        assert!(exists("db-history", "otra") && exists("db-tabs", "stack-mysql"));
        crate::app::plugins::remove(&store, "database-client", true, true).unwrap();
        assert!(!store.root().join("db-history").exists());
        assert!(!store.root().join("db-tabs").exists());
    }

    #[test]
    fn tabs_drop_text_with_passwords() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::new(temp.path().join("store")).unwrap();
        let saved = save_tabs(
            &store,
            "stack-mysql",
            vec![
                QueryTab {
                    id: "a".into(),
                    title: "Consulta 1".into(),
                    database: "app".into(),
                    sql: "select 1".into(),
                },
                QueryTab {
                    id: "b".into(),
                    title: "Usuarios".into(),
                    database: "".into(),
                    sql: "CREATE USER x IDENTIFIED BY 'y'".into(),
                },
            ],
        )
        .unwrap();
        assert_eq!(saved[1].sql, "");
        assert_eq!(tabs(&store, "stack-mysql").unwrap(), saved);
    }
}
