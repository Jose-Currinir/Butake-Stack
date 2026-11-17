//! Browsing: databases, tables, rows with filters and sorting, and the structure of a table.

use super::*;

/// Databases with their size and number of tables.
pub fn databases(target: &Target) -> Result<Value> {
    let d = dialect(target)?;
    let (database, sql) = match d {
        Dialect::MySql => (
            "",
            "SELECT s.SCHEMA_NAME, COALESCE(SUM(t.DATA_LENGTH + t.INDEX_LENGTH), 0), COUNT(t.TABLE_NAME) FROM information_schema.SCHEMATA s LEFT JOIN information_schema.TABLES t ON t.TABLE_SCHEMA = s.SCHEMA_NAME GROUP BY s.SCHEMA_NAME ORDER BY s.SCHEMA_NAME",
        ),
        Dialect::Postgres => (
            "",
            "SELECT datname, CASE WHEN has_database_privilege(datname, 'CONNECT') THEN pg_database_size(datname) END, NULL FROM pg_database WHERE NOT datistemplate AND datallowconn ORDER BY datname",
        ),
        Dialect::Sqlite => (
            "",
            "SELECT 'main', page_count * page_size, (SELECT COUNT(*) FROM sqlite_master WHERE type = 'table') FROM pragma_page_count(), pragma_page_size()",
        ),
    };
    let set = query(target, database, sql)?;
    Ok(json!(set.rows.iter().map(|r| {
        let name = r[0].clone().unwrap_or_default();
        json!({"name": name, "size": number(r, 1), "tables": number(r, 2), "system": SYSTEM_DATABASES.contains(&name.as_str()) && name != "postgres"})
    }).collect::<Vec<_>>()))
}

/// Tables and views of a database (every schema for PostgreSQL), with estimated rows and size.
pub fn objects(target: &Target, database: &str) -> Result<Value> {
    let d = dialect(target)?;
    let sql = match d {
        Dialect::MySql => format!("SELECT '', TABLE_NAME, TABLE_TYPE, TABLE_ROWS, COALESCE(DATA_LENGTH + INDEX_LENGTH, 0), COALESCE(ENGINE, '') FROM information_schema.TABLES WHERE TABLE_SCHEMA = {} ORDER BY TABLE_NAME", literal(d, database)),
        Dialect::Postgres => "SELECT n.nspname, c.relname, CASE c.relkind WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW' ELSE 'BASE TABLE' END, GREATEST(c.reltuples, 0)::bigint, pg_total_relation_size(c.oid), '' FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('r', 'p', 'v', 'm') AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema' ORDER BY 1, 2".into(),
        Dialect::Sqlite => "SELECT '', name, CASE type WHEN 'view' THEN 'VIEW' ELSE 'BASE TABLE' END, NULL, NULL, '' FROM sqlite_master WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%' ORDER BY name".into(),
    };
    let set = query(
        target,
        if d == Dialect::MySql { "" } else { database },
        &sql,
    )?;
    Ok(json!(set.rows.iter().map(|r| json!({
        "schema": cell(r, 0), "name": cell(r, 1), "view": r[2].as_deref().is_some_and(|t| t.contains("VIEW")),
        "rows": number(r, 3), "size": number(r, 4), "engine": cell(r, 5),
    })).collect::<Vec<_>>()))
}

/// Columns of a table: name, type, nullable, default, key, extra and comment.
pub(super) fn columns(
    target: &Target,
    database: &str,
    schema: &str,
    table: &str,
) -> Result<Vec<Value>> {
    Ok(columns_with(target, database, schema, table, vec![])?.0)
}

/// Columns plus other catalog reads in the same round trip (their results follow).
fn columns_with(
    target: &Target,
    database: &str,
    schema: &str,
    table: &str,
    extra: Vec<String>,
) -> Result<(Vec<Value>, Vec<crate::db::sql::ResultSet>)> {
    let d = dialect(target)?;
    let (db, sql) = match d {
        Dialect::MySql => (
            "",
            format!(
                "SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, COLUMN_KEY, EXTRA, COLUMN_COMMENT FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = {} AND TABLE_NAME = {} ORDER BY ORDINAL_POSITION",
                literal(d, database),
                literal(d, table)
            ),
        ),
        Dialect::Postgres => (
            database,
            format!(
                "SELECT a.attname, format_type(a.atttypid, a.atttypmod), CASE WHEN a.attnotnull THEN 'NO' ELSE 'YES' END, pg_get_expr(ad.adbin, ad.adrelid), \
             CASE WHEN EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.oid AND i.indisprimary AND a.attnum = ANY(i.indkey)) THEN 'PRI' ELSE '' END, \
             CASE WHEN a.attidentity <> '' THEN 'identity' ELSE '' END, col_description(c.oid, a.attnum) \
             FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace \
             LEFT JOIN pg_attrdef ad ON ad.adrelid = c.oid AND ad.adnum = a.attnum \
             WHERE n.nspname = {} AND c.relname = {} AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum",
                literal(d, if schema.is_empty() { "public" } else { schema }),
                literal(d, table)
            ),
        ),
        Dialect::Sqlite => (
            database,
            format!(
                "SELECT name, type, CASE WHEN \"notnull\" = 1 THEN 'NO' ELSE 'YES' END, dflt_value, CASE WHEN pk > 0 THEN 'PRI' ELSE '' END, '', '' FROM pragma_table_info({}) ORDER BY cid",
                literal(d, table)
            ),
        ),
    };
    let mut statements = vec![sql];
    statements.extend(extra);
    let out = crate::db::session::read(target, db, &statements, 100_000)?;
    if let Some(error) = out.error {
        return Err(client::db_error(&error));
    }
    let mut results = out.results.into_iter();
    let set = results.next().unwrap_or_default();
    ensure!(!set.rows.is_empty(), "unknown_table");
    let columns = set.rows.iter().map(|r| json!({
        "name": cell(r, 0), "type": cell(r, 1), "nullable": r[2].as_deref() == Some("YES"), "default": cell(r, 3),
        "key": cell(r, 4), "extra": cell(r, 5), "comment": cell(r, 6),
    })).collect();
    Ok((columns, results.collect()))
}

/// Rows the server estimates for a table (no scan): MySQL's TABLE_ROWS, PostgreSQL's reltuples.
fn estimate_sql(d: Dialect, database: &str, schema: &str, table: &str) -> Option<String> {
    match d {
        Dialect::MySql => Some(format!(
            "SELECT TABLE_ROWS FROM information_schema.TABLES WHERE TABLE_SCHEMA = {} AND TABLE_NAME = {}",
            literal(d, database),
            literal(d, table)
        )),
        Dialect::Postgres => Some(format!(
            "SELECT GREATEST(reltuples, 0)::bigint FROM pg_class WHERE oid = to_regclass({})",
            literal(d, &table_ref(d, database, schema, table))
        )),
        Dialect::Sqlite => None,
    }
}

/// Above this estimate a page without filters shows the estimate instead of counting every row.
const EXACT_COUNT_LIMIT: i64 = 200_000;
/// A filtered count stops here (the grid then says "more than").
const COUNT_CAP: i64 = 1_000_000;

pub(super) fn primary_key(columns: &[Value]) -> Vec<String> {
    columns
        .iter()
        .filter(|c| c["key"] == "PRI")
        .filter_map(|c| c["name"].as_str().map(str::to_string))
        .collect()
}

/// WHERE clause from the grid's filters, on known columns only. Each filter after the first says
/// how it joins the previous ones (`"join": "and"` by default, or `"or"`); AND binds first, as in
/// SQL, so `a AND b OR c` reads `(a AND b) OR c`.
pub(super) fn where_clause(d: Dialect, filters: &Value, known: &[String]) -> Result<String> {
    let mut parts: Vec<String> = vec![];
    for filter in filters.as_array().into_iter().flatten() {
        if !parts.is_empty() {
            parts.push(match filter["join"].as_str().unwrap_or("and") {
                "and" => "AND".into(),
                "or" => "OR".into(),
                _ => bail!("invalid_filter"),
            });
        }
        let column = filter["column"].as_str().unwrap_or("");
        ensure!(known.iter().any(|k| k == column), "invalid_filter");
        let c = ident(d, column);
        let value = filter["value"].as_str().unwrap_or("");
        let as_text = if d == Dialect::Postgres {
            format!("{c}::text")
        } else {
            c.clone()
        };
        let like = |pattern: String| {
            format!(
                "{as_text} {} {} ESCAPE '!'",
                if d == Dialect::Postgres {
                    "ILIKE"
                } else {
                    "LIKE"
                },
                literal(d, &pattern)
            )
        };
        let escaped = value
            .replace('!', "!!")
            .replace('%', "!%")
            .replace('_', "!_");
        parts.push(format!(
            "({})",
            match filter["op"].as_str().unwrap_or("") {
                "eq" => format!("{c} = {}", literal(d, value)),
                "ne" => format!("{c} <> {}", literal(d, value)),
                "lt" => format!("{c} < {}", literal(d, value)),
                "gt" => format!("{c} > {}", literal(d, value)),
                "le" => format!("{c} <= {}", literal(d, value)),
                "ge" => format!("{c} >= {}", literal(d, value)),
                "contains" => like(format!("%{escaped}%")),
                "starts" => like(format!("{escaped}%")),
                "null" => format!("{c} IS NULL"),
                "notnull" => format!("{c} IS NOT NULL"),
                _ => bail!("invalid_filter"),
            }
        ));
    }
    Ok(if parts.is_empty() {
        String::new()
    } else {
        format!(" WHERE {}", parts.join(" "))
    })
}

/// ORDER BY from the grid: several columns (`sorts`), or the older single `sort`; the primary key
/// otherwise, so pages are stable.
pub(super) fn order_clause(
    d: Dialect,
    request: &Value,
    names: &[String],
    columns: &[Value],
) -> Result<String> {
    let mut parts = vec![];
    for sort in request["sorts"].as_array().into_iter().flatten().take(8) {
        let column = sort["column"].as_str().unwrap_or("");
        ensure!(names.iter().any(|n| n == column), "invalid_filter");
        parts.push(format!(
            "{} {}",
            ident(d, column),
            if sort["descending"] == true {
                "DESC"
            } else {
                "ASC"
            }
        ));
    }
    if parts.is_empty()
        && let Some(sort) = request["sort"].as_str().filter(|s| !s.is_empty())
    {
        ensure!(names.iter().any(|n| n == sort), "invalid_filter");
        parts.push(format!(
            "{} {}",
            ident(d, sort),
            if request["descending"] == true {
                "DESC"
            } else {
                "ASC"
            }
        ));
    }
    if parts.is_empty() {
        parts = primary_key(columns).iter().map(|k| ident(d, k)).collect();
    }
    Ok(if parts.is_empty() {
        String::new()
    } else {
        format!(" ORDER BY {}", parts.join(", "))
    })
}

/// A page of rows with filters and order, the total that matches and the primary key (rows can
/// only be edited through it).
pub fn rows(target: &Target, request: &Value) -> Result<Value> {
    let d = dialect(target)?;
    let (database, schema, table) = (
        text(request, "database"),
        text(request, "schema"),
        text(request, "table"),
    );
    // Round trip 1: columns and the server's row estimate, together.
    let (columns, extra) = columns_with(
        target,
        database,
        schema,
        table,
        estimate_sql(d, database, schema, table)
            .into_iter()
            .collect(),
    )?;
    let estimate = extra
        .first()
        .and_then(|r| r.rows.first())
        .and_then(|row| row[0].clone())
        .and_then(|v| v.parse::<i64>().ok());
    let names: Vec<String> = columns
        .iter()
        .filter_map(|c| c["name"].as_str().map(str::to_string))
        .collect();
    let size = request["pageSize"]
        .as_u64()
        .unwrap_or(100)
        .clamp(1, MAX_ROWS as u64);
    let page = request["page"].as_u64().unwrap_or(0).min(10_000_000);
    let from = table_ref(d, database, schema, table);
    let filter = where_clause(d, &request["filters"], &names)?;
    let order = order_clause(d, request, &names, &columns)?;
    // Round trip 2: the page and, when it is cheap enough, the exact count.
    let db = if d == Dialect::MySql { "" } else { database };
    let mut statements = vec![format!(
        "SELECT * FROM {from}{filter}{order} LIMIT {size} OFFSET {}",
        page * size
    )];
    let exact = !filter.is_empty() || estimate.is_none_or(|e| e <= EXACT_COUNT_LIMIT);
    if exact {
        statements.push(if filter.is_empty() {
            format!("SELECT COUNT(*) FROM {from}")
        } else {
            format!("SELECT COUNT(*) FROM (SELECT 1 FROM {from}{filter} LIMIT {COUNT_CAP}) counted")
        });
    }
    let out = crate::db::session::read(target, db, &statements, MAX_ROWS)?;
    if let Some(error) = out.error {
        return Err(client::db_error(&error));
    }
    let mut results = out.results.into_iter();
    let data = results.next().unwrap_or_default();
    let counted = results
        .next()
        .and_then(|r| r.rows.first().and_then(|row| row[0].clone()))
        .and_then(|v| v.parse::<i64>().ok());
    let total = counted.or(estimate);
    Ok(json!({
        "columns": columns, "rows": data.rows, "total": total, "page": page, "pageSize": size,
        "totalEstimated": counted.is_none(), "totalCapped": counted == Some(COUNT_CAP),
        "primaryKey": primary_key(&columns), "durationMs": out.duration_ms,
    }))
}

/// Columns, indexes, foreign keys and the DDL of a table or view.
pub fn structure(target: &Target, request: &Value) -> Result<Value> {
    let d = dialect(target)?;
    let (database, schema, table) = (
        text(request, "database"),
        text(request, "schema"),
        text(request, "table"),
    );
    let schema = if d == Dialect::Postgres && schema.is_empty() {
        "public"
    } else {
        schema
    };
    let columns = columns(target, database, schema, table)?;
    let (db, statements): (&str, Vec<String>) = match d {
        Dialect::MySql => (
            "",
            vec![
                format!(
                    "SELECT INDEX_NAME, CASE WHEN NON_UNIQUE = 0 THEN 'YES' ELSE 'NO' END, GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ', '), INDEX_TYPE FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = {} AND TABLE_NAME = {} GROUP BY INDEX_NAME, NON_UNIQUE, INDEX_TYPE ORDER BY INDEX_NAME = 'PRIMARY' DESC, INDEX_NAME",
                    literal(d, database),
                    literal(d, table)
                ),
                format!(
                    "SELECT CONSTRAINT_NAME, GROUP_CONCAT(COLUMN_NAME ORDER BY ORDINAL_POSITION SEPARATOR ', '), CONCAT(REFERENCED_TABLE_NAME, '(', GROUP_CONCAT(REFERENCED_COLUMN_NAME ORDER BY ORDINAL_POSITION SEPARATOR ', '), ')') FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA = {} AND TABLE_NAME = {} AND REFERENCED_TABLE_NAME IS NOT NULL GROUP BY CONSTRAINT_NAME, REFERENCED_TABLE_NAME",
                    literal(d, database),
                    literal(d, table)
                ),
                format!(
                    "SHOW CREATE TABLE {}",
                    table_ref(d, database, schema, table)
                ),
            ],
        ),
        Dialect::Postgres => {
            let regclass = format!(
                "to_regclass({})",
                literal(d, &table_ref(d, database, schema, table))
            );
            (
                database,
                vec![
                    format!(
                        "SELECT i.indexname, CASE WHEN x.indisunique THEN 'YES' ELSE 'NO' END, i.indexdef, '' FROM pg_indexes i JOIN pg_class ic ON ic.relname = i.indexname JOIN pg_namespace n ON n.oid = ic.relnamespace AND n.nspname = i.schemaname JOIN pg_index x ON x.indexrelid = ic.oid WHERE i.schemaname = {} AND i.tablename = {} ORDER BY x.indisprimary DESC, 1",
                        literal(d, schema),
                        literal(d, table)
                    ),
                    format!(
                        "SELECT conname, pg_get_constraintdef(oid), '' FROM pg_constraint WHERE conrelid = {regclass} AND contype = 'f' ORDER BY 1"
                    ),
                    format!(
                        "SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = {regclass} AND contype <> 'n' ORDER BY contype = 'p' DESC, conname"
                    ),
                    format!(
                        "SELECT CASE WHEN c.relkind IN ('v', 'm') THEN pg_get_viewdef(c.oid, true) END, obj_description(c.oid, 'pg_class') FROM pg_class c WHERE c.oid = {regclass}"
                    ),
                ],
            )
        }
        Dialect::Sqlite => (
            database,
            vec![
                format!(
                    "SELECT il.name, CASE WHEN il.\"unique\" = 1 THEN 'YES' ELSE 'NO' END, (SELECT group_concat(ii.name, ', ') FROM pragma_index_info(il.name) ii), il.origin FROM pragma_index_list({}) il",
                    literal(d, table)
                ),
                format!(
                    "SELECT 'fk_' || id, group_concat(\"from\", ', '), \"table\" || '(' || group_concat(\"to\", ', ') || ')' FROM pragma_foreign_key_list({}) GROUP BY id",
                    literal(d, table)
                ),
                format!(
                    "SELECT sql FROM sqlite_master WHERE name = {} UNION ALL SELECT sql FROM sqlite_master WHERE tbl_name = {} AND type = 'index' AND sql IS NOT NULL",
                    literal(d, table),
                    literal(d, table)
                ),
            ],
        ),
    };
    let out = crate::db::session::read(target, db, &statements, 10_000)?;
    if let Some(error) = out.error {
        return Err(client::db_error(&error));
    }
    let results = out.results;
    let indexes: Vec<Value> = results.first().map(|r| r.rows.iter().map(|row| json!({"name": cell(row, 0), "unique": row[1].as_deref() == Some("YES"), "columns": cell(row, 2), "type": cell(row, 3)})).collect()).unwrap_or_default();
    let foreign: Vec<Value> = results.get(1).map(|r| r.rows.iter().map(|row| json!({"name": cell(row, 0), "columns": cell(row, 1), "references": cell(row, 2)})).collect()).unwrap_or_default();
    let ddl = match d {
        Dialect::MySql => {
            results
                .get(2)
                .and_then(|r| r.rows.first())
                .and_then(|row| row.get(1).cloned().flatten())
                .unwrap_or_default()
                + ";"
        }
        Dialect::Sqlite => results
            .get(2)
            .map(|r| {
                r.rows
                    .iter()
                    .filter_map(|row| row[0].clone())
                    .map(|s| s + ";")
                    .collect::<Vec<_>>()
                    .join("\n\n")
            })
            .unwrap_or_default(),
        Dialect::Postgres => {
            let name = table_ref(d, database, schema, table);
            let view = results
                .get(3)
                .and_then(|r| r.rows.first())
                .and_then(|row| row[0].clone());
            if let Some(definition) = view {
                format!("CREATE VIEW {name} AS\n{definition}")
            } else {
                let mut lines: Vec<String> = columns
                    .iter()
                    .map(|c| {
                        let mut line = format!(
                            "    {} {}",
                            ident(d, c["name"].as_str().unwrap_or("")),
                            c["type"].as_str().unwrap_or("")
                        );
                        if c["nullable"] == false {
                            line.push_str(" NOT NULL");
                        }
                        if let Some(default) = c["default"].as_str() {
                            line.push_str(&format!(" DEFAULT {default}"));
                        }
                        line
                    })
                    .collect();
                for row in results.get(2).map(|r| r.rows.clone()).unwrap_or_default() {
                    lines.push(format!(
                        "    CONSTRAINT {} {}",
                        ident(d, row[0].as_deref().unwrap_or("")),
                        row[1].clone().unwrap_or_default()
                    ));
                }
                let mut ddl = format!("CREATE TABLE {name} (\n{}\n);", lines.join(",\n"));
                let constraints: Vec<String> = results
                    .get(2)
                    .map(|r| r.rows.iter().filter_map(|row| row[0].clone()).collect())
                    .unwrap_or_default();
                for index in &indexes {
                    if !constraints
                        .iter()
                        .any(|c| index["name"].as_str() == Some(c))
                    {
                        ddl.push_str(&format!("\n{};", index["columns"].as_str().unwrap_or("")));
                    }
                }
                ddl
            }
        }
    };
    Ok(json!({"columns": columns, "indexes": indexes, "foreignKeys": foreign, "ddl": ddl}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn filters_quote_values_and_only_accept_known_columns() {
        let known = vec!["name".to_string(), "id".to_string()];
        let w = where_clause(Dialect::Postgres, &json!([{"column": "name", "op": "contains", "value": "50%_off'"}, {"column": "id", "op": "null"}]), &known).unwrap();
        assert_eq!(
            w,
            " WHERE (\"name\"::text ILIKE $b$%50!%!_off'%$b$ ESCAPE '!') AND (\"id\" IS NULL)"
        );
        assert!(
            where_clause(
                Dialect::MySql,
                &json!([{"column": "x; drop", "op": "eq", "value": "1"}]),
                &known
            )
            .is_err()
        );
        assert!(
            where_clause(
                Dialect::MySql,
                &json!([{"column": "id", "op": "or 1=1", "value": "1"}]),
                &known
            )
            .is_err()
        );
        let m = where_clause(
            Dialect::MySql,
            &json!([{"column": "id", "op": "eq", "value": "1"}]),
            &known,
        )
        .unwrap();
        assert_eq!(m, " WHERE (`id` = _utf8mb4 X'31')");
        // OR between filters; the joining word is never taken from the request as text.
        let or = where_clause(Dialect::Sqlite, &json!([{"column": "id", "op": "eq", "value": "1"}, {"column": "id", "op": "eq", "value": "2", "join": "or"}, {"column": "name", "op": "notnull", "join": "and"}]), &known).unwrap();
        assert_eq!(
            or,
            " WHERE (\"id\" = '1') OR (\"id\" = '2') AND (\"name\" IS NOT NULL)"
        );
        assert!(where_clause(Dialect::Sqlite, &json!([{"column": "id", "op": "null"}, {"column": "id", "op": "null", "join": "or 1=1 --"}]), &known).is_err());
    }

    #[test]
    fn several_sort_columns_in_order() {
        let names = vec!["a".to_string(), "b".to_string()];
        let columns = vec![
            json!({"name": "a", "key": "PRI"}),
            json!({"name": "b", "key": ""}),
        ];
        assert_eq!(
            order_clause(
                Dialect::MySql,
                &json!({"sorts": [{"column": "b", "descending": true}, {"column": "a"}]}),
                &names,
                &columns
            )
            .unwrap(),
            " ORDER BY `b` DESC, `a` ASC"
        );
        assert_eq!(
            order_clause(Dialect::MySql, &json!({"sort": "b"}), &names, &columns).unwrap(),
            " ORDER BY `b` ASC"
        );
        assert_eq!(
            order_clause(Dialect::MySql, &json!({}), &names, &columns).unwrap(),
            " ORDER BY `a`"
        );
        assert!(
            order_clause(
                Dialect::MySql,
                &json!({"sorts": [{"column": "a; drop"}]}),
                &names,
                &columns
            )
            .is_err()
        );
    }
}
