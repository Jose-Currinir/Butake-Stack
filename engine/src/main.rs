mod agent;
mod cache;
mod daemon;
mod detect;
mod engines;
mod envs;
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
        // Environments of a site's .env. Secret values never reach these responses (R1, R6).
        "envList" => {
            let project = store.get(id)?;
            Ok(json!({
                "site": envs::load(&store, id)?,
                "guard": envs::git_guard(&project),
                "exampleKeys": envs::example_keys(&project),
                "hasEnv": project.path.join(".env").is_file(),
            }))
        }
        "envSave" => {
            let site: envs::SiteEnvironments = serde_json::from_value(request["site"].clone())?;
            envs::save(&store, id, &site, request["actor"].as_str().unwrap_or(""))?;
            Ok(serde_json::to_value(envs::load(&store, id)?)?)
        }
        "envDelete" => Ok(serde_json::to_value(envs::delete_environment(
            &store,
            id,
            request["env"].as_str().unwrap_or(""),
            request["actor"].as_str().unwrap_or(""),
        )?)?),
        "envActivate" => {
            let secrets: std::collections::BTreeMap<String, String> =
                serde_json::from_value(request["secrets"].clone()).unwrap_or_default();
            let site = envs::activate(
                &store,
                id,
                request["env"].as_str().unwrap_or(""),
                &secrets,
                request["confirmed"] == true,
                request["actor"].as_str().unwrap_or(""),
            )?;
            drop(secrets);
            // New values only take effect once the site's processes restart.
            let _ = daemon::request_sync(&store, "reload", json!({}), false);
            let project = store.get(id)?;
            if project.enabled && !envs::production_active(&store, id) {
                for process in project.processes.iter().filter(|p| p.autostart) {
                    let _ = daemon::request_sync(&store, "restart", json!({"id": format!("{}.{}", id, process.name)}), false);
                }
            }
            Ok(serde_json::to_value(site)?)
        }
        "envExport" => {
            let secrets: std::collections::BTreeMap<String, String> =
                serde_json::from_value(request["secrets"].clone()).unwrap_or_default();
            envs::export(
                &store,
                id,
                request["env"].as_str().unwrap_or(""),
                &secrets,
                std::path::Path::new(request["path"].as_str().unwrap_or("")),
                request["actor"].as_str().unwrap_or(""),
            )?;
            Ok(json!(true))
        }
        "envAudit" => {
            envs::audit(
                &store,
                id,
                request["env"].as_str().unwrap_or(""),
                request["action"].as_str().unwrap_or(""),
                request["key"].as_str().unwrap_or(""),
                request["actor"].as_str().unwrap_or(""),
            )?;
            Ok(json!(true))
        }
        "createDatabase" => {
            anyhow::ensure!(request["engine"] == "postgres", "unsupported_engine");
            engines::create_postgres_database(&store, &store.config()?, request["name"].as_str().unwrap_or(""))
        }
        "envClassify" => {
            // Secret by default for credential-like names (R2); names only, never values.
            let keys: Vec<String> = serde_json::from_value(request["keys"].clone()).unwrap_or_default();
            Ok(json!(keys.iter().map(|k| envs::looks_secret(k)).collect::<Vec<_>>()))
        }
        "envAuditLog" => Ok(serde_json::to_value(envs::audit_lines(&store, id)?)?),
        // Used by scripts/php/build_php.py after a build: writes the runtime's php.ini.
        "generatePhpIni" => Ok(json!(runtimes::generate_ini(&store, request["series"].as_str().unwrap_or(""))?)),
        // Catalogs are cached on disk (6 h / 12 h / 24 h); "refresh": true asks the source again.
        "phpCatalog" => cache::cached(&store, "php-catalog", 6 * 3600, request["refresh"] == true, || {
            Ok(serde_json::to_value(runtimes::php_catalog()?)?)
        }),
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
            tools::validate_tool(tool)?;
            cache::cached(&store, &format!("available-{tool}"), 12 * 3600, request["refresh"] == true, || {
                Ok(serde_json::to_value(tools::available(tool)?)?)
            })
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
        "lifecycle" => {
            let tool = request["tool"].as_str().unwrap_or("");
            tools::validate_tool(tool)?;
            cache::cached(&store, &format!("lifecycle-{tool}"), 24 * 3600, request["refresh"] == true, || tools::lifecycle(tool))
        }
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
            // Its environments go too (R10); the app removes their Keychain secrets.
            let _ = std::fs::remove_file(store.directory("envs")?.join(format!("{id}.json")));
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
