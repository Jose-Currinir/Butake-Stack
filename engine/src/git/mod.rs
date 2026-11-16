//! The Git tool (`git`): the engine of the former Butake Git app inside Stack's engine (see
//! docs/herramientas.md, «Git», and docs/architecture.md, «Herramienta Git»). Every operation is a
//! `git*` method that answers `plugin_disabled` while the tool is off.
//!
//! Guards kept from the original product, each with its test: Git gets separate arguments (no
//! shell); the primary branch is protected per repository; destructive actions, pushes and console
//! commands need `confirmed`; pushes name their destination and are never forced or mass pushes; a
//! history rewrite stores `refs/butake/backup/<branch>/<epoch>` first and can be undone; reads have
//! size limits; no credential reaches a response (URLs, Git's output, error details).
//!
//! What a Stack project knows about its repository (branch, pending changes, worktrees) stays in
//! `web/projects/git.rs`, part of the base, and needs no tool.

mod access;
mod actions;
mod branches;
mod console;
mod diff;
mod editing;
mod files;
mod protection;
mod remotes;
pub mod repositories;
mod rewrite;
mod runner;
mod status;
#[cfg(test)]
mod tests;
mod words;
mod worktrees;

pub use console::{run_console, write_plan};
pub use runner::{public_detail, GitError};

use crate::core::store::Store;
use runner::{error, git, Result};
use serde_json::{json, Value};
use std::{future::Future, path::Path};

/// Every method of the tool. `gitStatus` is not here: that name belongs to the base (the branch and
/// changes of every Stack project); the tool's list of changed files is `gitChanges`.
///
/// Not called by the app, kept for the command line (`butake-stack` with JSON on stdin) and the
/// console: `gitPrepare` and `gitRun` (a console command checked and run with the same policy as
/// `git-console`), `gitRebaseCandidates` and `gitValidateRebase` (the plan an interactive rebase
/// gives `git-console` and `git-write-plan`), and `gitSetMainProtection` (the only way to change the
/// protection of the primary branch, which the app reads; the tests set it up with it).
pub const METHODS: &[&str] = &[
    "gitCapabilities",
    "gitHelp",
    "gitRepositories",
    "gitRepositoryAdd",
    "gitRepositoryForget",
    "gitClone",
    "gitSshAccess",
    "gitSshFingerprints",
    "gitSshTrust",
    "gitInit",
    "gitPublish",
    "gitOpen",
    "gitSnapshot",
    "gitChanges",
    "gitStats",
    "gitRewriteCandidates",
    "gitRewriteApply",
    "gitRewriteUndo",
    "gitBranchSync",
    "gitCopyCommits",
    "gitSetRemoteProtection",
    "gitSetMainProtection",
    "gitStagePaths",
    "gitBranchDetails",
    "gitReadFile",
    "gitDiff",
    "gitAction",
    "gitPrepare",
    "gitRun",
    "gitQuery",
    "gitRebaseCandidates",
    "gitValidateRebase",
    "gitStageHunk",
    "gitConflict",
    "gitResolveConflict",
];

/// Whether `method` belongs to this tool.
pub fn is_method(method: &str) -> bool {
    METHODS.contains(&method)
}

/// Largest request a method of the tool accepts (a conflict resolution or a file of the editor
/// travels whole); the rest of the engine keeps 1 MiB.
pub const REQUEST_LIMIT: usize = 16 * 1_048_576;

/// Runs the tool's async code from the engine's synchronous dispatch.
fn block<F: Future>(future: F) -> F::Output {
    match tokio::runtime::Handle::try_current() {
        Ok(handle) => tokio::task::block_in_place(|| handle.block_on(future)),
        Err(_) => tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("tokio runtime")
            .block_on(future),
    }
}

/// Requests of the Git tool (`git*`); the caller checked that the tool is on.
pub fn dispatch(store: &Store, method: &str, request: &Value) -> anyhow::Result<Value> {
    // Transfers over the network can take minutes: the app may stop them («Cancelar»).
    let action = request["action"].as_str().unwrap_or("");
    if matches!(method, "gitClone" | "gitPublish")
        || (method == "gitAction"
            && matches!(
                action,
                "fetch" | "pull" | "pull_merge" | "pull_rebase" | "pull_autostash" | "push"
            ))
    {
        runner::stop_on_request();
    }
    match method {
        "gitRepositories" => repositories::overview(store),
        "gitRepositoryAdd" => {
            let root = block(status::open_root(text(request, "path")))?;
            repositories::add(store, &root)?;
            repositories::overview(store)
        }
        "gitRepositoryForget" => {
            let path = Path::new(text(request, "path"));
            anyhow::ensure!(path.is_absolute(), "invalid_path");
            repositories::forget(store, path)?;
            repositories::overview(store)
        }
        "gitOpen" => {
            let root = block(status::open_root(text(request, "path")))?;
            let value = block(status::snapshot_with(
                &root,
                limit(request),
                request["stats"].as_bool().unwrap_or(false),
            ))?;
            // A failure to remember it never fails the opening.
            let _ = repositories::opened(store, &root);
            Ok(json!(value))
        }
        // What a clone over SSH needs on this Mac (no folder involved).
        "gitSshAccess" | "gitSshFingerprints" | "gitSshTrust" => {
            let home = Store::home().ok_or_else(|| anyhow::anyhow!("invalid_path"))?;
            let url = text(request, "url");
            Ok(match method {
                "gitSshAccess" => json!(access::ssh_access(
                    &home,
                    std::env::var_os("SSH_AUTH_SOCK").as_deref(),
                    url
                )?),
                "gitSshFingerprints" => json!(access::host_fingerprints(url)?),
                _ => {
                    confirmed(request, "Confirma que confías en el servidor.")?;
                    let seen = list(request, "fingerprints", "Faltan las huellas que viste.")?;
                    access::trust_host(&home, url, &seen)?;
                    json!(true)
                }
            })
        }
        _ => Ok(block(run(method, request))?),
    }
}

fn text<'a>(request: &'a Value, key: &str) -> &'a str {
    request[key].as_str().unwrap_or("")
}
fn limit(request: &Value) -> usize {
    request["limit"]
        .as_u64()
        .map(|value| value as usize)
        .unwrap_or(status::DEFAULT_HISTORY_LIMIT)
}
fn confirmed(request: &Value, detail: &str) -> Result<()> {
    if request["confirmed"] == true {
        Ok(())
    } else {
        Err(error("confirmation_required", detail))
    }
}
fn list(request: &Value, key: &str, detail: &str) -> Result<Vec<String>> {
    serde_json::from_value(request[key].clone()).map_err(|_| error("invalid_arguments", detail))
}

/// The methods that work on a folder (`path`): the repository, or the parent folder of a clone or
/// a new repository.
async fn run(method: &str, r: &Value) -> Result<Value> {
    match method {
        "gitCapabilities" => return Ok(json!(console::capabilities().await?)),
        "gitHelp" => return Ok(json!(console::command_help(text(r, "command")).await?)),
        _ => {}
    }
    let root = Path::new(text(r, "path")).canonicalize().map_err(|_| {
        error(
            "invalid_path",
            "La carpeta no existe o no se puede leer. Elige otra o revisa sus permisos.",
        )
    })?;
    if !root.is_dir() {
        return Err(error("invalid_path", "Selecciona una carpeta."));
    }
    let root = root.as_path();
    Ok(match method {
        "gitClone" => json!(remotes::clone(root, text(r, "url"), text(r, "name")).await?),
        "gitInit" => json!(
            remotes::init_repository(
                root,
                text(r, "name"),
                r["develop"].as_bool().unwrap_or(true)
            )
            .await?
        ),
        "gitPublish" => {
            confirmed(r, "Confirma la publicación.")?;
            let branches: Vec<String> =
                serde_json::from_value(r["branches"].clone()).unwrap_or_default();
            json!(
                remotes::publish(root, text(r, "url"), &branches, r["replaceOrigin"] == true)
                    .await?
            )
        }
        "gitSnapshot" => json!(
            status::snapshot_with(root, limit(r), r["stats"].as_bool().unwrap_or(false)).await?
        ),
        "gitChanges" => json!(status::status(root).await?),
        "gitStats" => json!(status::line_stats(root).await),
        "gitRewriteCandidates" => json!(rewrite::candidates(root).await?),
        "gitRewriteApply" => {
            confirmed(r, "Confirma la reorganización.")?;
            let plan: rewrite::RewritePlan = serde_json::from_value(r["plan"].clone())
                .map_err(|_| error("invalid_plan", "Plan inválido."))?;
            json!(rewrite::apply(root, &plan).await?)
        }
        "gitRewriteUndo" => {
            confirmed(r, "Confirma deshacer.")?;
            json!(rewrite::undo(root, text(r, "backup")).await?)
        }
        "gitBranchSync" => {
            json!(branches::branch_sync(root, text(r, "left"), text(r, "right")).await?)
        }
        "gitCopyCommits" => {
            confirmed(r, "Confirma la copia de commits.")?;
            let hashes = list(r, "hashes", "Lista de commits inválida.")?;
            json!(branches::copy_commits(root, text(r, "target"), &hashes).await?)
        }
        "gitSetRemoteProtection" => {
            json!(protection::set_remote_protection(root, text(r, "value")).await?)
        }
        "gitSetMainProtection" => {
            confirmed(r, "Confirma el cambio de protección.")?;
            json!(protection::set_main_protection(root, text(r, "value")).await?)
        }
        "gitStagePaths" => {
            let paths = list(r, "paths", "Lista de archivos inválida.")?;
            json!(status::stage_paths(root, &paths, r["staged"].as_bool().unwrap_or(false)).await?)
        }
        "gitBranchDetails" => {
            branches::branch_details(root, text(r, "branch"), text(r, "base")).await?
        }
        "gitReadFile" => files::read_file(root, text(r, "file")).await?,
        // `whole`: a file that is new since HEAD, shown complete (staged copy plus later edits).
        "gitDiff" if r["whole"] == true => json!(diff::diff_whole(root, text(r, "file")).await?),
        "gitDiff" => json!(
            diff::diff(
                root,
                text(r, "file"),
                r["staged"].as_bool().unwrap_or(false)
            )
            .await?
        ),
        "gitAction" => {
            let action: actions::Action = serde_json::from_value(r["action"].clone())
                .map_err(|_| error("unknown_action", "Acción desconocida."))?;
            json!(
                actions::execute(
                    root,
                    action,
                    text(r, "value"),
                    r["confirmed"].as_bool().unwrap_or(false)
                )
                .await?
            )
        }
        "gitPrepare" => {
            json!(console::prepare_in(root, text(r, "command"), text(r, "arguments")).await?)
        }
        "gitRun" => {
            let prepared =
                console::prepare_in(root, text(r, "command"), text(r, "arguments")).await?;
            confirmed(r, "Confirma el comando exacto.")?;
            let mut args = vec![prepared.command.as_str()];
            args.extend(prepared.args.iter().map(String::as_str));
            json!(console::public_output(
                &prepared.command,
                runner::git_console(root, &args).await?
            ))
        }
        "gitQuery" => {
            let args = list(r, "args", "Consulta inválida.")?;
            console::check_query(&args)?;
            let output = git(root, &args.iter().map(String::as_str).collect::<Vec<_>>()).await?;
            json!(console::public_output(&args[0], output))
        }
        "gitRebaseCandidates" => json!(console::rebase_candidates(root, text(r, "base")).await?),
        "gitValidateRebase" => {
            let plan = serde_json::from_value(r["plan"].clone())
                .map_err(|_| error("invalid_plan", "Plan inválido."))?;
            json!(console::validate_rebase(root, &plan).await?)
        }
        "gitStageHunk" => {
            editing::stage_hunk(
                root,
                text(r, "file"),
                r["staged"].as_bool().unwrap_or(false),
                r["index"].as_u64().unwrap_or(0) as usize,
                r["expected"].as_str(),
            )
            .await?;
            json!("ok")
        }
        "gitConflict" => json!(editing::conflict(root, text(r, "file")).await?),
        "gitResolveConflict" => {
            confirmed(r, "Confirma la resolución.")?;
            editing::resolve(
                root,
                text(r, "file"),
                text(r, "content"),
                text(r, "expected"),
            )
            .await?;
            json!("ok")
        }
        _ => return Err(error("unknown_method", "Operación desconocida.")),
    })
}
