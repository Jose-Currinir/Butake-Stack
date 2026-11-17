//! Archive extraction and the review of what came out. Every download of the engine that
//! unpacks anything goes through here: system tools with a cleared environment, no ownership
//! from the archive, and a walk over the result before it is trusted.

use anyhow::{ensure, Result};
use std::{fs, path::Path, process::Command};

/// The engine's stdout is its JSON channel: a tool's own output must never reach it.
fn quiet(command: &mut Command) -> &mut Command {
    command
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
}

/// Runs a tool until it ends and tells whether it succeeded. It runs in its own process group,
/// and while the app follows the operation a stop ends it (`install_cancelled`) instead of
/// waiting for a long extraction or copy to finish.
fn succeeds(command: &mut Command) -> Result<bool> {
    Ok(super::progress::run(quiet(command), || {})?.success())
}

/// What the extracted tree may contain.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Links {
    /// No symbolic link at all.
    Forbid,
    /// Only links that stay inside the tree (npm and npx are relative links in the Node tree).
    Inside,
}

/// Extracts a `.tar.gz` into `into`. bsdtar refuses absolute paths and `..` members unless
/// `-P` is given; the owner recorded in the archive is ignored. With `strip`, the single
/// top-level folder of the archive is dropped. `code` is the error reported on failure.
pub fn extract_tar_gz(archive: &Path, into: &Path, strip: bool, code: &'static str) -> Result<()> {
    let mut tar = Command::new("/usr/bin/tar");
    tar.arg("-xzf")
        .arg(archive)
        .arg("-C")
        .arg(into)
        .arg("--no-same-owner");
    if strip {
        tar.args(["--strip-components", "1"]);
    }
    ensure!(succeeds(tar.env_clear())?, code);
    Ok(())
}

/// Extracts a `.zip` into `into` (`unzip` drops absolute paths and `..` members).
pub fn extract_zip(archive: &Path, into: &Path, code: &'static str) -> Result<()> {
    ensure!(
        succeeds(
            Command::new("/usr/bin/unzip")
                .args(["-q", "-o"])
                .arg(archive)
                .arg("-d")
                .arg(into)
                .env_clear()
        )?,
        code
    );
    Ok(())
}

/// Extracts a `.zip` made by macOS (an app bundle with its links, signatures and attributes) into
/// `into` with `ditto`, the tool that made it.
pub fn extract_app_zip(archive: &Path, into: &Path, code: &'static str) -> Result<()> {
    ensure!(
        succeeds(
            Command::new("/usr/bin/ditto")
                .args(["-x", "-k"])
                .arg(archive)
                .arg(into)
                .env_clear()
        )?,
        code
    );
    Ok(())
}

/// Expands an installer package into `into` (which must not exist) with `pkgutil`: its files
/// are unpacked and its scripts are never run.
pub fn expand_pkg(pkg: &Path, into: &Path, code: &'static str) -> Result<()> {
    ensure!(
        succeeds(
            Command::new("/usr/sbin/pkgutil")
                .arg("--expand-full")
                .arg(pkg)
                .arg(into)
                .env_clear()
        )?,
        code
    );
    Ok(())
}

/// Copies a tree (an app bundle, an expanded payload) to `to` with `ditto`, keeping links,
/// signatures and attributes as they are.
pub fn copy_tree(from: &Path, to: &Path, code: &'static str) -> Result<()> {
    ensure!(
        succeeds(Command::new("/usr/bin/ditto").arg(from).arg(to).env_clear())?,
        code
    );
    Ok(())
}

/// Walks an extracted tree and rejects what `links` does not allow.
pub fn check_tree(root: &Path, links: Links) -> Result<()> {
    let base = root.canonicalize()?;
    let mut pending = vec![match links {
        Links::Forbid => root.to_path_buf(),
        Links::Inside => base.clone(),
    }];
    while let Some(dir) = pending.pop() {
        for item in fs::read_dir(&dir)? {
            let item = item?;
            let kind = item.file_type()?;
            if kind.is_symlink() {
                ensure!(links == Links::Inside, "unsafe_package_member");
                let target = item.path().canonicalize()?;
                ensure!(target.starts_with(&base), "unsafe_package_member");
            } else if kind.is_dir() {
                pending.push(item.path());
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(dir: &Path) -> std::path::PathBuf {
        let src = dir.join("pkg/inner");
        fs::create_dir_all(&src).unwrap();
        fs::write(src.join("file"), "x").unwrap();
        let tgz = dir.join("pkg.tar.gz");
        assert!(Command::new("/usr/bin/tar")
            .args(["-czf"])
            .arg(&tgz)
            .arg("-C")
            .arg(dir.join("pkg"))
            .arg("inner")
            .status()
            .unwrap()
            .success());
        tgz
    }

    #[test]
    fn tar_extracts_with_and_without_stripping() {
        let dir = tempfile::tempdir().unwrap();
        let tgz = sample(dir.path());
        let plain = dir.path().join("plain");
        let stripped = dir.path().join("stripped");
        fs::create_dir(&plain).unwrap();
        fs::create_dir(&stripped).unwrap();
        extract_tar_gz(&tgz, &plain, false, "boom").unwrap();
        extract_tar_gz(&tgz, &stripped, true, "boom").unwrap();
        assert!(plain.join("inner/file").is_file());
        assert!(stripped.join("file").is_file());
        let error = extract_tar_gz(&dir.path().join("none.tgz"), &plain, false, "boom");
        assert_eq!(error.unwrap_err().to_string(), "boom");
    }

    #[test]
    fn zip_extracts_and_reports_the_given_code() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("a.txt"), "x").unwrap();
        let zip = dir.path().join("a.zip");
        assert!(Command::new("/usr/bin/zip")
            .arg("-q")
            .arg(&zip)
            .arg("a.txt")
            .current_dir(dir.path())
            .status()
            .unwrap()
            .success());
        let out = dir.path().join("out");
        fs::create_dir(&out).unwrap();
        extract_zip(&zip, &out, "boom").unwrap();
        assert!(out.join("a.txt").is_file());
        assert!(extract_zip(&dir.path().join("none.zip"), &out, "boom").is_err());
    }

    #[test]
    fn app_zips_and_trees_keep_their_links_and_bad_packages_fail() {
        let dir = tempfile::tempdir().unwrap();
        let app = dir.path().join("A.app/Contents");
        fs::create_dir_all(&app).unwrap();
        fs::write(app.join("Info.plist"), "x").unwrap();
        std::os::unix::fs::symlink("Info.plist", app.join("Current")).unwrap();
        let zip = dir.path().join("a.zip");
        assert!(Command::new("/usr/bin/ditto")
            .args(["-c", "-k", "--keepParent"])
            .arg(dir.path().join("A.app"))
            .arg(&zip)
            .status()
            .unwrap()
            .success());
        let out = dir.path().join("out");
        fs::create_dir(&out).unwrap();
        extract_app_zip(&zip, &out, "boom").unwrap();
        assert!(fs::symlink_metadata(out.join("A.app/Contents/Current"))
            .unwrap()
            .file_type()
            .is_symlink());
        copy_tree(&out.join("A.app"), &dir.path().join("B.app"), "boom").unwrap();
        assert!(dir.path().join("B.app/Contents/Info.plist").is_file());
        fs::write(dir.path().join("bad.pkg"), "x").unwrap();
        let error = expand_pkg(&dir.path().join("bad.pkg"), &dir.path().join("x"), "boom");
        assert_eq!(error.unwrap_err().to_string(), "boom");
    }

    #[test]
    fn links_are_reviewed() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("t");
        fs::create_dir_all(root.join("bin")).unwrap();
        fs::write(root.join("bin/real"), "x").unwrap();
        check_tree(&root, Links::Forbid).unwrap();
        std::os::unix::fs::symlink("real", root.join("bin/inside")).unwrap();
        check_tree(&root, Links::Inside).unwrap();
        assert!(check_tree(&root, Links::Forbid).is_err());
        std::os::unix::fs::symlink("/etc", root.join("bin/escape")).unwrap();
        assert!(check_tree(&root, Links::Inside).is_err());
    }
}
