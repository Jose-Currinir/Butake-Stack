use super::*;
use crate::runtimes::utilities::tests::{HOME, sandbox};
use std::{os::unix::fs::PermissionsExt, time::Duration};

fn script(path: &Path, body: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, format!("#!/bin/sh\n{body}\n")).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

/// Asks the install to stop (as the app does) once `file` holds `words` words.
fn stop_when(file: PathBuf, words: usize) -> std::thread::JoinHandle<()> {
    std::thread::spawn(move || {
        for _ in 0..200 {
            if fs::read_to_string(&file).is_ok_and(|t| t.split_whitespace().count() >= words) {
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        // SAFETY: `raise` takes an integer and touches no memory; the test process handles SIGTERM
        // (the stop it is testing), so this only asks the code under test to stop.
        unsafe { libc::raise(libc::SIGTERM) };
    })
}

fn steps(log: &Path) -> Value {
    progress::read(&fs::read_to_string(log).unwrap_or_default(), None)
}

#[test]
fn plans_follow_what_this_mac_already_has() {
    let _guard = HOME.lock().unwrap_or_else(|e| e.into_inner());
    let (dir, _store) = sandbox();
    let home = dir.path().join("home");
    // SAFETY: only tests change these variables, and each one does it holding `HOME` (the shared
    // test turn), so two tests never change them at once. They are Stack's own variables, read by
    // no library; a test on another thread reading the environment at that moment is the remaining
    // risk, and it is limited to the test run.
    unsafe { std::env::set_var("ANDROID_HOME", home.join("sdk")) };
    assert_eq!(plan("rustup"), ["download", "verifySum", "runInstaller"]);
    assert_eq!(
        plan("android-sdk")[..3],
        ["download", "verifySum", "install"]
    );
    script(&home.join(".cargo/bin/rustup"), "true");
    script(
        &home.join("sdk/cmdline-tools/latest/bin/sdkmanager"),
        "true",
    );
    assert_eq!(plan("rustup"), ["updateToolchain"]);
    assert_eq!(plan("android-sdk"), ["licenses", "platformTools"]);
    assert_eq!(plan("wrangler"), ["npmPackage", "link"]);
    for tool in TOOLS.iter().chain(utilities::IDS.iter()) {
        assert!(known(tool) && !plan(tool).is_empty(), "{tool}");
    }
    assert!(!known("brew"));
    // SAFETY: only tests change these variables, and each one does it holding `HOME` (the shared
    // test turn), so two tests never change them at once. They are Stack's own variables, read by
    // no library; a test on another thread reading the environment at that moment is the remaining
    // risk, and it is limited to the test run.
    unsafe { std::env::remove_var("ANDROID_HOME") };
    // SAFETY: only tests change these variables, and each one does it holding `HOME` (the shared
    // test turn), so two tests never change them at once. They are Stack's own variables, read by
    // no library; a test on another thread reading the environment at that moment is the remaining
    // risk, and it is limited to the test run.
    unsafe { std::env::remove_var("BUTAKE_DEVTOOLS_HOME") };
}

/// rustup's own update and a toolchain install run to the end although the app asked to stop
/// (cutting them would leave ~/.rustup half done); they report one fixed step and their output.
#[test]
fn an_official_installer_is_followed_but_not_cut() {
    let _guard = HOME.lock().unwrap_or_else(|e| e.into_inner());
    let (dir, store) = sandbox();
    let home = dir.path().join("home");
    script(
        &home.join(".cargo/bin/rustup"),
        "case \"$1\" in\n  toolchain) [ \"$2\" = list ] && { echo 'stable-aarch64-apple-darwin (default)'; exit 0; } ;;\nesac\necho \"$@\" >> \"$HOME/rustup-args\"\n/bin/sleep 1\necho listo \"$1\"",
    );
    let stopper = stop_when(home.join("rustup-args"), 2);
    let answer = install(
        &store,
        &Options {
            tool: "rustup".into(),
            version: String::new(),
            shell_path: false,
            accept_licenses: false,
        },
    );
    stopper.join().unwrap();
    progress::end();
    answer.unwrap();
    let log = store.directory("logs").unwrap().join("devtool-rustup.log");
    let read = steps(&log);
    assert_eq!(read["steps"], json!(["updateToolchain"]));
    assert_eq!(read["fixed"], true);
    assert!(read["lines"].to_string().contains("listo update"));

    let log = dir.path().join("toolchain.log");
    progress::begin(&log);
    let stopper = stop_when(home.join("rustup-args"), 5);
    let answer = crate::runtimes::languages::toolchains::rust_action("install", "beta");
    stopper.join().unwrap();
    progress::end();
    assert_eq!(answer.unwrap()[0]["default"], true);
    assert_eq!(steps(&log)["steps"], json!(["toolchain"]));
    assert!(
        fs::read_to_string(home.join("rustup-args"))
            .unwrap()
            .contains("toolchain install beta")
    );
    // SAFETY: only tests change these variables, and each one does it holding `HOME` (the shared
    // test turn), so two tests never change them at once. They are Stack's own variables, read by
    // no library; a test on another thread reading the environment at that moment is the remaining
    // risk, and it is limited to the test run.
    unsafe { std::env::remove_var("BUTAKE_DEVTOOLS_HOME") };
}

/// Wrangler goes to a folder beside the one in use: a finished install takes its place, and
/// «Cancelar» while npm works ends npm and what it started and leaves the installed one as it was.
#[test]
fn wrangler_replaces_its_folder_only_when_npm_finished() {
    let _guard = HOME.lock().unwrap_or_else(|e| e.into_inner());
    let (dir, store) = sandbox();
    let home = dir.path().join("home");
    // The terminal already has a node: the install does not link one.
    script(&home.join(".local/bin/node"), "true");
    let node = dir.path().join("node/bin");
    script(
        &node.join("npm"),
        "p=\"$7\"\nprintf '%s\\n' \"$@\" > \"$HOME/npm-args\"\nmkdir -p \"$p/lib/node_modules/wrangler/bin\" \"$p/bin\"\necho 1 > \"$p/lib/node_modules/wrangler/version\"\nprintf '#!/bin/sh\\n' > \"$p/lib/node_modules/wrangler/bin/wrangler.js\"\nln -s ../lib/node_modules/wrangler/bin/wrangler.js \"$p/bin/wrangler\"",
    );
    let log = store
        .directory("logs")
        .unwrap()
        .join("devtool-wrangler.log");
    progress::begin(&log);
    install_wrangler(&store, &node).unwrap();
    assert_eq!(steps(&log)["steps"], json!(["npmPackage", "link"]));
    // A fixed release, and no install scripts of the package or its dependencies.
    let args = fs::read_to_string(home.join("npm-args")).unwrap();
    assert!(args.lines().any(|a| a == "--ignore-scripts"));
    assert!(
        args.lines()
            .any(|a| a == format!("wrangler@{}", install::WRANGLER_VERSION))
    );
    let share = home.join(".local/share/butake-stack");
    let target = fs::canonicalize(home.join(".local/bin/wrangler")).unwrap();
    assert_eq!(
        target,
        fs::canonicalize(share.join("npm/lib/node_modules/wrangler/bin/wrangler.js")).unwrap()
    );

    // An update stopped while npm works (a child of its own included).
    fs::remove_file(&log).unwrap();
    script(
        &node.join("npm"),
        "mkdir -p \"$7/lib/node_modules/wrangler\"\n/bin/sleep 60 & echo $$ $! > \"$HOME/npm-pids\"; wait",
    );
    let stopper = stop_when(home.join("npm-pids"), 2);
    let error = install_wrangler(&store, &node).unwrap_err();
    stopper.join().unwrap();
    progress::end();
    assert_eq!(error.to_string(), "install_cancelled");
    assert_eq!(steps(&log)["steps"], json!(["npmPackage"]));
    std::thread::sleep(Duration::from_millis(300));
    for pid in fs::read_to_string(home.join("npm-pids"))
        .unwrap()
        .split_whitespace()
    {
        let pid: i32 = pid.parse().unwrap();
        assert!(
            crate::core::watch::started(pid).is_none(),
            "{pid} still runs"
        );
    }
    let left: Vec<String> = fs::read_dir(&share)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    assert_eq!(left, ["npm"]);
    assert_eq!(
        fs::read_to_string(share.join("npm/lib/node_modules/wrangler/version")).unwrap(),
        "1\n"
    );
    // SAFETY: only tests change these variables, and each one does it holding `HOME` (the shared
    // test turn), so two tests never change them at once. They are Stack's own variables, read by
    // no library; a test on another thread reading the environment at that moment is the remaining
    // risk, and it is limited to the test run.
    unsafe { std::env::remove_var("BUTAKE_DEVTOOLS_HOME") };
}

#[test]
fn a_source_that_does_not_answer_keeps_what_it_said_before() {
    let now = json!({"gh": "2.80.0", "unavailable": {"codex": "source_rate_limited:12", "uv": "download_offline"}});
    let before = json!({"gh": "2.79.0", "codex": "0.58.0", "unavailable": {}});
    let merged = keep_known(now.clone(), Some((before, 1_700_000_000)));
    assert_eq!(merged["gh"], "2.80.0");
    assert_eq!(merged["codex"], "0.58.0");
    assert_eq!(merged["known"]["codex"], 1_700_000_000);
    assert!(merged.get("uv").is_none() && merged["known"].get("uv").is_none());
    assert_eq!(merged["unavailable"]["codex"], "source_rate_limited:12");
    assert_eq!(keep_known(now.clone(), None), now);
}

#[test]
fn finds_listed_checksums_in_both_formats() {
    let sums = "abc  other.zip\n0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  gh_2.0_macOS_arm64.zip\n";
    assert_eq!(
        listed_hash(sums, "gh_2.0_macOS_arm64.zip").unwrap(),
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    );
    let body = "SHA256 Checksums:\n```\ncloudflared-darwin-arm64.tgz: FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210\n```";
    assert_eq!(
        listed_hash(body, "cloudflared-darwin-arm64.tgz").unwrap(),
        "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
    );
    assert!(listed_hash(body, "missing.tgz").is_err());
}

/// A link inside an extracted archive is never taken for the program, nor walked into.
#[test]
fn find_file_ignores_links() {
    let temp = tempfile::tempdir().unwrap();
    let outside = temp.path().join("fuera");
    fs::create_dir_all(&outside).unwrap();
    fs::write(outside.join("uv"), "x").unwrap();
    let tree = temp.path().join("tree");
    fs::create_dir_all(&tree).unwrap();
    std::os::unix::fs::symlink(outside.join("uv"), tree.join("uv")).unwrap();
    std::os::unix::fs::symlink(&outside, tree.join("carpeta")).unwrap();
    assert!(find_file(&tree, "uv").is_none());
    fs::create_dir_all(tree.join("real")).unwrap();
    fs::write(tree.join("real/uv"), "x").unwrap();
    assert_eq!(find_file(&tree, "uv"), Some(tree.join("real/uv")));
}

/// Wrangler is installed from a fixed release, never `latest`.
#[test]
fn wrangler_version_is_fixed() {
    assert!(
        install::WRANGLER_VERSION.split('.').count() == 3 && install::WRANGLER_VERSION != "latest"
    );
}
