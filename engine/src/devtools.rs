//! Developer tools the work profiles need, installed from their official sources into the user's
//! home, where their own installers put them (rustup in `~/.cargo`, uv/gh/cloudflared in
//! `~/.local/bin`, the Android SDK in `~/Library/Android/sdk`). No Homebrew, no sudo. Every download
//! is checked against the checksum its publisher lists, and the app asks before calling this.
use crate::{store::Store, tools};
use anyhow::{bail, ensure, Context, Result};
use serde_json::{json, Value};
use std::{
    fs,
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

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
    std::env::var_os("BUTAKE_DEVTOOLS_HOME").map(PathBuf::from).or_else(dirs::home_dir).ok_or_else(|| anyhow::anyhow!("no_home"))
}
fn arm() -> bool {
    std::env::consts::ARCH == "aarch64"
}
fn work_dir(store: &Store, tool: &str) -> Result<PathBuf> {
    let dir = store.directory("cache")?.join(format!("devtool-{tool}"));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir)?;
    Ok(dir)
}
fn log(store: &Store, tool: &str, line: &str) {
    use std::io::Write;
    if let Ok(dir) = store.directory("logs") {
        if let Ok(mut file) = fs::OpenOptions::new().create(true).append(true).open(dir.join(format!("devtool-{tool}.log"))) {
            let _ = writeln!(file, "{line}");
        }
    }
}
/// Runs a program with a clean environment (HOME and a basic PATH plus `extra_path`), logging output.
fn run(store: &Store, tool: &str, program: &Path, args: &[&str], extra_path: &[PathBuf], env: &[(&str, String)], stdin_yes: bool) -> Result<()> {
    let home = home()?;
    log(store, tool, &format!("$ {} {}", program.file_name().unwrap_or_default().to_string_lossy(), args.join(" ")));
    let logs = store.directory("logs")?.join(format!("devtool-{tool}.log"));
    let out = fs::OpenOptions::new().create(true).append(true).open(&logs)?;
    let mut path: Vec<String> = extra_path.iter().map(|p| p.to_string_lossy().into_owned()).collect();
    path.push("/usr/bin:/bin:/usr/sbin:/sbin".into());
    let mut command = Command::new(program);
    command.args(args).env_clear().env("HOME", &home).env("PATH", path.join(":")).env("LANG", "en_US.UTF-8")
        .stdout(out.try_clone()?).stderr(out);
    for (k, v) in env { command.env(k, v); }
    let status = if stdin_yes {
        let mut child = command.stdin(Stdio::piped()).spawn()?;
        if let Some(mut input) = child.stdin.take() {
            use std::io::Write;
            let _ = input.write_all("y\n".repeat(50).as_bytes());
        }
        child.wait()?
    } else {
        command.stdin(Stdio::null()).status()?
    };
    ensure!(status.success(), "devtool_step_failed");
    Ok(())
}
fn latest_release(repo: &str) -> Result<Value> {
    Ok(serde_json::from_slice(&tools::fetch(&format!("https://api.github.com/repos/{repo}/releases/latest"), 20_000_000)?)?)
}
fn asset_url(release: &Value, name: &str) -> Result<String> {
    release["assets"].as_array().and_then(|assets| assets.iter().find(|a| a["name"] == name))
        .and_then(|a| a["browser_download_url"].as_str()).map(str::to_string)
        .ok_or_else(|| anyhow::anyhow!("asset_not_found"))
}
/// SHA-256 GitHub computed when the asset was uploaded ("sha256:<hex>"), when the API gives it.
fn asset_digest(release: &Value, name: &str) -> Option<String> {
    release["assets"].as_array()?.iter().find(|a| a["name"] == name)?["digest"].as_str()?
        .strip_prefix("sha256:").map(str::to_lowercase)
}
/// The checksum listed for `name` in a checksums text ("<hex>  <name>" or "<name>: <hex>").
fn listed_hash(text: &str, name: &str) -> Result<String> {
    for line in text.lines() {
        let words: Vec<&str> = line.split(|c: char| c.is_whitespace() || c == ':' || c == '*').filter(|w| !w.is_empty()).collect();
        if words.contains(&name) {
            if let Some(hash) = words.iter().find(|w| w.len() == 64 && w.chars().all(|c| c.is_ascii_hexdigit())) {
                return Ok(hash.to_lowercase());
            }
        }
    }
    bail!("checksum_not_found")
}
fn fetch_verified(store: &Store, tool: &str, url: &str, sha256: &str, into: &Path) -> Result<PathBuf> {
    let file = into.join(url.rsplit('/').next().unwrap_or("download"));
    log(store, tool, &format!("descargando {url}"));
    tools::download(url, &file)?;
    let actual = tools::sha256_file(&file)?;
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
        if path.file_name().is_some_and(|n| n == name) && path.is_file() { return Some(path); }
        if path.is_dir() { if let Some(found) = find_file(&path, name) { return Some(found); } }
    }
    None
}
fn untar(archive: &Path, into: &Path) -> Result<()> {
    ensure!(Command::new("/usr/bin/tar").arg("-xzf").arg(archive).arg("-C").arg(into).status()?.success(), "extract_failed");
    Ok(())
}
fn unzip(archive: &Path, into: &Path) -> Result<()> {
    ensure!(Command::new("/usr/bin/ditto").args(["-x", "-k"]).arg(archive).arg(into).status()?.success(), "extract_failed");
    Ok(())
}

/// `~/.local/bin`, `~/.cargo/bin` and `~/.swiftly/bin` on the terminal's PATH, and `PHPRC` for the
/// terminal's `php` (Stack's php.ini of the global version), in a marked block of ~/.zprofile that
/// is rewritten in place when it changes.
pub fn shell_path(store: &Store) -> Result<()> {
    let file = home()?.join(".zprofile");
    let text = fs::read_to_string(&file).unwrap_or_default();
    let phprc = store.root().join("config/php/current");
    let phprc = phprc.to_string_lossy().replace('\\', "\\\\").replace('"', "\\\"").replace('$', "\\$").replace('`', "\\`");
    let block = format!("# >>> Butake Stack >>>\n# Herramientas y lenguajes de Butake Stack (enlaces a los binarios reales).\nexport PATH=\"$HOME/.local/bin:$HOME/.cargo/bin:$HOME/.swiftly/bin:$PATH\"\n[ -f \"{phprc}/php.ini\" ] && export PHPRC=\"{phprc}\"\n# <<< Butake Stack <<<\n");
    let updated = match (text.find("# >>> Butake Stack >>>"), text.find("# <<< Butake Stack <<<")) {
        (Some(start), Some(end)) if end > start => {
            let end = end + "# <<< Butake Stack <<<".len();
            let end = if text[end..].starts_with('\n') { end + 1 } else { end };
            format!("{}{}{}", &text[..start], block, &text[end..])
        }
        _ => format!("{text}\n{block}"),
    };
    if updated != text { fs::write(&file, updated)?; }
    Ok(())
}

pub fn install(store: &Store, options: &Options) -> Result<Value> {
    let tool = options.tool.as_str();
    ensure!(["rustup", "uv", "python", "gh", "cloudflared", "wrangler", "android-sdk", "swiftly"].contains(&tool), "unknown_tool");
    if let Ok(dir) = store.directory("logs") { let _ = fs::remove_file(dir.join(format!("devtool-{tool}.log"))); }
    let home = home()?;
    let result = match tool {
        "swiftly" => crate::toolchains::install_swiftly(store)?,
        "rustup" if home.join(".cargo/bin/rustup").is_file() => {
            // Already there: rustup's own update to the newest stable.
            run(store, tool, &home.join(".cargo/bin/rustup"), &["update", "stable"], &[], &[("CARGO_HOME", home.join(".cargo").to_string_lossy().into_owned()), ("RUSTUP_HOME", home.join(".rustup").to_string_lossy().into_owned())], false)?;
            json!({"path": home.join(".cargo/bin")})
        }
        "rustup" => {
            let target = if arm() { "aarch64-apple-darwin" } else { "x86_64-apple-darwin" };
            let url = format!("https://static.rust-lang.org/rustup/dist/{target}/rustup-init");
            let listed = String::from_utf8(tools::fetch(&format!("{url}.sha256"), 10_000)?)?;
            let hash = listed.split_whitespace().next().unwrap_or("").to_string();
            let dir = work_dir(store, tool)?;
            let init = fetch_verified(store, tool, &url, &hash, &dir)?;
            fs::set_permissions(&init, std::os::unix::fs::PermissionsExt::from_mode(0o755))?;
            // rustup-init edits shell profiles itself unless told not to; Stack does it its own way.
            run(store, tool, &init, &["-y", "--profile", "default", "--default-toolchain", "stable", "--no-modify-path"], &[],
                &[("CARGO_HOME", home.join(".cargo").to_string_lossy().into_owned()), ("RUSTUP_HOME", home.join(".rustup").to_string_lossy().into_owned())], false)?;
            json!({"path": home.join(".cargo/bin")})
        }
        "uv" => {
            let release = latest_release("astral-sh/uv")?;
            let name = if arm() { "uv-aarch64-apple-darwin.tar.gz" } else { "uv-x86_64-apple-darwin.tar.gz" };
            let hash = listed_hash(&String::from_utf8(tools::fetch(&asset_url(&release, &format!("{name}.sha256"))?, 10_000)?)?, name)?;
            ensure!(asset_digest(&release, name).is_none_or(|d| d == hash), "checksum_mismatch");
            let dir = work_dir(store, tool)?;
            let archive = fetch_verified(store, tool, &asset_url(&release, name)?, &hash, &dir)?;
            untar(&archive, &dir)?;
            for program in ["uv", "uvx"] {
                place(&find_file(&dir, program).context("uv_missing")?, program)?;
            }
            json!({"version": release["tag_name"], "path": home.join(".local/bin/uv")})
        }
        "python" => {
            // Python is a Stack language now: CPython from python-build-standalone, in runtimes/python.
            let manifest = crate::python::install(store, &options.version)?;
            json!({"version": manifest.version})
        }
        "gh" => {
            let release = latest_release("cli/cli")?;
            let version = release["tag_name"].as_str().unwrap_or("").trim_start_matches('v').to_string();
            let name = format!("gh_{version}_macOS_{}.zip", if arm() { "arm64" } else { "amd64" });
            let sums = String::from_utf8(tools::fetch(&asset_url(&release, &format!("gh_{version}_checksums.txt"))?, 100_000)?)?;
            let dir = work_dir(store, tool)?;
            let hash = listed_hash(&sums, &name)?;
            ensure!(asset_digest(&release, &name).is_none_or(|d| d == hash), "checksum_mismatch");
            let archive = fetch_verified(store, tool, &asset_url(&release, &name)?, &hash, &dir)?;
            unzip(&archive, &dir)?;
            place(&find_file(&dir, "gh").context("gh_missing")?, "gh")?;
            json!({"version": version})
        }
        "cloudflared" => {
            let release = latest_release("cloudflare/cloudflared")?;
            let name = if arm() { "cloudflared-darwin-arm64.tgz" } else { "cloudflared-darwin-amd64.tgz" };
            // The archive against GitHub's digest; the binary inside against the SHA-256 Cloudflare lists
            // in the release notes (that one is the binary's, not the archive's); and its Apple signature.
            let archive_hash = asset_digest(&release, name).context("checksum_not_found")?;
            let binary_hash = listed_hash(release["body"].as_str().unwrap_or(""), name)?;
            let dir = work_dir(store, tool)?;
            let archive = fetch_verified(store, tool, &asset_url(&release, name)?, &archive_hash, &dir)?;
            untar(&archive, &dir)?;
            let binary = find_file(&dir, "cloudflared").context("cloudflared_missing")?;
            ensure!(tools::sha256_file(&binary)?.eq_ignore_ascii_case(&binary_hash), "checksum_mismatch");
            log(store, tool, &format!("SHA-256 del binario verificado: {binary_hash}"));
            let signed = Command::new("/usr/bin/codesign").args(["--verify", "--strict", "-R=anchor apple generic and certificate leaf[subject.OU] = \"68WVV388M8\""]).arg(&binary).stderr(Stdio::null()).status()?;
            ensure!(signed.success(), "signature_invalid");
            log(store, tool, "Firma de Cloudflare (68WVV388M8) verificada");
            place(&binary, "cloudflared")?;
            json!({"version": release["tag_name"]})
        }
        "wrangler" => {
            // npm checks each package against the registry's integrity hash.
            let node = tools::resolve(store, "node", "").map(|d| d.join("bin")).context("node_not_installed")?;
            let prefix = home.join(".local/share/butake-stack/npm");
            fs::create_dir_all(&prefix)?;
            run(store, tool, &node.join("npm"), &["install", "--global", "--no-fund", "--no-audit", "--prefix", &prefix.to_string_lossy(), "wrangler@latest"], &[node.clone()], &[], false)?;
            // Wrangler's own entry point (#!/usr/bin/env node), linked; Node comes from the terminal's
            // global Node (Stack links it when asked) or the site's.
            let launcher = home.join(".local/bin/wrangler");
            fs::create_dir_all(launcher.parent().unwrap())?;
            if fs::symlink_metadata(&launcher).is_ok_and(|m| m.is_file() || m.file_type().is_symlink()) { fs::remove_file(&launcher)?; }
            crate::toolchains::replace_link(&prefix.join("bin/wrangler"), &launcher)?;
            // Its entry point runs with `node` from the PATH: the global Node goes on the terminal too
            // (links only, never replacing files that aren't Stack's).
            if !home.join(".local/bin/node").exists() {
                let wanted = store.config()?.versions.get("node").cloned().unwrap_or_default();
                let version = if tools::resolve(store, "node", &wanted).is_some() { wanted } else { String::new() };
                let version = if version.is_empty() { node.parent().and_then(|p| p.file_name()).map(|n| n.to_string_lossy().into_owned()).unwrap_or_default() } else { version };
                crate::toolchains::link_terminal(store, "node", &version)?;
            }
            json!({"path": launcher})
        }
        "android-sdk" => {
            ensure!(options.accept_licenses, "licenses_not_accepted");
            let jdk = tools::resolve(store, "jdk", "").map(|r| r.join("Contents/Home")).context("jdk_not_installed")?;
            let sdk = std::env::var_os("ANDROID_HOME").map(PathBuf::from).unwrap_or_else(|| home.join("Library/Android/sdk"));
            let sdkmanager = sdk.join("cmdline-tools/latest/bin/sdkmanager");
            if !sdkmanager.is_file() {
                // Google's repository lists the command-line tools with their SHA-1.
                let xml = String::from_utf8(tools::fetch("https://dl.google.com/android/repository/repository2-3.xml", 20_000_000)?)?;
                let package = xml.split("<remotePackage path=\"cmdline-tools;latest\">").nth(1).context("cmdline_tools_not_listed")?;
                let package = package.split("</remotePackage>").next().unwrap_or("");
                let archive = package.split("<archive>").find(|a| a.contains("<host-os>macosx</host-os>")).context("cmdline_tools_not_listed")?;
                let between = |tag: &str| archive.split(&format!("<{tag}")).nth(1).and_then(|r| r.split('>').nth(1)).and_then(|r| r.split('<').next()).map(str::to_string);
                let file = between("url").context("cmdline_tools_not_listed")?;
                let sha1 = between("checksum").context("cmdline_tools_not_listed")?;
                ensure!(file.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_' || c == b'.'), "invalid_url");
                let dir = work_dir(store, tool)?;
                let zip = dir.join(&file);
                log(store, tool, &format!("descargando {file}"));
                tools::download(&format!("https://dl.google.com/android/repository/{file}"), &zip)?;
                let out = Command::new("/usr/bin/shasum").args(["-a", "1"]).arg(&zip).output()?;
                let actual = String::from_utf8_lossy(&out.stdout).split_whitespace().next().unwrap_or("").to_string();
                ensure!(actual.eq_ignore_ascii_case(&sha1), "checksum_mismatch");
                log(store, tool, &format!("SHA-1 verificado: {actual}"));
                unzip(&zip, &dir)?;
                let latest = sdk.join("cmdline-tools/latest");
                fs::create_dir_all(latest.parent().unwrap())?;
                let _ = fs::remove_dir_all(&latest);
                fs::rename(dir.join("cmdline-tools"), &latest)?;
            }
            let java = [("JAVA_HOME", jdk.to_string_lossy().into_owned()), ("ANDROID_HOME", sdk.to_string_lossy().into_owned())];
            // The user accepted the licenses in the app: answer sdkmanager's prompts for them.
            run(store, tool, &sdkmanager, &["--licenses"], &[jdk.join("bin")], &java, true)?;
            run(store, tool, &sdkmanager, &["platform-tools"], &[jdk.join("bin")], &java, true)?;
            json!({"path": sdk})
        }
        _ => unreachable!(),
    };
    if options.shell_path && tool != "android-sdk" && tool != "python" {
        shell_path(store)?;
    }
    Ok(result)
}

/// Newest version of each tool at its source: GitHub releases (uv, gh, cloudflared), npm (Wrangler),
/// Rust's stable channel and Python's supported lines. Cached by the caller; a source that doesn't
/// answer is just left out.
pub fn latest() -> Result<Value> {
    let tag = |repo: &'static str| std::thread::spawn(move || latest_release(repo).ok().and_then(|r| r["tag_name"].as_str().map(|t| t.trim_start_matches('v').to_string())));
    let (uv, gh, cloudflared) = (tag("astral-sh/uv"), tag("cli/cli"), tag("cloudflare/cloudflared"));
    let wrangler = std::thread::spawn(|| tools::fetch("https://registry.npmjs.org/wrangler/latest", 2_000_000).ok()
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok()).and_then(|v| v["version"].as_str().map(str::to_string)));
    let rust = std::thread::spawn(|| tools::fetch("https://static.rust-lang.org/dist/channel-rust-stable.toml", 30_000_000).ok().and_then(|b| {
        let text = String::from_utf8(b).ok()?;
        let section = text.split("[pkg.rust]").nth(1)?;
        section.lines().find(|l| l.starts_with("version"))?.split('"').nth(1)?.split_whitespace().next().map(str::to_string)
    }));
    let python = std::thread::spawn(|| python_versions().ok());
    let mut out = serde_json::Map::new();
    for (id, handle) in [("uv", uv), ("gh", gh), ("cloudflared", cloudflared), ("wrangler", wrangler), ("rustup", rust)] {
        if let Ok(Some(version)) = handle.join() { out.insert(id.into(), json!(version)); }
    }
    if let Ok(Some(lines)) = python.join() {
        let map: serde_json::Map<String, Value> = lines.as_array().cloned().unwrap_or_default().into_iter()
            .filter_map(|l| Some((l["version"].as_str()?.to_string(), l["latest"].clone()))).collect();
        out.insert("python".into(), Value::Object(map));
    }
    ensure!(!out.is_empty(), "offline");
    Ok(Value::Object(out))
}

fn newer(latest: &str, installed: &str) -> bool {
    let parse = |v: &str| v.split(['.', '-']).map(|p| p.parse::<u64>().unwrap_or(0)).collect::<Vec<_>>();
    parse(latest) > parse(installed)
}

/// What can be updated: installed version against the newest at its source.
pub fn updates(store: &Store, latest: &Value) -> Result<Value> {
    let local = tools::dev_tools(store)?;
    let mut out = serde_json::Map::new();
    for id in ["uv", "gh", "cloudflared", "wrangler", "rustup"] {
        if let (Some(installed), Some(newest)) = (local[id]["version"].as_str(), latest[id].as_str()) {
            out.insert(id.into(), json!({"installed": installed, "latest": newest, "update": newer(newest, installed)}));
        }
    }
    // Python: each line Stack has, against that line's newest patch.
    let mut lines = serde_json::Map::new();
    for manifest in crate::python::installed(store) {
        if let Some(newest) = latest["python"][&manifest.line].as_str() {
            lines.insert(manifest.line.clone(), json!({"installed": manifest.version, "latest": newest, "update": newer(newest, &manifest.version)}));
        }
    }
    out.insert("python".into(), Value::Object(lines));
    Ok(Value::Object(out))
}

/// Python lines Stack can install (python-build-standalone's newest release) that are still
/// supported, newest first: {version: line, latest: patch, eol}.
pub fn python_versions() -> Result<Value> {
    let today = chrono_today();
    let list: Vec<Value> = crate::python::catalog()?.as_array().cloned().unwrap_or_default().into_iter()
        .filter(|c| c["eol"].as_str().is_none_or(|eol| eol > today.as_str()))
        .map(|c| json!({"version": c["line"], "latest": c["version"], "eol": c["eol"], "support": c["support"]}))
        .collect();
    Ok(Value::Array(list))
}
fn chrono_today() -> String {
    let out = Command::new("/bin/date").arg("+%Y-%m-%d").output().ok();
    out.map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string()).unwrap_or_else(|| "2026-01-01".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn finds_listed_checksums_in_both_formats() {
        let sums = "abc  other.zip\n0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  gh_2.0_macOS_arm64.zip\n";
        assert_eq!(listed_hash(sums, "gh_2.0_macOS_arm64.zip").unwrap(), "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
        let body = "SHA256 Checksums:\n```\ncloudflared-darwin-arm64.tgz: FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210\n```";
        assert_eq!(listed_hash(body, "cloudflared-darwin-arm64.tgz").unwrap(), "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210");
        assert!(listed_hash(body, "missing.tgz").is_err());
    }
}

/// Python lines Stack has installed ("3.13"…), for the environment backup.
pub fn installed_pythons(store: &Store) -> Vec<String> {
    crate::python::installed(store).into_iter().map(|m| m.line).collect()
}
