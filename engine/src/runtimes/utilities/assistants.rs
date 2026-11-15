//! The AI assistants: Codex, Claude Code, Claude Desktop and ChatGPT, each from its maker's source.

use super::*;

// ---- Codex ----

pub(super) fn codex_target() -> &'static str {
    if arm() {
        "aarch64-apple-darwin"
    } else {
        "x86_64-apple-darwin"
    }
}

/// The version of a Codex release tag ("rust-v0.169.0" → "0.169.0").
pub(super) fn codex_version(tag: &str) -> Result<String> {
    let version = tag.strip_prefix("rust-v").unwrap_or("");
    ensure!(valid_version(version), "unexpected_artifact");
    Ok(version.into())
}

/// As the official install.sh does: the package of the newest release of openai/codex, whose
/// SHA-256 is listed in codex-package_SHA256SUMS (that file checked against GitHub's digest) and
/// must equal GitHub's digest of the package itself.
pub(super) fn install_codex(store: &Store, dir: &Path) -> Result<Value> {
    progress::step("download");
    let release = crate::core::github::latest_release(store, "openai/codex")?;
    let version = codex_version(release["tag_name"].as_str().unwrap_or(""))?;
    let package = format!("codex-package-{}.tar.gz", codex_target());
    let sums_name = "codex-package_SHA256SUMS";
    let sums_digest = asset_digest(&release, sums_name).context("checksum_not_found")?;
    let sums = dir.join(sums_name);
    download::download_verified(&asset_url(&release, sums_name)?, &sums, &sums_digest)?;
    let sha256 = listed_hash(&fs::read_to_string(&sums)?, &package)?;
    ensure!(
        asset_digest(&release, &package).as_deref() == Some(sha256.as_str()),
        "checksum_mismatch"
    );
    let archive = dir.join(&package);
    devtools::log(store, "codex", &format!("descargando {package} {version}"));
    download::download_verified(&asset_url(&release, &package)?, &archive, &sha256)?;
    place_codex(store, &archive, &sha256, &version)
}

/// Checks the downloaded package (its SHA-256, then the signature and notarization of every
/// program in it) and lays it out as install.sh does: `~/.codex/packages/standalone/releases/
/// <version>-<target>`, `current` pointing at it, and `codex` and `codex-code-mode-host` linked
/// in `~/.local/bin`.
pub(super) fn place_codex(
    store: &Store,
    archive: &Path,
    sha256: &str,
    version: &str,
) -> Result<Value> {
    progress::step("verifyBinary");
    ensure!(
        hash::sha256_file(archive)?.eq_ignore_ascii_case(sha256),
        "checksum_mismatch"
    );
    let home = home()?;
    let target = codex_target();
    let root = home.join(".codex/packages/standalone");
    let releases = root.join("releases");
    fs::create_dir_all(&releases)?;
    let name = format!("{version}-{target}");
    let stage = releases.join(format!(".staging.{name}.{}", std::process::id()));
    let _ = fs::remove_dir_all(&stage);
    fs::create_dir_all(&stage)?;
    let checked = (|| -> Result<()> {
        archive::extract_tar_gz(archive, &stage, false, "extract_failed")?;
        archive::check_tree(&stage, archive::Links::Forbid)?;
        let manifest: Value = serde_json::from_slice(&fs::read(stage.join("codex-package.json"))?)?;
        ensure!(
            manifest["version"] == version && manifest["target"] == target,
            "unexpected_artifact"
        );
        let mut programs = vec!["bin/codex", "bin/codex-code-mode-host", "codex-path/rg"];
        if stage.join("bin/codex-exec-server").is_file() {
            programs.push("bin/codex-exec-server");
        }
        for program in programs {
            let path = stage.join(program);
            ensure!(path.is_file(), "unexpected_artifact");
            signature::verify_code(&path, OPENAI_TEAM, false)?;
        }
        signature::verify_notarized(&stage.join("bin/codex"), false)?;
        devtools::log(store, "codex", &format!("SHA-256 verificado ({sha256}); firma de OpenAI ({OPENAI_TEAM}) y notarización de Apple verificadas"));
        std::os::unix::fs::symlink("bin/codex", stage.join("codex"))?;
        progress::check()
    })();
    if let Err(error) = checked {
        let _ = fs::remove_dir_all(&stage);
        return Err(error);
    }
    progress::fixed_step("install");
    let release_dir = releases.join(&name);
    if fs::symlink_metadata(&release_dir).is_ok() {
        fs::remove_dir_all(&release_dir)?;
    }
    fs::rename(&stage, &release_dir)?;
    let current = root.join("current");
    crate::runtimes::languages::toolchains::replace_link(&release_dir, &current)?;
    fsutil::write_private(&root.join("auto-update-version"), &name)?;
    let bin = home.join(".local/bin");
    fs::create_dir_all(&bin)?;
    let codex = bin.join("codex");
    let host = bin.join("codex-code-mode-host");
    crate::runtimes::languages::toolchains::replace_link(&current.join("bin/codex"), &codex)?;
    crate::runtimes::languages::toolchains::replace_link(
        &current.join("bin/codex-code-mode-host"),
        &host,
    )?;
    check_reported(&codex, version)?;
    record(store, "codex", version, vec![codex.clone(), host, root])?;
    Ok(json!({"version": version, "path": codex}))
}

// ---- Claude Code ----

pub(super) fn claude_platform() -> &'static str {
    if arm() {
        "darwin-arm64"
    } else {
        "darwin-x64"
    }
}

/// The SHA-256 the release manifest lists for `platform`, after checking it is that version's.
pub(super) fn claude_checksum(manifest: &Value, version: &str, platform: &str) -> Result<String> {
    ensure!(manifest["version"] == version, "unexpected_artifact");
    let checksum = manifest["platforms"][platform]["checksum"]
        .as_str()
        .context("checksum_not_found")?;
    ensure!(
        checksum.len() == 64 && checksum.bytes().all(|c| c.is_ascii_hexdigit()),
        "checksum_not_found"
    );
    Ok(checksum.to_lowercase())
}

/// As the official native installer does: the version of the `latest` channel, its manifest and
/// the binary for this Mac checked against the manifest's SHA-256.
pub(super) fn install_claude_code(store: &Store, dir: &Path) -> Result<Value> {
    progress::step("download");
    let version = fetch_text(&format!("{CLAUDE_CODE_BASE}/latest"), 100)?;
    ensure!(valid_version(&version), "unexpected_artifact");
    let manifest: Value = serde_json::from_slice(&download::fetch(
        &format!("{CLAUDE_CODE_BASE}/{version}/manifest.json"),
        1_000_000,
    )?)?;
    let platform = claude_platform();
    let sha256 = claude_checksum(&manifest, &version, platform)?;
    let binary = dir.join("claude");
    devtools::log(
        store,
        "claude-code",
        &format!("descargando Claude Code {version} ({platform})"),
    );
    download::download_verified(
        &format!("{CLAUDE_CODE_BASE}/{version}/{platform}/claude"),
        &binary,
        &sha256,
    )?;
    place_claude_code(store, &binary, &sha256, &version)
}

/// Checks the binary (SHA-256, Anthropic's signature, notarization) and places it where the native
/// installer does: `~/.local/share/claude/versions/<version>`, linked as `~/.local/bin/claude`.
pub(super) fn place_claude_code(
    store: &Store,
    binary: &Path,
    sha256: &str,
    version: &str,
) -> Result<Value> {
    progress::step("verifyBinary");
    ensure!(
        hash::sha256_file(binary)?.eq_ignore_ascii_case(sha256),
        "checksum_mismatch"
    );
    signature::verify_code(binary, ANTHROPIC_TEAM, false)?;
    signature::verify_notarized(binary, false)?;
    devtools::log(store, "claude-code", &format!("SHA-256 verificado ({sha256}); firma de Anthropic ({ANTHROPIC_TEAM}) y notarización de Apple verificadas"));
    progress::check()?;
    progress::fixed_step("install");
    let home = home()?;
    let share = home.join(".local/share/claude");
    let versions = share.join("versions");
    fs::create_dir_all(&versions)?;
    let target = versions.join(version);
    let temp = versions.join(format!(".{version}.butake"));
    fs::copy(binary, &temp)?;
    fs::set_permissions(&temp, std::os::unix::fs::PermissionsExt::from_mode(0o755))?;
    fs::rename(&temp, &target)?;
    let bin = home.join(".local/bin");
    fs::create_dir_all(&bin)?;
    let claude = bin.join("claude");
    crate::runtimes::languages::toolchains::replace_link(&target, &claude)?;
    check_reported(&claude, version)?;
    record(store, "claude-code", version, vec![claude.clone(), share])?;
    Ok(json!({"version": version, "path": claude}))
}

// ---- Claude Desktop ----

/// The current release of the update feed: its version and the archive's address, which must be
/// on Anthropic's own download host.
pub(super) fn desktop_release(feed: &Value) -> Result<(String, String)> {
    let version = feed["currentRelease"].as_str().unwrap_or("").to_string();
    ensure!(valid_version(&version), "unexpected_artifact");
    let url = feed["releases"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|r| r["version"] == version.as_str())
        .and_then(|r| r["updateTo"]["url"].as_str())
        .context("unexpected_artifact")?;
    let file = url.strip_prefix(CLAUDE_DESKTOP_FILES).unwrap_or("");
    ensure!(
        file.starts_with(&format!("{version}/"))
            && file.ends_with(".zip")
            && file
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || b"-_./".contains(&c))
            && !file.contains(".."),
        "unexpected_artifact"
    );
    Ok((version, url.to_string()))
}

/// The app of the current release in Claude Desktop's own update feed. Anthropic publishes no
/// checksum for it: the app must carry Anthropic's signature (every nested bundle too) and Apple's
/// notarization, or nothing is copied.
pub(super) fn install_claude_desktop(store: &Store, dir: &Path) -> Result<Value> {
    progress::step("download");
    let feed: Value = serde_json::from_slice(&download::fetch(CLAUDE_DESKTOP_FEED, 1_000_000)?)?;
    let (version, url) = desktop_release(&feed)?;
    let zip = dir.join("Claude.zip");
    devtools::log(
        store,
        "claude-desktop",
        &format!("descargando Claude {version}"),
    );
    download::download(&url, &zip)?;
    place_app(store, &CLAUDE_DESKTOP, &zip, &version)
}

/// Unpacks the app's `.zip` in Stack's work folder (never opening it), checks it (the maker's
/// signature on every nested bundle, notarization, bundle identifier and version) and copies it
/// with ditto to `~/Applications/<name>`.
pub(super) fn place_app(store: &Store, spec: &App, zip: &Path, version: &str) -> Result<Value> {
    let unpacked = zip.with_extension("unpacked");
    let _ = fs::remove_dir_all(&unpacked);
    fs::create_dir_all(&unpacked)?;
    let staging = format!(".{}.butake", spec.name);
    let result = (|| -> Result<Value> {
        progress::step("verifyApp");
        archive::extract_app_zip(zip, &unpacked, "extract_failed")?;
        let entries: Vec<_> = fs::read_dir(&unpacked)?
            .flatten()
            .map(|e| e.file_name())
            .collect();
        ensure!(entries == [spec.name], "unexpected_artifact");
        let app = unpacked.join(spec.name);
        archive::check_tree(&app, archive::Links::Inside)?;
        signature::verify_code(&app, spec.team, true)?;
        signature::verify_notarized(&app, true)?;
        ensure!(
            plist_value(&app.join("Contents/Info.plist"), "CFBundleIdentifier").as_deref()
                == Some(spec.bundle)
                && app_version(&app).as_deref() == Some(version),
            "unexpected_artifact"
        );
        devtools::log(
            store,
            spec.tool,
            &format!(
                "firma de {} ({}) y notarización de Apple verificadas",
                spec.maker, spec.team
            ),
        );
        progress::check()?;
        progress::fixed_step("copyApp");
        let applications = applications()?;
        fs::create_dir_all(&applications)?;
        let target = applications.join(spec.name);
        let stage = applications.join(&staging);
        let _ = fs::remove_dir_all(&stage);
        archive::copy_tree(&app, &stage, "extract_failed")?;
        // The copy must still be the checked app before it takes the place of the old one.
        signature::verify_code(&stage, spec.team, true)?;
        if fs::symlink_metadata(&target).is_ok() {
            fs::remove_dir_all(&target)?;
        }
        fs::rename(&stage, &target)?;
        record(store, spec.tool, version, vec![target.clone()])?;
        Ok(json!({"version": version, "path": target}))
    })();
    let _ = fs::remove_dir_all(&unpacked);
    if result.is_err() {
        if let Ok(applications) = applications() {
            let _ = fs::remove_dir_all(applications.join(&staging));
        }
    }
    result
}

// ---- ChatGPT ----

/// The newest full archive in the app's Sparkle feed: its version and address, which must be
/// exactly `ChatGPT-darwin-arm64-<version>.zip` on OpenAI's download host (the deltas and anything
/// else are ignored). Sparkle's own EdDSA signature is not checked (no such tool in macOS).
pub(super) fn chatgpt_release(feed: &str) -> Result<(String, String)> {
    let mut best: Option<(String, String)> = None;
    for item in feed.split("<item>").skip(1) {
        let item = item.split("</item>").next().unwrap_or("");
        let version = item
            .split("<sparkle:shortVersionString>")
            .nth(1)
            .and_then(|r| r.split("</sparkle:shortVersionString>").next())
            .unwrap_or("")
            .trim();
        let full = item.split("<sparkle:deltas>").next().unwrap_or("");
        let url = full
            .split("<enclosure url=\"")
            .nth(1)
            .and_then(|r| r.split('"').next())
            .unwrap_or("");
        if valid_version(version)
            && url == format!("{CHATGPT_FILES}ChatGPT-darwin-arm64-{version}.zip")
            && best
                .as_ref()
                .is_none_or(|(newest, _)| devtools::newer(version, newest))
        {
            best = Some((version.to_string(), url.to_string()));
        }
    }
    best.context("unexpected_artifact")
}

/// The app of the newest release in ChatGPT's own update feed (Apple silicon only). OpenAI
/// publishes no checksum for it: the app must carry OpenAI's signature (every nested bundle too)
/// and Apple's notarization, or nothing is copied.
pub(super) fn install_chatgpt(store: &Store, dir: &Path) -> Result<Value> {
    ensure!(arm(), "unsupported_platform");
    progress::step("download");
    let (version, url) = chatgpt_release(&fetch_text(CHATGPT_FEED, 1_000_000)?)?;
    let zip = dir.join("ChatGPT.zip");
    devtools::log(store, "chatgpt", &format!("descargando ChatGPT {version}"));
    download::download_up_to(&url, &zip, CHATGPT_MAX_BYTES)?;
    place_app(store, &CHATGPT, &zip, &version)
}
