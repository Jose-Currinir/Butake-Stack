//! Developer tools the work profiles need, installed from their official sources into the user's
//! home, where their own installers put them (rustup in `~/.cargo`, uv/gh/cloudflared in
//! `~/.local/bin`, the Android SDK in `~/Library/Android/sdk`). No Homebrew, no sudo. Every download
//! is checked against the checksum its publisher lists, and the app asks before calling this.
mod install;
mod latest;

use install::*;
pub use latest::*;

use crate::{
    core::store::Store,
    core::{archive, download, github, hash, process, progress},
    runtimes::{utilities, utilities::catalog},
};
use anyhow::{bail, ensure, Context, Result};
use serde_json::{json, Value};
use std::{
    fs,
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

/// Cloudflare's Developer ID team, which signs cloudflared for macOS.
const CLOUDFLARE_TEAM: &str = "68WVV388M8";

pub struct Options {
    pub tool: String,
    /// Python version for `python` (through uv), e.g. "3.13".
    pub version: String,
    /// Add `~/.local/bin` and `~/.cargo/bin` to the terminal's PATH (`~/.zprofile`).
    pub shell_path: bool,
    /// The user accepted the Android SDK licenses in the app.
    pub accept_licenses: bool,
}

/// The user's home; tests (and QA) point it elsewhere with BUTAKE_DEVTOOLS_HOME.
pub fn home() -> Result<PathBuf> {
    std::env::var_os("BUTAKE_DEVTOOLS_HOME")
        .map(PathBuf::from)
        .or_else(Store::home)
        .ok_or_else(|| anyhow::anyhow!("no_home"))
}
pub(super) fn arm() -> bool {
    std::env::consts::ARCH == "aarch64"
}
pub(super) fn work_dir(store: &Store, tool: &str) -> Result<PathBuf> {
    let dir = store.directory("cache")?.join(format!("devtool-{tool}"));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir)?;
    Ok(dir)
}
pub(super) fn log(store: &Store, tool: &str, line: &str) {
    use std::io::Write;
    if let Ok(dir) = store.directory("logs") {
        if let Ok(mut file) = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(dir.join(format!("devtool-{tool}.log")))
        {
            let _ = writeln!(file, "{line}");
        }
    }
}
/// How a program of an install runs while the app follows it (see `progress`).
#[derive(Clone, Copy, PartialEq)]
enum Mode {
    /// In its own process group: «Cancelar» ends it and what it started.
    Stoppable,
    /// An official installer (rustup, sdkmanager) that would leave its own folders half done if it
    /// were cut: it runs to the end, the app does not offer «Cancelar» meanwhile.
    External,
    /// The same, answering «y» to its questions (the licenses the user accepted in the app).
    ExternalYes,
}

/// The utilities `install` takes besides those of `utilities::IDS`.
const TOOLS: [&str; 8] = [
    "rustup",
    "uv",
    "python",
    "gh",
    "cloudflared",
    "wrangler",
    "android-sdk",
    "swiftly",
];

/// The Android SDK's folder: `ANDROID_HOME` or where Android Studio puts it.
fn android_sdk(home: &Path) -> PathBuf {
    std::env::var_os("ANDROID_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join("Library/Android/sdk"))
}

/// The steps an install of `tool` reports (see `progress`), for the app to show before they
/// start. What is already on this Mac (rustup, the SDK's command-line tools) is not downloaded.
pub fn plan(tool: &str) -> Vec<&'static str> {
    let home = home().ok();
    let has = |path: &str| home.as_ref().is_some_and(|h| h.join(path).is_file());
    match tool {
        "rustup" if has(".cargo/bin/rustup") => vec!["updateToolchain"],
        "rustup" => vec!["download", "verifySum", "runInstaller"],
        "uv" | "gh" | "python" => vec!["download", "verifySum", "install"],
        "cloudflared" => vec!["download", "verifyBinary", "install"],
        "wrangler" => vec!["npmPackage", "link"],
        "swiftly" => vec!["download", "verifyPackage", "install"],
        "android-sdk"
            if home.as_ref().is_some_and(|h| {
                android_sdk(h)
                    .join("cmdline-tools/latest/bin/sdkmanager")
                    .is_file()
            }) =>
        {
            vec!["licenses", "platformTools"]
        }
        "android-sdk" => vec![
            "download",
            "verifySum",
            "install",
            "licenses",
            "platformTools",
        ],
        _ => utilities::plan(tool).to_vec(),
    }
}

/// Every utility `install` takes.
pub fn known(tool: &str) -> bool {
    TOOLS.contains(&tool) || utilities::IDS.contains(&tool)
}

/// Runs a program with a clean environment (HOME and a basic PATH plus `extra_path`), logging output.
fn run(
    store: &Store,
    tool: &str,
    program: &Path,
    args: &[&str],
    extra_path: &[PathBuf],
    env: &[(&str, String)],
    mode: Mode,
) -> Result<()> {
    let home = home()?;
    log(
        store,
        tool,
        &format!(
            "$ {} {}",
            program.file_name().unwrap_or_default().to_string_lossy(),
            args.join(" ")
        ),
    );
    let logs = store.directory("logs")?.join(format!("devtool-{tool}.log"));
    let out = process::append_log(&logs)?;
    let mut path: Vec<String> = extra_path
        .iter()
        .map(|p| p.to_string_lossy().into_owned())
        .collect();
    path.push("/usr/bin:/bin:/usr/sbin:/sbin".into());
    let mut command = Command::new(program);
    process::minimal_environment(&mut command, &home, path.join(":"));
    command.args(args).stdout(out.try_clone()?).stderr(out);
    for (k, v) in env {
        command.env(k, v);
    }
    // An external installer stays in the engine's group: a stop sent to the engine does not reach it.
    let status = match mode {
        Mode::ExternalYes => {
            let mut child = command.stdin(Stdio::piped()).spawn()?;
            if let Some(mut input) = child.stdin.take() {
                use std::io::Write;
                let _ = input.write_all("y\n".repeat(50).as_bytes());
            }
            child.wait()?
        }
        Mode::External => command.stdin(Stdio::null()).status()?,
        Mode::Stoppable => progress::run(command.stdin(Stdio::null()), || {})?,
    };
    ensure!(status.success(), "devtool_step_failed");
    Ok(())
}
pub(super) fn asset_url(release: &Value, name: &str) -> Result<String> {
    release["assets"]
        .as_array()
        .and_then(|assets| assets.iter().find(|a| a["name"] == name))
        .and_then(|a| a["browser_download_url"].as_str())
        .map(str::to_string)
        .ok_or_else(|| anyhow::anyhow!("asset_not_found"))
}
/// SHA-256 GitHub computed when the asset was uploaded ("sha256:<hex>"), when the API gives it.
pub(super) fn asset_digest(release: &Value, name: &str) -> Option<String> {
    release["assets"]
        .as_array()?
        .iter()
        .find(|a| a["name"] == name)?["digest"]
        .as_str()?
        .strip_prefix("sha256:")
        .map(str::to_lowercase)
}
/// The checksum listed for `name` in a checksums text ("<hex>  <name>" or "<name>: <hex>").
pub(super) fn listed_hash(text: &str, name: &str) -> Result<String> {
    for line in text.lines() {
        let words: Vec<&str> = line
            .split(|c: char| c.is_whitespace() || c == ':' || c == '*')
            .filter(|w| !w.is_empty())
            .collect();
        if words.contains(&name) {
            if let Some(hash) = words
                .iter()
                .find(|w| w.len() == 64 && w.chars().all(|c| c.is_ascii_hexdigit()))
            {
                return Ok(hash.to_lowercase());
            }
        }
    }
    bail!("checksum_not_found")
}
/// Downloads `url` into `into` and checks its SHA-256; `verify` is the step the check reports.
fn fetch_verified(
    store: &Store,
    tool: &str,
    url: &str,
    sha256: &str,
    into: &Path,
    verify: &str,
) -> Result<PathBuf> {
    let file = into.join(url.rsplit('/').next().unwrap_or("download"));
    log(store, tool, &format!("descargando {url}"));
    download::download(url, &file)?;
    progress::step(verify);
    let actual = hash::sha256_file(&file)?;
    ensure!(actual.eq_ignore_ascii_case(sha256), "checksum_mismatch");
    log(store, tool, &format!("SHA-256 verificado: {actual}"));
    Ok(file)
}
/// Copies an executable into `~/.local/bin` atomically.
fn place(source: &Path, name: &str) -> Result<PathBuf> {
    let bin = home()?.join(".local/bin");
    fs::create_dir_all(&bin)?;
    let target = bin.join(name);
    let temp = bin.join(format!(".{name}.butake"));
    fs::copy(source, &temp)?;
    fs::set_permissions(&temp, std::os::unix::fs::PermissionsExt::from_mode(0o755))?;
    fs::rename(&temp, &target)?;
    Ok(target)
}
fn find_file(root: &Path, name: &str) -> Option<PathBuf> {
    for entry in fs::read_dir(root).ok()?.flatten() {
        let path = entry.path();
        // A link is neither the file nor a folder to walk into (`is_file` would follow it).
        let kind = fs::symlink_metadata(&path).ok()?.file_type();
        if path.file_name().is_some_and(|n| n == name) && kind.is_file() {
            return Some(path);
        }
        if kind.is_dir() {
            if let Some(found) = find_file(&path, name) {
                return Some(found);
            }
        }
    }
    None
}

/// `~/.local/bin`, `~/.cargo/bin` and `~/.swiftly/bin` on the terminal's PATH, and `PHPRC` for the
/// terminal's `php` (Stack's php.ini of the global version), in a marked block of ~/.zprofile that
/// is rewritten in place when it changes.
pub fn shell_path(store: &Store) -> Result<()> {
    // The block's markers keep the name it was first written with, so every block already in a
    // ~/.zprofile is found and rewritten in place instead of added again.
    const START: &str = "# >>> Butake Stack >>>";
    const END: &str = "# <<< Butake Stack <<<";
    let file = home()?.join(".zprofile");
    let text = fs::read_to_string(&file).unwrap_or_default();
    let phprc = store.root().join("config/php/current");
    let phprc = phprc
        .to_string_lossy()
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('$', "\\$")
        .replace('`', "\\`");
    let block = format!("{START}\n# Herramientas y lenguajes de Stack (enlaces a los binarios reales).\nexport PATH=\"$HOME/.local/bin:$HOME/.cargo/bin:$HOME/.swiftly/bin:$PATH\"\n[ -f \"{phprc}/php.ini\" ] && export PHPRC=\"{phprc}\"\n{END}\n");
    let updated = match (text.find(START), text.find(END)) {
        (Some(start), Some(end)) if end > start => {
            let end = end + END.len();
            let end = if text[end..].starts_with('\n') {
                end + 1
            } else {
                end
            };
            format!("{}{}{}", &text[..start], block, &text[end..])
        }
        _ => format!("{text}\n{block}"),
    };
    if updated != text {
        fs::write(&file, updated)?;
    }
    Ok(())
}

pub fn install(store: &Store, options: &Options) -> Result<Value> {
    let tool = options.tool.as_str();
    ensure!(known(tool), "unknown_tool");
    if let Ok(dir) = store.directory("logs") {
        let log = dir.join(format!("devtool-{tool}.log"));
        let _ = fs::remove_file(&log);
        // The app follows this log (steps, bytes, output) and may stop the install.
        progress::begin(&log);
    }
    let result = install_tool(store, options);
    // A failed or cancelled install leaves nothing of its download behind.
    if result.is_err() {
        if let Ok(cache) = store.directory("cache") {
            let _ = fs::remove_dir_all(cache.join(format!("devtool-{tool}")));
        }
    }
    result
}

fn rust_homes(home: &Path) -> [(&'static str, String); 2] {
    [
        (
            "CARGO_HOME",
            home.join(".cargo").to_string_lossy().into_owned(),
        ),
        (
            "RUSTUP_HOME",
            home.join(".rustup").to_string_lossy().into_owned(),
        ),
    ]
}

#[cfg(test)]
mod tests;
