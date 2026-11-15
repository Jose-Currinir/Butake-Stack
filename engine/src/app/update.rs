//! Bundle replacement after the GUI has finished shutting down.
#[cfg(target_os = "macos")]
pub fn replace(mut args: impl Iterator<Item = std::ffi::OsString>) -> anyhow::Result<()> {
    use anyhow::{ensure, Context};
    use std::{
        ffi::CString,
        fs,
        os::unix::ffi::OsStrExt,
        path::PathBuf,
        process::Command,
        thread,
        time::{Duration, Instant},
    };

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
            && unsafe { libc::getppid() } == pid
            && target.extension().is_some_and(|ext| ext == "app"),
        "invalid target"
    );
    ensure!(
        !target.starts_with(&work) && fs::symlink_metadata(&staged)?.file_type().is_dir(),
        "invalid workspace"
    );

    // The helper only deletes entries it created or the old bundle after a successful swap.
    let cleanup = || {
        let _ = fs::remove_dir_all(&staged);
        let _ = fs::remove_file(work.join("Butake-Stack.dmg"));
        let _ = fs::remove_dir(work.join("mount"));
        let _ = fs::remove_dir(&work);
    };

    let deadline = Instant::now() + Duration::from_secs(600);
    while unsafe { libc::getppid() } == pid {
        if Instant::now() >= deadline {
            cleanup();
            return Ok(());
        }
        thread::sleep(Duration::from_millis(200));
    }

    let swap = || -> anyhow::Result<()> {
        let from = CString::new(staged.as_os_str().as_bytes())?;
        let to = CString::new(target.as_os_str().as_bytes())?;
        if unsafe { libc::renamex_np(from.as_ptr(), to.as_ptr(), libc::RENAME_SWAP) } != 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        Ok(())
    };
    let launch = || {
        Command::new("/usr/bin/open")
            .arg(&target)
            .status()
            .is_ok_and(|status| status.success())
    };
    if let Err(error) = swap() {
        launch();
        cleanup();
        return Err(error);
    }
    if !launch() {
        // The old bundle is still available in the private staging folder.
        swap()?;
        launch();
        cleanup();
        anyhow::bail!("relaunch failed");
    }

    let service = format!("gui/{}/cl.butake.stack.daemon", unsafe { libc::geteuid() });
    let signaled = Command::new("/bin/launchctl")
        .args(["kill", "TERM", &service])
        .output()
        .is_ok_and(|output| output.status.success());
    if !signaled {
        let _ = Command::new("/bin/launchctl")
            .args(["kickstart", &service])
            .output();
    }
    cleanup();
    Ok(())
}
