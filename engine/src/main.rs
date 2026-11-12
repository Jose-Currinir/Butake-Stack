mod backup;
mod devtools;
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
mod python;
mod toolchains;
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
        "siteGroups" => Ok(serde_json::to_value(store.groups()?)?),
        "saveSiteGroups" => Ok(serde_json::to_value(store.save_groups(serde_json::from_value(request["groups"].clone())?)?)?),
        "missingProjects" => Ok(json!(store
            .missing()?
            .into_iter()
            .map(|(id, path)| json!({"id": id, "path": path}))
            .collect::<Vec<_>>())),
        "createProject" | "createLaravel" => {
            let options = scaffold::Options {
                kind: request["kind"].as_str().unwrap_or("laravel").into(),
                template: request["template"].as_str().unwrap_or("").into(),
                platform: request["platform"].as_str().unwrap_or("").into(),
                name: request["name"].as_str().unwrap_or("").into(),
                parent: std::path::PathBuf::from(request["parent"].as_str().unwrap_or("")),
                kit: request["kit"].as_str().unwrap_or("none").into(),
                testing: request["testing"].as_str().unwrap_or("pest").into(),
                database: request["database"].as_str().unwrap_or("sqlite").into(),
                git: request["git"].as_bool().unwrap_or(true),
                python: request["python"].as_str().unwrap_or("").into(),
                manager: request["manager"].as_str().unwrap_or("pip").into(),
                php: request["php"].as_str().unwrap_or("").into(),
            };
            anyhow::ensure!(options.parent.is_absolute(), "invalid_path");
            let created = scaffold::create(&store, &options)?;
            if created.project.is_some() {
                let _ = daemon::request_sync(&store, "reload", json!({}), false);
            }
            Ok(json!({"project": created.project, "path": created.path, "notes": created.notes}))
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
        "devTools" => tools::dev_tools(&store),
        "exportEnvironment" => backup::export(&store, serde_json::from_value(request["profiles"].clone()).unwrap_or_default()),
        "planRestore" => backup::plan(&store, &request["data"]),
        "restoreEnvironment" => {
            anyhow::ensure!(request["confirmed"] == true, "confirmation_required");
            let result = backup::restore(&store, &request["data"], &request["parts"])?;
            let _ = daemon::request_sync(&store, "reload", json!({}), false);
            Ok(result)
        }
        "cloneSite" => {
            anyhow::ensure!(request["confirmed"] == true, "confirmation_required");
            backup::clone(std::path::Path::new(request["path"].as_str().unwrap_or("")), request["remote"].as_str().unwrap_or(""), request["branch"].as_str())?;
            Ok(json!(true))
        }
        "installDevTool" => {
            anyhow::ensure!(request["confirmed"] == true, "confirmation_required");
            devtools::install(&store, &devtools::Options {
                tool: request["tool"].as_str().unwrap_or("").into(),
                version: request["version"].as_str().unwrap_or("").into(),
                shell_path: request["shellPath"].as_bool().unwrap_or(false),
                accept_licenses: request["acceptLicenses"] == true,
            })
        }
        "devToolUpdates" => {
            let latest = cache::cached(&store, "devtools-latest", 6 * 3600, request["refresh"] == true, devtools::latest)?;
            devtools::updates(&store, &latest)
        }
        "pythonVersions" => cache::cached(&store, "python-versions", 24 * 3600, request["refresh"] == true, devtools::python_versions),
        "scanFolder" => {
            let path = std::path::PathBuf::from(request["path"].as_str().unwrap_or(""));
            anyhow::ensure!(path.is_absolute(), "invalid_path");
            detect::scan(&path)
        }
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
        "projectVersions" => cache::cached(&store, "project-versions", 12 * 3600, request["refresh"] == true, scaffold::versions),
        "lifecycle" => {
            let tool = request["tool"].as_str().unwrap_or("");
            anyhow::ensure!(tools::validate_tool(tool).is_ok() || ["php", "python", "rust"].contains(&tool), "unknown_tool");
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
        // ---- Python (python-build-standalone) and versions per language ----
        "pythonCatalog" => cache::cached(&store, "python-catalog", 6 * 3600, request["refresh"] == true, python::catalog),
        "listPythonRuntimes" => Ok(serde_json::to_value(python::installed(&store))?),
        "installPython" => {
            anyhow::ensure!(request["confirmed"] == true, "confirmation_required");
            let manifest = python::install(&store, request["line"].as_str().unwrap_or(""))?;
            let _ = daemon::request_sync(&store, "reload", json!({}), false);
            Ok(serde_json::to_value(manifest)?)
        }
        "removePython" => {
            anyhow::ensure!(request["confirmed"] == true, "confirmation_required");
            python::remove(&store, request["line"].as_str().unwrap_or(""))?;
            let _ = daemon::request_sync(&store, "reload", json!({}), false);
            Ok(json!(true))
        }
        "preparePython" => {
            let project = store.get(id)?;
            let log = store.directory("logs")?.join(format!("python-{id}.log"));
            let _ = std::fs::remove_file(&log);
            let result = python::prepare(&store, &project, request["manager"].as_str().unwrap_or("pip"), request["recreate"] == true, &log)?;
            let _ = daemon::request_sync(&store, "reload", json!({}), false);
            for process in &project.processes {
                let _ = daemon::request_sync(&store, "restart", json!({"id": format!("{}.{}", id, process.name)}), false);
            }
            Ok(result)
        }
        "frameworkRequirement" => {
            let framework = request["framework"].as_str().unwrap_or("");
            anyhow::ensure!(["django", "fastapi", "laravel"].contains(&framework), "unknown_framework");
            let mut info = cache::cached(&store, &format!("requires-{framework}"), 12 * 3600, request["refresh"] == true, || python::framework_requirement(framework))?;
            let requirement = info["requirement"].as_str().unwrap_or("").to_string();
            // Lines Stack offers for that language, compatible or not.
            let lines: Vec<String> = if info["language"] == "python" {
                let catalog = cache::cached(&store, "python-catalog", 6 * 3600, false, python::catalog).unwrap_or(json!([]));
                let mut lines: Vec<String> = catalog.as_array().into_iter().flatten().filter_map(|c| c["line"].as_str().map(str::to_string)).collect();
                lines.extend(python::installed(&store).into_iter().map(|m| m.line));
                lines
            } else {
                let catalog = cache::cached(&store, "php-catalog", 6 * 3600, false, || Ok(json!(runtimes::php_catalog()?))).unwrap_or(json!([]));
                let mut lines: Vec<String> = catalog.as_array().into_iter().flatten().filter_map(|c| c["series"].as_str().map(str::to_string)).collect();
                lines.extend(runtimes::list(&store).into_iter().filter(|r| r.installed).map(|r| r.series));
                lines
            };
            let mut lines: Vec<String> = lines.into_iter().collect::<std::collections::BTreeSet<_>>().into_iter().collect();
            lines.sort_by_key(|l| std::cmp::Reverse(l.split('.').map(|p| p.parse::<u32>().unwrap_or(0)).collect::<Vec<_>>()));
            let compatible: Vec<&String> = lines.iter().filter(|l| python::satisfies(&requirement, l)).collect();
            info["lines"] = json!(lines);
            info["compatible"] = json!(compatible);
            Ok(info)
        }
        "setGlobalVersion" => {
            let language = request["language"].as_str().unwrap_or("");
            anyhow::ensure!(["php", "node", "jdk", "python"].contains(&language), "unknown_language");
            let version = request["version"].as_str().unwrap_or("");
            let mut config = store.config()?;
            if version.is_empty() { config.versions.remove(language); } else { config.versions.insert(language.into(), version.into()); }
            store.save_config(&config)?;
            // The terminal follows the global version when the user linked that language.
            if toolchains::terminal_status(&store).get(language).is_some() && !version.is_empty() {
                toolchains::link_terminal(&store, language, version)?;
            }
            let _ = daemon::request_sync(&store, "reload", json!({}), false);
            Ok(serde_json::to_value(config)?)
        }
        "terminalStatus" => Ok(toolchains::terminal_status(&store)),
        "terminalPlan" => toolchains::terminal_plan(&store, request["language"].as_str().unwrap_or(""), request["version"].as_str().unwrap_or("")),
        "linkTerminal" => {
            anyhow::ensure!(request["confirmed"] == true, "confirmation_required");
            toolchains::link_terminal(&store, request["language"].as_str().unwrap_or(""), request["version"].as_str().unwrap_or(""))
        }
        "unlinkTerminal" => {
            anyhow::ensure!(request["confirmed"] == true, "confirmation_required");
            toolchains::unlink_terminal(&store, request["language"].as_str().unwrap_or(""))
        }
        "setSiteVersion" => {
            let project = toolchains::set_site_version(&store, id, request["language"].as_str().unwrap_or(""), request["version"].as_str().unwrap_or(""))?;
            let _ = daemon::request_sync(&store, "reload", json!({}), false);
            Ok(serde_json::to_value(project)?)
        }
        "siteVersionFiles" => Ok(toolchains::site_files(&store.get(id)?.path)),
        "rustToolchains" => toolchains::rust_toolchains(),
        "rustToolchain" => {
            let action = request["action"].as_str().unwrap_or("");
            anyhow::ensure!(action == "default" || request["confirmed"] == true, "confirmation_required");
            toolchains::rust_action(action, request["toolchain"].as_str().unwrap_or(""))
        }
        "swiftToolchains" => toolchains::swift_toolchains(request["available"] == true),
        "swiftToolchain" => {
            let action = request["action"].as_str().unwrap_or("");
            anyhow::ensure!(action == "default" || request["confirmed"] == true, "confirmation_required");
            toolchains::swift_action(action, request["version"].as_str().unwrap_or(""))
        }
        "installSwiftly" => {
            anyhow::ensure!(request["confirmed"] == true, "confirmation_required");
            toolchains::install_swiftly(&store)
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
            // Out of its folder too.
            let mut groups = store.groups().unwrap_or_default();
            if groups.iter().any(|g| g.sites.iter().any(|s| s == id)) {
                for group in &mut groups {
                    group.sites.retain(|s| s != id);
                }
                let _ = store.save_groups(groups);
            }
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
/// Error codes the app may show with their own message.
const PUBLIC_ERRORS: &[&str] = &[
    "folder_exists", "site_exists", "invalid_name", "node_not_installed", "php_not_installed",
    "scaffold_step_failed", "kmp_use_wizard", "unknown_template", "domain_in_use",
    "postgres_not_installed", "postgres_command_failed", "no_free_port", "invalid_group_name",
    "checksum_mismatch", "checksum_not_found", "devtool_step_failed", "licenses_not_accepted", "jdk_not_installed",
    "uv_not_installed", "python_not_installed", "swiftly_not_installed", "version_not_in_catalog", "download_failed", "signature_invalid", "cargo_not_installed", "clt_not_installed", "invalid_backup", "clone_failed", "invalid_remote",
];

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
            // Known codes are fixed strings of this engine (never request data or paths), so the
            // app can say what happened; anything else stays generic.
            let code = error.to_string();
            if PUBLIC_ERRORS.contains(&code.as_str()) {
                json!({"ok":false,"error":{"code":code,"messageKey":format!("error.{code}")}})
            } else {
                json!({"ok":false,"error":{"code":"invalid_request","messageKey":"engine.requestFailed"}})
            }
        }
    };
    println!("{response}");
}
