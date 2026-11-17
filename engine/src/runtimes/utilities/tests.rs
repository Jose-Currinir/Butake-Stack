use super::*;
use std::sync::Mutex;

/// Tests that set BUTAKE_DEVTOOLS_HOME (or follow an install) run one at a time.
pub(crate) static HOME: &Mutex<()> = &crate::core::progress::TEST_TURN;

pub(crate) fn sandbox() -> (tempfile::TempDir, Store) {
    let dir = tempfile::tempdir().unwrap();
    fs::create_dir_all(dir.path().join("home")).unwrap();
    // SAFETY: only tests change these variables, and each one does it holding `HOME` (the shared
    // test turn), so two tests never change them at once. They are Stack's own variables, read by
    // no library; a test on another thread reading the environment at that moment is the remaining
    // risk, and it is limited to the test run.
    unsafe { std::env::set_var("BUTAKE_DEVTOOLS_HOME", dir.path().join("home")) };
    let store = Store::new(dir.path().join("store")).unwrap();
    (dir, store)
}

#[test]
fn versions_sources_and_manifests_are_read_strictly() {
    assert_eq!(
        version_in("codex-cli 0.169.0\n").as_deref(),
        Some("0.169.0")
    );
    assert_eq!(
        version_in("2.1.323 (Claude Code)").as_deref(),
        Some("2.1.323")
    );
    assert_eq!(
        version_in("aws-cli/2.40.2 Python/3.14.8 Darwin/27.2.0 exe/arm64").as_deref(),
        Some("2.40.2")
    );
    assert_eq!(codex_version("rust-v0.169.0").unwrap(), "0.169.0");
    for tag in ["v0.169.0", "rust-v1", "rust-v1.2.3; rm", "rust-v../1.2"] {
        assert!(codex_version(tag).is_err(), "{tag}");
    }
    assert!(valid_version("5.11492.2") && !valid_version("1") && !valid_version("1.2.x"));
    let sum = "5432918d904a9b6afef7bb79d20df24d76052eabc1f41bceb84091d21f8889a7";
    let manifest = json!({"version": "2.1.323", "platforms": {"darwin-arm64": {"checksum": sum}}});
    assert_eq!(
        claude_checksum(&manifest, "2.1.323", "darwin-arm64").unwrap(),
        sum
    );
    assert_eq!(
        claude_checksum(&manifest, "2.1.324", "darwin-arm64")
            .unwrap_err()
            .to_string(),
        "unexpected_artifact"
    );
    assert!(claude_checksum(&manifest, "2.1.323", "darwin-x64").is_err());
    let feed = |url: &str| json!({"currentRelease": "5.11492.2", "releases": [{"version": "5.11492.2", "updateTo": {"url": url}}]});
    let good =
        "https://downloads.claude.ai/releases/darwin/universal/5.11492.2/Claude-b1edc633.zip";
    assert_eq!(desktop_release(&feed(good)).unwrap().0, "5.11492.2");
    for bad in [
        "https://example.com/releases/darwin/universal/5.11492.2/Claude.zip",
        "https://downloads.claude.ai/releases/darwin/universal/5.11492.1/Claude.zip",
        "https://downloads.claude.ai/releases/darwin/universal/5.11492.2/../x.zip",
        "https://downloads.claude.ai/releases/darwin/universal/5.11492.2/Claude.dmg",
    ] {
        assert!(desktop_release(&feed(bad)).is_err(), "{bad}");
    }
    // ChatGPT's Sparkle feed: the newest full archive, never a delta or another host.
    let item = |version: &str, url: &str| {
        format!(
            "<item><sparkle:shortVersionString>{version}</sparkle:shortVersionString><enclosure url=\"{url}\" length=\"1\"/><sparkle:deltas><enclosure url=\"{CHATGPT_FILES}ChatGPT1-2-arm64.delta\"/></sparkle:deltas></item>"
        )
    };
    let zip = |version: &str| format!("{CHATGPT_FILES}ChatGPT-darwin-arm64-{version}.zip");
    let feed = format!(
        "<rss><channel>{}{}{}</channel></rss>",
        item("26.1106.51428", &zip("26.1106.51428")),
        item("26.1111.21308", &zip("26.1111.21308")),
        item(
            "27.1.1",
            "https://example.com/ChatGPT-darwin-arm64-27.1.1.zip"
        ),
    );
    assert_eq!(
        chatgpt_release(&feed).unwrap(),
        ("26.1111.21308".to_string(), zip("26.1111.21308"))
    );
    for bad in [
        item("26.1111.21308", &zip("26.1111.21307")),
        item(
            "26.1111.21308",
            &format!("{CHATGPT_FILES}../ChatGPT-darwin-arm64-26.1111.21308.zip"),
        ),
        item("26.1111.x", &zip("26.1111.x")),
        format!(
            "<item><sparkle:shortVersionString>1.2.3</sparkle:shortVersionString><sparkle:deltas><enclosure url=\"{}\"/></sparkle:deltas></item>",
            zip("1.2.3")
        ),
    ] {
        assert!(chatgpt_release(&bad).is_err(), "{bad}");
    }
}

#[test]
fn the_newest_git_release_is_read_from_the_checksum_list() {
    let sum = |c: char| c.to_string().repeat(64);
    let list = format!(
        "-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA256\n\n{}  git-2.9.5.tar.gz\n{}  git-2.56.1.tar.gz\n{}  git-2.56.1.tar.xz\n{}  git-2.57.0-rc1.tar.gz\n{}  git-manpages-2.60.0.tar.gz\n{}  git-2.100.0.tar.gz; rm\nzz  git-2.99.0.tar.gz\n{}  git-1.7.tar.gz\n-----BEGIN PGP SIGNATURE-----\n",
        sum('a'),
        sum('B'),
        sum('c'),
        sum('d'),
        sum('e'),
        sum('f'),
        sum('0')
    );
    assert_eq!(
        git_release(&list).unwrap(),
        ("2.56.1".to_string(), sum('b'))
    );
    assert_eq!(
        git_release("Hash: SHA256\n").unwrap_err().to_string(),
        "checksum_not_found"
    );
    assert_eq!(
        version_in("git version 2.50.1 (Apple Git-155)\n").as_deref(),
        Some("2.50.1")
    );
}

/// A Git source tarball whose Makefile runs `recipe` for `install`.
fn git_tarball(dir: &Path, version: &str, recipe: &str) -> (PathBuf, String) {
    let source = dir.join(format!("src/git-{version}"));
    fs::create_dir_all(&source).unwrap();
    fs::write(source.join("version"), format!("{version}\n")).unwrap();
    fs::write(
        source.join("Makefile"),
        format!("install:\n{recipe}\ninstall-git-credential-osxkeychain:\n\ttrue\n"),
    )
    .unwrap();
    let tgz = dir.join(format!("git-{version}.tar.gz"));
    assert!(
        Command::new("/usr/bin/tar")
            .arg("-czf")
            .arg(&tgz)
            .arg("-C")
            .arg(dir.join("src"))
            .arg(format!("git-{version}"))
            .status()
            .unwrap()
            .success()
    );
    let sum = hash::sha256_file(&tgz).unwrap();
    (tgz, sum)
}

/// Apple's refusal while Xcode's license is pending is told apart from any other failed build.
#[test]
fn a_pending_xcode_license_is_recognized() {
    assert!(license_pending(
        "You have not agreed to the Xcode license agreements. Please run 'sudo xcodebuild -license' from within a Terminal window to review and agree to the Xcode and Apple SDKs license.\n"
    ));
    assert!(!license_pending("Apple clang version 17.0.0\n"));
    assert!(!license_pending(
        "xcode-select: note: No developer tools were found, requesting install.\n"
    ));
    assert!(!license_pending(""));
}

/// The steps a Git install reports are its plan's, in order; «Cancelar» while it compiles
/// ends make and what it started (checked by pid) and leaves nothing installed.
#[test]
fn git_reports_its_steps_and_a_cancelled_build_leaves_nothing() {
    let _guard = HOME.lock().unwrap_or_else(|e| e.into_inner());
    if apple_developer_dir().is_none() {
        return;
    }
    let (dir, store) = sandbox();
    let home = dir.path().join("home");
    let log = dir.path().join("progress.log");
    progress::begin(&log);
    let (tgz, sum) = git_tarball(
        dir.path(),
        "9.9.7",
        "\tmkdir -p \"$(DESTDIR)$(prefix)/bin\"\n\tprintf '#!/bin/sh\\necho git version 9.9.7\\n' > \"$(DESTDIR)$(prefix)/bin/git\"\n\tchmod +x \"$(DESTDIR)$(prefix)/bin/git\"",
    );
    place_git(&store, &tgz, &sum, "9.9.7").unwrap();
    let read = progress::read(&fs::read_to_string(&log).unwrap(), None);
    assert_eq!(read["steps"], json!(plan("git")[1..]));
    assert!(home.join(".local/bin/git").exists());

    // A build that waits (a child included): stopped while it compiles.
    fs::remove_file(&log).unwrap();
    let pids = dir.path().join("pids");
    let (tgz, sum) = git_tarball(
        dir.path(),
        "9.9.8",
        &format!(
            "\t/bin/sleep 60 & echo $$$$ $$! > '{}'; wait",
            pids.display()
        ),
    );
    let stopper = std::thread::spawn({
        let pids = pids.clone();
        move || {
            for _ in 0..200 {
                if fs::read_to_string(&pids).is_ok_and(|t| t.split_whitespace().count() == 2) {
                    break;
                }
                std::thread::sleep(std::time::Duration::from_millis(50));
            }
            // SAFETY: `raise` takes an integer and touches no memory; the test process handles
            // SIGTERM (the stop it is testing), so this only asks the code under test to stop.
            unsafe { libc::raise(libc::SIGTERM) };
        }
    });
    let error = place_git(&store, &tgz, &sum, "9.9.8").unwrap_err();
    stopper.join().unwrap();
    progress::end();
    assert_eq!(error.to_string(), "install_cancelled");
    let read = progress::read(&fs::read_to_string(&log).unwrap(), None);
    assert_eq!(read["steps"], json!(["verifySum", "build"]));
    let started: Vec<i32> = fs::read_to_string(&pids)
        .unwrap()
        .split_whitespace()
        .map(|p| p.parse().unwrap())
        .collect();
    std::thread::sleep(std::time::Duration::from_millis(300));
    for pid in started {
        assert!(
            crate::core::watch::started(pid).is_none(),
            "{pid} still runs"
        );
    }
    // Only the version installed before stays; no build or stage folder, same record.
    let left: Vec<String> = fs::read_dir(home.join(".local/share/butake-stack/git"))
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    assert_eq!(left, ["9.9.7"]);
    assert_eq!(read_record(&store, "git").unwrap().version, "9.9.7");
    // SAFETY: only tests change these variables, and each one does it holding `HOME` (the shared
    // test turn), so two tests never change them at once. They are Stack's own variables, read by
    // no library; a test on another thread reading the environment at that moment is the remaining
    // risk, and it is limited to the test run.
    unsafe { std::env::remove_var("BUTAKE_DEVTOOLS_HOME") };
}

#[test]
fn every_plan_starts_by_downloading_and_ends_placing() {
    for tool in IDS {
        let steps = plan(tool);
        assert!(steps[0].starts_with("download"), "{tool}");
        assert!(
            ["install", "copyApp", "link"].contains(steps.last().unwrap()),
            "{tool}"
        );
    }
}

#[test]
fn an_altered_git_source_is_not_built() {
    let _guard = HOME.lock().unwrap_or_else(|e| e.into_inner());
    let (dir, store) = sandbox();
    let home = dir.path().join("home");
    let source = dir.path().join("src/git-9.9.9");
    fs::create_dir_all(&source).unwrap();
    fs::write(source.join("version"), "9.9.9\n").unwrap();
    fs::write(source.join("Makefile"), "install:\n\tfalse\n").unwrap();
    let tgz = dir.path().join("git-9.9.9.tar.gz");
    assert!(
        Command::new("/usr/bin/tar")
            .arg("-czf")
            .arg(&tgz)
            .arg("-C")
            .arg(dir.path().join("src"))
            .arg("git-9.9.9")
            .status()
            .unwrap()
            .success()
    );
    // Not the published SHA-256: nothing is unpacked.
    let wrong = "0".repeat(64);
    assert_eq!(
        place_git(&store, &tgz, &wrong, "9.9.9")
            .unwrap_err()
            .to_string(),
        "checksum_mismatch"
    );
    assert!(!home.join(".local/share/butake-stack/git").exists());
    // The right SHA-256 of a tarball that is not that version: refused before building.
    let sum = hash::sha256_file(&tgz).unwrap();
    if apple_developer_dir().is_some() {
        assert_eq!(
            place_git(&store, &tgz, &sum, "9.9.8")
                .unwrap_err()
                .to_string(),
            "unexpected_artifact"
        );
        // A build that fails leaves nothing behind.
        assert_eq!(
            place_git(&store, &tgz, &sum, "9.9.9")
                .unwrap_err()
                .to_string(),
            "build_failed"
        );
        let left: Vec<_> = fs::read_dir(home.join(".local/share/butake-stack/git"))
            .unwrap()
            .collect();
        assert!(left.is_empty());
    }
    assert!(fs::symlink_metadata(home.join(".local/bin/git")).is_err());
    assert!(read_record(&store, "git").is_none());
    // With a temporary home Apple's Git is not looked at.
    assert_eq!(git_status()["installed"], false);
    // SAFETY: only tests change these variables, and each one does it holding `HOME` (the shared
    // test turn), so two tests never change them at once. They are Stack's own variables, read by
    // no library; a test on another thread reading the environment at that moment is the remaining
    // risk, and it is limited to the test run.
    unsafe { std::env::remove_var("BUTAKE_DEVTOOLS_HOME") };
}

#[test]
fn an_altered_or_foreign_artifact_is_not_installed() {
    let _guard = HOME.lock().unwrap_or_else(|e| e.into_inner());
    let (dir, store) = sandbox();
    let home = dir.path().join("home");
    // A binary whose bytes do not match the published SHA-256.
    let fake = dir.path().join("claude");
    fs::write(&fake, "not claude").unwrap();
    let wrong = "0".repeat(64);
    let error = place_claude_code(&store, &fake, &wrong, "2.1.323").unwrap_err();
    assert_eq!(error.to_string(), "checksum_mismatch");
    // The right SHA-256 of something Anthropic did not sign (Apple's own `true`).
    let foreign = dir.path().join("true");
    fs::copy("/usr/bin/true", &foreign).unwrap();
    let sum = hash::sha256_file(&foreign).unwrap();
    let error = place_claude_code(&store, &foreign, &sum, "2.1.323").unwrap_err();
    assert_eq!(error.to_string(), "signature_invalid");
    // A Codex package with the right checksum and a program OpenAI did not sign.
    let pkg = dir.path().join("pkg");
    fs::create_dir_all(pkg.join("bin")).unwrap();
    fs::create_dir_all(pkg.join("codex-path")).unwrap();
    fs::write(
        pkg.join("codex-package.json"),
        json!({"version": "0.1.0", "target": codex_target()}).to_string(),
    )
    .unwrap();
    for program in ["bin/codex", "bin/codex-code-mode-host", "codex-path/rg"] {
        fs::copy("/usr/bin/true", pkg.join(program)).unwrap();
    }
    let tgz = dir.path().join("codex.tar.gz");
    assert!(
        Command::new("/usr/bin/tar")
            .arg("-czf")
            .arg(&tgz)
            .arg("-C")
            .arg(&pkg)
            .arg(".")
            .status()
            .unwrap()
            .success()
    );
    let sum = hash::sha256_file(&tgz).unwrap();
    assert_eq!(
        place_codex(&store, &tgz, &wrong, "0.1.0")
            .unwrap_err()
            .to_string(),
        "checksum_mismatch"
    );
    assert_eq!(
        place_codex(&store, &tgz, &sum, "0.1.0")
            .unwrap_err()
            .to_string(),
        "signature_invalid"
    );
    // A package AWS did not sign, and an app Anthropic did not sign.
    fs::write(dir.path().join("AWSCLIV2.pkg"), "x").unwrap();
    assert_eq!(
        place_aws(&store, &dir.path().join("AWSCLIV2.pkg"), "2.40.2")
            .unwrap_err()
            .to_string(),
        "signature_invalid"
    );
    let app = dir.path().join("app/Claude.app/Contents/MacOS");
    fs::create_dir_all(&app).unwrap();
    fs::copy("/usr/bin/true", app.join("Claude")).unwrap();
    let zip = dir.path().join("Claude.zip");
    assert!(
        Command::new("/usr/bin/ditto")
            .args(["-c", "-k"])
            .arg(dir.path().join("app"))
            .arg(&zip)
            .status()
            .unwrap()
            .success()
    );
    assert_eq!(
        place_app(&store, &CLAUDE_DESKTOP, &zip, "5.11492.2")
            .unwrap_err()
            .to_string(),
        "signature_invalid"
    );
    // An unsigned ChatGPT.app, and the same app validly signed by someone else (ad hoc).
    for folder in ["unsigned", "foreign"] {
        let contents = dir.path().join(folder).join("ChatGPT.app/Contents");
        fs::create_dir_all(contents.join("MacOS")).unwrap();
        fs::copy("/usr/bin/true", contents.join("MacOS/ChatGPT")).unwrap();
        fs::write(contents.join("Info.plist"), format!("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleExecutable</key><string>ChatGPT</string><key>CFBundleIdentifier</key><string>{}</string><key>CFBundleShortVersionString</key><string>26.1111.21308</string></dict></plist>", CHATGPT.bundle)).unwrap();
    }
    assert!(
        Command::new("/usr/bin/codesign")
            .args(["--force", "--deep", "--sign", "-"])
            .arg(dir.path().join("foreign/ChatGPT.app"))
            .status()
            .unwrap()
            .success()
    );
    assert!(
        signature::verify_code(&dir.path().join("foreign/ChatGPT.app"), OPENAI_TEAM, true).is_err()
    );
    for folder in ["unsigned", "foreign"] {
        let zip = dir.path().join(format!("{folder}.zip"));
        assert!(
            Command::new("/usr/bin/ditto")
                .args(["-c", "-k"])
                .arg(dir.path().join(folder))
                .arg(&zip)
                .status()
                .unwrap()
                .success()
        );
        assert_eq!(
            place_app(&store, &CHATGPT, &zip, "26.1111.21308")
                .unwrap_err()
                .to_string(),
            "signature_invalid",
            "{folder}"
        );
    }
    // Nothing was placed and nothing recorded.
    for path in [
        ".local/bin/claude",
        ".local/bin/codex",
        ".local/share/claude",
        ".local/share/aws-cli",
        ".codex/packages/standalone/releases/0.1.0-aarch64-apple-darwin",
        "Applications/Claude.app",
        "Applications/ChatGPT.app",
        "Applications/.ChatGPT.app.butake",
    ] {
        assert!(fs::symlink_metadata(home.join(path)).is_err(), "{path}");
    }
    assert!(IDS.iter().all(|id| read_record(&store, id).is_none()));
    // SAFETY: only tests change these variables, and each one does it holding `HOME` (the shared
    // test turn), so two tests never change them at once. They are Stack's own variables, read by
    // no library; a test on another thread reading the environment at that moment is the remaining
    // risk, and it is limited to the test run.
    unsafe { std::env::remove_var("BUTAKE_DEVTOOLS_HOME") };
}

#[test]
fn only_recorded_paths_inside_the_home_are_removed() {
    let _guard = HOME.lock().unwrap_or_else(|e| e.into_inner());
    let (dir, store) = sandbox();
    let home = dir.path().join("home");
    // Without a record (a copy installed some other way) nothing is touched.
    fs::create_dir_all(home.join(".local/bin")).unwrap();
    fs::write(home.join(".local/bin/aws"), "theirs").unwrap();
    assert_eq!(
        remove(&store, "aws").unwrap_err().to_string(),
        "not_managed"
    );
    assert!(home.join(".local/bin/aws").is_file());
    // A record can only name paths inside the home.
    assert!(record(&store, "aws", "2.40.2", vec![PathBuf::from("/etc/hosts")]).is_err());
    let outside = dir.path().join("outside");
    fs::write(&outside, "keep").unwrap();
    fs::write(
        record_file(&store, "aws").unwrap(),
        serde_json::to_vec(&Record {
            version: "1.0".into(),
            paths: vec![home.join("../outside")],
            installed_at: 0,
        })
        .unwrap(),
    )
    .unwrap();
    assert_eq!(
        remove(&store, "aws").unwrap_err().to_string(),
        "unsafe_runtime_path"
    );
    assert!(outside.is_file());
    // What Stack placed goes, and its record; the user's data next to it stays.
    let share = home.join(".local/share/aws-cli");
    fs::create_dir_all(&share).unwrap();
    fs::write(share.join("aws"), "x").unwrap();
    std::os::unix::fs::symlink(share.join("aws"), home.join(".local/bin/aws.link")).unwrap();
    fs::create_dir_all(home.join(".aws")).unwrap();
    record(
        &store,
        "aws",
        "2.40.2",
        vec![home.join(".local/bin/aws.link"), share.clone()],
    )
    .unwrap();
    let mut tools = serde_json::Map::new();
    tools.insert(
        "aws".into(),
        json!({"installed": true, "path": home.join(".local/bin/aws.link")}),
    );
    mark_managed(&store, &mut tools);
    assert_eq!(tools["aws"]["managed"], true);
    remove(&store, "aws").unwrap();
    assert!(!share.exists() && fs::symlink_metadata(home.join(".local/bin/aws.link")).is_err());
    assert!(home.join(".aws").is_dir() && home.join(".local/bin/aws").is_file());
    assert!(read_record(&store, "aws").is_none());
    assert!(remove(&store, "rustup").is_err());
    // SAFETY: only tests change these variables, and each one does it holding `HOME` (the shared
    // test turn), so two tests never change them at once. They are Stack's own variables, read by
    // no library; a test on another thread reading the environment at that moment is the remaining
    // risk, and it is limited to the test run.
    unsafe { std::env::remove_var("BUTAKE_DEVTOOLS_HOME") };
}

/// The real artifacts, when BUTAKE_UTILITY_ARTIFACTS names a folder with them (downloaded by
/// hand from the official sources): each installs into a temporary home and reports its
/// version, and with one byte changed or from another team it is refused.
#[test]
fn real_artifacts_install_and_altered_ones_do_not() {
    let Some(folder) = std::env::var_os("BUTAKE_UTILITY_ARTIFACTS").map(PathBuf::from) else {
        return;
    };
    let _guard = HOME.lock().unwrap_or_else(|e| e.into_inner());
    let (dir, store) = sandbox();
    let altered = |source: &Path| {
        let copy = dir.path().join(format!(
            "altered-{}",
            source.file_name().unwrap().to_string_lossy()
        ));
        let mut bytes = fs::read(source).unwrap();
        let middle = bytes.len() / 2;
        bytes[middle] ^= 0xFF;
        fs::write(&copy, bytes).unwrap();
        copy
    };
    let claude = folder.join("claude");
    if claude.is_file() {
        let version = fs::read_to_string(folder.join("claude.version"))
            .unwrap()
            .trim()
            .to_string();
        let sum = hash::sha256_file(&claude).unwrap();
        let bad = altered(&claude);
        assert_eq!(
            place_claude_code(&store, &bad, &sum, &version)
                .unwrap_err()
                .to_string(),
            "checksum_mismatch"
        );
        let bad_sum = hash::sha256_file(&bad).unwrap();
        assert_eq!(
            place_claude_code(&store, &bad, &bad_sum, &version)
                .unwrap_err()
                .to_string(),
            "signature_invalid"
        );
        place_claude_code(&store, &claude, &sum, &version).unwrap();
        remove(&store, "claude-code").unwrap();
    }
    let codex = folder.join("codex-package.tar.gz");
    if codex.is_file() {
        let version = fs::read_to_string(folder.join("codex.version"))
            .unwrap()
            .trim()
            .to_string();
        let sum = hash::sha256_file(&codex).unwrap();
        assert_eq!(
            place_codex(&store, &altered(&codex), &sum, &version)
                .unwrap_err()
                .to_string(),
            "checksum_mismatch"
        );
        place_codex(&store, &codex, &sum, &version).unwrap();
        // Signed by OpenAI, not by Anthropic: refused as Claude Code.
        let foreign = home()
            .unwrap()
            .join(".codex/packages/standalone/current/bin/codex");
        let foreign_sum = hash::sha256_file(&foreign).unwrap();
        assert_eq!(
            place_claude_code(&store, &foreign, &foreign_sum, "0.1.0")
                .unwrap_err()
                .to_string(),
            "signature_invalid"
        );
        remove(&store, "codex").unwrap();
    }
    let pkg = folder.join("AWSCLIV2.pkg");
    if pkg.is_file() {
        let version = fs::read_to_string(folder.join("aws.version"))
            .unwrap()
            .trim()
            .to_string();
        assert_eq!(
            place_aws(&store, &altered(&pkg), &version)
                .unwrap_err()
                .to_string(),
            "signature_invalid"
        );
        place_aws(&store, &pkg, &version).unwrap();
        remove(&store, "aws").unwrap();
    }
    let zip = folder.join("Claude.zip");
    if zip.is_file() {
        let version = fs::read_to_string(folder.join("desktop.version"))
            .unwrap()
            .trim()
            .to_string();
        assert!(place_app(&store, &CLAUDE_DESKTOP, &altered(&zip), &version).is_err());
        place_app(&store, &CLAUDE_DESKTOP, &zip, &version).unwrap();
        assert!(applications().unwrap().join("Claude.app").is_dir());
        remove(&store, "claude-desktop").unwrap();
    }
    // ChatGPT.zip from its update feed (version in chatgpt.version): an altered copy is refused,
    // as Claude Desktop's app is; the real one is copied, found as Stack's, and removed.
    let zip = folder.join("ChatGPT.zip");
    if zip.is_file() {
        let version = fs::read_to_string(folder.join("chatgpt.version"))
            .unwrap()
            .trim()
            .to_string();
        let refused = place_app(&store, &CHATGPT, &altered(&zip), &version).unwrap_err();
        eprintln!("ChatGPT.zip alterado: {refused}");
        assert_eq!(
            place_app(&store, &CLAUDE_DESKTOP, &zip, &version)
                .unwrap_err()
                .to_string(),
            "unexpected_artifact"
        );
        place_app(&store, &CHATGPT, &zip, &version).unwrap();
        let mut tools = serde_json::Map::new();
        tools.insert("chatgpt".into(), app_status(CHATGPT.name));
        mark_managed(&store, &mut tools);
        assert_eq!(tools["chatgpt"]["version"], version.as_str());
        assert_eq!(tools["chatgpt"]["managed"], true);
        remove(&store, "chatgpt").unwrap();
        assert!(!applications().unwrap().join("ChatGPT.app").exists());
    }
    // Git's source (git-<version>.tar.gz with its SHA-256 from kernel.org in git.sha256): built,
    // reporting its version, cloning over HTTPS with the system's libcurl, and removed.
    let git_sum = folder.join("git.sha256");
    if git_sum.is_file() {
        let version = fs::read_to_string(folder.join("git.version"))
            .unwrap()
            .trim()
            .to_string();
        let tarball = folder.join(format!("git-{version}.tar.gz"));
        let sum = fs::read_to_string(&git_sum).unwrap().trim().to_string();
        assert_eq!(
            place_git(&store, &altered(&tarball), &sum, &version)
                .unwrap_err()
                .to_string(),
            "checksum_mismatch"
        );
        let started = Instant::now();
        place_git(&store, &tarball, &sum, &version).unwrap();
        eprintln!("git {version}: {} s", started.elapsed().as_secs());
        let git = home().unwrap().join(".local/bin/git");
        assert_eq!(reported_version(&git).as_deref(), Some(version.as_str()));
        let mut tools = serde_json::Map::new();
        tools.insert("git".into(), git_status());
        mark_managed(&store, &mut tools);
        assert_eq!(tools["git"]["managed"], true);
        let clone = dir.path().join("clone");
        let mut command = Command::new(&git);
        process::minimal_environment(&mut command, home().unwrap(), "/usr/bin:/bin");
        let status = command
            .args(["clone", "--quiet", "--depth", "1"])
            .arg("https://github.com/octocat/Hello-World.git")
            .arg(&clone)
            .status()
            .unwrap();
        assert!(status.success() && clone.join("README").is_file());
        let mut command = Command::new(&git);
        process::minimal_environment(&mut command, home().unwrap(), "/usr/bin:/bin");
        let helper = command
            .args(["config", "--system", "credential.helper"])
            .output()
            .unwrap();
        assert_eq!(
            String::from_utf8_lossy(&helper.stdout).trim(),
            "osxkeychain"
        );
        remove(&store, "git").unwrap();
        assert!(
            !home()
                .unwrap()
                .join(".local/share/butake-stack/git")
                .exists()
        );
    }
    assert!(
        fs::read_dir(home().unwrap().join(".local/bin"))
            .map(|d| d.count())
            .unwrap_or(0)
            == 0
    );
    // SAFETY: only tests change these variables, and each one does it holding `HOME` (the shared
    // test turn), so two tests never change them at once. They are Stack's own variables, read by
    // no library; a test on another thread reading the environment at that moment is the remaining
    // risk, and it is limited to the test run.
    unsafe { std::env::remove_var("BUTAKE_DEVTOOLS_HOME") };
}
