mod agent;
mod daemon;
mod detect;
mod engines;
mod git;
mod scaffold;
mod dns;
mod listeners;
mod services;
mod tools;
mod logs;
mod model;
mod runtimes;
mod store;
mod supervisor;
use anyhow::{bail, Result};
use serde_json::{json, Value};
use std::io::Read;

fn dispatch(request: Value) -> Result<Value> {
    let method = request["method"].as_str().unwrap_or("");
    let store = store::Store::from_environment()?;
    let id = request["id"].as_str().unwrap_or("");
    match method {
        "startDaemon" => daemon::request_sync(&store, "stackStatus", json!({}), true),
        "processAction" => {
            let action = request["action"].as_str().unwrap_or("");
            anyhow::ensure!(["start", "stop", "restart"].contains(&action), "invalid_action");
            supervisor::validate_process_id(id)?;
            daemon::request_sync(&store, action, json!({"id":id}), false)
        }
        "processLogs" => {
            supervisor::validate_process_id(id)?;
            daemon::request_sync(&store, "logs", json!({"id":id,"tail":500}), false)
        }
        "agentStatus" => Ok(agent::status()),
        "portStatus" => Ok(json!({
            "dns": listeners::port_owner(53, true),
            "http": listeners::port_owner(80, false),
            "https": listeners::port_owner(443, false),
        })),
        "installPhpPackage" => {
            anyhow::ensure!(request["confirmed"] == true, "confirmation_required");
            let path = std::path::PathBuf::from(request["path"].as_str().unwrap_or(""));
            anyhow::ensure!(path.is_absolute(), "invalid_package");
            let manifest = runtimes::install_package(&store, &path)?;
            runtimes::generate_ini(&store, &manifest.series)?;
            Ok(serde_json::to_value(manifest)?)
        }
        "phpCatalog" => Ok(serde_json::to_value(runtimes::php_catalog()?)?),
        "downloadPhp" => {
            anyhow::ensure!(request["confirmed"] == true, "confirmation_required");
            let manifest = runtimes::download_php(&store, request["version"].as_str().unwrap_or(""))?;
            let _ = daemon::request_sync(&store, "reload", json!({}), false);
            Ok(serde_json::to_value(manifest)?)
        }
        "createLaravel" => {
            let options = scaffold::Options {
                name: request["name"].as_str().unwrap_or("").into(),
                parent: std::path::PathBuf::from(request["parent"].as_str().unwrap_or("")),
                kit: request["kit"].as_str().unwrap_or("none").into(),
                testing: request["testing"].as_str().unwrap_or("pest").into(),
                database: request["database"].as_str().unwrap_or("sqlite").into(),
                git: request["git"].as_bool().unwrap_or(true),
            };
            anyhow::ensure!(options.parent.is_absolute(), "invalid_path");
            let project = scaffold::create(&store, &options)?;
            let _ = daemon::request_sync(&store, "reload", json!({}), false);
            Ok(serde_json::to_value(project)?)
        }
        "gitStatus" => {
            // Branch and pending changes of every site that is a Git repository.
            let mut out = serde_json::Map::new();
            for project in store.list()? {
                if let Some(info) = git::info(&project) {
                    out.insert(project.id.clone(), serde_json::to_value(info)?);
                }
            }
            Ok(Value::Object(out))
        }
        "worktrees" => Ok(serde_json::to_value(git::worktrees(&store, &store.get(id)?)?)?),
        "addWorktreeSite" => {
            let path = std::path::PathBuf::from(request["path"].as_str().unwrap_or(""));
            anyhow::ensure!(path.is_absolute(), "invalid_path");
            let project = git::add_worktree_site(&store, id, &path)?;
            let _ = daemon::request_sync(&store, "reload", json!({}), false);
            Ok(serde_json::to_value(project)?)
        }
        "branchChanges" => Ok(serde_json::to_value(git::branch_changes(
            &store,
            id,
            request["from"].as_str().unwrap_or(""),
            request["to"].as_str().unwrap_or(""),
        )?)?),
        "siteTask" => {
            git::run_task(&store, id, request["task"].as_str().unwrap_or(""))?;
            Ok(json!(true))
        }
        "stepLog" => Ok(serde_json::to_value(scaffold::log_tail(&store, request["name"].as_str().unwrap_or(""))?)?),
        "detect" => {
            let path = std::path::PathBuf::from(request["path"].as_str().unwrap_or(""));
            anyhow::ensure!(path.is_absolute(), "invalid_path");
            Ok(serde_json::to_value(detect::detect(&path)?)?)
        }
        "availableTools" => {
            let tool = request["tool"].as_str().unwrap_or("");
            Ok(serde_json::to_value(tools::available(tool)?)?)
        }
        "siteHealth" => {
            // HTTP status of every site (redirects not followed: a 302 to login is healthy).
            let mut out = serde_json::Map::new();
            for project in store.list()? {
                let Some(domain) = project.domains.first() else { continue };
                let scheme = if project.https { "https" } else { "http" };
                let output = std::process::Command::new("/usr/bin/curl")
                    .args(["-s", "-k", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "6"])
                    .arg(format!("{scheme}://{domain}/"))
                    .env_clear()
                    .output()?;
                let code: u16 = String::from_utf8_lossy(&output.stdout).trim().parse().unwrap_or(0);
                out.insert(project.id, json!(code));
            }
            Ok(serde_json::Value::Object(out))
        }
        "lifecycle" => Ok(tools::lifecycle(request["tool"].as_str().unwrap_or(""))?),
        "installedTools" => {
            let tool = request["tool"].as_str().unwrap_or("");
            Ok(serde_json::to_value(tools::installed(&store, tool)?)?)
        }
        "installTool" => {
            anyhow::ensure!(request["confirmed"] == true, "confirmation_required");
            let manifest = tools::install(
                &store,
                request["tool"].as_str().unwrap_or(""),
                request["version"].as_str().unwrap_or(""),
            )?;
            let _ = daemon::request_sync(&store, "reload", json!({}), false);
            Ok(serde_json::to_value(manifest)?)
        }
        "removeTool" => {
            anyhow::ensure!(request["confirmed"] == true, "confirmation_required");
            tools::remove(
                &store,
                request["tool"].as_str().unwrap_or(""),
                request["version"].as_str().unwrap_or(""),
            )?;
            let _ = daemon::request_sync(&store, "reload", json!({}), false);
            Ok(json!(true))
        }
        "engineRecipes" => {
            let config = store.config()?;
            Ok(json!(engines::RECIPES
                .iter()
                .map(|r| json!({"id": r.id, "category": r.category, "port": engines::port(&config, r.id)}))
                .collect::<Vec<_>>()))
        }
        "setEngine" => {
            let name = request["engine"].as_str().unwrap_or("");
            anyhow::ensure!(engines::recipe(name).is_some(), "unknown_engine");
            let mut config = store.config()?;
            let entry = config.engines.entry(name.into()).or_default();
            if let Some(enabled) = request["enabled"].as_bool() {
                entry.enabled = enabled;
            }
            if let Some(version) = request["version"].as_str() {
                entry.version = version.into();
            }
            if let Some(port) = request["port"].as_u64() {
                entry.port = u16::try_from(port).ok().filter(|p| *p > 0);
            }
            store.save_config(&config)?;
            let _ = daemon::request_sync(&store, "reload", json!({}), false);
            Ok(serde_json::to_value(config)?)
        }
        "importEngineData" => {
            anyhow::ensure!(request["confirmed"] == true, "confirmation_required");
            let engine = request["engine"].as_str().unwrap_or("");
            let config = store.config()?;
            anyhow::ensure!(
                !config.engines.get(engine).is_some_and(|e| e.enabled),
                "engine_must_be_off"
            );
            let path = std::path::PathBuf::from(request["path"].as_str().unwrap_or(""));
            anyhow::ensure!(path.is_absolute(), "invalid_path");
            services::import_engine_data(&store, engine, &path)?;
            Ok(json!(true))
        }
        "stackStatus" => daemon::request_sync(&store, "stackStatus", json!({}), false),
        "reloadStack" => daemon::request_sync(&store, "reload", json!({}), false),
        "listPhpRuntimes" => Ok(serde_json::to_value(runtimes::list(&store))?),
        "installAgent" => {
            if request["confirmed"] == true && request["preview"] != true {
                // A daemon started by hand holds the lock; launchd's copy must replace it.
                let _ = daemon::request_sync(&store, "shutdown", json!({}), false);
                std::thread::sleep(std::time::Duration::from_millis(1500));
            }
            agent::configure(&request, true)
        }
        "uninstallAgent" => agent::configure(&request, false),
        "listProjects" => Ok(serde_json::to_value(store.list()?)?),
        "getProject" => Ok(serde_json::to_value(store.get(id)?)?),
        "saveProject" => {
            let project = store.save(serde_json::from_value(request["project"].clone())?)?;
            let _ = daemon::request_sync(&store, "reload", json!({}), false);
            Ok(serde_json::to_value(project)?)
        }
        "setSiteEnabled" => {
            let mut project = store.get(id)?;
            project.enabled = request["enabled"].as_bool().unwrap_or(false);
            let project = store.save(project)?;
            let _ = daemon::request_sync(&store, "reload", json!({}), false);
            Ok(serde_json::to_value(project)?)
        }
        "deleteProject" => {
            store.delete(id)?;
            let _ = daemon::request_sync(&store, "reload", json!({}), false);
            Ok(json!(true))
        }
        "stackConfig" => {
            if let Some(value) = request.get("config") {
                store.save_config(&serde_json::from_value(value.clone())?)?;
            }
            Ok(serde_json::to_value(store.config()?)?)
        }
        _ => bail!("unknown_method"),
    }
}
#[tokio::main]
async fn main() {
    if std::env::args().nth(1).as_deref() == Some("daemon") {
        if let Err(error) = daemon::run().await {
            let already_running = error.to_string() == "daemon_already_running";
            println!(
                "{}",
                daemon::failure(
                    Value::Null,
                    if already_running {
                        "daemon_already_running"
                    } else {
                        "daemon_failed"
                    },
                    if already_running {
                        "daemon.alreadyRunning"
                    } else {
                        "daemon.requestFailed"
                    }
                )
            );
            std::process::exit(1);
        }
        return;
    }
    let result = (|| -> Result<Value> {
        let mut input = Vec::new();
        std::io::stdin().take(1_048_577).read_to_end(&mut input)?;
        anyhow::ensure!(input.len() <= 1_048_576, "request_too_large");
        dispatch(serde_json::from_slice(&input)?)
    })();
    // Never reflect request data or filesystem errors into UI/logs.
    let response = match result {
        Ok(value) => json!({"ok":true,"value":value}),
        Err(error) => {
            // Diagnostics only on demand and only to stderr; responses never carry details.
            if std::env::var_os("BUTAKE_STACK_DEBUG").is_some() {
                eprintln!("{error:#}");
            }
            json!({"ok":false,"error":{"code":"invalid_request","messageKey":"engine.requestFailed"}})
        }
    };
    println!("{response}");
}
