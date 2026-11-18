//! Requests about projects: the list and its records, folders, environments, renaming, the
//! new-project assistant, Git of the projects and watched folders.

use crate::{core::store::Store, daemon, web};
use anyhow::Result;
use serde_json::{Value, json};

/// Requests of this domain; `None` when `method` is not one of them.
pub fn dispatch(store: &Store, method: &str, request: &Value) -> Result<Option<Value>> {
    let id = request["id"].as_str().unwrap_or("");
    let result: Result<Value> = match method {
        // Environments of a site's .env. Secret values never reach these responses (R1, R6).
        "envList" => {
            let project = store.get(id)?;
            Ok(json!({
                "site": web::projects::envs::load(store, id)?,
                "guard": web::projects::envs::git_guard(&project),
                "exampleKeys": web::projects::envs::example_keys(&project),
                "hasEnv": project.path.join(".env").is_file(),
                "publicPending": web::projects::envs::public_pending(store, id),
            }))
        }
        "envSave" => {
            let site: web::projects::envs::SiteEnvironments =
                serde_json::from_value(request["site"].clone())?;
            web::projects::envs::save(store, id, &site, request["actor"].as_str().unwrap_or(""))?;
            Ok(serde_json::to_value(web::projects::envs::load(store, id)?)?)
        }
        // Keys moved in from the vault: names only; their values are already in the Keychain.
        "envMergeSecrets" => {
            let keys: Vec<String> = serde_json::from_value(request["keys"].clone())?;
            let kind: Option<web::projects::envs::Kind> = match &request["kind"] {
                Value::Null => None,
                kind => Some(serde_json::from_value(kind.clone())?),
            };
            let name = request["name"].as_str().unwrap_or("");
            Ok(serde_json::to_value(
                web::projects::envs::merge_secret_keys(
                    store,
                    id,
                    request["env"].as_str().unwrap_or(""),
                    &keys,
                    kind.map(|kind| (name, kind)),
                    request["actor"].as_str().unwrap_or(""),
                )?,
            )?)
        }
        "envDelete" => Ok(serde_json::to_value(
            web::projects::envs::delete_environment(
                store,
                id,
                request["env"].as_str().unwrap_or(""),
                request["actor"].as_str().unwrap_or(""),
            )?,
        )?),
        "envActivate" => {
            let secrets: std::collections::BTreeMap<String, String> =
                serde_json::from_value(request["secrets"].clone()).unwrap_or_default();
            let site = web::projects::envs::activate(
                store,
                id,
                request["env"].as_str().unwrap_or(""),
                &secrets,
                request["confirmed"] == true,
                request["actor"].as_str().unwrap_or(""),
            )?;
            drop(secrets);
            // New values only take effect once the site's processes restart: right away unless the
            // app asks first (`restart: false`, then `restartProcesses`).
            let _ = daemon::request_sync(store, "reload", json!({}), false);
            let project = store.get(id)?;
            if request["restart"] != false
                && project.enabled
                && !web::projects::envs::production_active(store, id)
            {
                for process in project.processes.iter().filter(|p| p.autostart) {
                    let _ = daemon::request_sync(
                        store,
                        "restart",
                        json!({"id": format!("{}.{}", id, process.name)}),
                        false,
                    );
                }
            }
            Ok(serde_json::to_value(site)?)
        }
        "envExport" => {
            let secrets: std::collections::BTreeMap<String, String> =
                serde_json::from_value(request["secrets"].clone()).unwrap_or_default();
            web::projects::envs::export(
                store,
                id,
                request["env"].as_str().unwrap_or(""),
                &secrets,
                std::path::Path::new(request["path"].as_str().unwrap_or("")),
                request["actor"].as_str().unwrap_or(""),
            )?;
            Ok(json!(true))
        }
        "envAudit" => {
            web::projects::envs::audit(
                store,
                id,
                request["env"].as_str().unwrap_or(""),
                request["action"].as_str().unwrap_or(""),
                request["key"].as_str().unwrap_or(""),
                request["actor"].as_str().unwrap_or(""),
            )?;
            Ok(json!(true))
        }
        "envClassify" => {
            // Secret by default for credential-like names (R2); names only, never values.
            let keys: Vec<String> =
                serde_json::from_value(request["keys"].clone()).unwrap_or_default();
            Ok(json!(
                keys.iter()
                    .map(|k| web::projects::envs::looks_secret(k))
                    .collect::<Vec<_>>()
            ))
        }
        "envAuditLog" => Ok(serde_json::to_value(web::projects::envs::audit_lines(
            store, id,
        )?)?),
        "siteGroups" => Ok(serde_json::to_value(
            if web::projects::disk::load(store)?.enabled {
                web::projects::disk::groups_view(store)?
            } else {
                store.groups()?
            },
        )?),
        "saveSiteGroups" => {
            let groups = serde_json::from_value(request["groups"].clone())?;
            Ok(serde_json::to_value(
                if web::projects::disk::load(store)?.enabled {
                    web::projects::disk::save_groups(store, groups)?
                } else {
                    store.save_groups(groups)?
                },
            )?)
        }
        // The folders of the disk (the sidebar follows them): state, acting on them and the
        // first comparison with `groups.json`. See web/projects/disk.rs.
        "diskState" => Ok(web::projects::disk::state(
            store,
            request["root"].as_str().map(std::path::Path::new),
        )?),
        "diskMove" => web::projects::disk::move_into(
            store,
            std::path::Path::new(request["path"].as_str().unwrap_or("")),
            std::path::Path::new(request["into"].as_str().unwrap_or("")),
        ),
        "diskRenameFolder" => web::projects::disk::rename_folder(
            store,
            std::path::Path::new(request["path"].as_str().unwrap_or("")),
            request["name"].as_str().unwrap_or(""),
        ),
        "diskCreateFolder" => web::projects::disk::create_folder(
            store,
            std::path::Path::new(request["parent"].as_str().unwrap_or("")),
            request["name"].as_str().unwrap_or(""),
        ),
        "diskRemoveFolder" => web::projects::disk::remove_folder(
            store,
            std::path::Path::new(request["path"].as_str().unwrap_or("")),
        ),
        "diskMultipart" => Ok(serde_json::to_value(web::projects::disk::set_multipart(
            store,
            request["path"].as_str().unwrap_or(""),
            request["on"] == true,
        )?)?),
        "diskMigrate" => web::projects::disk::migrate(store, request["accept"] == true),
        "diskMode" => {
            web::projects::disk::set_enabled(store, request["enabled"] == true)?;
            Ok(json!(true))
        }
        // Points a project whose folder went away at where it is now: a project folder that no
        // other project uses.
        "relocateProject" => {
            let path = std::path::PathBuf::from(request["path"].as_str().unwrap_or(""));
            anyhow::ensure!(path.is_absolute(), "invalid_path");
            anyhow::ensure!(
                web::projects::detect::looks_like_project(&path),
                "not_a_project"
            );
            let project = store.relocate(id, &path)?;
            let _ = daemon::request_sync(store, "reload", json!({}), false);
            Ok(serde_json::to_value(project)?)
        }
        // A project's new id, or the folder it points at, with everything that depends on them
        // (P-41; see web/projects/rename.rs). The Keychain step is the app's: `keychainMoved` says it is
        // done, otherwise it stays pending in `pendingRenames`.
        "renameProject" => {
            let options = web::projects::rename::RenameOptions {
                name: request["name"].as_str().map(str::to_string),
                domain: request["domain"] == true,
                keychain_moved: request["keychainMoved"] == true,
                actor: request["actor"].as_str().unwrap_or("").to_string(),
            };
            web::projects::rename::rename_project(
                store,
                id,
                request["newId"].as_str().unwrap_or(""),
                &options,
            )
        }
        "moveProject" => web::projects::rename::move_project(
            store,
            id,
            std::path::Path::new(request["path"].as_str().unwrap_or("")),
        ),
        "pendingRenames" => Ok(serde_json::to_value(web::projects::rename::pending(
            store,
        )?)?),
        "renameStepDone" => Ok(serde_json::to_value(web::projects::rename::step_done(
            store,
            request["from"].as_str().unwrap_or(""),
            request["to"].as_str().unwrap_or(""),
            request["step"].as_str().unwrap_or(""),
        )?)?),
        "createProject" => {
            let options = web::projects::scaffold::Options {
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
                framework_version: request["frameworkVersion"].as_str().unwrap_or("").into(),
                mysql_password: request["mysqlPassword"]
                    .as_str()
                    .filter(|p| !p.is_empty())
                    .map(str::to_string),
            };
            anyhow::ensure!(options.parent.is_absolute(), "invalid_path");
            let created = web::projects::scaffold::create(store, &options)?;
            if created.project.is_some() {
                let _ = daemon::request_sync(store, "reload", json!({}), false);
            }
            Ok(json!({"project": created.project, "path": created.path, "notes": created.notes}))
        }
        "gitStatus" => {
            // Branch and pending changes of every site that is a Git repository.
            let mut out = serde_json::Map::new();
            for project in store.list()? {
                if let Some(info) = web::projects::git::info(&project) {
                    out.insert(project.id.clone(), serde_json::to_value(info)?);
                }
            }
            Ok(Value::Object(out))
        }
        "worktrees" => Ok(serde_json::to_value(web::projects::git::worktrees(
            store,
            &store.get(id)?,
        )?)?),
        "addWorktreeSite" => {
            let path = std::path::PathBuf::from(request["path"].as_str().unwrap_or(""));
            anyhow::ensure!(path.is_absolute(), "invalid_path");
            let project = web::projects::git::add_worktree_site(store, id, &path)?;
            let _ = daemon::request_sync(store, "reload", json!({}), false);
            Ok(serde_json::to_value(project)?)
        }
        "branchChanges" => Ok(serde_json::to_value(web::projects::git::branch_changes(
            store,
            id,
            request["from"].as_str().unwrap_or(""),
            request["to"].as_str().unwrap_or(""),
        )?)?),
        "siteTask" => {
            web::projects::git::run_task(store, id, request["task"].as_str().unwrap_or(""))?;
            Ok(json!(true))
        }
        "stepLog" => Ok(serde_json::to_value(web::projects::scaffold::log_tail(
            store,
            request["name"].as_str().unwrap_or(""),
        )?)?),
        "scanFolder" => {
            let path = std::path::PathBuf::from(request["path"].as_str().unwrap_or(""));
            anyhow::ensure!(path.is_absolute(), "invalid_path");
            web::projects::detect::scan(&path)
        }
        "detect" => {
            let path = std::path::PathBuf::from(request["path"].as_str().unwrap_or(""));
            anyhow::ensure!(path.is_absolute(), "invalid_path");
            Ok(serde_json::to_value(web::projects::detect::detect(&path)?)?)
        }
        // Every project; one whose folder is not there is listed too, marked `missing` and off (it
        // is neither served nor started), so it never vanishes from the app.
        "listProjects" => {
            let mut listed = vec![];
            for project in store.list()? {
                // A project without a server says what it is built with (Swift, Rust, Android…).
                let technology = (!project.kind.served())
                    .then(|| web::projects::detect::technology(&project.path));
                let mut value = serde_json::to_value(project)?;
                if let Some(technology) = technology.flatten() {
                    value["technology"] = json!(technology);
                }
                listed.push(value);
            }
            for project in store.folder_missing()? {
                let mut value = serde_json::to_value(project)?;
                value["enabled"] = json!(false);
                value["missing"] = json!(true);
                listed.push(value);
            }
            listed.sort_by(|a, b| a["id"].as_str().cmp(&b["id"].as_str()));
            Ok(Value::Array(listed))
        }
        "saveProject" => {
            // `missing` and `technology` are what the list says of a project, never part of its
            // record.
            let mut record = request["project"].clone();
            if let Some(fields) = record.as_object_mut() {
                fields.remove("missing");
                fields.remove("technology");
            }
            let before = record["id"]
                .as_str()
                .and_then(|id| store.get(id).ok())
                .and_then(|p| p.upstream);
            let project = store.save(serde_json::from_value(record)?)?;
            // A new port reaches the `.env` of the projects that name it with `{port:<id>}`.
            let dependents = if before.is_some() && before != project.upstream {
                web::projects::envs::refresh_port_dependents(
                    store,
                    &project.id,
                    request["actor"].as_str().unwrap_or(""),
                )?
            } else {
                vec![]
            };
            let _ = daemon::request_sync(store, "reload", json!({}), false);
            let mut value = serde_json::to_value(project)?;
            value["portDependents"] = serde_json::to_value(dependents)?;
            Ok(value)
        }
        "setSiteEnabled" => {
            anyhow::ensure!(
                !store.folder_missing()?.iter().any(|p| p.id == id),
                "folder_missing"
            );
            let mut project = store.get(id)?;
            // A project without a server has no switch.
            anyhow::ensure!(project.kind.served(), "project_not_served");
            project.enabled = request["enabled"].as_bool().unwrap_or(false);
            let project = store.save(project)?;
            // Turned on, its services that are installed and off come on with it, and the
            // answer says which (`servicesStarted`) so the app can tell the user.
            let started = if project.enabled {
                web::projects::service_use::start_for(store, &project, &format!("project:{id}"))?
            } else {
                vec![]
            };
            let _ = daemon::request_sync(store, "reload", json!({}), false);
            let mut value = serde_json::to_value(project)?;
            value["servicesStarted"] = json!(started);
            Ok(value)
        }
        // What each project needs now (P-42; see web/projects/attention.rs), and its one-click fix.
        "projectAttention" => Ok(Value::Object(web::projects::attention::all(store)?)),
        "applyProjectFix" => {
            let project = web::projects::attention::apply(
                store,
                id,
                request["fix"].as_str().unwrap_or(""),
                request["process"].as_str().unwrap_or(""),
            )?;
            let _ = daemon::request_sync(store, "reload", json!({}), false);
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
            // Projects that named its port keep their `.env` and say it is out of date.
            let dependents = web::projects::envs::refresh_port_dependents(
                store,
                id,
                request["actor"].as_str().unwrap_or(""),
            )?;
            let _ = daemon::request_sync(store, "reload", json!({}), false);
            Ok(json!({"portDependents": dependents}))
        }
        // ---- Watched folders ----
        "watchedFolders" => Ok(serde_json::to_value(web::projects::watch::load(store)?)?),
        "setWatchedFolder" => Ok(serde_json::to_value(web::projects::watch::set(
            store,
            std::path::Path::new(request["path"].as_str().unwrap_or("")),
            request["watched"] == true,
        )?)?),
        "ignoreWatched" => {
            let paths: Vec<std::path::PathBuf> =
                serde_json::from_value(request["paths"].clone()).unwrap_or_default();
            web::projects::watch::ignore(
                store,
                std::path::Path::new(request["folder"].as_str().unwrap_or("")),
                &paths,
            )?;
            Ok(json!(true))
        }
        "watchedScan" => Ok(json!(web::projects::watch::scan(store)?)),
        _ => return Ok(None),
    };
    result.map(Some)
}
