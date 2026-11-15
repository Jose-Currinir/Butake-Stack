//! Who uses an installed version (P-42): a version a project runs with, or the global one, is
//! never removed. The guard of removing PHP, Python, Node.js and the JDK.

use crate::core::{model::Project, store::Store};
use anyhow::{ensure, Result};

/// Whether `wanted` (a project's or the global setting: "8.2", "24", "24.22.3") names `version`.
fn names(wanted: &str, version: &str) -> bool {
    !wanted.is_empty() && (wanted == version || version.starts_with(&format!("{wanted}.")))
}

/// Projects whose setting for `language` resolves to `version` and to no other installed one
/// (`others`): removing it would leave them without it. A PHP project without its own setting
/// runs with the global line, which is guarded on its own.
pub fn users<'a>(
    projects: &'a [Project],
    language: &str,
    version: &str,
    others: &[String],
) -> Vec<&'a Project> {
    projects
        .iter()
        .filter(|p| {
            p.runtime.get(language).is_some_and(|wanted| {
                names(wanted, version) && !others.iter().any(|other| names(wanted, other))
            })
        })
        .collect()
}

/// Refuses to remove `version` of `language` while the global setting names it
/// (`runtime_global`) or a project uses it (`runtime_in_use:<names>`). `others`: the versions
/// of the same language that stay installed.
pub fn ensure_unused(
    store: &Store,
    language: &str,
    version: &str,
    others: &[String],
) -> Result<()> {
    let config = store.config()?;
    // PHP without a global setting runs with 8.2 (`web::services::web_server::php_series`).
    let fallback = if language == "php" { "8.2" } else { "" };
    let global = config
        .versions
        .get(language)
        .map(String::as_str)
        .unwrap_or(fallback);
    ensure!(
        !names(global, version) || others.iter().any(|other| names(global, other)),
        "runtime_global"
    );
    // Projects whose folder is missing still count: they come back when it does.
    let mut projects = store.list()?;
    projects.extend(store.missing()?);
    let using = users(&projects, language, version, others);
    if !using.is_empty() {
        let names: Vec<String> = using
            .iter()
            .map(|p| {
                p.name
                    .chars()
                    .filter(|c| !c.is_control())
                    .take(200)
                    .collect()
            })
            .collect();
        anyhow::bail!("runtime_in_use:{}", names.join(", "));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn project(id: &str, runtime: serde_json::Value) -> Project {
        serde_json::from_value(serde_json::json!({
            "id": id, "name": format!("Proyecto {id}"), "path": "/tmp", "domains": [format!("{id}.test")],
            "https": false, "kind": "laravel", "runtime": runtime, "docroot": ".", "services": [],
            "databases": [], "processes": []}))
        .unwrap()
    }

    #[test]
    fn a_version_in_use_is_found() {
        let projects = [
            project("a", serde_json::json!({"php": "8.2"})),
            project("b", serde_json::json!({"node": "24"})),
            project("c", serde_json::json!({})),
        ];
        let ids = |list: Vec<&Project>| list.iter().map(|p| p.id.clone()).collect::<Vec<_>>();
        assert_eq!(ids(users(&projects, "php", "8.2", &[])), ["a"]);
        assert!(users(&projects, "php", "8.5", &["8.2".into()]).is_empty());
        assert_eq!(
            ids(users(&projects, "node", "24.22.3", &["22.23.5".into()])),
            ["b"]
        );
        // Another 24 stays: the project keeps a Node 24.
        assert!(users(&projects, "node", "24.22.3", &["24.10.0".into()]).is_empty());
    }
}
