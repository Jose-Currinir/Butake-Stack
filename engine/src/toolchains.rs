//! Versions per language: the global one (in Stack's config and, when the user asks for it, on the
//! terminal as symbolic links to the real binaries in `~/.local/bin`, never wrapper scripts), the one
//! of each project (in the ecosystem's standard file: `.nvmrc`, `.java-version`, `.python-version`,
//! `rust-toolchain.toml`, `.swift-version`) and the toolchain managers of Rust (rustup) and Swift
//! (swiftly, swift.org's installer).
use crate::{devtools, store::Store, tools};
use anyhow::{bail, ensure, Context, Result};
use serde_json::{json, Value};
use std::{
    fs,
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

/// Swift's official installer is signed by this Apple Team ID (Swift Open Source).
const SWIFT_TEAM: &str = "V9AUD2URP3";

/// Real binaries a language puts on the terminal: (link name, path inside its version folder).
fn binaries(store: &Store, language: &str, version: &str) -> Result<(PathBuf, Vec<(&'static str, &'static str)>)> {
    Ok(match language {
        "php" => {
            crate::runtimes::manifest(store, version)?;
            (store.root().join("runtimes/php").join(version), vec![("php", "bin/php"), ("composer", "composer.phar")])
        }
        "node" => (tools::resolve(store, "node", version).context("node_not_installed")?, vec![("node", "bin/node"), ("npm", "bin/npm"), ("npx", "bin/npx")]),
        "jdk" => (tools::resolve(store, "jdk", version).context("jdk_not_installed")?, vec![("java", "Contents/Home/bin/java"), ("javac", "Contents/Home/bin/javac"), ("jar", "Contents/Home/bin/jar")]),
        "python" => {
            let python = crate::python::resolve(store, version).context("python_not_installed")?;
            (python.parent().and_then(Path::parent).unwrap().to_path_buf(), vec![("python3", "bin/python3"), ("python", "bin/python3"), ("pip3", "bin/pip3"), ("pip", "bin/pip3")])
        }
        _ => bail!("unknown_language"),
    })
}

/// Links in `~/.local/bin` that point into Stack's runtimes (ours to replace or remove).
fn ours(link: &Path, store: &Store) -> bool {
    match fs::symlink_metadata(link) {
        Err(_) => true,
        Ok(meta) => meta.file_type().is_symlink() && fs::read_link(link).is_ok_and(|t| {
            // corepack writes relative links; resolve them before comparing.
            let resolved = if t.is_absolute() { t } else { link.parent().map(|p| p.join(&t)).unwrap_or(t) };
            let resolved = resolved.canonicalize().unwrap_or(resolved);
            let root = store.root().canonicalize().unwrap_or_else(|_| store.root().to_path_buf());
            resolved.starts_with(root.join("runtimes")) || resolved.starts_with(root.join("run")) || resolved.starts_with(store.root().join("runtimes"))
        }),
    }
}

/// What linking a language would do: links to create and files in the way that aren't Stack's
/// (those are never touched).
pub fn terminal_plan(store: &Store, language: &str, version: &str) -> Result<Value> {
    let bin = devtools::home()?.join(".local/bin");
    let (root, list) = binaries(store, language, version)?;
    let mut links = vec![];
    let mut blocked = vec![];
    for (name, relative) in list {
        if !root.join(relative).exists() { continue; }
        let link = bin.join(name);
        if ours(&link, store) { links.push(name) } else { blocked.push(name) }
    }
    Ok(json!({"links": links, "blocked": blocked, "bin": bin}))
}

/// Points `~/.local/bin/<name>` at the language's real binaries (atomic replace of our own links)
/// and adds `~/.local/bin` to the terminal's PATH. PHP also gets `PHPRC` to a stable folder that
/// follows the global version, so the terminal's `php` reads Stack's php.ini.
pub fn link_terminal(store: &Store, language: &str, version: &str) -> Result<Value> {
    let bin = devtools::home()?.join(".local/bin");
    fs::create_dir_all(&bin)?;
    let (root, list) = binaries(store, language, version)?;
    let mut linked = vec![];
    for (name, relative) in list {
        let target = root.join(relative);
        if !target.exists() { continue; }
        let link = bin.join(name);
        if !ours(&link, store) { continue; }
        if language == "php" && name == "composer" {
            // composer.phar runs as a program (#!/usr/bin/env php) when it is executable.
            fs::set_permissions(&target, std::os::unix::fs::PermissionsExt::from_mode(0o755))?;
        }
        replace_link(&target, &link)?;
        linked.push(name);
    }
    if language == "php" {
        crate::runtimes::generate_ini(store, version)?;
        let current = store.directory("config")?.join("php/current");
        replace_link(&store.root().join("config/php").join(version), &current)?;
    }
    if language == "node" {
        // pnpm and yarn as corepack's own links (Node up to 24 ships corepack).
        let node_bin = root.join("bin");
        if node_bin.join("corepack").exists() {
            corepack_enable(&node_bin, &bin)?;
        }
    }
    devtools::shell_path(store)?;
    Ok(json!({"linked": linked, "bin": bin}))
}

/// Removes the language's links from `~/.local/bin` (only links that point into Stack).
pub fn unlink_terminal(store: &Store, language: &str) -> Result<Value> {
    let bin = devtools::home()?.join(".local/bin");
    let names: &[&str] = match language {
        "php" => &["php", "composer"],
        "node" => &["node", "npm", "npx", "pnpm", "pnpx", "yarn", "yarnpkg"],
        "jdk" => &["java", "javac", "jar"],
        "python" => &["python3", "python", "pip3", "pip"],
        _ => bail!("unknown_language"),
    };
    let mut removed = vec![];
    for name in names {
        let link = bin.join(name);
        if fs::symlink_metadata(&link).is_ok() && ours(&link, store) {
            fs::remove_file(&link)?;
            removed.push(*name);
        }
    }
    Ok(json!({"removed": removed}))
}

/// Which languages are on the terminal through Stack's links, and which version each points to.
pub fn terminal_status(store: &Store) -> Value {
    let bin = devtools::home().map(|h| h.join(".local/bin")).unwrap_or_default();
    let mut out = serde_json::Map::new();
    for (language, name) in [("php", "php"), ("node", "node"), ("jdk", "java"), ("python", "python3")] {
        let link = bin.join(name);
        if let Ok(target) = fs::read_link(&link) {
            if ours(&link, store) {
                let runtimes = store.root().join("runtimes");
                let version = target.strip_prefix(&runtimes).ok().and_then(|r| r.iter().nth(1)).map(|v| v.to_string_lossy().into_owned());
                out.insert(language.into(), json!({"version": version}));
            }
        }
    }
    Value::Object(out)
}

pub fn replace_link(target: &Path, link: &Path) -> Result<()> {
    let temp = link.with_file_name(format!(".{}.butake-link", link.file_name().unwrap_or_default().to_string_lossy()));
    let _ = fs::remove_file(&temp);
    std::os::unix::fs::symlink(target, &temp)?;
    fs::rename(&temp, link)?;
    Ok(())
}

/// `corepack enable --install-directory <dir>`: pnpm, pnpx, yarn and yarnpkg as links to corepack.
pub fn corepack_enable(node_bin: &Path, dir: &Path) -> Result<()> {
    fs::create_dir_all(dir)?;
    let status = Command::new(node_bin.join("corepack"))
        .args(["enable", "--install-directory"]).arg(dir)
        .env_clear().env("PATH", format!("{}:/usr/bin:/bin", node_bin.display()))
        .env("HOME", devtools::home()?).env("COREPACK_ENABLE_DOWNLOAD_PROMPT", "0")
        .stdout(Stdio::null()).stderr(Stdio::null()).status()?;
    ensure!(status.success(), "devtool_step_failed");
    Ok(())
}

/// Folder with pnpm and yarn for a Node install, made once by corepack (`run/corepack/<version>`).
pub fn corepack_dir(store: &Store, node_bin: &Path) -> Option<PathBuf> {
    let version = node_bin.parent()?.file_name()?.to_string_lossy().into_owned();
    tools::validate_version(&version).ok()?;
    let dir = store.directory("run").ok()?.join("corepack").join(&version);
    if dir.join("pnpm").symlink_metadata().is_ok() { return Some(dir); }
    node_bin.join("corepack").exists().then(|| corepack_enable(node_bin, &dir).ok()).flatten().map(|_| dir)
}

// ---- Rust (rustup) ----

fn rustup() -> Result<PathBuf> {
    let home = devtools::home()?;
    let own = home.join(".cargo/bin/rustup");
    own.is_file().then_some(own).or_else(|| tools::user_tool("rustup")).context("cargo_not_installed")
}
fn rust_env(home: &Path) -> [(&'static str, String); 2] {
    [("CARGO_HOME", home.join(".cargo").to_string_lossy().into_owned()), ("RUSTUP_HOME", home.join(".rustup").to_string_lossy().into_owned())]
}
/// `stable`, `beta`, `nightly` or a release (`1.91`, `1.91.1`), optionally with the host triple.
pub fn validate_rust(toolchain: &str) -> Result<()> {
    let base = toolchain.strip_suffix("-aarch64-apple-darwin").or_else(|| toolchain.strip_suffix("-x86_64-apple-darwin")).unwrap_or(toolchain);
    let release = base.split('.').count() >= 2 && base.split('.').count() <= 3 && base.split('.').all(|p| !p.is_empty() && p.len() <= 3 && p.bytes().all(|c| c.is_ascii_digit()));
    ensure!(["stable", "beta", "nightly"].contains(&base) || release, "invalid_version");
    Ok(())
}
fn run_rustup(args: &[&str]) -> Result<String> {
    let home = devtools::home()?;
    let mut command = Command::new(rustup()?);
    command.args(args).env_clear().env("HOME", &home).env("PATH", format!("{}:/usr/bin:/bin", home.join(".cargo/bin").display()));
    for (k, v) in rust_env(&home) { command.env(k, v); }
    let out = command.stdin(Stdio::null()).stderr(Stdio::null()).output()?;
    ensure!(out.status.success(), "devtool_step_failed");
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}
/// Installed toolchains with their rustc version, and the global default.
pub fn rust_toolchains() -> Result<Value> {
    let list = run_rustup(&["toolchain", "list"])?;
    let home = devtools::home()?;
    let mut out = vec![];
    for line in list.lines().filter(|l| !l.trim().is_empty()) {
        let name = line.split_whitespace().next().unwrap_or("").to_string();
        if validate_rust(&name).is_err() { continue; }
        let default = line.contains("(default)") || line.contains("default)");
        let rustc = home.join(".rustup/toolchains").join(&name).join("bin/rustc");
        let version = Command::new(&rustc).arg("--version").env_clear().output().ok()
            .and_then(|o| String::from_utf8_lossy(&o.stdout).split_whitespace().nth(1).map(str::to_string));
        out.push(json!({"name": name, "default": default, "version": version}));
    }
    Ok(json!(out))
}
pub fn rust_action(action: &str, toolchain: &str) -> Result<Value> {
    validate_rust(toolchain)?;
    match action {
        "install" => run_rustup(&["toolchain", "install", toolchain, "--profile", "default", "--no-self-update"])?,
        "uninstall" => run_rustup(&["toolchain", "uninstall", toolchain])?,
        "default" => run_rustup(&["default", toolchain])?,
        _ => bail!("invalid_action"),
    };
    rust_toolchains()
}

// ---- Swift (swiftly) ----

fn swiftly_home() -> Result<PathBuf> {
    Ok(devtools::home()?.join(".swiftly"))
}
fn swiftly() -> Result<PathBuf> {
    let path = swiftly_home()?.join("bin/swiftly");
    ensure!(path.is_file(), "swiftly_not_installed");
    Ok(path)
}
fn run_swiftly(args: &[&str]) -> Result<String> {
    let home = devtools::home()?;
    let swiftly_home = swiftly_home()?;
    let out = Command::new(swiftly()?).args(args).env_clear().env("HOME", &home)
        .env("SWIFTLY_HOME_DIR", &swiftly_home).env("SWIFTLY_BIN_DIR", swiftly_home.join("bin"))
        // swiftly's default on macOS, named so a test home keeps its toolchains apart.
        .env("SWIFTLY_TOOLCHAINS_DIR", home.join("Library/Developer/Toolchains"))
        .env("PATH", format!("{}:/usr/bin:/bin:/usr/sbin:/sbin", swiftly_home.join("bin").display()))
        .stdin(Stdio::null()).stderr(Stdio::null()).output()?;
    ensure!(out.status.success(), "devtool_step_failed");
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}
/// Installs swiftly from swift.org: the package must be signed by Swift Open Source and notarized,
/// and the program inside signed by the same team. It is unpacked (no `installer`, no sudo) into
/// `~/.swiftly` and initialized without touching shell profiles (Stack's PATH block covers it).
pub fn install_swiftly(store: &Store) -> Result<Value> {
    let work = store.directory("cache")?.join("devtool-swiftly");
    let _ = fs::remove_dir_all(&work);
    fs::create_dir_all(&work)?;
    let result = (|| -> Result<Value> {
        let pkg = work.join("swiftly.pkg");
        tools::download("https://download.swift.org/swiftly/darwin/swiftly.pkg", &pkg)?;
        let check = Command::new("/usr/sbin/pkgutil").arg("--check-signature").arg(&pkg).env_clear().output()?;
        let text = String::from_utf8_lossy(&check.stdout);
        ensure!(check.status.success() && text.contains(&format!("Developer ID Installer: Swift Open Source ({SWIFT_TEAM})")) && text.contains("Notarization: trusted"), "signature_invalid");
        let expanded = work.join("expanded");
        ensure!(Command::new("/usr/sbin/pkgutil").arg("--expand-full").arg(&pkg).arg(&expanded).env_clear().stdout(Stdio::null()).status()?.success(), "extract_failed");
        let binary = fs::read_dir(&expanded)?.flatten().map(|e| e.path().join("Payload/bin/swiftly")).find(|p| p.is_file()).context("swiftly_missing")?;
        tools::verify_signature(&binary, SWIFT_TEAM)?;
        let home = devtools::home()?;
        let swiftly_home = swiftly_home()?;
        let status = Command::new(&binary).args(["init", "--skip-install", "--no-modify-profile", "--assume-yes", "--quiet-shell-followup"])
            .env_clear().env("HOME", &home).env("SWIFTLY_HOME_DIR", &swiftly_home).env("SWIFTLY_BIN_DIR", swiftly_home.join("bin"))
            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin").stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).status()?;
        ensure!(status.success() && swiftly_home.join("bin/swiftly").is_file(), "devtool_step_failed");
        devtools::shell_path(store)?;
        Ok(json!({"path": swiftly_home.join("bin/swiftly")}))
    })();
    let _ = fs::remove_dir_all(&work);
    result
}
pub fn validate_swift(version: &str) -> Result<()> {
    let parts: Vec<&str> = version.split('.').collect();
    ensure!(version == "latest" || ((2..=3).contains(&parts.len()) && parts.iter().all(|p| !p.is_empty() && p.len() <= 3 && p.bytes().all(|c| c.is_ascii_digit()))), "invalid_version");
    Ok(())
}
/// Installed toolchains (and Xcode's), the newest available stable releases and the default.
pub fn swift_toolchains(include_available: bool) -> Result<Value> {
    if swiftly().is_err() {
        return Ok(json!({"installed": false, "toolchains": [], "available": []}));
    }
    let list: Value = serde_json::from_str(&run_swiftly(&["list", "--format", "json"])?)?;
    let mut available = json!([]);
    if include_available {
        let all: Value = serde_json::from_str(&run_swiftly(&["list-available", "--format", "json"])?).unwrap_or(Value::Null);
        // The newest patch of each minor line (6.4.2, 6.3.3…), newest first.
        let mut seen = std::collections::HashSet::new();
        available = json!(all["toolchains"].as_array().into_iter().flatten().filter(|t| t["version"]["type"] == "stable")
            .filter(|t| seen.insert((t["version"]["major"].as_u64(), t["version"]["minor"].as_u64()))).take(6)
            .map(|t| json!({"name": t["version"]["name"], "installed": t["installed"]})).collect::<Vec<_>>());
    }
    let toolchains: Vec<Value> = list["toolchains"].as_array().into_iter().flatten()
        .map(|t| json!({"name": t["version"]["name"], "kind": t["version"]["type"], "default": t["isDefault"]})).collect();
    Ok(json!({"installed": true, "toolchains": toolchains, "available": available}))
}
pub fn swift_action(action: &str, version: &str) -> Result<Value> {
    validate_swift(version)?;
    match action {
        // swiftly checks each toolchain package's signature itself.
        "install" => run_swiftly(&["install", version, "--assume-yes"])?,
        "uninstall" => run_swiftly(&["uninstall", version, "--assume-yes"])?,
        "default" => run_swiftly(&["use", version, "--global-default", "--assume-yes"])?,
        _ => bail!("invalid_action"),
    };
    swift_toolchains(false)
}

// ---- Version of each project ----

/// Writes the project's version in its ecosystem's standard file and in Stack's site settings.
/// An empty version removes Stack's setting (the site follows the global) and leaves files alone.
pub fn set_site_version(store: &Store, id: &str, language: &str, version: &str) -> Result<crate::model::Project> {
    let mut project = store.get(id)?;
    let file = match language {
        "php" => None,
        "node" => Some(".nvmrc"),
        "jdk" => Some(".java-version"),
        "python" => Some(".python-version"),
        "rust" => Some("rust-toolchain.toml"),
        "swift" => Some(".swift-version"),
        _ => bail!("unknown_language"),
    };
    match language {
        "rust" => validate_rust(version).or_else(|e| if version.is_empty() { Ok(()) } else { Err(e) })?,
        "swift" => validate_swift(version).or_else(|e| if version.is_empty() { Ok(()) } else { Err(e) })?,
        _ => ensure!(version.is_empty() || (version.len() <= 20 && version.bytes().all(|c| c.is_ascii_digit() || c == b'.') && !version.starts_with('.') && !version.ends_with('.')), "invalid_version"),
    }
    if ["php", "node", "jdk", "python"].contains(&language) {
        if version.is_empty() { project.runtime.remove(language); } else { project.runtime.insert(language.into(), version.into()); }
    }
    if let (Some(file), false) = (file, version.is_empty()) {
        let path = project.path.join(file);
        ensure!(fs::symlink_metadata(&path).map(|m| !m.file_type().is_symlink()).unwrap_or(true), "unsafe_path");
        let content = if language == "rust" {
            // Keep the file's other settings (components, targets); only the channel changes.
            let previous = fs::read_to_string(&path).unwrap_or_default();
            let rest: Vec<&str> = previous.lines().filter(|l| !l.trim_start().starts_with("channel") && l.trim() != "[toolchain]").collect();
            let mut text = format!("[toolchain]\nchannel = \"{version}\"\n");
            for line in rest.iter().filter(|l| !l.trim().is_empty()) { text.push_str(line); text.push('\n'); }
            text
        } else {
            format!("{version}\n")
        };
        crate::services::write_private(&path, &content)?;
        fs::set_permissions(&path, std::os::unix::fs::PermissionsExt::from_mode(0o644))?;
    }
    store.save(project)
}

/// Version a project's standard file asks for (shown next to Stack's setting).
pub fn site_files(project: &Path) -> Value {
    let read = |name: &str| fs::read_to_string(project.join(name)).ok().filter(|t| t.len() < 4096);
    let rust = read("rust-toolchain.toml").and_then(|t| t.lines().find(|l| l.trim_start().starts_with("channel")).and_then(|l| l.split('"').nth(1)).map(str::to_string))
        .or_else(|| read("rust-toolchain").map(|t| t.trim().to_string()));
    json!({
        "node": read(".nvmrc").map(|t| t.trim().trim_start_matches('v').to_string()),
        "jdk": read(".java-version").map(|t| t.trim().to_string()),
        "python": read(".python-version").map(|t| t.trim().to_string()),
        "rust": rust,
        "swift": read(".swift-version").map(|t| t.trim().to_string()),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn validates_toolchains() {
        for ok in ["stable", "nightly", "1.91", "1.91.1", "stable-aarch64-apple-darwin"] { validate_rust(ok).unwrap(); }
        for bad in ["", "1", "stable;rm", "../x", "1.91.1.1", "nightly-2025-01-01"] { assert!(validate_rust(bad).is_err(), "{bad}"); }
        for ok in ["6.2", "6.2.1", "latest"] { validate_swift(ok).unwrap(); }
        assert!(validate_swift("main-snapshot").is_err());
    }
}
