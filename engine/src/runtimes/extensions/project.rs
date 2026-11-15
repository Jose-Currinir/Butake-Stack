//! A project declares the extensions each of its databases needs (`databases[].extensions`).
//! Before it starts, Stack checks both levels (installed in the engine, active in the database) and
//! says what is missing with the action that resolves it.
use super::{catalog, database, install};
use crate::core::model::Project;
use crate::core::store::Store;
use crate::web::services::databases::Postgres;
use anyhow::Result;
use serde::Serialize;
use std::collections::BTreeSet;

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Issue {
    pub database: String,
    pub extension: String,
    /// `serviceMissing` (no PostgreSQL), `notInstalled` (the catalog has it: install), `unsupported`
    /// (not for this engine version), `unknown` (nowhere), `serverStopped` (cannot check the
    /// database), `databaseMissing`, `inactive` (installed: activate).
    pub problem: &'static str,
    /// The catalog entry that installs it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub catalog: Option<&'static str>,
}

impl Issue {
    /// What «Resolver» can do about it from the app.
    pub fn fixable(&self) -> bool {
        matches!(self.problem, "notInstalled" | "inactive")
    }
}

/// The (database, extension) pairs a project needs.
pub fn wanted(project: &Project) -> Vec<(String, String)> {
    project
        .databases
        .iter()
        .flat_map(|db| {
            db.extensions
                .iter()
                .map(move |ext| (db.name.clone(), ext.clone()))
        })
        .collect()
}

/// What is missing for `project`, if anything. Never changes anything.
pub fn check(store: &Store, project: &Project) -> Result<Vec<Issue>> {
    let pairs = wanted(project);
    if pairs.is_empty() {
        return Ok(vec![]);
    }
    let issue = |(db, ext): &(String, String), problem, catalog| Issue {
        database: db.clone(),
        extension: ext.clone(),
        problem,
        catalog,
    };
    let Ok(engine) = install::engine(store, "postgres", None) else {
        return Ok(pairs
            .iter()
            .map(|p| issue(p, "serviceMissing", None))
            .collect());
    };
    let names = install::control_names(&engine.root);
    let mut issues = vec![];
    let mut present = vec![];
    for pair in &pairs {
        if names.contains_key(&pair.1) {
            present.push(pair);
            continue;
        }
        issues.push(match catalog::providing("postgres", &pair.1) {
            Some(recipe) if recipe.supports(&engine.version) => {
                issue(pair, "notInstalled", Some(recipe.id))
            }
            Some(recipe) => issue(pair, "unsupported", Some(recipe.id)),
            None => issue(pair, "unknown", None),
        });
    }
    let server = store
        .config()
        .and_then(|config| Postgres::new(store, &config))
        .and_then(|pg| database::databases(&pg).map(|dbs| (pg, dbs)));
    let Ok((pg, databases)) = server else {
        issues.extend(present.into_iter().map(|p| issue(p, "serverStopped", None)));
        return Ok(issues);
    };
    for pair in present {
        if !databases.contains(&pair.0) {
            issues.push(issue(pair, "databaseMissing", None));
            continue;
        }
        let active = database::active(&pg, &pair.0).unwrap_or_default();
        if !active.iter().any(|a| a.name == pair.1) {
            let catalog = catalog::providing("postgres", &pair.1).map(|r| r.id);
            issues.push(issue(pair, "inactive", catalog));
        }
    }
    Ok(issues)
}

/// The steps resolving `issues` reports (one install after another, then the activations).
pub fn plan(issues: &[Issue]) -> Vec<&'static str> {
    let mut steps: Vec<&'static str> = vec![];
    for id in to_install(issues) {
        if let Some(recipe) = catalog::recipe("postgres", id) {
            for step in recipe.plan() {
                if !steps.contains(&step) {
                    steps.push(step);
                }
            }
        }
    }
    if issues.iter().any(Issue::fixable) {
        steps.push("activate");
    }
    steps
}

fn to_install(issues: &[Issue]) -> BTreeSet<&'static str> {
    issues
        .iter()
        .filter(|i| i.problem == "notInstalled")
        .filter_map(|i| i.catalog)
        .collect()
}

/// Installs what the catalog has and activates every declared extension in its database (the
/// user asked, with «Resolver»). Returns what is still missing after it.
pub fn resolve(store: &Store, project: &Project, fetch: install::Fetch<'_>) -> Result<Vec<Issue>> {
    let issues = check(store, project)?;
    if !issues.iter().any(Issue::fixable) {
        return Ok(issues);
    }
    let engine = install::engine(store, "postgres", None)?;
    for id in to_install(&issues) {
        if let Some(recipe) = catalog::recipe("postgres", id) {
            if !install::state(&engine.root).extensions.contains_key(id) {
                install::install(store, &engine, recipe, fetch)?;
            }
        }
    }
    crate::core::progress::step("activate");
    let config = store.config()?;
    let pg = Postgres::new(store, &config)?;
    let databases = database::databases(&pg)?;
    let names = install::control_names(&engine.root);
    for (db, ext) in wanted(project) {
        if databases.contains(&db) && names.contains_key(&ext) {
            database::activate(&pg, &db, &ext)?;
        }
    }
    check(store, project)
}
