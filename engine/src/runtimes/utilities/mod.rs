//! Utilities of the Utilidades page that are not part of a language: the AI assistants (Codex,
//! Claude Code, Claude Desktop, ChatGPT), AWS CLI v2 and Git. Each comes from its maker's own
//! source and is checked before anything is placed: the checksum the maker publishes and, for
//! what the maker builds, the Apple signature of its Developer ID team and Apple's notarization.
//! Nothing downloaded is run to install it (no installer scripts, no package scripts, no
//! `installer`, no sudo); the layout is the one the maker's own installer leaves in the user's
//! home, so their updaters keep working. Git has no official build for macOS: Stack compiles the
//! official source with Apple's compiler (`make`, never a downloaded script run by a shell).
//!
//! Stack writes a record of what it placed (`utilities/<id>.json` in its store) and only ever
//! removes what such a record lists: a copy the user installed some other way is shown, never
//! replaced or removed.
//!
//! Beside them, in this folder: the developer tools of the work profiles (`devtools`) and the
//! catalog of downloadable pieces (`catalog`: Node, Caddy, the services).

mod assistants;
mod aws_cli;
pub mod catalog;
pub mod devtools;
mod version_control;

use assistants::*;
use aws_cli::*;
use version_control::*;

use crate::{
    core::store::Store,
    core::{archive, download, fsutil, hash, process, progress, signature},
    runtimes::utilities::devtools::{arm, asset_digest, asset_url, home, listed_hash},
};
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    fs,
    io::Read,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{Duration, Instant},
};

/// OpenAI's Developer ID team: `codesign -dv` of codex, codex-code-mode-host and rg in
/// codex-package-aarch64-apple-darwin.tar.gz (release rust-v0.169.0) and of ChatGPT.app
/// 26.1111.21308 (also `spctl -a -vv`): "OpenAI OpCo, LLC (2DC432GLL2)".
const OPENAI_TEAM: &str = "2DC432GLL2";
/// Anthropic's Developer ID team: `codesign -dv` of the Claude Code 2.1.323 darwin-arm64 binary
/// and of Claude.app 5.11492.2: "Anthropic PBC (Q6L2SF6YDW)".
const ANTHROPIC_TEAM: &str = "Q6L2SF6YDW";
/// The team that signs AWSCLIV2.pkg: `pkgutil --check-signature` of AWSCLIV2-2.40.2.pkg
/// ("Developer ID Installer: AMZN Mobile LLC (94KV3E626L)"), the same constant AWS's own
/// install.sh checks; its programs carry the matching Developer ID Application certificate.
const AWS_TEAM: &str = "94KV3E626L";

const CLAUDE_CODE_BASE: &str = "https://downloads.claude.ai/claude-code-releases";
/// The feed Claude Desktop updates itself from (the download page's link is behind a browser check).
const CLAUDE_DESKTOP_FEED: &str =
    "https://downloads.claude.ai/releases/darwin/universal/RELEASES.json";
const CLAUDE_DESKTOP_FILES: &str = "https://downloads.claude.ai/releases/darwin/universal/";
const AWS_BASE: &str = "https://awscli.amazonaws.com";
/// The update feed (Sparkle) of the ChatGPT app for Mac, the one its own app.asar names. The
/// download page's button gives an installer app (ChatGPTInstaller.dmg) that would have to be run.
const CHATGPT_FEED: &str = "https://persistent.oaistatic.com/codex-app-prod/appcast.xml";
const CHATGPT_FILES: &str = "https://persistent.oaistatic.com/codex-app-prod/";
/// Its full archive is about 840 MB.
const CHATGPT_MAX_BYTES: u64 = 2_000_000_000;

/// An app Stack copies to `~/Applications`: its bundle's name, the Developer ID team that must sign
/// all of it, and the bundle identifier it must declare.
struct App {
    tool: &'static str,
    name: &'static str,
    maker: &'static str,
    team: &'static str,
    bundle: &'static str,
}
const CLAUDE_DESKTOP: App = App {
    tool: "claude-desktop",
    name: "Claude.app",
    maker: "Anthropic",
    team: ANTHROPIC_TEAM,
    bundle: "com.anthropic.claudefordesktop",
};
/// The new ChatGPT app (chat, Work and Codex) is the Codex app renamed: its bundle keeps Codex's
/// identifier (ChatGPT.app 26.1111.21308). The previous app, «ChatGPT Classic», is `com.openai.chat`.
const CHATGPT: App = App {
    tool: "chatgpt",
    name: "ChatGPT.app",
    maker: "OpenAI",
    team: OPENAI_TEAM,
    bundle: "com.openai.codex",
};
/// Git's releases on kernel.org, with `sha256sums.asc`: the SHA-256 of every file there, in a
/// message signed with OpenPGP (that signature is not checked: macOS has no OpenPGP tool).
const GIT_BASE: &str = "https://www.kernel.org/pub/software/scm/git";
/// `make` variables for Git with only what macOS has: Apple's compiler, libcurl (curl-config),
/// zlib, iconv and CommonCrypto. No translations (gettext), Perl, Python, Tcl/Tk, Rust or expat
/// (only `git http-push` needs it). The prefix is the final folder (its paths are compiled in, so
/// `git` works through a link); `make` installs it under a staging DESTDIR that is moved there.
const GIT_MAKE: [&str; 11] = [
    "CC=/usr/bin/cc",
    "NO_HOMEBREW=YesPlease",
    "NO_GETTEXT=YesPlease",
    "NO_PERL=YesPlease",
    "NO_PYTHON=YesPlease",
    "NO_TCLTK=YesPlease",
    "NO_RUST=YesPlease",
    "NO_EXPAT=YesPlease",
    "CURL_CONFIG=/usr/bin/curl-config",
    "NO_INSTALL_HARDLINKS=YesPlease",
    "SKIP_DASHED_BUILT_INS=YesPlease",
];

/// The utilities of the page; those installed by `devtools` (gh, cloudflared, wrangler) also leave
/// a record so they can be removed from it.
pub const IDS: [&str; 6] = [
    "codex",
    "claude-code",
    "claude-desktop",
    "chatgpt",
    "aws",
    "git",
];
pub const REMOVABLE: [&str; 9] = [
    "codex",
    "claude-code",
    "claude-desktop",
    "chatgpt",
    "aws",
    "git",
    "gh",
    "cloudflared",
    "wrangler",
];

/// What Stack placed for one utility.
#[derive(Serialize, Deserialize, Debug, PartialEq)]
pub struct Record {
    pub version: String,
    /// Links, files and folders Stack created, all inside the user's home.
    pub paths: Vec<PathBuf>,
    #[serde(rename = "installedAt")]
    pub installed_at: u64,
}

fn record_file(store: &Store, tool: &str) -> Result<PathBuf> {
    ensure!(REMOVABLE.contains(&tool), "unknown_tool");
    Ok(store.directory("utilities")?.join(format!("{tool}.json")))
}

pub fn record(store: &Store, tool: &str, version: &str, paths: Vec<PathBuf>) -> Result<()> {
    let home = home()?;
    ensure!(
        paths
            .iter()
            .all(|p| p.is_absolute() && p.starts_with(&home)),
        "unsafe_runtime_path"
    );
    let record = Record {
        version: version.into(),
        paths,
        installed_at: crate::core::time::now_secs(),
    };
    fsutil::write_private(
        &record_file(store, tool)?,
        &serde_json::to_string_pretty(&record)?,
    )
}

pub fn read_record(store: &Store, tool: &str) -> Option<Record> {
    serde_json::from_slice(&fs::read(record_file(store, tool).ok()?).ok()?).ok()
}

/// "1.2.3", "2026.11.0", "5.11492.2": two to four numeric parts.
fn valid_version(version: &str) -> bool {
    let parts: Vec<&str> = version.split('.').collect();
    (2..=4).contains(&parts.len())
        && parts
            .iter()
            .all(|p| !p.is_empty() && p.len() <= 7 && p.bytes().all(|c| c.is_ascii_digit()))
}

/// The first word of a `--version` line that starts with a digit ("codex-cli 0.169.0",
/// "2.1.323 (Claude Code)", "aws-cli/2.40.2 Python/3.14.8 …").
pub fn version_in(text: &str) -> Option<String> {
    text.split(|c: char| c.is_whitespace() || c == '/')
        .find(|w| w.chars().next().is_some_and(|c| c.is_ascii_digit()))
        .map(|v| v.trim_end_matches(',').to_string())
}

/// What `program --version` says, with the minimal environment and a time limit.
fn reported_version(program: &Path) -> Option<String> {
    let mut command = Command::new(program);
    process::minimal_environment(&mut command, home().ok()?, "/usr/bin:/bin:/usr/sbin:/sbin");
    let mut child = command
        .arg("--version")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let deadline = Instant::now() + Duration::from_secs(30);
    while child.try_wait().ok()?.is_none() {
        if Instant::now() > deadline {
            let _ = child.kill();
            return None;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    let mut out = String::new();
    child
        .stdout
        .take()?
        .take(64 * 1024)
        .read_to_string(&mut out)
        .ok()?;
    version_in(&out)
}

fn check_reported(program: &Path, version: &str) -> Result<()> {
    ensure!(
        reported_version(program).as_deref() == Some(version),
        "version_mismatch"
    );
    Ok(())
}

/// The folder where Stack puts apps: `~/Applications` (the user's own, writable without an
/// administrator, where Claude Desktop can also update itself). With BUTAKE_DEVTOOLS_HOME (tests
/// and QA) it is inside that temporary home.
pub fn applications() -> Result<PathBuf> {
    Ok(home()?.join("Applications"))
}

/// Where a copy of an app may already be: Stack's folder first, then the system's (never looked
/// at with a temporary home).
fn app_candidates(name: &str) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = applications().into_iter().map(|a| a.join(name)).collect();
    if std::env::var_os("BUTAKE_DEVTOOLS_HOME").is_none() {
        out.push(PathBuf::from("/Applications").join(name));
    }
    out
}

/// The version of an app bundle, read from its Info.plist (binary or XML) with plutil.
pub fn app_version(app: &Path) -> Option<String> {
    plist_value(
        &app.join("Contents/Info.plist"),
        "CFBundleShortVersionString",
    )
}
fn plist_value(plist: &Path, key: &str) -> Option<String> {
    let out = Command::new("/usr/bin/plutil")
        .args(["-extract", key, "raw", "-o", "-"])
        .arg(plist)
        .env_clear()
        .stderr(Stdio::null())
        .output()
        .ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
        .filter(|v| !v.is_empty())
}

/// An app as found on this Mac: the first copy of `name` (Claude.app, ChatGPT.app).
fn app_status(name: &str) -> Value {
    let app = app_candidates(name)
        .into_iter()
        .find(|p| p.join("Contents/Info.plist").is_file());
    json!({"installed": app.is_some(), "version": app.as_deref().and_then(app_version), "path": app, "broken": false})
}

/// The folder of Apple's developer tools (command line tools or Xcode) when their Git is really
/// there. `/usr/bin/git` itself is never run: without the tools it only opens macOS's offer to
/// install them.
fn apple_developer_dir() -> Option<PathBuf> {
    let out = Command::new("/usr/bin/xcode-select")
        .arg("-p")
        .env_clear()
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    let dir = PathBuf::from(String::from_utf8_lossy(&out.stdout).trim());
    (out.status.success() && dir.is_absolute() && dir.join("usr/bin/git").is_file()).then_some(dir)
}

/// What Apple's tools print, instead of running, while Xcode's license is pending.
pub(crate) fn license_pending(output: &str) -> bool {
    output.contains("agreed to the Xcode license")
}

/// Apple's developer tools are there and its compiler runs: `clt_not_installed` without them,
/// `xcode_license_pending` when Xcode is installed and its license has not been accepted (every
/// tool in `/usr/bin` refuses to run until it is). Asked before anything is downloaded for a
/// build, so the user reads what to do instead of a `build_failed` whose reason is in a log.
pub(crate) fn ensure_apple_toolchain() -> Result<()> {
    ensure!(apple_developer_dir().is_some(), "clt_not_installed");
    // Only with the tools in place: without them `/usr/bin/cc` opens macOS's offer to install them.
    let out = Command::new("/usr/bin/cc")
        .arg("--version")
        .env_clear()
        .stdin(Stdio::null())
        .output();
    if let Ok(out) = out {
        let said = [out.stdout, out.stderr].concat();
        ensure!(
            out.status.success() || !license_pending(&String::from_utf8_lossy(&said)),
            "xcode_license_pending"
        );
    }
    Ok(())
}

/// Git as found on this Mac: a copy in the user's places (Stack's link in `~/.local/bin` first) or
/// Apple's, from its developer tools (`apple`: it comes with them and they update it). With a
/// temporary home (tests and QA) only that home is looked at.
pub fn git_status() -> Value {
    if let Some(path) = crate::runtimes::utilities::catalog::user_tool("git") {
        let version = reported_version(&path);
        return json!({"installed": true, "broken": version.is_none(), "version": version, "path": path, "apple": false});
    }
    let apple = std::env::var_os("BUTAKE_DEVTOOLS_HOME")
        .is_none()
        .then(apple_developer_dir)
        .flatten()
        .map(|dir| dir.join("usr/bin/git"));
    let version = apple.as_deref().and_then(reported_version);
    json!({"installed": apple.is_some(), "broken": apple.is_some() && version.is_none(), "version": version, "path": apple, "apple": apple.is_some()})
}

/// The status of the utilities that are not one program in the user's places: the apps and Git.
pub fn statuses() -> Vec<(&'static str, Value)> {
    vec![
        ("claude-desktop", app_status(CLAUDE_DESKTOP.name)),
        ("chatgpt", app_status(CHATGPT.name)),
        ("git", git_status()),
    ]
}

/// Adds `managed` to the status of each utility of the page: Stack's record lists the path where it
/// was found. Only those can be updated or removed from Stack.
pub fn mark_managed(store: &Store, tools: &mut serde_json::Map<String, Value>) {
    for id in REMOVABLE {
        let Some(entry) = tools.get_mut(id).and_then(Value::as_object_mut) else {
            continue;
        };
        let found = entry.get("path").and_then(Value::as_str).map(PathBuf::from);
        let managed = match (read_record(store, id), found) {
            (Some(record), Some(path)) => record.paths.contains(&path),
            _ => false,
        };
        entry.insert("managed".into(), json!(managed));
    }
}

/// A copy installed some other way is never replaced: Stack would shadow or overwrite it. Apple's
/// Git is the exception: it stays where it is, and Stack's goes first on the terminal's PATH.
fn ensure_not_elsewhere(store: &Store, tool: &str) -> Result<()> {
    let mut tools = crate::runtimes::utilities::catalog::dev_tools(store)?
        .as_object()
        .cloned()
        .unwrap_or_default();
    mark_managed(store, &mut tools);
    let entry = &tools[tool];
    ensure!(
        entry["installed"] != true || entry["managed"] == true || entry["apple"] == true,
        "installed_elsewhere"
    );
    Ok(())
}

/// The steps an install of `tool` goes through, as `progress` reports them (the app shows them
/// before they start). Codes, not text.
pub fn plan(tool: &str) -> &'static [&'static str] {
    match tool {
        "git" => &["downloadSource", "verifySum", "build", "install", "link"],
        "claude-desktop" | "chatgpt" => &["download", "verifyApp", "copyApp"],
        "aws" => &["download", "verifyPackage", "install"],
        _ => &["download", "verifyBinary", "install"],
    }
}

pub fn install(store: &Store, tool: &str) -> Result<Value> {
    ensure!(IDS.contains(&tool), "unknown_tool");
    ensure_not_elsewhere(store, tool)?;
    let dir = devtools::work_dir(store, tool)?;
    let result = match tool {
        "codex" => install_codex(store, &dir),
        "claude-code" => install_claude_code(store, &dir),
        "claude-desktop" => install_claude_desktop(store, &dir),
        "chatgpt" => install_chatgpt(store, &dir),
        "aws" => install_aws(store, &dir),
        "git" => install_git(store, &dir),
        _ => unreachable!(),
    };
    let _ = fs::remove_dir_all(&dir);
    if let Err(error) = &result {
        devtools::log(store, tool, &format!("no se instaló: {error}"));
    }
    result
}

fn fetch_text(url: &str, limit: u64) -> Result<String> {
    Ok(String::from_utf8(download::fetch(url, limit)?)?
        .trim()
        .to_string())
}

// ---- Removal and versions ----

/// Removes what Stack's record lists, and the record. Data and settings of the utility in the home
/// (`~/.codex`, `~/.claude`, `~/.aws`, the app's support folder) are left alone.
pub fn remove(store: &Store, tool: &str) -> Result<()> {
    ensure!(REMOVABLE.contains(&tool), "unknown_tool");
    let record = read_record(store, tool).context("not_managed")?;
    let home = home()?;
    for path in &record.paths {
        ensure!(
            path.is_absolute()
                && path.starts_with(&home)
                && path != &home
                && !path
                    .components()
                    .any(|c| c == std::path::Component::ParentDir),
            "unsafe_runtime_path"
        );
    }
    for path in &record.paths {
        match fs::symlink_metadata(path) {
            Ok(meta) if meta.is_dir() => fs::remove_dir_all(path)?,
            Ok(_) => fs::remove_file(path)?,
            Err(_) => {}
        }
    }
    fs::remove_file(record_file(store, tool)?)?;
    Ok(())
}

/// Newest version of each utility at its source, or the error code of a source that did not answer
/// (`download_offline`, `source_rate_limited:<minutes>`…).
pub fn latest() -> Vec<(&'static str, std::result::Result<String, String>)> {
    fn code<T>(result: Result<T>) -> std::result::Result<T, String> {
        result.map_err(|e| e.to_string())
    }
    fn checked(version: String) -> std::result::Result<String, String> {
        if valid_version(&version) {
            Ok(version)
        } else {
            Err("unexpected_artifact".into())
        }
    }
    let codex = std::thread::spawn(|| {
        code(crate::core::github::latest_tag("openai/codex"))
            .and_then(|tag| code(codex_version(&tag)))
    });
    let claude = std::thread::spawn(|| {
        code(fetch_text(&format!("{CLAUDE_CODE_BASE}/latest"), 100)).and_then(checked)
    });
    let desktop = std::thread::spawn(|| {
        code(download::fetch(CLAUDE_DESKTOP_FEED, 1_000_000))
            .and_then(|b| serde_json::from_slice::<Value>(&b).map_err(|_| "download_failed".into()))
            .and_then(|f| code(desktop_release(&f)))
            .map(|(version, _)| version)
    });
    let aws = std::thread::spawn(|| {
        code(fetch_text(&format!("{AWS_BASE}/v2/version.txt"), 100)).and_then(checked)
    });
    let git = std::thread::spawn(|| {
        code(fetch_text(&format!("{GIT_BASE}/sha256sums.asc"), 2_000_000))
            .and_then(|sums| code(git_release(&sums)))
            .map(|(version, _)| version)
    });
    let chatgpt = std::thread::spawn(|| {
        if !arm() {
            return Err("unsupported_platform".to_string());
        }
        code(fetch_text(CHATGPT_FEED, 1_000_000))
            .and_then(|feed| code(chatgpt_release(&feed)))
            .map(|(version, _)| version)
    });
    let joined = |handle: std::thread::JoinHandle<std::result::Result<String, String>>| {
        handle
            .join()
            .unwrap_or_else(|_| Err("download_failed".into()))
    };
    vec![
        ("codex", joined(codex)),
        ("claude-code", joined(claude)),
        ("chatgpt", joined(chatgpt)),
        ("claude-desktop", joined(desktop)),
        ("aws", joined(aws)),
        ("git", joined(git)),
    ]
}

#[cfg(test)]
pub(crate) mod tests;
