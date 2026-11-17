//! What a project needs before it works as the user expects (P-42), worked out from its record,
//! its files and what Stack has installed, never stored: a service it uses that is off, a fixed
//! port another project also takes, a static site that would publish its repository, a command
//! whose program or script is not there, a Node.js that is not the one the project asks for. Each
//! item may carry the fix Stack applies with one click (`applyProjectFix`), recomputed then and
//! never taken from the request.

use crate::core::{
    model::{Project, ProjectKind, StackConfig},
    store::Store,
};
use crate::runtimes::{languages::node_range, utilities::catalog};
use anyhow::{ensure, Result};
use serde::Serialize;
use serde_json::Value;
use std::path::PathBuf;

/// One thing a project needs. `code` says what; the other fields, which part (all optional).
#[derive(Debug, Clone, Default, Serialize, PartialEq)]
pub struct Attention {
    pub code: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub process: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub service: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub port: Option<u16>,
    /// The other project's name (a port both take).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub other: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub program: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub script: Option<String>,
    /// What runs now (a Node.js version, a line).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub current: Option<String>,
    /// What the project asks for, and where it says it (`.nvmrc`, `package.json`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub wanted: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fix: Option<Fix>,
}

/// The one-click fix of an item: `startService` (value: the service), `useScript` (process and
/// value: the script to call instead), `setNode` (value: the line or version) or `makeUnserved`.
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct Fix {
    pub id: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub process: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
}

/// Programs that run with the project's Node.js.
const NODE_PROGRAMS: [&str; 4] = ["node", "npm", "npx", "corepack"];

fn package_json(project: &Project) -> Value {
    crate::web::projects::detect::read_small(&project.path.join("package.json"), 1_048_576)
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or(Value::Null)
}

/// Every project's items, by id (projects with nothing to say are left out).
pub fn all(store: &Store) -> Result<serde_json::Map<String, Value>> {
    let config = store.config()?;
    let projects = store.list()?;
    let mut out = serde_json::Map::new();
    for project in &projects {
        let items = of(store, &config, &projects, project);
        if !items.is_empty() {
            out.insert(project.id.clone(), serde_json::to_value(items)?);
        }
    }
    Ok(out)
}

/// What `project` needs, among `projects` (all of them, for ports).
pub fn of(
    store: &Store,
    config: &StackConfig,
    projects: &[Project],
    project: &Project,
) -> Vec<Attention> {
    let mut out = vec![];
    if project.enabled {
        services(store, config, project, &mut out);
    }
    ports(projects, project, &mut out);
    if crate::web::projects::detect::serves_repository(project) {
        out.push(Attention {
            code: "serves_repository",
            fix: Some(Fix {
                id: "makeUnserved",
                process: None,
                value: None,
            }),
            ..Default::default()
        });
    } else if crate::web::projects::detect::serves_project_root(project) {
        out.push(Attention {
            code: "serves_project_root",
            ..Default::default()
        });
    }
    let package = package_json(project);
    commands(store, config, project, &package, &mut out);
    node(store, config, project, &package, &mut out);
    out
}

/// A service the project uses that is off (Stack turns it on) or not installed.
fn services(store: &Store, config: &StackConfig, project: &Project, out: &mut Vec<Attention>) {
    let off = crate::web::projects::service_use::off_services(store, config, project);
    for service in &project.services {
        if config.engines.get(service).is_some_and(|e| e.enabled)
            && crate::web::services::engines::engine_dir(store, config, service).is_some()
        {
            continue;
        }
        let installed = off.contains(service);
        out.push(Attention {
            code: if installed {
                "service_off"
            } else {
                "service_missing"
            },
            service: Some(service.clone()),
            fix: installed.then(|| Fix {
                id: "startService",
                process: None,
                value: Some(service.clone()),
            }),
            ..Default::default()
        });
    }
}

/// A fixed port another project also takes (records saved before the check at save time).
fn ports(projects: &[Project], project: &Project, out: &mut Vec<Attention>) {
    let mine = project.fixed_ports();
    for other in projects.iter().filter(|p| p.id != project.id) {
        if let Some(port) = other.fixed_ports().intersection(&mine).next() {
            out.push(Attention {
                code: "port_conflict",
                port: Some(*port),
                other: Some(other.name.clone()),
                ..Default::default()
            });
        }
    }
}

/// Where a process's program is, as the supervisor runs it (`daemon::specs`).
fn program_path(store: &Store, config: &StackConfig, project: &Project, program: &str) -> PathBuf {
    let runtime = crate::daemon::site_runtime(store, config, project);
    match program {
        "php" | "composer" => runtime.php_bin.join("php"),
        "gradlew" => project.path.join("gradlew"),
        "uv" | "cargo" => {
            catalog::user_tool(program).unwrap_or_else(|| PathBuf::from("/nonexistent"))
        }
        "python" => runtime.venv.join("bin/python"),
        program if crate::core::model::SYSTEM_PROGRAMS.contains(&program) => {
            PathBuf::from("/usr/bin").join(program)
        }
        program => runtime
            .node_bin
            .map(|bin| bin.join(program))
            .unwrap_or_else(|| PathBuf::from("/nonexistent")),
    }
}

/// The script an npm or pnpm process runs and what it passes after it: `npm run <s> -- <extra>`,
/// `corepack pnpm run <s> <extra>`.
fn script_call(program: &str, args: &[String]) -> Option<(usize, Vec<String>)> {
    let start = match (program, args.first().map(String::as_str)) {
        ("npm", Some("run" | "run-script")) => 1,
        ("corepack", Some("pnpm" | "yarn")) if args.get(1).is_some_and(|a| a == "run") => 2,
        _ => return None,
    };
    let rest: Vec<String> = args[start + 1..]
        .iter()
        .filter(|a| *a != "--")
        .cloned()
        .collect();
    args.get(start).map(|_| (start, rest))
}

/// The one script a script only forwards to (`npm run dev:local`, `pnpm dev:local`, `yarn x`).
fn forwarded(body: &str) -> Option<String> {
    let words: Vec<&str> = body.split_whitespace().collect();
    if body.contains("&&") || body.contains(';') || body.contains('|') {
        return None;
    }
    match words.as_slice() {
        ["npm", "run", target] | ["pnpm", "run", target] | ["yarn", "run", target] => {
            Some(target.to_string())
        }
        ["pnpm", target] | ["yarn", target] if !target.starts_with('-') => Some(target.to_string()),
        _ => None,
    }
}

/// Commands whose program is not there, whose script the project does not have, or that pass
/// arguments to a script that only calls another one (they never reach the server).
fn commands(
    store: &Store,
    config: &StackConfig,
    project: &Project,
    package: &Value,
    out: &mut Vec<Attention>,
) {
    for process in &project.processes {
        if !program_path(store, config, project, &process.program).exists() {
            out.push(Attention {
                code: "program_missing",
                process: Some(process.name.clone()),
                program: Some(process.program.clone()),
                ..Default::default()
            });
            continue;
        }
        let Some((index, extra)) = script_call(&process.program, &process.args) else {
            continue;
        };
        let script = process.args[index].clone();
        let Some(body) = package["scripts"][&script].as_str() else {
            out.push(Attention {
                code: "script_missing",
                process: Some(process.name.clone()),
                script: Some(script),
                ..Default::default()
            });
            continue;
        };
        if extra.is_empty() {
            continue;
        }
        if let Some(target) = forwarded(body) {
            let exists = package["scripts"][&target].is_string();
            out.push(Attention {
                code: "script_forwards",
                process: Some(process.name.clone()),
                script: Some(script),
                wanted: Some(target.clone()),
                fix: exists.then(|| Fix {
                    id: "useScript",
                    process: Some(process.name.clone()),
                    value: Some(target),
                }),
                ..Default::default()
            });
        }
    }
}

/// Installed Node.js versions, newest first.
fn node_versions(store: &Store) -> Vec<String> {
    let mut versions: Vec<String> = catalog::installed(store, "node")
        .unwrap_or_default()
        .into_iter()
        .map(|m| m.version)
        .collect();
    versions.sort_by(|a, b| {
        let key = |v: &str| {
            v.split('.')
                .map(|p| p.parse::<u64>().unwrap_or(0))
                .collect::<Vec<_>>()
        };
        key(b).cmp(&key(a))
    });
    versions
}

/// The Node.js the project runs with against what it asks for: its line not installed, or a
/// version outside `.nvmrc` or `engines.node`. The fix picks an installed version that gives
/// both (the `.nvmrc` line first) and only changes Stack's setting, never the project's files.
fn node(
    store: &Store,
    config: &StackConfig,
    project: &Project,
    package: &Value,
    out: &mut Vec<Attention>,
) {
    let uses_node = project.runtime.contains_key("node")
        || project
            .processes
            .iter()
            .any(|p| NODE_PROGRAMS.contains(&p.program.as_str()));
    if !uses_node {
        return;
    }
    let installed = node_versions(store);
    let wanted = project
        .runtime
        .get("node")
        .or_else(|| config.versions.get("node"))
        .cloned()
        .unwrap_or_default();
    let matching = |line: &str| {
        installed
            .iter()
            .find(|v| line.is_empty() || *v == line || v.starts_with(&format!("{line}.")))
            .cloned()
    };
    // As `site_runtime`: the wanted line, else the newest installed.
    let Some(current) = matching(&wanted).or_else(|| installed.first().cloned()) else {
        return;
    };
    let mut asks: Vec<(&'static str, String)> = vec![];
    if let Some(range) = crate::web::projects::detect::read_small(&project.path.join(".nvmrc"), 64)
        .and_then(|t| node_range::nvmrc_range(&t))
    {
        asks.push((".nvmrc", range));
    }
    if let Some(range) = package["engines"]["node"].as_str() {
        if node_range::satisfies(range, "0.0.0").is_some() {
            asks.push(("package.json", range.to_string()));
        }
    }
    let gives = |version: &str| {
        asks.iter()
            .all(|(_, range)| node_range::satisfies(range, version) != Some(false))
    };
    // The line Stack's setting names is not installed: the project runs with another one.
    if !wanted.is_empty() && matching(&wanted).is_none() && project.runtime.contains_key("node") {
        out.push(Attention {
            code: "node_missing",
            wanted: Some(wanted.clone()),
            current: Some(current.clone()),
            ..Default::default()
        });
    }
    let Some((source, range)) = asks
        .iter()
        .find(|(_, range)| node_range::satisfies(range, &current) == Some(false))
        .cloned()
    else {
        return;
    };
    // The line of `.nvmrc` first, then the newest that gives everything; the line alone when its
    // newest installed version is that one, so patches keep following.
    let nvmrc_major = asks
        .iter()
        .find(|(source, _)| *source == ".nvmrc")
        .map(|(_, range)| node_range::major(range.trim_start_matches(">=")));
    let chosen = installed
        .iter()
        .filter(|v| gives(v))
        .find(|v| nvmrc_major.as_deref() == Some(node_range::major(v).as_str()))
        .or_else(|| installed.iter().find(|v| gives(v)))
        .map(|version| {
            let line = node_range::major(version);
            if matching(&line).as_deref() == Some(version.as_str()) {
                line
            } else {
                version.clone()
            }
        });
    out.push(Attention {
        code: "node_mismatch",
        current: Some(current),
        wanted: Some(range),
        source: Some(source),
        fix: chosen.map(|value| Fix {
            id: "setNode",
            process: None,
            value: Some(value),
        }),
        ..Default::default()
    });
}

/// Applies the fix `id` (of `process`, for a command) that the project's items offer now. What
/// is applied comes from that recomputed item, never from the request. Returns the project.
pub fn apply(store: &Store, id: &str, fix: &str, process: &str) -> Result<Project> {
    let config = store.config()?;
    let projects = store.list()?;
    let project = projects
        .iter()
        .find(|p| p.id == id)
        .cloned()
        .ok_or_else(|| anyhow::anyhow!("unknown_project"))?;
    let offered = of(store, &config, &projects, &project)
        .into_iter()
        .filter_map(|item| item.fix)
        .find(|f| f.id == fix && (process.is_empty() || f.process.as_deref() == Some(process)))
        .ok_or_else(|| anyhow::anyhow!("unknown_fix"))?;
    let mut project = project;
    match offered.id {
        "startService" => {
            let service = offered.value.unwrap_or_default();
            crate::web::projects::service_use::set_enabled(
                store,
                &service,
                true,
                true,
                &format!("project:{id}"),
            )?;
            return store.get(id);
        }
        "useScript" => {
            let target = offered.value.unwrap_or_default();
            let name = offered.process.unwrap_or_default();
            let process = project
                .processes
                .iter_mut()
                .find(|p| p.name == name)
                .ok_or_else(|| anyhow::anyhow!("unknown_fix"))?;
            let (index, _) = script_call(&process.program, &process.args)
                .ok_or_else(|| anyhow::anyhow!("unknown_fix"))?;
            process.args[index] = target;
        }
        "setNode" => {
            project
                .runtime
                .insert("node".into(), offered.value.unwrap_or_default());
        }
        "makeUnserved" => {
            ensure!(project.kind == ProjectKind::Static, "unknown_fix");
            project.kind = ProjectKind::Unserved;
        }
        _ => anyhow::bail!("unknown_fix"),
    }
    store.save(project)
}

#[cfg(test)]
#[path = "attention_tests.rs"]
mod tests;
