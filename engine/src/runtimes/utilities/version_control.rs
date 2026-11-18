//! Git: the official source, verified and compiled with Apple's compiler into the user's home.

use super::*;

/// The newest release in kernel.org's checksum list and its SHA-256: lines "<hex>  git-X.Y.Z.tar.gz";
/// release candidates, documentation and the rest of the files are skipped.
pub(super) fn git_release(sums: &str) -> Result<(String, String)> {
    let mut best: Option<(String, String)> = None;
    for line in sums.lines() {
        let [hash, name] = line.split_whitespace().collect::<Vec<_>>()[..] else {
            continue;
        };
        let Some(version) = name
            .strip_prefix("git-")
            .and_then(|n| n.strip_suffix(".tar.gz"))
        else {
            continue;
        };
        if version.split('.').count() != 3
            || !valid_version(version)
            || hash.len() != 64
            || !hash.bytes().all(|c| c.is_ascii_hexdigit())
        {
            continue;
        }
        if best
            .as_ref()
            .is_none_or(|(newest, _)| devtools::newer(version, newest))
        {
            best = Some((version.to_string(), hash.to_lowercase()));
        }
    }
    best.context("checksum_not_found")
}

/// The official source of the newest Git release, checked against the SHA-256 kernel.org lists
/// for it, built with Apple's compiler. Without Apple's developer tools, or with Xcode's license pending, nothing is downloaded.
pub(super) fn install_git(store: &Store, dir: &Path) -> Result<Value> {
    ensure_apple_toolchain()?;
    progress::step("downloadSource");
    let (version, sha256) = git_release(&fetch_text(
        &format!("{GIT_BASE}/sha256sums.asc"),
        2_000_000,
    )?)?;
    let tarball = dir.join(format!("git-{version}.tar.gz"));
    devtools::log(store, "git", &format!("descargando git-{version}.tar.gz"));
    download::download_verified(
        &format!("{GIT_BASE}/git-{version}.tar.gz"),
        &tarball,
        &sha256,
    )?;
    place_git(store, &tarball, &sha256, &version)
}

/// `make install` of the unpacked source for `prefix`, into `destdir`, with a clean environment
/// and its output in the utility's log.
pub(super) fn build_git(store: &Store, source: &Path, prefix: &Path, destdir: &Path) -> Result<()> {
    let jobs = std::thread::available_parallelism()
        .map(|n| n.get().min(8))
        .unwrap_or(4);
    let log = process::append_log(&store.directory("logs")?.join("devtool-git.log"))?;
    let mut make = Command::new("/usr/bin/make");
    process::minimal_environment(&mut make, home()?, "/usr/bin:/bin:/usr/sbin:/sbin");
    make.current_dir(source)
        .arg(format!("-j{jobs}"))
        .arg(format!("prefix={}", prefix.display()))
        .arg(format!("DESTDIR={}", destdir.display()))
        .args(GIT_MAKE)
        .args(["install", "install-git-credential-osxkeychain"])
        .stdin(Stdio::null())
        .stdout(log.try_clone()?)
        .stderr(log);
    // In its own process group: «Cancelar» ends make and every compiler it started.
    let status = progress::run(&mut make, || {})?;
    ensure!(status.success(), "build_failed");
    Ok(())
}

/// Checks the tarball's SHA-256, builds it and places it in `~/.local/share/butake-stack/git/
/// <version>` (Stack's folder for what it builds in the home; Git's Makefile does not take paths
/// with spaces, like Application Support), with `git` linked in `~/.local/bin`. Its own system
/// configuration (`etc/gitconfig`, inside that folder) keeps passwords in the Keychain, as Apple's
/// Git does; the user's `~/.gitconfig` is never touched. Older versions Stack built go.
pub(super) fn place_git(
    store: &Store,
    tarball: &Path,
    sha256: &str,
    version: &str,
) -> Result<Value> {
    progress::step("verifySum");
    ensure!(
        hash::sha256_file(tarball)?.eq_ignore_ascii_case(sha256),
        "checksum_mismatch"
    );
    devtools::log(
        store,
        "git",
        &format!("SHA-256 verificado ({sha256}), el que publica kernel.org"),
    );
    ensure_apple_toolchain()?;
    let home = home()?;
    let root = home.join(".local/share/butake-stack/git");
    ensure!(
        !root.to_string_lossy().chars().any(char::is_whitespace),
        "unsafe_runtime_path"
    );
    fs::create_dir_all(&root)?;
    let build = root.join(format!(".build-{version}-{}", std::process::id()));
    let stage = root.join(format!(".{version}.butake"));
    let _ = fs::remove_dir_all(&build);
    let _ = fs::remove_dir_all(&stage);
    let result = (|| -> Result<Value> {
        fs::create_dir_all(&build)?;
        archive::extract_tar_gz(tarball, &build, true, "extract_failed")?;
        archive::check_tree(&build, archive::Links::Inside)?;
        ensure!(
            build.join("Makefile").is_file()
                && fs::read_to_string(build.join("version"))?.trim() == version,
            "unexpected_artifact"
        );
        let target = root.join(version);
        let started = Instant::now();
        progress::step("build");
        build_git(store, &build, &target, &stage)?;
        devtools::log(
            store,
            "git",
            &format!("compilado e instalado en {} s", started.elapsed().as_secs()),
        );
        let built = stage.join(target.strip_prefix("/")?);
        check_reported(&built.join("bin/git"), version)?;
        progress::check()?;
        progress::fixed_step("install");
        fs::create_dir_all(built.join("etc"))?;
        fs::write(
            built.join("etc/gitconfig"),
            "[credential]\n\thelper = osxkeychain\n",
        )?;
        if fs::symlink_metadata(&target).is_ok() {
            fs::remove_dir_all(&target)?;
        }
        fs::rename(&built, &target)?;
        for entry in fs::read_dir(&root)?.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name != version && valid_version(&name) && entry.file_type()?.is_dir() {
                fs::remove_dir_all(entry.path())?;
            }
        }
        progress::fixed_step("link");
        let bin = home.join(".local/bin");
        fs::create_dir_all(&bin)?;
        let git = bin.join("git");
        crate::runtimes::languages::toolchains::replace_link(&target.join("bin/git"), &git)?;
        check_reported(&git, version)?;
        record(store, "git", version, vec![git.clone(), root.clone()])?;
        Ok(json!({"version": version, "path": git}))
    })();
    let _ = fs::remove_dir_all(&build);
    let _ = fs::remove_dir_all(&stage);
    result
}
