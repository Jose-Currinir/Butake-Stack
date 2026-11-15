//! Importing a CSV file into a table.

use super::*;

/// Imports a CSV file into an existing table: the first row names the columns (they must exist);
/// rows go in batches of INSERTs inside one transaction. Unquoted empty fields are NULL.
pub fn import_csv(store: &Store, target: &Target, request: &Value) -> Result<Value> {
    let d = dialect(target)?;
    let (database, schema, table) = (
        text(request, "database"),
        text(request, "schema"),
        text(request, "table"),
    );
    let source = PathBuf::from(text(request, "path"));
    ensure!(source.is_absolute() && source.is_file(), "invalid_file");
    ensure!(
        std::fs::metadata(&source)?.len() <= 200 * 1024 * 1024,
        "file_too_large"
    );
    let content =
        String::from_utf8(std::fs::read(&source)?).map_err(|_| anyhow::anyhow!("invalid_file"))?;
    let content = content.strip_prefix('\u{feff}').unwrap_or(&content);
    let mut rows = sql::parse_csv(content).into_iter();
    let header: Vec<String> = rows
        .next()
        .ok_or_else(|| anyhow::anyhow!("invalid_file"))?
        .into_iter()
        .map(|(n, _)| n.trim().to_string())
        .collect();
    let names: Vec<String> = columns(target, database, schema, table)?
        .iter()
        .filter_map(|c| c["name"].as_str().map(str::to_string))
        .collect();
    ensure!(
        !header.is_empty() && header.iter().all(|h| names.contains(h)),
        "csv_columns_mismatch"
    );
    let rows: Vec<Vec<(String, bool)>> = rows
        .filter(|r| !(r.len() == 1 && r[0].0.is_empty()))
        .collect();
    ensure!(rows.iter().all(|r| r.len() == header.len()), "invalid_file");
    let from = table_ref(d, database, schema, table);
    if !confirmed(target, request) {
        return Ok(
            json!({"needsConfirmation": true, "statements": [format!("INSERT INTO {from} ({}) … {} filas", header.join(", "), rows.len())]}),
        );
    }
    let mut progress = Progress::new(store, text(request, "progress"), rows.len() as u64)?.rows();
    let cols = header
        .iter()
        .map(|h| ident(d, h))
        .collect::<Vec<_>>()
        .join(", ");
    let mut statements = vec![if d == Dialect::MySql {
        "START TRANSACTION".to_string()
    } else {
        "BEGIN".into()
    }];
    for chunk in rows.chunks(500) {
        let values: Vec<String> = chunk
            .iter()
            .map(|row| {
                format!(
                    "({})",
                    row.iter()
                        .map(|(v, quoted)| if v.is_empty() && !quoted {
                            "NULL".into()
                        } else {
                            literal(d, v)
                        })
                        .collect::<Vec<_>>()
                        .join(", ")
                )
            })
            .collect();
        statements.push(format!(
            "INSERT INTO {from} ({cols}) VALUES {}",
            values.join(", ")
        ));
    }
    statements.push("COMMIT".into());
    progress.report(0, table, true);
    let out = run_sql(
        target,
        if d == Dialect::MySql { "" } else { database },
        &statements,
        1,
    )?;
    progress.report(rows.len() as u64, table, true);
    if let Some(error) = out.error {
        return Err(client::db_error(&error));
    }
    Ok(json!({"rows": rows.len()}))
}
