//! Extensions of a component (P-43): one model, «extension of a component», for every service or
//! language that admits them. Two levels:
//!
//! 1. *installed in the engine*: its files are in one installed version of the component
//!    (`install.rs`). Bundled ones come with the component (PostgreSQL's `contrib`, PHP's built-in
//!    modules); catalog ones are downloaded and built on demand from `catalog.rs`.
//! 2. *active in a database* (`database.rs`, PostgreSQL's `CREATE EXTENSION`).
//!
//! A project declares what its databases need (`project.rs`). Methods are listed in
//! `docs/extensiones.md`.

pub mod catalog;
pub mod database;
pub mod install;
pub mod project;

use crate::core::store::Store;
use crate::web::services::databases::Postgres;
use anyhow::{anyhow, ensure, Result};
use serde::Serialize;
use serde_json::{json, Value};

/// One extension of a component, as the app lists it.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Extension {
    pub component: String,
    pub id: String,
    pub name: String,
    /// `bundled` (comes with the component), `catalog` (downloaded on demand) or `builtin`
    /// (compiled into the component; PHP).
    pub kind: &'static str,
    /// The version the catalog offers, or the component's for what comes with it.
    pub version: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub license: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub homepage: Option<&'static str>,
    /// Names `CREATE EXTENSION` takes once it is installed.
    pub sql_names: Vec<String>,
    /// Every file it downloads (its own first), with its origin, sum and size.
    pub downloads: Vec<Value>,
    pub download_size: u64,
    /// Installed version in this copy of the component, if any.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub installed: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub installed_at: Option<u64>,
    /// The catalog has a newer version than the one installed.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub update: Option<String>,
    /// It exists for this version of the component.
    pub supported: bool,
    /// Can be removed from here (catalog ones).
    pub removable: bool,
    /// Other installed versions of the component that have it (to carry it over after a change).
    pub elsewhere: Vec<String>,
    /// What it leaves out, as a key of the app (`ext.note.<key>`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub note: Option<&'static str>,
}

fn downloads(recipe: &catalog::Recipe) -> Vec<Value> {
    std::iter::once(json!({
        "id": recipe.id, "name": recipe.name, "version": recipe.version, "license": recipe.license,
        "role": "extension", "url": recipe.archive.url, "sha256": recipe.archive.sha256,
        "size": recipe.archive.size,
    }))
    .chain(recipe.dependencies.iter().map(|d| {
        json!({
            "id": d.id, "name": d.name, "version": d.version, "license": d.license,
            "role": match d.role { catalog::Role::Library => "library", catalog::Role::BuildTool => "buildTool" },
            "url": d.archive.url, "sha256": d.archive.sha256, "size": d.archive.size,
        })
    }))
    .collect()
}

fn newer(a: &str, b: &str) -> bool {
    let key = |v: &str| -> Vec<u64> { v.split('.').map(|p| p.parse().unwrap_or(0)).collect() };
    key(a) > key(b)
}

/// The extensions of PostgreSQL `engine`: the catalog's (installed or not) and the bundled ones.
pub fn postgres(store: &Store, engine: &install::Engine) -> Result<Vec<Extension>> {
    let state = install::state(&engine.root);
    let others: Vec<(String, install::State)> =
        crate::runtimes::utilities::catalog::installed(store, "postgres")?
            .into_iter()
            .filter(|m| m.version != engine.version)
            .map(|m| {
                let root = engine.root.with_file_name(&m.version);
                (m.version, install::state(&root))
            })
            .collect();
    let mut out = vec![];
    for recipe in catalog::RECIPES
        .iter()
        .filter(|r| r.component == "postgres")
    {
        let installed = state.extensions.get(recipe.id);
        out.push(Extension {
            component: "postgres".into(),
            id: recipe.id.into(),
            name: recipe.name.into(),
            kind: "catalog",
            version: recipe.version.into(),
            license: Some(recipe.license),
            homepage: Some(recipe.homepage),
            sql_names: recipe.sql_names.iter().map(|s| s.to_string()).collect(),
            downloads: downloads(recipe),
            download_size: recipe.download_size(),
            installed: installed.map(|i| i.version.clone()),
            installed_at: installed.map(|i| i.installed_at),
            update: installed
                .filter(|i| newer(recipe.version, &i.version))
                .map(|_| recipe.version.to_string()),
            supported: recipe.supports(&engine.version),
            removable: true,
            elsewhere: others
                .iter()
                .filter(|(_, s)| s.extensions.contains_key(recipe.id))
                .map(|(v, _)| v.clone())
                .collect(),
            note: recipe.note,
        });
    }
    for (name, owner) in install::control_names(&engine.root) {
        if owner.is_some() {
            continue;
        }
        out.push(Extension {
            component: "postgres".into(),
            id: name.clone(),
            name: name.clone(),
            kind: "bundled",
            version: engine.version.clone(),
            license: None,
            homepage: None,
            sql_names: vec![name],
            downloads: vec![],
            download_size: 0,
            installed: Some(engine.version.clone()),
            installed_at: None,
            update: None,
            supported: true,
            removable: false,
            elsewhere: vec![],
            note: None,
        });
    }
    Ok(out)
}

/// PHP's extensions, in the same model: compiled into each line's binary (and Xdebug, which ships
/// beside it and is switched per line). They come with the build: none is installed or removed
/// alone, a line is installed or rebuilt whole (`docs/extensiones.md`, «PHP»).
pub fn php(store: &Store, series: &str) -> Result<Vec<Extension>> {
    let manifest = crate::runtimes::languages::php::manifest(store, series)?;
    let xdebug = manifest.sha256.contains_key("xdebug.so");
    let builtin = |id: &str| Extension {
        component: "php".into(),
        id: id.into(),
        name: id.into(),
        kind: "builtin",
        version: manifest.version.clone(),
        license: None,
        homepage: None,
        sql_names: vec![],
        downloads: vec![],
        download_size: 0,
        installed: Some(manifest.version.clone()),
        installed_at: None,
        update: None,
        supported: true,
        removable: false,
        elsewhere: vec![],
        note: None,
    };
    let mut out: Vec<Extension> = manifest.extensions.iter().map(|e| builtin(e)).collect();
    if xdebug {
        out.push(Extension {
            note: Some("xdebugSwitch"),
            ..builtin("xdebug")
        });
    }
    Ok(out)
}

fn postgres_server(store: &Store) -> Result<Postgres> {
    Postgres::new(store, &store.config()?)
}

/// Follows an extension operation in the log the app reads (`install-extension`).
fn follow(store: &Store) -> Result<()> {
    let log = store.directory("logs")?.join("install-extension.log");
    let _ = std::fs::remove_file(&log);
    crate::core::progress::begin(&log);
    Ok(())
}

/// What the app may back up or carry to another Mac: per installed PostgreSQL, the extensions
/// installed in it; per database of the running server, the ones active in it.
pub fn snapshot(store: &Store) -> Value {
    let mut installed = serde_json::Map::new();
    for manifest in
        crate::runtimes::utilities::catalog::installed(store, "postgres").unwrap_or_default()
    {
        if let Ok(engine) = install::engine(store, "postgres", Some(&manifest.version)) {
            let state = install::state(&engine.root);
            let list: Value = state
                .extensions
                .iter()
                .map(|(id, i)| (id.clone(), json!(i.version)))
                .collect::<serde_json::Map<_, _>>()
                .into();
            installed.insert(manifest.version, list);
        }
    }
    let mut active = serde_json::Map::new();
    if let Ok(pg) = postgres_server(store) {
        for db in database::databases(&pg).unwrap_or_default() {
            if let Ok(list) = database::active(&pg, &db) {
                active.insert(db, json!(list));
            }
        }
    }
    json!({"postgres": {"installed": installed, "active": active}})
}

fn str_of<'a>(request: &'a Value, key: &str) -> &'a str {
    request[key].as_str().unwrap_or("")
}

/// Requests about extensions; `None` when `method` is not one of them.
pub fn dispatch(store: &Store, method: &str, request: &Value) -> Result<Option<Value>> {
    let version = request["version"].as_str();
    let value = match method {
        "extensionCatalog" => match str_of(request, "component") {
            "postgres" => {
                let engine = install::engine(store, "postgres", version)?;
                json!({"component": "postgres", "version": engine.version,
                       "extensions": postgres(store, &engine)?})
            }
            "php" => {
                let series = str_of(request, "series");
                json!({"component": "php", "version": series, "extensions": php(store, series)?})
            }
            _ => anyhow::bail!("extension_component_unsupported"),
        },
        "installExtension" => {
            ensure!(request["confirmed"] == true, "confirmation_required");
            let recipe = catalog::recipe(str_of(request, "component"), str_of(request, "id"))
                .ok_or_else(|| anyhow!("unknown_extension"))?;
            let engine = install::engine(store, recipe.component, version)?;
            let update = install::state(&engine.root)
                .extensions
                .contains_key(recipe.id);
            follow(store)?;
            let installed = install::install(store, &engine, recipe, &install::fetch_official)?;
            // An update reaches the databases that use it (when the server is running).
            let updated = match (update, postgres_server(store)) {
                (true, Ok(pg)) => {
                    database::update_everywhere(&pg, recipe.sql_names).unwrap_or_default()
                }
                _ => vec![],
            };
            json!({"installed": installed, "updatedDatabases": updated})
        }
        "removeExtension" => {
            ensure!(request["confirmed"] == true, "confirmation_required");
            let recipe = catalog::recipe(str_of(request, "component"), str_of(request, "id"))
                .ok_or_else(|| anyhow!("unknown_extension"))?;
            let engine = install::engine(store, recipe.component, version)?;
            ensure!(
                install::state(&engine.root)
                    .extensions
                    .contains_key(recipe.id),
                "extension_not_installed"
            );
            // Only the server can say which databases use it: it must be running.
            let pg = postgres_server(store).map_err(|_| anyhow!("postgres_not_running"))?;
            let in_use = database::in_use(&pg, recipe.sql_names)?;
            install::remove(&engine, recipe.id, &in_use)?;
            json!(true)
        }
        "databaseExtensions" => {
            let pg = postgres_server(store)?;
            let database = str_of(request, "database");
            json!({"active": database::active(&pg, database)?,
                   "offered": database::offered(&pg, database)?})
        }
        "activateExtension" => {
            ensure!(request["confirmed"] == true, "confirmation_required");
            let pg = postgres_server(store)?;
            let database = str_of(request, "database");
            let names: Vec<&str> = match request["names"].as_array() {
                Some(list) => list.iter().filter_map(Value::as_str).collect(),
                None => vec![str_of(request, "name")],
            };
            for name in names {
                database::activate(&pg, database, name)?;
            }
            json!(database::active(&pg, database)?)
        }
        "extensionDependents" => {
            let pg = postgres_server(store)?;
            json!(database::dependents(
                &pg,
                str_of(request, "database"),
                str_of(request, "name")
            )?)
        }
        "deactivateExtension" => {
            ensure!(request["confirmed"] == true, "confirmation_required");
            let pg = postgres_server(store)?;
            let database = str_of(request, "database");
            database::deactivate(
                &pg,
                database,
                str_of(request, "name"),
                request["cascade"] == true,
            )?;
            json!(database::active(&pg, database)?)
        }
        "projectExtensions" => {
            let project = store.get(str_of(request, "id"))?;
            json!(project::check(store, &project)?)
        }
        "resolveProjectExtensions" => {
            ensure!(request["confirmed"] == true, "confirmation_required");
            let project = store.get(str_of(request, "id"))?;
            follow(store)?;
            json!(project::resolve(store, &project, &install::fetch_official)?)
        }
        "extensionState" => snapshot(store),
        // The steps the app shows while it follows an install (`extension-<id>`) or the resolving
        // of a project (`extension-project-<id>`).
        "installSteps" => {
            let tool = str_of(request, "tool");
            if let Some(id) = tool.strip_prefix("extension-project-") {
                let project = store.get(id)?;
                json!(project::plan(&project::check(store, &project)?))
            } else if let Some(id) = tool.strip_prefix("extension-") {
                let recipe =
                    catalog::recipe("postgres", id).ok_or_else(|| anyhow!("unknown_extension"))?;
                json!(recipe.plan())
            } else {
                return Ok(None);
            }
        }
        _ => return Ok(None),
    };
    Ok(Some(value))
}

#[cfg(test)]
mod tests;
