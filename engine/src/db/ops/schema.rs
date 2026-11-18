//! The schema of a database and structure changes (DDL).

use super::*;

/// Tables with their columns and the foreign keys between them, for completion and the diagram.
pub fn schema(target: &Target, database: &str) -> Result<Value> {
    let d = dialect(target)?;
    let (db, statements): (&str, Vec<String>) = match d {
        Dialect::MySql => ("", vec![
            format!("SELECT '', TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, COLUMN_KEY FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = {} ORDER BY TABLE_NAME, ORDINAL_POSITION", literal(d, database)),
            format!("SELECT CONSTRAINT_NAME, '', TABLE_NAME, COLUMN_NAME, '', REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA = {} AND REFERENCED_TABLE_NAME IS NOT NULL AND REFERENCED_TABLE_SCHEMA = TABLE_SCHEMA ORDER BY TABLE_NAME, CONSTRAINT_NAME, ORDINAL_POSITION", literal(d, database)),
        ]),
        Dialect::Postgres => (database, vec![
            "SELECT n.nspname, c.relname, a.attname, format_type(a.atttypid, a.atttypmod), \
             CASE WHEN EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.oid AND i.indisprimary AND a.attnum = ANY(i.indkey)) THEN 'PRI' ELSE '' END \
             FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace JOIN pg_attribute a ON a.attrelid = c.oid \
             WHERE c.relkind IN ('r', 'p', 'v', 'm') AND a.attnum > 0 AND NOT a.attisdropped AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema' \
             ORDER BY 1, 2, a.attnum LIMIT 50000".into(),
            "SELECT con.conname, n.nspname, c.relname, a.attname, rn.nspname, rc.relname, ra.attname FROM pg_constraint con \
             JOIN pg_class c ON c.oid = con.conrelid JOIN pg_namespace n ON n.oid = c.relnamespace \
             JOIN pg_class rc ON rc.oid = con.confrelid JOIN pg_namespace rn ON rn.oid = rc.relnamespace \
             CROSS JOIN LATERAL unnest(con.conkey, con.confkey) WITH ORDINALITY AS k(col, refcol, ord) \
             JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = k.col JOIN pg_attribute ra ON ra.attrelid = rc.oid AND ra.attnum = k.refcol \
             WHERE con.contype = 'f' AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema' ORDER BY 2, 3, 1, k.ord".into(),
        ]),
        Dialect::Sqlite => (database, vec![
            "SELECT '', m.name, p.name, p.type, CASE WHEN p.pk > 0 THEN 'PRI' ELSE '' END FROM sqlite_master m JOIN pragma_table_info(m.name) p \
             WHERE m.type IN ('table', 'view') AND m.name NOT LIKE 'sqlite_%' ORDER BY m.name, p.cid".into(),
            "SELECT 'fk_' || m.name || '_' || f.id, '', m.name, f.\"from\", '', f.\"table\", f.\"to\" FROM sqlite_master m JOIN pragma_foreign_key_list(m.name) f \
             WHERE m.type = 'table' ORDER BY m.name, f.id, f.seq".into(),
        ]),
    };
    let out = crate::db::session::read(target, db, &statements, 50_000)?;
    if let Some(error) = out.error {
        return Err(client::db_error(&error));
    }
    let mut results = out.results.into_iter();
    let columns = results.next().unwrap_or_default();
    let keys = results.next().unwrap_or_default();
    let mut tables: Vec<Value> = vec![];
    for row in &columns.rows {
        let (schema, table) = (cell(row, 0), cell(row, 1));
        let column = json!({"name": cell(row, 2), "type": cell(row, 3), "key": cell(row, 4)});
        match tables.last_mut() {
            Some(last) if last["schema"] == schema && last["name"] == table => {
                if let Some(list) = last["columns"].as_array_mut() {
                    list.push(column);
                }
            }
            _ => tables.push(json!({"schema": schema, "name": table, "columns": [column]})),
        }
    }
    let mut foreign: Vec<Value> = vec![];
    for row in &keys.rows {
        let (name, schema, table) = (cell(row, 0), cell(row, 1), cell(row, 2));
        match foreign.last_mut() {
            Some(last) if last["name"] == name && last["schema"] == schema && last["table"] == table => {
                if let Some(list) = last["columns"].as_array_mut() {
                    list.push(cell(row, 3));
                }
                if let Some(list) = last["refColumns"].as_array_mut() {
                    list.push(cell(row, 6));
                }
            }
            _ => foreign.push(json!({"name": name, "schema": schema, "table": table, "columns": [cell(row, 3)], "refSchema": cell(row, 4), "refTable": cell(row, 5), "refColumns": [cell(row, 6)]})),
        }
    }
    Ok(json!({"tables": tables, "foreignKeys": foreign}))
}

fn string_list(value: &Value) -> Vec<String> {
    value
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|v| v.as_str().map(str::to_string))
        .collect()
}

/// A structure change from the client's forms. The first answer is the SQL it would run (the
/// preview); dropping a table or a column also needs its name typed again.
pub fn ddl(target: &Target, request: &Value) -> Result<Value> {
    let d = dialect(target)?;
    let (database, schema, table) = (
        text(request, "database"),
        text(request, "schema"),
        text(request, "table"),
    );
    let table_name = || -> Result<String> {
        crate::db::ddl::valid_name(table)?;
        Ok(table_ref(d, database, schema, table))
    };
    let mut typed: Option<&str> = None;
    let statements = match text(request, "action") {
        "createTable" => {
            let columns: Vec<crate::db::ddl::ColumnSpec> = request["columns"]
                .as_array()
                .into_iter()
                .flatten()
                .map(crate::db::ddl::ColumnSpec::from_json)
                .collect::<Result<_>>()?;
            crate::db::ddl::create_table(d, &table_name()?, &columns)?
        }
        "addColumn" => crate::db::ddl::add_column(
            d,
            &table_name()?,
            &crate::db::ddl::ColumnSpec::from_json(&request["column"])?,
        )?,
        "alterColumn" => crate::db::ddl::alter_column(
            d,
            &table_name()?,
            &crate::db::ddl::ColumnSpec::from_json(&request["original"])?,
            &crate::db::ddl::ColumnSpec::from_json(&request["column"])?,
        )?,
        "dropColumn" => {
            typed = Some(text(request, "name"));
            crate::db::ddl::drop_column(d, &table_name()?, text(request, "name"))?
        }
        "createIndex" => crate::db::ddl::create_index(
            d,
            &table_name()?,
            text(request, "name"),
            &string_list(&request["columns"]),
            request["unique"] == true,
        )?,
        "dropIndex" => crate::db::ddl::drop_index(
            d,
            &table_name()?,
            if schema.is_empty() { "public" } else { schema },
            text(request, "name"),
        )?,
        "addForeignKey" => {
            let ref_table = text(request, "refTable");
            crate::db::ddl::valid_name(ref_table)?;
            let ref_schema = if text(request, "refSchema").is_empty() {
                schema
            } else {
                text(request, "refSchema")
            };
            crate::db::ddl::add_foreign_key(
                d,
                &table_name()?,
                text(request, "name"),
                &string_list(&request["columns"]),
                &table_ref(d, database, ref_schema, ref_table),
                &string_list(&request["refColumns"]),
                text(request, "onDelete"),
                text(request, "onUpdate"),
            )?
        }
        "dropForeignKey" => {
            crate::db::ddl::drop_foreign_key(d, &table_name()?, text(request, "name"))?
        }
        "renameTable" => {
            crate::db::ddl::rename_table(d, &table_name()?, text(request, "newName"), database)?
        }
        "dropTable" => {
            typed = Some(table);
            crate::db::ddl::drop_table(&table_name()?, request["view"] == true)
        }
        _ => bail!("invalid_ddl"),
    };
    if !confirmed(target, request) || typed.is_some_and(|name| text(request, "typedName") != name) {
        return Ok(json!({"needsConfirmation": true, "statements": statements}));
    }
    // PostgreSQL and SQLite change structure inside a transaction: all of it or nothing.
    let mut run: Vec<String> = vec![];
    let atomic = d != Dialect::MySql && statements.len() > 1;
    if atomic {
        run.push("BEGIN".into());
    }
    run.extend(statements);
    if atomic {
        run.push("COMMIT".into());
    }
    let out = run_sql(
        target,
        if d == Dialect::MySql { "" } else { database },
        &run,
        10,
    )?;
    if let Some(error) = out.error {
        return Err(client::db_error(&error));
    }
    Ok(serde_json::to_value(out)?)
}
