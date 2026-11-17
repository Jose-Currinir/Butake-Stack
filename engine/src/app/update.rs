//! Bundle replacement after the GUI has finished shutting down.
use std::{
    ffi::CString,
    os::unix::{ffi::OsStrExt, fs::MetadataExt},
    path::Path,
};

/// Developer ID team that signs Stack.
const TEAM: &str = "9MJ82YJXM2";
/// launchd label of the daemon.
const DAEMON_LABEL: &str = "cl.butake.stack.daemon";

/// Arguments of `launchctl` that restart the daemon whether or not it is running. `kickstart -k`
/// kills a running instance and starts it again, so the agent is back even though the daemon
/// leaves with code 0 (`KeepAlive/SuccessfulExit=false` would not restart it after `kill TERM`).
fn restart_daemon_args(uid: u32) -> Vec<String> {
    vec![
        "kickstart".into(),
        "-k".into(),
        format!("gui/{uid}/{DAEMON_LABEL}"),
    ]
}

/// The staging folder was created by the app for this user and nobody else can write to it.
fn work_is_private(meta: &std::fs::Metadata, uid: u32) -> bool {
    meta.is_dir() && meta.uid() == uid && meta.mode() & 0o022 == 0
}

/// Entries the app puts in the staging folder (`UpdateService.swift`); everything else is left.
const STAGED_ENTRIES: [&str; 5] = [
    "Replacement.app",
    "Butake-Stack.dmg",
    "Butake-Stack.zip",
    "unpacked",
    "mount",
];

/// Removes the staging folder the app created: only its known entries, then the folder itself
/// (which stays if something unknown is inside).
fn clean_workspace(work: &Path) {
    for name in STAGED_ENTRIES {
        let path = work.join(name);
        match std::fs::symlink_metadata(&path) {
            Ok(meta) if meta.is_dir() => {
                let _ = std::fs::remove_dir_all(&path);
            }
            Ok(_) => {
                let _ = std::fs::remove_file(&path);
            }
            Err(_) => {}
        }
    }
    let _ = std::fs::remove_dir(work);
}

/// Swaps `staged` and `target` atomically (`renamex_np` with `RENAME_SWAP`).
fn swap_bundles(staged: &Path, target: &Path) -> anyhow::Result<()> {
    let from = CString::new(staged.as_os_str().as_bytes())?;
    let to = CString::new(target.as_os_str().as_bytes())?;
    // SAFETY: `from` and `to` are NUL-terminated `CString`s that stay alive for the whole call and
    // contain no interior NUL; `renamex_np` only reads the two paths.
    if unsafe { libc::renamex_np(from.as_ptr(), to.as_ptr(), libc::RENAME_SWAP) } != 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok(())
}

/// Runs `verify` on the copy about to be placed and swaps only if it passes, so what is checked
/// is what is installed (the app checked it minutes ago, before the helper waited for it to quit).
fn swap_verified(
    staged: &Path,
    target: &Path,
    verify: impl FnOnce(&Path) -> anyhow::Result<()>,
) -> anyhow::Result<()> {
    verify(staged)?;
    swap_bundles(staged, target)
}

/// Same checks as the app (`UpdateService.verifySignature`): Developer ID of Stack's team on the
/// whole bundle, and Gatekeeper assessment for execution.
#[cfg(target_os = "macos")]
fn verify_staged(staged: &Path) -> anyhow::Result<()> {
    use anyhow::ensure;
    use std::process::{Command, Stdio};
    crate::core::signature::verify_code(staged, TEAM, true)?;
    let status = Command::new("/usr/sbin/spctl")
        .args(["--assess", "--type", "execute"])
        .arg(staged)
        .env_clear()
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()?;
    ensure!(status.success(), "signature_invalid");
    Ok(())
}

#[cfg(target_os = "macos")]
pub fn replace(mut args: impl Iterator<Item = std::ffi::OsString>) -> anyhow::Result<()> {
    use anyhow::{ensure, Context};
    use std::{
        fs,
        path::PathBuf,
        process::Command,
        thread,
        time::{Duration, Instant},
    };

    // SAFETY: `geteuid` takes no arguments, cannot fail and touches no memory.
    let uid = unsafe { libc::geteuid() };
    let pid: libc::pid_t = args
        .next()
        .context("missing parent")?
        .to_str()
        .context("invalid parent")?
        .parse()?;
    let target = PathBuf::from(args.next().context("missing target")?).canonicalize()?;
    let work = PathBuf::from(args.next().context("missing workspace")?).canonicalize()?;
    let staged = work.join("Replacement.app");
    ensure!(
        pid > 1
            // SAFETY: `getppid` takes no arguments, cannot fail and touches no memory.
            && unsafe { libc::getppid() } == pid
            && target.extension().is_some_and(|ext| ext == "app"),
        "invalid target"
    );
    ensure!(
        !target.starts_with(&work)
            && work_is_private(&fs::symlink_metadata(&work)?, uid)
            && fs::symlink_metadata(&staged)?.file_type().is_dir(),
        "invalid workspace"
    );

    // The helper only deletes entries the app created in its private folder, or the old bundle
    // after a successful swap.
    let cleanup = || clean_workspace(&work);

    let deadline = Instant::now() + Duration::from_secs(600);
    // SAFETY: `getppid` takes no arguments, cannot fail and touches no memory.
    while unsafe { libc::getppid() } == pid {
        if Instant::now() >= deadline {
            cleanup();
            return Ok(());
        }
        thread::sleep(Duration::from_millis(200));
    }

    let launch = || {
        Command::new("/usr/bin/open")
            .arg(&target)
            .status()
            .is_ok_and(|status| status.success())
    };
    if let Err(error) = swap_verified(&staged, &target, verify_staged) {
        launch();
        cleanup();
        return Err(error);
    }
    if !launch() {
        // The old bundle is still available in the private staging folder.
        swap_bundles(&staged, &target)?;
        launch();
        cleanup();
        anyhow::bail!("relaunch failed");
    }

    // Restart the daemon (it runs the old engine) even if it leaves cleanly.
    let _ = Command::new("/bin/launchctl")
        .args(restart_daemon_args(uid))
        .output();
    cleanup();
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{fs, os::unix::fs::PermissionsExt};

    #[test]
    fn daemon_is_restarted_even_if_it_is_running() {
        assert_eq!(
            restart_daemon_args(501),
            ["kickstart", "-k", "gui/501/cl.butake.stack.daemon"]
        );
    }

    #[test]
    fn workspace_must_be_private_and_ours() {
        let dir = tempfile::tempdir().unwrap();
        let uid = fs::metadata(dir.path()).unwrap().uid();
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let meta = fs::metadata(dir.path()).unwrap();
        assert!(work_is_private(&meta, uid));
        assert!(!work_is_private(&meta, uid + 1));
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o770)).unwrap();
        assert!(!work_is_private(&fs::metadata(dir.path()).unwrap(), uid));
        let file = dir.path().join("file");
        fs::write(&file, "x").unwrap();
        assert!(!work_is_private(&fs::metadata(&file).unwrap(), uid));
    }

    #[test]
    fn cleanup_removes_what_the_app_staged() {
        let dir = tempfile::tempdir().unwrap();
        let work = dir.path().join("work");
        fs::create_dir_all(work.join("unpacked/Inner.app")).unwrap();
        fs::create_dir_all(work.join("Replacement.app/Contents")).unwrap();
        fs::write(work.join("Butake-Stack.zip"), "zip").unwrap();
        clean_workspace(&work);
        assert!(!work.exists());
        // Something the app did not create keeps the folder and is not touched.
        fs::create_dir_all(&work).unwrap();
        fs::write(work.join("Butake-Stack.zip"), "zip").unwrap();
        fs::write(work.join("other.txt"), "mine").unwrap();
        clean_workspace(&work);
        assert!(work.join("other.txt").exists());
        assert!(!work.join("Butake-Stack.zip").exists());
    }

    #[test]
    fn the_copy_is_verified_right_before_the_swap() {
        let dir = tempfile::tempdir().unwrap();
        let (staged, target) = (dir.path().join("New.app"), dir.path().join("Old.app"));
        fs::create_dir(&staged).unwrap();
        fs::create_dir(&target).unwrap();
        fs::write(staged.join("id"), "new").unwrap();
        fs::write(target.join("id"), "old").unwrap();
        // A copy that fails verification is never placed.
        let error = swap_verified(&staged, &target, |_| anyhow::bail!("signature_invalid"));
        assert_eq!(error.unwrap_err().to_string(), "signature_invalid");
        assert_eq!(fs::read_to_string(target.join("id")).unwrap(), "old");
        // One that passes is verified at its own path, then swapped.
        let seen = std::cell::RefCell::new(None);
        swap_verified(&staged, &target, |path| {
            *seen.borrow_mut() = Some(path.to_path_buf());
            Ok(())
        })
        .unwrap();
        assert_eq!(seen.into_inner().as_deref(), Some(staged.as_path()));
        assert_eq!(fs::read_to_string(target.join("id")).unwrap(), "new");
        assert_eq!(fs::read_to_string(staged.join("id")).unwrap(), "old");
    }

    #[test]
    fn an_unsigned_bundle_is_not_accepted_by_the_real_check() {
        let dir = tempfile::tempdir().unwrap();
        let app = dir.path().join("Fake.app");
        fs::create_dir_all(app.join("Contents")).unwrap();
        assert!(verify_staged(&app).is_err());
    }
}
