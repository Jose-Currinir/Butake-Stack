//! Query plans as trees.

use super::*;

/// One node of a plan: its depth in the tree and its text (`detail` lines belong to the node above).
fn plan_line(depth: usize, text: &str, detail: bool) -> Value {
    json!({"depth": depth, "text": text, "detail": detail})
}

/// Indented plans (PostgreSQL text, MySQL TREE): `->` starts a node, deeper indentation is a
/// child; other lines are details of the node above.
pub(crate) fn indented_plan(text: &str) -> Vec<Value> {
    let mut levels: Vec<usize> = vec![];
    let mut lines = vec![];
    let mut current = 0;
    for raw in text.lines().filter(|l| !l.trim().is_empty()) {
        let indent = raw.len() - raw.trim_start().len();
        let trimmed = raw.trim();
        if lines.is_empty() || trimmed.starts_with("->") {
            while levels.last().is_some_and(|l| *l >= indent) {
                levels.pop();
            }
            levels.push(indent);
            current = levels.len() - 1;
            lines.push(plan_line(
                current,
                trimmed.trim_start_matches("->").trim(),
                false,
            ));
        } else {
            lines.push(plan_line(current + 1, trimmed, true));
        }
    }
    lines
}

/// The plan of one statement, without running it (no ANALYZE), as a tree of lines; MariaDB's
/// classic EXPLAIN comes back as a table.
pub fn explain(target: &Target, request: &Value) -> Result<Value> {
    let d = dialect(target)?;
    let sql = text(request, "sql");
    ensure!(sql.len() <= 512 * 1024, "request_too_large");
    let statements = sql::split(sql, d);
    ensure!(statements.len() == 1, "invalid_explain");
    let statement = &statements[0];
    // Only plain statements: never EXPLAIN ANALYZE (which runs it), never options in parentheses.
    ensure!(
        statement
            .trim_start()
            .starts_with(|c: char| c.is_ascii_alphabetic())
            && matches!(
                sql::first_word(statement, d).as_str(),
                "select" | "with" | "insert" | "update" | "delete" | "replace" | "values" | "table"
            ),
        "invalid_explain"
    );
    let database = text(request, "database");
    let run = |sql: String| crate::db::session::read(target, database, &[sql], 5000);
    match d {
        Dialect::Postgres => {
            let out = run(format!("EXPLAIN {statement}"))?;
            if let Some(error) = out.error {
                return Err(client::db_error(&error));
            }
            let text: String = out
                .results
                .first()
                .map(|r| {
                    r.rows
                        .iter()
                        .filter_map(|row| row.first().cloned().flatten())
                        .collect::<Vec<_>>()
                        .join("\n")
                })
                .unwrap_or_default();
            Ok(json!({"lines": indented_plan(&text), "raw": text}))
        }
        Dialect::MySql => {
            let tree = run(format!("EXPLAIN FORMAT=TREE {statement}"))?;
            if tree.error.is_none() {
                let text = tree
                    .results
                    .first()
                    .and_then(|r| r.rows.first())
                    .and_then(|row| row.first().cloned().flatten())
                    .unwrap_or_default();
                return Ok(json!({"lines": indented_plan(&text), "raw": text}));
            }
            // MariaDB (and old MySQL): the classic table.
            let out = run(format!("EXPLAIN {statement}"))?;
            if let Some(error) = out.error {
                return Err(client::db_error(&error));
            }
            let set = out.results.into_iter().next().unwrap_or_default();
            Ok(json!({"lines": [], "table": {"columns": set.columns, "rows": set.rows}, "raw": ""}))
        }
        Dialect::Sqlite => {
            let out = run(format!("EXPLAIN QUERY PLAN {statement}"))?;
            if let Some(error) = out.error {
                return Err(client::db_error(&error));
            }
            let set = out.results.into_iter().next().unwrap_or_default();
            let mut lines = vec![];
            let mut raw = vec![];
            if set.columns.len() == 1 {
                // The sqlite3 shell draws the plan itself: "|--SCAN t", "|  `--SEARCH u …".
                // (A detail with commas comes back cut into CSV fields: glue them again.)
                for line in set.rows.iter().map(|row| {
                    row.iter()
                        .map(|c| c.clone().unwrap_or_default())
                        .collect::<Vec<_>>()
                        .join(",")
                }) {
                    let Some(at) = line.find("--") else { continue };
                    let depth = at.saturating_sub(1) / 3;
                    let detail = line[at + 2..].trim().to_string();
                    raw.push(format!("{}{}", "  ".repeat(depth), detail));
                    lines.push(plan_line(depth, &detail, false));
                }
                return Ok(json!({"lines": lines, "raw": raw.join("\n")}));
            }
            // Rows of (id, parent, notused, detail): depth from the parent chain.
            let mut depth_of: std::collections::HashMap<String, usize> = Default::default();
            for row in &set.rows {
                let id = row.first().cloned().flatten().unwrap_or_default();
                let parent = row.get(1).cloned().flatten().unwrap_or_default();
                let detail = row.get(3).cloned().flatten().unwrap_or_default();
                let depth = depth_of.get(&parent).map_or(0, |d| d + 1);
                depth_of.insert(id, depth);
                raw.push(format!("{}{}", "  ".repeat(depth), detail));
                lines.push(plan_line(depth, &detail, false));
            }
            Ok(json!({"lines": lines, "raw": raw.join("\n")}))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plans_become_trees() {
        let pg = "Sort  (cost=1.1..1.2 rows=3 width=8)\n  Sort Key: a\n  ->  Seq Scan on t  (cost=0.00..1.03 rows=3 width=8)\n        Filter: (a > 1)\n        ->  Index Scan on u\n  ->  Hash\n";
        let lines = indented_plan(pg);
        let depths: Vec<(u64, bool)> = lines
            .iter()
            .map(|l| (l["depth"].as_u64().unwrap(), l["detail"] == true))
            .collect();
        assert_eq!(
            depths,
            vec![
                (0, false),
                (1, true),
                (1, false),
                (2, true),
                (2, false),
                (1, false)
            ]
        );
        assert_eq!(
            lines[2]["text"],
            "Seq Scan on t  (cost=0.00..1.03 rows=3 width=8)"
        );
        let mysql = "-> Filter: (t.a > 1)  (cost=0.55 rows=1)\n    -> Table scan on t  (cost=0.55 rows=3)\n";
        let lines = indented_plan(mysql);
        assert_eq!(lines[1]["depth"], 1);
        assert_eq!(lines[0]["text"], "Filter: (t.a > 1)  (cost=0.55 rows=1)");
    }
}
