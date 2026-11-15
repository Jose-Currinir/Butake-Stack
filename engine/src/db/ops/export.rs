//! Exporting a grid to a file.

use super::*;

/// Streams a table (with the grid's filters and order) or a query's rows into a CSV, JSON or SQL
/// file the user chose. Never more than one row in memory.
pub fn export(store: &Store, target: &Target, request: &Value) -> Result<Value> {
    let d = dialect(target)?;
    let format = crate::db::export::Format::parse(text(request, "format"))?;
    let path = destination(text(request, "path"))?;
    let (database, schema, table) = (
        text(request, "database"),
        text(request, "schema"),
        text(request, "table"),
    );
    let (db, select, insert_into, fallback) = match text(request, "source") {
        "table" => {
            let columns = columns(target, database, schema, table)?;
            let names: Vec<String> = columns
                .iter()
                .filter_map(|c| c["name"].as_str().map(str::to_string))
                .collect();
            let from = table_ref(d, database, schema, table);
            let select = format!(
                "SELECT * FROM {from}{}{}",
                where_clause(d, &request["filters"], &names)?,
                order_clause(d, request, &names, &columns)?
            );
            let insert_into = match d {
                // A dump is restored into whichever database the user picks: no database prefix.
                Dialect::MySql => ident(d, table),
                _ => from,
            };
            (
                if d == Dialect::MySql { "" } else { database },
                select,
                insert_into,
                names,
            )
        }
        "query" => {
            let sql = text(request, "sql");
            ensure!(sql.len() <= 512 * 1024, "request_too_large");
            let statements = sql::split(sql, d);
            ensure!(statements.len() == 1, "invalid_request");
            ensure!(
                sql::is_read_only(&statements[0], d)
                    && matches!(
                        sql::first_word(&statements[0], d).as_str(),
                        "select" | "with" | "values" | "table"
                    ),
                "invalid_request"
            );
            let name = if table.is_empty() { "resultado" } else { table };
            (database, statements[0].clone(), ident(d, name), vec![])
        }
        _ => bail!("invalid_request"),
    };
    let mut progress = Progress::new(store, text(request, "progress"), 0)?.rows();
    let rows = crate::db::export::export(
        target,
        db,
        &select,
        format,
        &path,
        &insert_into,
        fallback,
        &mut |n| progress.report(n, table, false),
    )?;
    progress.report(rows, table, true);
    let size = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
    Ok(json!({"path": path, "rows": rows, "size": size}))
}
