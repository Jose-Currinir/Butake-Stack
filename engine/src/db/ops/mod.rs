//! Database client operations, one per request method: browse (databases, tables, rows,
//! structure), query, edit rows, administer (databases, users, processes) and back up / restore.
//! Every change to data, structure, users or the server needs `"confirmed": true`; without it the
//! request returns what would run so the app can show it first.
use crate::{
    core::fsutil::write_private,
    core::store::Store,
    db::client::{self, Connection, MAX_ROWS, Target, query, run_sql},
    db::sql::{self, Dialect, ident, literal},
};
use anyhow::{Result, bail, ensure};
use serde_json::{Map, Value, json};
use std::{
    io::{Read, Write},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{Duration, Instant},
};

mod admin;
mod dump;
mod edit;
mod explain;
mod export;
mod import;
mod objects;
mod redis;
mod restore;
mod schema;
mod terminal;
mod transfer;

use admin::*;
use dump::*;
use edit::*;
use explain::*;
use export::*;
use import::*;
use objects::*;
use redis::*;
use restore::*;
use schema::*;
use terminal::*;
use transfer::*;

const SYSTEM_DATABASES: &[&str] = &[
    "mysql",
    "information_schema",
    "performance_schema",
    "sys",
    "postgres",
    "template0",
    "template1",
];

fn text<'a>(request: &'a Value, key: &str) -> &'a str {
    request[key].as_str().unwrap_or("")
}

fn connect(store: &Store, request: &Value) -> Result<Target> {
    let connection = client::find(store, text(request, "connection"))?;
    client::target(
        store,
        connection,
        request["password"].as_str().map(str::to_string),
    )
}

fn dialect(target: &Target) -> Result<Dialect> {
    target
        .dialect()
        .ok_or_else(|| anyhow::anyhow!("invalid_connection"))
}

/// The user accepted the change; on a production connection, also typed its name again.
fn confirmed(target: &Target, request: &Value) -> bool {
    request["confirmed"] == true
        && (!target.connection.production
            || text(request, "typedConnection") == target.connection.name)
}

/// Changes only on connections that allow them: a read-only one refuses every write, whatever
/// the request says (the app hides those actions, the engine is the one that decides).
fn writable(target: &Target) -> Result<()> {
    ensure!(!target.connection.read_only, "read_only_connection");
    Ok(())
}

/// Readable SQL for the confirmation dialog (what runs uses `literal`, safe in every SQL mode).
fn shown(value: &Value) -> String {
    match value {
        Value::Null => "NULL".into(),
        Value::String(s) => format!("'{}'", s.replace('\'', "''")),
        other => other.to_string(),
    }
}

fn sql_value(dialect: Dialect, value: &Value) -> String {
    match value {
        Value::Null => "NULL".into(),
        Value::String(s) => literal(dialect, s),
        Value::Bool(b) => literal(dialect, if *b { "1" } else { "0" }),
        other => literal(dialect, &other.to_string()),
    }
}

fn table_ref(dialect: Dialect, database: &str, schema: &str, table: &str) -> String {
    match dialect {
        Dialect::MySql => format!("{}.{}", ident(dialect, database), ident(dialect, table)),
        Dialect::Postgres => format!(
            "{}.{}",
            ident(dialect, if schema.is_empty() { "public" } else { schema }),
            ident(dialect, table)
        ),
        Dialect::Sqlite => ident(dialect, table),
    }
}

fn cell(row: &[Option<String>], index: usize) -> Value {
    row.get(index)
        .cloned()
        .flatten()
        .map(Value::String)
        .unwrap_or(Value::Null)
}
fn number(row: &[Option<String>], index: usize) -> Value {
    row.get(index)
        .cloned()
        .flatten()
        .and_then(|v| v.parse::<f64>().ok())
        .map(|n| json!(n as i64))
        .unwrap_or(Value::Null)
}

fn valid_name(name: &str) -> Result<()> {
    ensure!(
        !name.is_empty()
            && name.len() <= 63
            && !name.starts_with('-')
            && name
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'_' | b'-' | b'$')),
        "invalid_database_name"
    );
    Ok(())
}

/// Methods that change something: refused on a read-only connection before anything else.
const WRITE_METHODS: &[&str] = &[
    "dbEdit",
    "dbCreateDatabase",
    "dbDropDatabase",
    "dbCreateUser",
    "dbDropUser",
    "dbKill",
    "dbRedisDelete",
    "dbRestore",
    "dbImportCsv",
    "dbSetRootPassword",
    "dbDdl",
    "dbTxBegin",
];

/// Request methods of the client (`db*`).
/// Files with a password that a request leaves behind when the engine is stopped before it can
/// clean up (`Secret::drop` does not run on SIGTERM): the MySQL options file of a client and the
/// terminal script. Both are read by the client within seconds, so old ones are only leftovers.
fn sweep_leftovers(store: &Store) {
    let Ok(run) = store.directory("run") else {
        return;
    };
    sweep_older_than(&run, Duration::from_secs(30 * 60));
}

fn sweep_older_than(run: &Path, age: Duration) {
    for entry in std::fs::read_dir(run).into_iter().flatten().flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        let ours = (name.starts_with("client-") && name.ends_with(".cnf"))
            || (name.starts_with("terminal-") && name.ends_with(".command"));
        let old = entry
            .metadata()
            .ok()
            .filter(|meta| meta.is_file())
            .and_then(|meta| meta.modified().ok())
            .and_then(|time| time.elapsed().ok())
            .is_some_and(|elapsed| elapsed >= age);
        if ours && old {
            let _ = std::fs::remove_file(entry.path());
        }
    }
}

pub fn dispatch(store: &Store, method: &str, request: &Value) -> Result<Value> {
    sweep_leftovers(store);
    match method {
        "dbConnections" => Ok(serde_json::to_value(client::list(store)?)?),
        "dbHistory" => Ok(json!(crate::db::history::list(
            store,
            text(request, "connection"),
            text(request, "database")
        )?)),
        "dbHistoryAdd" => Ok(json!(crate::db::history::add(
            store,
            text(request, "connection"),
            text(request, "database"),
            text(request, "sql")
        )?)),
        "dbHistoryClear" => {
            crate::db::history::clear(
                store,
                text(request, "connection"),
                request["database"].as_str(),
            )?;
            Ok(json!(true))
        }
        "dbQueryTabs" => Ok(serde_json::to_value(crate::db::history::tabs(
            store,
            text(request, "connection"),
        )?)?),
        "dbSaveQueryTabs" => {
            let tabs: Vec<crate::db::history::QueryTab> =
                serde_json::from_value(request["tabs"].clone())
                    .map_err(|_| anyhow::anyhow!("invalid_request"))?;
            Ok(serde_json::to_value(crate::db::history::save_tabs(
                store,
                text(request, "connection"),
                tabs,
            )?)?)
        }
        "dbSaveConnection" => Ok(serde_json::to_value(client::save(
            store,
            serde_json::from_value::<Connection>(request["connection"].clone())
                .map_err(|_| anyhow::anyhow!("invalid_connection"))?,
        )?)?),
        "dbDeleteConnection" => {
            client::delete(store, text(request, "connection"))?;
            Ok(json!(true))
        }
        "dbDisconnect" => {
            crate::db::session::close(store, text(request, "connection"));
            client::close_tunnel(store, text(request, "connection"));
            Ok(json!(true))
        }
        // When the app quits: every session and tunnel of the client.
        "dbDisconnectAll" => {
            let mut ids = crate::db::session::connections(store);
            ids.extend(client::saved(store)?.into_iter().map(|c| c.id));
            ids.sort();
            ids.dedup();
            for id in &ids {
                crate::db::session::close(store, id);
                client::close_tunnel(store, id);
            }
            Ok(json!(ids.len()))
        }
        "dbSshFingerprints" => {
            let port = request["port"]
                .as_u64()
                .and_then(|p| u16::try_from(p).ok())
                .unwrap_or(22);
            Ok(json!(
                crate::ssh::common::ssh_fingerprints(text(request, "host"), port)?.0
            ))
        }
        "dbSshTrust" => {
            let port = request["port"]
                .as_u64()
                .and_then(|p| u16::try_from(p).ok())
                .unwrap_or(22);
            ensure!(request["confirmed"] == true, "confirmation_required");
            let seen: Vec<String> =
                serde_json::from_value(request["fingerprints"].clone()).unwrap_or_default();
            crate::ssh::common::ssh_trust(store, text(request, "host"), port, &seen)?;
            Ok(json!(true))
        }
        _ => {
            let target = connect(store, request)?;
            if WRITE_METHODS.contains(&method) {
                writable(&target)?;
            }
            match method {
                "dbTest" => {
                    if target.connection.is_redis() {
                        let info = client::redis(&target, "", &["INFO".into(), "server".into()])?;
                        let version = info
                            .as_str()
                            .unwrap_or("")
                            .lines()
                            .find_map(|l| {
                                l.strip_prefix("redis_version:")
                                    .or_else(|| l.strip_prefix("valkey_version:"))
                            })
                            .unwrap_or("")
                            .to_string();
                        return Ok(json!({"version": version}));
                    }
                    let sql = match dialect(&target)? {
                        Dialect::Sqlite => "SELECT sqlite_version()",
                        _ => "SELECT version()",
                    };
                    let set = query(&target, "", sql)?;
                    Ok(
                        json!({"version": set.rows.first().and_then(|r| r[0].clone()).unwrap_or_default()}),
                    )
                }
                "dbDatabases" => databases(&target),
                "dbObjects" => objects(&target, text(request, "database")),
                "dbRows" => rows(&target, request),
                "dbStructure" => structure(&target, request),
                "dbRun" => run(&target, request),
                "dbEdit" => edit(&target, request),
                "dbCreateDatabase" => create_database(&target, request),
                "dbDropDatabase" => drop_database(&target, request),
                "dbUsers" => users(&target),
                "dbCreateUser" => create_user(&target, request),
                "dbDropUser" => drop_user(&target, request),
                "dbProcesses" => processes(&target),
                "dbKill" => kill(&target, request),
                "dbRedisKeys" => redis_keys(&target, request),
                "dbRedisValue" => redis_value(&target, request),
                "dbRedisDelete" => redis_delete(&target, request),
                "dbDump" => dump(store, &target, request),
                "dbRestore" => restore(store, &target, request),
                "dbImportCsv" => import_csv(store, &target, request),
                "dbTerminal" => {
                    // A Redis terminal cannot be held to reads; the SQL clients open read-only.
                    ensure!(
                        !(target.connection.read_only && target.connection.is_redis()),
                        "read_only_connection"
                    );
                    terminal(store, &target, request)
                }
                "dbExport" => export(store, &target, request),
                "dbExplain" => explain(&target, request),
                "dbSchema" => schema(&target, text(request, "database")),
                "dbDdl" => ddl(&target, request),
                "dbTxBegin" => {
                    crate::db::session::begin(&target, text(request, "database"))?;
                    Ok(json!(true))
                }
                "dbTxCommit" => Ok(serde_json::to_value(crate::db::session::finish(
                    &target,
                    text(request, "database"),
                    true,
                )?)?),
                "dbTxRollback" => Ok(serde_json::to_value(crate::db::session::finish(
                    &target,
                    text(request, "database"),
                    false,
                )?)?),
                "dbTxStatus" => Ok(json!(crate::db::session::transaction_open(
                    &target,
                    text(request, "database")
                ))),
                "dbSetRootPassword" => set_root_password(&target, request),
                _ => bail!("unknown_method"),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A SQLite file with one table, and a connection to it saved in a temporary store.
    fn sqlite_store(read_only: bool, production: bool) -> (tempfile::TempDir, Store, PathBuf) {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::new(temp.path().join("store")).unwrap();
        let file = temp.path().join("qa.sqlite");
        let mut sqlite = Command::new("/usr/bin/sqlite3")
            .arg(&file)
            .stdin(Stdio::piped())
            .spawn()
            .unwrap();
        sqlite.stdin.take().unwrap().write_all(b"CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT); INSERT INTO t VALUES (1, 'uno'), (2, 'dos'), (3, NULL);").unwrap();
        assert!(sqlite.wait().unwrap().success());
        let connection = Connection {
            id: "qa".into(),
            name: "QA local".into(),
            kind: "sqlite".into(),
            host: String::new(),
            port: 0,
            user: String::new(),
            database: String::new(),
            path: Some(file.clone()),
            tls: "off".into(),
            ssh: None,
            builtin: false,
            has_password: false,
            stack_password: false,
            production,
            read_only,
        };
        client::save(&store, connection).unwrap();
        (temp, store, file)
    }

    fn count(store: &Store) -> i64 {
        let out = dispatch(
            store,
            "dbRun",
            &json!({"connection": "qa", "sql": "SELECT COUNT(*) FROM t"}),
        )
        .unwrap();
        out["results"][0]["rows"][0][0]
            .as_str()
            .unwrap()
            .parse()
            .unwrap()
    }

    #[test]
    fn leftover_password_files_are_swept_and_nothing_else() {
        let temp = tempfile::tempdir().unwrap();
        for name in [
            "client-aa.cnf",
            "terminal-bb.command",
            "keep.json",
            "client-x.txt",
        ] {
            std::fs::write(temp.path().join(name), "x").unwrap();
        }
        // Recent ones belong to a request that is running.
        sweep_older_than(temp.path(), Duration::from_secs(3600));
        assert_eq!(std::fs::read_dir(temp.path()).unwrap().count(), 4);
        sweep_older_than(temp.path(), Duration::ZERO);
        let mut left: Vec<String> = std::fs::read_dir(temp.path())
            .unwrap()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();
        left.sort();
        assert_eq!(left, ["client-x.txt", "keep.json"]);
    }

    #[test]
    fn read_only_connections_refuse_every_write() {
        let (_temp, store, file) = sqlite_store(true, false);
        // Reads work.
        assert_eq!(count(&store), 3);
        let refused = |method: &str, request: Value| {
            let mut request = request;
            request["connection"] = json!("qa");
            request["confirmed"] = json!(true);
            let error = dispatch(&store, method, &request).expect_err(method);
            assert_eq!(error.to_string(), "read_only_connection", "{method}");
        };
        refused("dbRun", json!({"sql": "INSERT INTO t VALUES (9, 'nueve')"}));
        refused("dbRun", json!({"sql": "select 1; delete from t"}));
        refused("dbEdit", json!({"table": "t", "deletes": [{"id": "1"}]}));
        refused(
            "dbDdl",
            json!({"action": "dropTable", "table": "t", "typedName": "t"}),
        );
        refused(
            "dbDdl",
            json!({"action": "addColumn", "table": "t", "column": {"name": "x", "type": "text"}}),
        );
        refused(
            "dbImportCsv",
            json!({"table": "t", "path": file.to_string_lossy()}),
        );
        refused("dbTxBegin", json!({}));
        assert_eq!(count(&store), 3);
        // The second wall: even a write the heuristic missed is refused by the client itself.
        let connection = client::find(&store, "qa").unwrap();
        let target = client::target(&store, connection, None).unwrap();
        let out = run_sql(
            &target,
            "",
            &["INSERT INTO t VALUES (10, 'diez')".to_string()],
            10,
        )
        .unwrap();
        assert!(
            out.error
                .unwrap_or_default()
                .to_lowercase()
                .contains("readonly")
        );
        assert_eq!(count(&store), 3);
    }

    #[test]
    fn production_connections_need_their_name_typed() {
        let (_temp, store, _file) = sqlite_store(false, true);
        let insert = json!({"connection": "qa", "sql": "INSERT INTO t VALUES (4, 'cuatro')", "confirmed": true});
        assert_eq!(
            dispatch(&store, "dbRun", &insert).unwrap()["needsConfirmation"],
            true,
            "confirmed alone is not enough"
        );
        let mut wrong = insert.clone();
        wrong["typedConnection"] = json!("qa local");
        assert_eq!(
            dispatch(&store, "dbRun", &wrong).unwrap()["needsConfirmation"],
            true
        );
        let mut typed = insert.clone();
        typed["typedConnection"] = json!("QA local");
        assert!(dispatch(&store, "dbRun", &typed).unwrap()["error"].is_null());
        assert_eq!(count(&store), 4);
        // Reads need nothing.
        assert!(
            dispatch(
                &store,
                "dbRun",
                &json!({"connection": "qa", "sql": "select 1"})
            )
            .unwrap()["needsConfirmation"]
                .is_null()
        );
    }

    #[test]
    fn structure_changes_show_their_sql_first() {
        let (_temp, store, _file) = sqlite_store(false, false);
        let create = json!({"connection": "qa", "action": "createTable", "table": "notas", "columns": [
            {"name": "id", "type": "integer", "primary": true, "autoIncrement": true, "nullable": false},
            {"name": "texto", "type": "text", "nullable": false, "default": "vacía"},
        ]});
        let preview = dispatch(&store, "dbDdl", &create).unwrap();
        assert_eq!(
            preview["statements"][0],
            "CREATE TABLE \"notas\" (\n    \"id\" integer PRIMARY KEY AUTOINCREMENT,\n    \"texto\" text NOT NULL DEFAULT 'vacía'\n)"
        );
        let mut run = create.clone();
        run["confirmed"] = json!(true);
        dispatch(&store, "dbDdl", &run).unwrap();
        let drop =
            json!({"connection": "qa", "action": "dropTable", "table": "notas", "confirmed": true});
        assert_eq!(
            dispatch(&store, "dbDdl", &drop).unwrap()["needsConfirmation"],
            true,
            "the name must be typed"
        );
        let schema = dispatch(&store, "dbSchema", &json!({"connection": "qa"})).unwrap();
        let tables: Vec<&str> = schema["tables"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["name"].as_str().unwrap())
            .collect();
        assert_eq!(tables, vec!["notas", "t"]);
        let plan = dispatch(
            &store,
            "dbExplain",
            &json!({"connection": "qa", "sql": "SELECT * FROM t WHERE id = 1"}),
        )
        .unwrap();
        assert!(plan["raw"].as_str().unwrap().contains("t"));
        assert!(
            dispatch(
                &store,
                "dbExplain",
                &json!({"connection": "qa", "sql": "(analyze) select 1"})
            )
            .is_err()
        );
        assert!(
            dispatch(
                &store,
                "dbExplain",
                &json!({"connection": "qa", "sql": "select 1; select 2"})
            )
            .is_err()
        );
    }

    #[test]
    fn exports_follow_the_grid_filters() {
        let (temp, store, _file) = sqlite_store(true, false);
        let path = temp.path().join("t.csv");
        let request = json!({"connection": "qa", "source": "table", "table": "t", "format": "csv", "path": path.to_string_lossy(),
                             "filters": [{"column": "id", "op": "gt", "value": "1"}], "sorts": [{"column": "id", "descending": true}]});
        let done = dispatch(&store, "dbExport", &request).unwrap();
        assert_eq!(done["rows"], 2);
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            "id,name\n3,\n2,dos\n"
        );
        let json_path = temp.path().join("q.json");
        let query = json!({"connection": "qa", "source": "query", "sql": "select id, name from t order by id", "format": "json", "path": json_path.to_string_lossy()});
        dispatch(&store, "dbExport", &query).unwrap();
        let value: Value =
            serde_json::from_str(&std::fs::read_to_string(&json_path).unwrap()).unwrap();
        assert_eq!(value[0]["name"], "uno");
        assert_eq!(value[2]["name"], Value::Null);
        let mut write = query.clone();
        write["sql"] = json!("delete from t");
        assert!(
            dispatch(&store, "dbExport", &write).is_err(),
            "only reads are exported"
        );
    }
}
