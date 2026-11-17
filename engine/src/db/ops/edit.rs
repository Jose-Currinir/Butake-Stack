//! Running a query and editing rows in the grid.

use super::*;

/// Runs what the editor sends (the selection or the whole script). Statements that may change
/// anything only run with `confirmed`; otherwise the answer lists them for the dialog.
pub fn run(target: &Target, request: &Value) -> Result<Value> {
    let sql = text(request, "sql");
    ensure!(sql.len() <= 512 * 1024, "request_too_large");
    if target.connection.is_redis() {
        let writes: Vec<String> = sql
            .lines()
            .map(str::trim)
            .filter(|l| !l.is_empty() && !l.starts_with('#') && !client::redis_read_only(l))
            .map(str::to_string)
            .collect();
        if !writes.is_empty() {
            writable(target)?;
        }
        if !writes.is_empty() && !confirmed(target, request) {
            return Ok(json!({"needsConfirmation": true, "statements": writes}));
        }
        return Ok(serde_json::to_value(client::redis_console(
            target,
            text(request, "database"),
            sql,
        )?)?);
    }
    let d = dialect(target)?;
    let statements = sql::split(sql, d);
    ensure!(!statements.is_empty(), "empty_query");
    let writes: Vec<&String> = statements
        .iter()
        .filter(|s| !sql::is_read_only(s, d))
        .collect();
    // A read-only connection refuses anything that may write before it reaches the server (whose
    // read-only session is the second wall).
    if !writes.is_empty() {
        writable(target)?;
    }
    let database = text(request, "database");
    // Manual transaction: everything (reads too) runs inside it, never outside.
    if request["transaction"] == true {
        if !writes.is_empty() && !confirmed(target, request) {
            return Ok(json!({"needsConfirmation": true, "statements": writes}));
        }
        return Ok(serde_json::to_value(crate::db::session::in_transaction(
            target,
            database,
            &statements,
            MAX_ROWS,
        )?)?);
    }
    if !writes.is_empty() && !confirmed(target, request) {
        return Ok(json!({"needsConfirmation": true, "statements": writes}));
    }
    // Reads reuse the connection's open session; anything that writes runs on its own client and
    // stops at the first error.
    let output = if writes.is_empty() {
        crate::db::session::read(target, text(request, "database"), &statements, MAX_ROWS)?
    } else {
        run_sql(target, text(request, "database"), &statements, MAX_ROWS)?
    };
    Ok(serde_json::to_value(output)?)
}

fn key_condition(d: Dialect, key: &Map<String, Value>, readable: bool) -> Result<String> {
    ensure!(!key.is_empty(), "needs_primary_key");
    Ok(key
        .iter()
        .map(|(column, value)| match value {
            Value::Null => format!("{} IS NULL", ident(d, column)),
            v => format!(
                "{} = {}",
                ident(d, column),
                if readable { shown(v) } else { sql_value(d, v) }
            ),
        })
        .collect::<Vec<_>>()
        .join(" AND "))
}

/// Changes from the grid (edited cells, new rows, deleted rows) as one transaction. Rows are found
/// by their full primary key. The batch commits as a whole: the answer says how many rows each
/// statement changed (`affected`) and which ones did not change exactly one (`unexpected`, by
/// position), so the app can warn; the engine does not undo the others.
pub fn edit(target: &Target, request: &Value) -> Result<Value> {
    let d = dialect(target)?;
    let (database, schema, table) = (
        text(request, "database"),
        text(request, "schema"),
        text(request, "table"),
    );
    let columns = columns(target, database, schema, table)?;
    let key = primary_key(&columns);
    ensure!(!key.is_empty(), "needs_primary_key");
    let names: Vec<String> = columns
        .iter()
        .filter_map(|c| c["name"].as_str().map(str::to_string))
        .collect();
    let known = |m: &Map<String, Value>| m.keys().all(|k| names.contains(k));
    let from = table_ref(d, database, schema, table);
    let mut run = vec![];
    let mut readable = vec![];
    for change in request["updates"].as_array().into_iter().flatten() {
        let (Some(k), Some(values)) = (change["key"].as_object(), change["values"].as_object())
        else {
            bail!("invalid_request")
        };
        ensure!(
            known(k)
                && known(values)
                && !values.is_empty()
                && key.iter().all(|c| k.contains_key(c)),
            "invalid_request"
        );
        let set = |readable: bool| {
            values
                .iter()
                .map(|(c, v)| {
                    format!(
                        "{} = {}",
                        ident(d, c),
                        if readable { shown(v) } else { sql_value(d, v) }
                    )
                })
                .collect::<Vec<_>>()
                .join(", ")
        };
        run.push(format!(
            "UPDATE {from} SET {} WHERE {}",
            set(false),
            key_condition(d, k, false)?
        ));
        readable.push(format!(
            "UPDATE {from} SET {} WHERE {}",
            set(true),
            key_condition(d, k, true)?
        ));
    }
    for row in request["inserts"].as_array().into_iter().flatten() {
        let Some(values) = row.as_object() else {
            bail!("invalid_request")
        };
        ensure!(known(values), "invalid_request");
        let cols = values
            .keys()
            .map(|c| ident(d, c))
            .collect::<Vec<_>>()
            .join(", ");
        let make = |readable: bool| {
            values
                .values()
                .map(|v| if readable { shown(v) } else { sql_value(d, v) })
                .collect::<Vec<_>>()
                .join(", ")
        };
        if values.is_empty() {
            run.push(format!("INSERT INTO {from} DEFAULT VALUES"));
            readable.push(run.last().cloned().unwrap_or_default());
        } else {
            run.push(format!(
                "INSERT INTO {from} ({cols}) VALUES ({})",
                make(false)
            ));
            readable.push(format!(
                "INSERT INTO {from} ({cols}) VALUES ({})",
                make(true)
            ));
        }
    }
    for k in request["deletes"].as_array().into_iter().flatten() {
        let Some(k) = k.as_object() else {
            bail!("invalid_request")
        };
        ensure!(
            known(k) && key.iter().all(|c| k.contains_key(c)),
            "invalid_request"
        );
        run.push(format!(
            "DELETE FROM {from} WHERE {}",
            key_condition(d, k, false)?
        ));
        readable.push(format!(
            "DELETE FROM {from} WHERE {}",
            key_condition(d, k, true)?
        ));
    }
    ensure!(!run.is_empty(), "invalid_request");
    if !confirmed(target, request) {
        return Ok(json!({"needsConfirmation": true, "statements": readable}));
    }
    let begin = if d == Dialect::MySql {
        "START TRANSACTION"
    } else {
        "BEGIN"
    };
    let mut statements = vec![begin.to_string()];
    statements.extend(run);
    statements.push("COMMIT".into());
    let db = if d == Dialect::MySql { "" } else { database };
    let out = run_sql(target, db, &statements, 10)?;
    if let Some(error) = out.error {
        return Err(client::db_error(&error));
    }
    // Rows touched per statement, as the server reports them (the app shows when none matched).
    let changed: Vec<i64> = out
        .results
        .iter()
        .skip(1)
        .take(statements.len() - 2)
        .map(|r| r.affected.unwrap_or(-1))
        .collect();
    let unexpected: Vec<usize> = unexpected_rows(&changed);
    Ok(json!({"applied": changed.len(), "affected": changed, "unexpected": unexpected}))
}

/// Positions of the statements that did not change exactly one row (a key that changed under the
/// user, or a count the server did not report).
fn unexpected_rows(affected: &[i64]) -> Vec<usize> {
    affected
        .iter()
        .enumerate()
        .filter(|(_, rows)| **rows != 1)
        .map(|(index, _)| index)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn edits_that_did_not_change_one_row_are_reported() {
        assert_eq!(unexpected_rows(&[1, 0, 1, -1, 2]), [1, 3, 4]);
        assert!(unexpected_rows(&[1, 1]).is_empty());
    }

    #[test]
    fn readable_values_for_the_confirmation() {
        assert_eq!(shown(&json!("it's")), "'it''s'");
        assert_eq!(shown(&Value::Null), "NULL");
        assert_eq!(
            key_condition(
                Dialect::MySql,
                json!({"id": "7"}).as_object().unwrap(),
                true
            )
            .unwrap(),
            "`id` = '7'"
        );
    }
}
