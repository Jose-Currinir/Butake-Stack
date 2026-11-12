//! "Mi entorno": everything needed to set up another Mac the same way, in one file: work profiles,
//! languages and engines (which and which version), developer tools, Stack's settings, sites (with
//! their Git origin so they can be cloned), folders and environments. Never secrets: environments
//! keep secret keys with empty values (the values live in the Keychain) and Git URLs lose any
//! credentials. Restoring is a plan the user reviews first; nothing is downloaded or cloned without it.
use crate::{envs, git, model::Project, runtimes, store::{SiteGroup, Store}, tools};
use anyhow::{ensure, Result};
use serde_json::{json, Value};
use std::{fs, path::{Path, PathBuf}, process::Command};

const FORMAT: &str = "butake-stack-entorno";

fn site_records(store: &Store) -> Vec<Project> {
    let mut sites = store.list().unwrap_or_default();
    // Sites whose folder isn't on this Mac are part of the environment too.
    for (id, _) in store.missing().unwrap_or_default() {
        if let Ok(text) = fs::read_to_string(store.root().join("projects").join(format!("{id}.json"))) {
            if let Ok(project) = serde_json::from_str::<Project>(&text) { sites.push(project); }
        }
    }
    sites
}

pub fn export(store: &Store, profiles: Vec<String>) -> Result<Value> {
    let mut tools_map = serde_json::Map::new();
    for tool in tools::TOOLS {
        let versions: Vec<String> = tools::installed(store, tool).unwrap_or_default().into_iter().map(|m| m.version).collect();
        if !versions.is_empty() { tools_map.insert(tool.into(), json!(versions)); }
    }
    let php: Vec<String> = runtimes::list(store).into_iter().filter(|r| r.installed).map(|r| r.series).collect();
    let dev = tools::dev_tools(store)?;
    let devtools: Vec<&str> = ["rustup", "uv", "gh", "cloudflared", "wrangler", "android-sdk"].into_iter()
        .filter(|id| dev[*id]["installed"] == true).collect();
    let sites: Vec<Value> = site_records(store).into_iter().map(|project| {
        let remote = git::origin(&project.path);
        let branch = git::current_branch(&project.path);
        json!({"project": project, "git": {"remote": remote, "branch": branch}})
    }).collect();
    let mut environments = serde_json::Map::new();
    for site in &sites {
        let id = site["project"]["id"].as_str().unwrap_or_default();
        if let Ok(mut envs) = envs::load(store, id) {
            if envs.environments.is_empty() { continue; }
            // Secrets stay out (they're empty in the store already; this keeps it so if that changes).
            for environment in &mut envs.environments {
                for entry in &mut environment.entries { if entry.secret { entry.value.clear(); } }
            }
            environments.insert(id.into(), serde_json::to_value(envs)?);
        }
    }
    let python = crate::devtools::installed_pythons();
    Ok(json!({
        "format": FORMAT, "version": 1,
        "stackVersion": env!("CARGO_PKG_VERSION"),
        "profiles": profiles,
        "config": store.config()?,
        "runtimes": {"php": php, "tools": tools_map},
        "devtools": devtools,
        "python": python,
        "sites": sites,
        "groups": store.groups()?,
        "environments": environments,
    }))
}

fn check(data: &Value) -> Result<()> {
    ensure!(data["format"] == FORMAT && data["version"].as_u64() == Some(1), "invalid_backup");
    Ok(())
}

/// What restoring would do on this Mac: what's missing to download, sites already here, to clone
/// or impossible to bring (no folder, no Git origin), and how many folders and environments.
pub fn plan(store: &Store, data: &Value) -> Result<Value> {
    check(data)?;
    let have_php: Vec<String> = runtimes::list(store).into_iter().filter(|r| r.installed).map(|r| r.series).collect();
    let php: Vec<&Value> = data["runtimes"]["php"].as_array().map(|a| a.iter().filter(|v| !have_php.iter().any(|h| Some(h.as_str()) == v.as_str())).collect()).unwrap_or_default();
    let mut tools_missing = vec![];
    if let Some(map) = data["runtimes"]["tools"].as_object() {
        for (tool, versions) in map {
            if tools::validate_tool(tool).is_err() { continue; }
            let have: Vec<String> = tools::installed(store, tool).unwrap_or_default().into_iter().map(|m| m.version).collect();
            for version in versions.as_array().into_iter().flatten().filter_map(Value::as_str) {
                if !have.iter().any(|h| h == version) { tools_missing.push(json!({"tool": tool, "version": version})); }
            }
        }
    }
    let dev = tools::dev_tools(store)?;
    let devtools: Vec<&Value> = data["devtools"].as_array().map(|a| a.iter().filter(|id| id.as_str().is_some_and(|id| dev[id]["installed"] != true)).collect()).unwrap_or_default();
    let have_python = crate::devtools::installed_pythons();
    let python: Vec<&Value> = data["python"].as_array().map(|a| a.iter().filter(|v| v.as_str().is_some_and(|line| !have_python.iter().any(|h| h == line))).collect()).unwrap_or_default();
    let registered: Vec<String> = store.list()?.into_iter().map(|p| p.id).chain(store.missing()?.into_iter().map(|(id, _)| id)).collect();
    let sites: Vec<Value> = data["sites"].as_array().into_iter().flatten().map(|site| {
        let project = &site["project"];
        let id = project["id"].as_str().unwrap_or("");
        let path = PathBuf::from(project["path"].as_str().unwrap_or(""));
        let remote = site["git"]["remote"].as_str();
        let state = if registered.iter().any(|r| r == id) { "registered" }
            else if path.is_dir() { "ready" }
            else if remote.is_some() { "clone" }
            else { "unavailable" };
        json!({"id": id, "name": project["name"], "kind": project["kind"], "path": path, "remote": remote, "branch": site["git"]["branch"], "state": state})
    }).collect();
    Ok(json!({
        "profiles": data["profiles"], "php": php, "tools": tools_missing, "devtools": devtools, "python": python,
        "sites": sites, "groups": data["groups"].as_array().map(Vec::len).unwrap_or(0),
        "environments": data["environments"].as_object().map(|m| m.len()).unwrap_or(0),
        "config": data["config"],
    }))
}

/// Applies the settings, folders, sites whose folder is here (registered off) and environments
/// (without secrets, never over existing ones). Downloads and clones are separate calls.
pub fn restore(store: &Store, data: &Value, parts: &Value) -> Result<Value> {
    check(data)?;
    let mut done = serde_json::Map::new();
    if parts["config"] == true {
        let wanted: crate::model::StackConfig = serde_json::from_value(data["config"].clone())?;
        wanted.validate()?;
        store.save_config(&wanted)?;
        done.insert("config".into(), json!(true));
    }
    let mut added = vec![];
    if parts["sites"] == true {
        let registered: Vec<String> = store.list()?.into_iter().map(|p| p.id).collect();
        for site in data["sites"].as_array().into_iter().flatten() {
            let Ok(mut project) = serde_json::from_value::<Project>(site["project"].clone()) else { continue };
            if registered.contains(&project.id) || !project.path.is_dir() { continue; }
            project.enabled = false;
            if store.save(project.clone()).is_ok() { added.push(project.id); }
        }
        done.insert("sites".into(), json!(added));
    }
    if parts["environments"] == true {
        let mut count = 0;
        if let Some(map) = data["environments"].as_object() {
            for (id, value) in map {
                if crate::model::validate_id(id).is_err() || !envs::load(store, id).map(|e| e.environments.is_empty()).unwrap_or(false) { continue; }
                if let Ok(mut site) = serde_json::from_value::<envs::SiteEnvironments>(value.clone()) {
                    for environment in &mut site.environments {
                        for entry in &mut environment.entries { if entry.secret { entry.value.clear(); } }
                    }
                    if envs::save(store, id, &site, "restore").is_ok() { count += 1; }
                }
            }
        }
        done.insert("environments".into(), json!(count));
    }
    if parts["groups"] == true {
        let incoming: Vec<SiteGroup> = serde_json::from_value(data["groups"].clone()).unwrap_or_default();
        let mut groups = store.groups()?;
        for group in incoming {
            if let Some(existing) = groups.iter_mut().find(|g| g.id == group.id) {
                for site in group.sites { if !existing.sites.contains(&site) { existing.sites.push(site); } }
            } else {
                groups.push(group);
            }
        }
        store.save_groups(groups)?;
        done.insert("groups".into(), json!(true));
    }
    Ok(Value::Object(done))
}

/// Clones a site's repository into the folder it had (its parent folders are created). Uses the
/// user's own Git setup (SSH agent, Keychain credentials) and never prompts.
pub fn clone(path: &Path, remote: &str, branch: Option<&str>) -> Result<()> {
    ensure!(path.is_absolute() && !path.exists(), "folder_exists");
    ensure!(path.starts_with(dirs::home_dir().unwrap_or_default()), "invalid_path");
    let valid = remote.len() <= 500 && !remote.starts_with('-') && !remote.chars().any(|c| c.is_whitespace() || c.is_control())
        && (remote.starts_with("https://") || remote.starts_with("ssh://") || remote.starts_with("git@"));
    ensure!(valid, "invalid_remote");
    if let Some(parent) = path.parent() { fs::create_dir_all(parent)?; }
    let mut command = Command::new("/usr/bin/git");
    command.args(["clone", "--quiet"]);
    if let Some(branch) = branch.filter(|b| !b.starts_with('-') && b.len() <= 200 && !b.contains("..")) { command.args(["--branch", branch]); }
    command.arg("--").arg(remote).arg(path)
        .env_clear()
        .env("HOME", dirs::home_dir().unwrap_or_default())
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .env("GIT_TERMINAL_PROMPT", "0");
    if let Some(agent) = std::env::var_os("SSH_AUTH_SOCK") { command.env("SSH_AUTH_SOCK", agent); }
    let status = command.stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).status()?;
    if !status.success() {
        let _ = fs::remove_dir_all(path);
    }
    ensure!(status.success(), "clone_failed");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn git_urls_lose_their_credentials() {
        assert_eq!(git::strip_credentials("https://usuario:token@github.com/a/b.git"), "https://github.com/a/b.git");
        assert_eq!(git::strip_credentials("https://github.com/a/b.git"), "https://github.com/a/b.git");
        assert_eq!(git::strip_credentials("git@github.com:a/b.git"), "git@github.com:a/b.git");
    }
}
