//! Installing one tool from its official source (rustup, uv, gh, cloudflared, the Android SDK, swiftly, Wrangler, the utilities).

use super::*;

pub(super) fn install_tool(store: &Store, options: &Options) -> Result<Value> {
    let tool = options.tool.as_str();
    let home = home()?;
    let result = match tool {
        _ if utilities::IDS.contains(&tool) => utilities::install(store, tool)?,
        "swiftly" => crate::runtimes::languages::toolchains::install_swiftly(store)?,
        "rustup" if home.join(".cargo/bin/rustup").is_file() => {
            // Already there: rustup's own update to the newest stable, not cut halfway.
            progress::fixed_step("updateToolchain");
            run(
                store,
                tool,
                &home.join(".cargo/bin/rustup"),
                &["update", "stable"],
                &[],
                &rust_homes(&home),
                Mode::External,
            )?;
            json!({"path": home.join(".cargo/bin")})
        }
        "rustup" => {
            progress::step("download");
            let target = if arm() {
                "aarch64-apple-darwin"
            } else {
                "x86_64-apple-darwin"
            };
            let url = format!("https://static.rust-lang.org/rustup/dist/{target}/rustup-init");
            let listed = String::from_utf8(download::fetch(&format!("{url}.sha256"), 10_000)?)?;
            let hash = listed.split_whitespace().next().unwrap_or("").to_string();
            let dir = work_dir(store, tool)?;
            let init = fetch_verified(store, tool, &url, &hash, &dir, "verifySum")?;
            fs::set_permissions(&init, std::os::unix::fs::PermissionsExt::from_mode(0o755))?;
            progress::check()?;
            // rustup-init downloads the compiler and fills ~/.cargo and ~/.rustup: it is not cut
            // halfway. It edits shell profiles itself unless told not to; Stack does it its own way.
            progress::fixed_step("runInstaller");
            run(
                store,
                tool,
                &init,
                &[
                    "-y",
                    "--profile",
                    "default",
                    "--default-toolchain",
                    "stable",
                    "--no-modify-path",
                ],
                &[],
                &rust_homes(&home),
                Mode::External,
            )?;
            json!({"path": home.join(".cargo/bin")})
        }
        "uv" => {
            progress::step("download");
            let release = github::latest_release(store, "astral-sh/uv")?;
            let name = if arm() {
                "uv-aarch64-apple-darwin.tar.gz"
            } else {
                "uv-x86_64-apple-darwin.tar.gz"
            };
            let hash = listed_hash(
                &String::from_utf8(download::fetch(
                    &asset_url(&release, &format!("{name}.sha256"))?,
                    10_000,
                )?)?,
                name,
            )?;
            ensure!(
                asset_digest(&release, name).is_none_or(|d| d == hash),
                "checksum_mismatch"
            );
            let dir = work_dir(store, tool)?;
            let archive = fetch_verified(
                store,
                tool,
                &asset_url(&release, name)?,
                &hash,
                &dir,
                "verifySum",
            )?;
            archive::extract_tar_gz(&archive, &dir, false, "extract_failed")?;
            archive::check_tree(&dir, archive::Links::Forbid)?;
            let uv = find_file(&dir, "uv").context("uv_missing")?;
            let uvx = find_file(&dir, "uvx").context("uv_missing")?;
            progress::check()?;
            progress::fixed_step("install");
            place(&uv, "uv")?;
            place(&uvx, "uvx")?;
            json!({"version": release["tag_name"], "path": home.join(".local/bin/uv")})
        }
        "python" => {
            // Python is a Stack language now: CPython from python-build-standalone, in runtimes/python.
            let manifest = crate::runtimes::languages::python::install(store, &options.version)?;
            json!({"version": manifest.version})
        }
        "gh" => {
            progress::step("download");
            let release = github::latest_release(store, "cli/cli")?;
            let version = release["tag_name"]
                .as_str()
                .unwrap_or("")
                .trim_start_matches('v')
                .to_string();
            let name = format!(
                "gh_{version}_macOS_{}.zip",
                if arm() { "arm64" } else { "amd64" }
            );
            let sums = String::from_utf8(download::fetch(
                &asset_url(&release, &format!("gh_{version}_checksums.txt"))?,
                100_000,
            )?)?;
            let dir = work_dir(store, tool)?;
            let hash = listed_hash(&sums, &name)?;
            ensure!(
                asset_digest(&release, &name).is_none_or(|d| d == hash),
                "checksum_mismatch"
            );
            let archive = fetch_verified(
                store,
                tool,
                &asset_url(&release, &name)?,
                &hash,
                &dir,
                "verifySum",
            )?;
            archive::extract_zip(&archive, &dir, "extract_failed")?;
            archive::check_tree(&dir, archive::Links::Forbid)?;
            let binary = find_file(&dir, "gh").context("gh_missing")?;
            progress::check()?;
            progress::fixed_step("install");
            let gh = place(&binary, "gh")?;
            utilities::record(store, "gh", &version, vec![gh])?;
            json!({"version": version})
        }
        "cloudflared" => {
            progress::step("download");
            let release = github::latest_release(store, "cloudflare/cloudflared")?;
            let name = if arm() {
                "cloudflared-darwin-arm64.tgz"
            } else {
                "cloudflared-darwin-amd64.tgz"
            };
            // The archive against GitHub's digest; the binary inside against the SHA-256 Cloudflare lists
            // in the release notes (that one is the binary's, not the archive's); and its Apple signature.
            let archive_hash = asset_digest(&release, name).context("checksum_not_found")?;
            let binary_hash = listed_hash(release["body"].as_str().unwrap_or(""), name)?;
            let dir = work_dir(store, tool)?;
            let archive = fetch_verified(
                store,
                tool,
                &asset_url(&release, name)?,
                &archive_hash,
                &dir,
                "verifyBinary",
            )?;
            archive::extract_tar_gz(&archive, &dir, false, "extract_failed")?;
            archive::check_tree(&dir, archive::Links::Forbid)?;
            let binary = find_file(&dir, "cloudflared").context("cloudflared_missing")?;
            ensure!(
                hash::sha256_file(&binary)?.eq_ignore_ascii_case(&binary_hash),
                "checksum_mismatch"
            );
            log(
                store,
                tool,
                &format!("SHA-256 del binario verificado: {binary_hash}"),
            );
            crate::core::signature::verify_code(&binary, CLOUDFLARE_TEAM, false)?;
            log(store, tool, "Firma de Cloudflare (68WVV388M8) verificada");
            progress::check()?;
            progress::fixed_step("install");
            let placed = place(&binary, "cloudflared")?;
            let version = release["tag_name"].as_str().unwrap_or("");
            utilities::record(store, "cloudflared", version, vec![placed])?;
            json!({"version": release["tag_name"]})
        }
        "wrangler" => {
            // npm checks each package against the registry's integrity hash.
            let node = catalog::resolve(store, "node", "")
                .map(|d| d.join("bin"))
                .context("node_not_installed")?;
            install_wrangler(store, &node)?
        }
        "android-sdk" => {
            ensure!(options.accept_licenses, "licenses_not_accepted");
            let jdk = catalog::resolve(store, "jdk", "")
                .map(|r| r.join("Contents/Home"))
                .context("jdk_not_installed")?;
            let sdk = android_sdk(&home);
            let sdkmanager = sdk.join("cmdline-tools/latest/bin/sdkmanager");
            if !sdkmanager.is_file() {
                progress::step("download");
                // Google's repository lists the command-line tools with their SHA-1.
                let xml = String::from_utf8(download::fetch(
                    "https://dl.google.com/android/repository/repository2-3.xml",
                    20_000_000,
                )?)?;
                let package = xml
                    .split("<remotePackage path=\"cmdline-tools;latest\">")
                    .nth(1)
                    .context("cmdline_tools_not_listed")?;
                let package = package.split("</remotePackage>").next().unwrap_or("");
                let archive = package
                    .split("<archive>")
                    .find(|a| a.contains("<host-os>macosx</host-os>"))
                    .context("cmdline_tools_not_listed")?;
                let between = |tag: &str| {
                    archive
                        .split(&format!("<{tag}"))
                        .nth(1)
                        .and_then(|r| r.split('>').nth(1))
                        .and_then(|r| r.split('<').next())
                        .map(str::to_string)
                };
                let file = between("url").context("cmdline_tools_not_listed")?;
                let sha1 = between("checksum").context("cmdline_tools_not_listed")?;
                ensure!(
                    file.bytes()
                        .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_' || c == b'.'),
                    "invalid_url"
                );
                let dir = work_dir(store, tool)?;
                let zip = dir.join(&file);
                log(store, tool, &format!("descargando {file}"));
                download::download(
                    &format!("https://dl.google.com/android/repository/{file}"),
                    &zip,
                )?;
                progress::step("verifySum");
                let out = Command::new("/usr/bin/shasum")
                    .args(["-a", "1"])
                    .arg(&zip)
                    .output()?;
                let actual = String::from_utf8_lossy(&out.stdout)
                    .split_whitespace()
                    .next()
                    .unwrap_or("")
                    .to_string();
                ensure!(actual.eq_ignore_ascii_case(&sha1), "checksum_mismatch");
                log(store, tool, &format!("SHA-1 verificado: {actual}"));
                archive::extract_zip(&zip, &dir, "extract_failed")?;
                archive::check_tree(&dir, archive::Links::Inside)?;
                progress::check()?;
                progress::fixed_step("install");
                let latest = sdk.join("cmdline-tools/latest");
                fs::create_dir_all(latest.parent().unwrap())?;
                let _ = fs::remove_dir_all(&latest);
                fs::rename(dir.join("cmdline-tools"), &latest)?;
            }
            let java = [
                ("JAVA_HOME", jdk.to_string_lossy().into_owned()),
                ("ANDROID_HOME", sdk.to_string_lossy().into_owned()),
            ];
            // The user accepted the licenses in the app: answer sdkmanager's prompts for them.
            // sdkmanager fills the SDK's own folders: it is not cut halfway.
            progress::fixed_step("licenses");
            run(
                store,
                tool,
                &sdkmanager,
                &["--licenses"],
                &[jdk.join("bin")],
                &java,
                Mode::ExternalYes,
            )?;
            progress::fixed_step("platformTools");
            run(
                store,
                tool,
                &sdkmanager,
                &["platform-tools"],
                &[jdk.join("bin")],
                &java,
                Mode::ExternalYes,
            )?;
            json!({"path": sdk})
        }
        _ => unreachable!(),
    };
    if options.shell_path && !["android-sdk", "python", "claude-desktop", "chatgpt"].contains(&tool)
    {
        shell_path(store)?;
    }
    Ok(result)
}

/// The Wrangler release Stack installs: fixed, not `latest`, so a newly published (or hijacked)
/// version does not reach the Mac until Stack is updated to it. Read from
/// `https://registry.npmjs.org/wrangler/latest` (dist.integrity
/// `sha512-WwM+DL4F+zvz1id0CAPa06CAmTb6nOq1adR+Dy5AdwDsDXH5xDjSmDUUBQQN8KgSEuPCOLvzkrdMDUODIDml1A==`),
/// which npm checks on download.
pub(super) const WRANGLER_VERSION: &str = "4.164.0";

/// Wrangler from npm with Stack's Node (`node`: its `bin`). npm fills a folder of its own beside
/// the one in use, so «Cancelar» while it downloads leaves the installed Wrangler as it was; the
/// new folder takes the old one's place only once npm finished.
pub(super) fn install_wrangler(store: &Store, node: &Path) -> Result<Value> {
    let home = home()?;
    let share = home.join(".local/share/butake-stack");
    let prefix = share.join("npm");
    let staging = share.join(format!(".npm-{}", std::process::id()));
    let _ = fs::remove_dir_all(&staging);
    fs::create_dir_all(&staging)?;
    progress::step("npmPackage");
    let fetched = run(
        store,
        "wrangler",
        &node.join("npm"),
        &[
            "install",
            "--global",
            "--no-fund",
            "--no-audit",
            // No `preinstall`/`postinstall` of wrangler or its dependencies runs on the user's disk.
            "--ignore-scripts",
            "--prefix",
            &staging.to_string_lossy(),
            &format!("wrangler@{WRANGLER_VERSION}"),
        ],
        &[node.to_path_buf()],
        &[],
        Mode::Stoppable,
    )
    .and_then(|()| {
        ensure!(staging.join("bin/wrangler").exists(), "devtool_step_failed");
        progress::check()
    });
    if let Err(error) = fetched {
        let _ = fs::remove_dir_all(&staging);
        return Err(error);
    }
    progress::fixed_step("link");
    // npm links its programs with relative paths: the folder moves whole.
    if fs::symlink_metadata(&prefix).is_ok() {
        fs::remove_dir_all(&prefix)?;
    }
    fs::rename(&staging, &prefix)?;
    // Wrangler's own entry point (#!/usr/bin/env node), linked; Node comes from the terminal's
    // global Node (Stack links it when asked) or the site's.
    let launcher = home.join(".local/bin/wrangler");
    fs::create_dir_all(launcher.parent().unwrap())?;
    if fs::symlink_metadata(&launcher).is_ok_and(|m| m.is_file() || m.file_type().is_symlink()) {
        fs::remove_file(&launcher)?;
    }
    crate::runtimes::languages::toolchains::replace_link(&prefix.join("bin/wrangler"), &launcher)?;
    utilities::record(
        store,
        "wrangler",
        "",
        vec![
            launcher.clone(),
            prefix.join("bin/wrangler"),
            prefix.join("lib/node_modules/wrangler"),
        ],
    )?;
    // Its entry point runs with `node` from the PATH: the global Node goes on the terminal too
    // (links only, never replacing files that aren't Stack's).
    if !home.join(".local/bin/node").exists() {
        let wanted = store
            .config()?
            .versions
            .get("node")
            .cloned()
            .unwrap_or_default();
        let version = if catalog::resolve(store, "node", &wanted).is_some() {
            wanted
        } else {
            String::new()
        };
        let version = if version.is_empty() {
            node.parent()
                .and_then(|p| p.file_name())
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default()
        } else {
            version
        };
        crate::runtimes::languages::toolchains::link_terminal(store, "node", &version)?;
    }
    Ok(json!({"path": launcher}))
}
