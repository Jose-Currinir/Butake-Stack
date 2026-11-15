//! Installing a piece of the catalog: download, verification, the builds from source (Redis, Valkey, PostgreSQL with its static OpenSSL) and the relocation of the result.

use super::*;

/// Installs `tool` `version`. With `replace`, an installed copy of that version is rebuilt and
/// swapped only once the new one is complete (PostgreSQL «Reinstalar con extensiones»); its data
/// lives elsewhere and is not touched.
pub fn install(store: &Store, tool: &str, version: &str, replace: bool) -> Result<ToolManifest> {
    validate_tool(tool)?;
    validate_version(version)?;
    let root = tool_root(store, tool)?;
    let target = root.join(version);
    ensure!(!target.exists() || replace, "runtime_exists");
    if target.exists() {
        ensure!(
            target.symlink_metadata()?.is_dir() && target.canonicalize()?.starts_with(&root),
            "unsafe_runtime_path"
        );
    }
    let src = source(tool, version);
    let steps = plan(tool);
    progress::step(steps[0]);
    let expected = match &src.verify {
        Verify::Codesign(_) | Verify::HttpsOnly => None,
        Verify::GithubDigest(api) => {
            let release = crate::core::github::api(store, api)?;
            let digest = release["assets"]
                .as_array()
                .and_then(|a| a.iter().find(|x| x["name"] == src.archive.as_str()))
                .and_then(|x| x["digest"].as_str())
                .and_then(|d| d.strip_prefix("sha256:"))
                .ok_or_else(|| anyhow::anyhow!("checksum_missing"))?;
            Some(digest.to_ascii_lowercase())
        }
        _ => {
            let sums = String::from_utf8(fetch(&src.checksum_url, 2_000_000)?)?;
            Some(
                sums.lines()
                    .find_map(|line| {
                        let parts: Vec<&str> = line.split_whitespace().collect();
                        // "HASH  name" (nodejs.org, Caddy) or "hash name sha256 HASH url" (Redis).
                        match parts.as_slice() {
                            ["hash", name, "sha256", hash, ..] if *name == src.archive => {
                                Some(hash.to_ascii_lowercase())
                            }
                            [hash, name, ..] if name.trim_start_matches('*') == src.archive => {
                                Some(hash.to_ascii_lowercase())
                            }
                            _ => None,
                        }
                    })
                    .ok_or_else(|| anyhow::anyhow!("checksum_missing"))?,
            )
        }
    };
    let cache = store.directory("cache")?;
    let archive = cache.join(&src.archive);
    let _ = fs::remove_file(&archive);
    // PostgreSQL also needs OpenSSL's source: downloaded in the same step, checked in the next.
    let openssl = (src.build == Build::Postgres)
        .then(|| cache.join(format!("openssl-{OPENSSL_VERSION}.tar.gz")));
    if let Some(path) = &openssl {
        let _ = fs::remove_file(path);
    }
    let staging = root.join(format!(".install-{version}-{}", std::process::id()));
    let previous = root.join(format!(".previous-{version}-{}", std::process::id()));
    // What is built from source is built in a folder without spaces (see `build_workspace`) and
    // only the result moves to the version folder, wherever Stack's data lives.
    let work = match src.build {
        Build::None => None,
        _ => Some(build_workspace(tool, version)?),
    };
    let result = (|| -> Result<ToolManifest> {
        download(&src.url, &archive)?;
        if let Some(path) = &openssl {
            download(&openssl_url(), path)?;
        }
        progress::step(steps[1]);
        if let Some(path) = &openssl {
            ensure!(
                hash::sha256_file(path)? == OPENSSL_SHA256,
                "checksum_mismatch"
            );
        }
        match src.verify {
            Verify::Sha256 | Verify::GithubDigest(_) => ensure!(
                Some(hash::sha256_file(&archive)?) == expected,
                "checksum_mismatch"
            ),
            Verify::HttpsOnly => {}
            Verify::Sha512 => ensure!(
                Some(hash::sha512_file(&archive)?) == expected,
                "checksum_mismatch"
            ),
            Verify::Codesign(_) => {}
        }
        if staging.exists() {
            fs::remove_dir_all(&staging)?;
        }
        fs::create_dir(&staging)?;
        let tree = work.clone().unwrap_or_else(|| staging.clone());
        let bin = tree.join("bin");
        match src.layout {
            Layout::Binary(name) => {
                fs::create_dir_all(&bin)?;
                fs::copy(&archive, bin.join(name))?;
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(bin.join(name), fs::Permissions::from_mode(0o755))?;
            }
            Layout::ZipIntoBin => {
                fs::create_dir_all(&bin)?;
                archive::extract_zip(&archive, &bin, "package_extract_failed")?;
            }
            Layout::Tar | Layout::TarIntoBin => {
                let into = if src.layout == Layout::TarIntoBin {
                    fs::create_dir_all(&bin)?;
                    bin.clone()
                } else {
                    tree.clone()
                };
                archive::extract_tar_gz(&archive, &into, src.strip, "package_extract_failed")?;
            }
        }
        archive::check_tree(&tree, Links::Inside)?;
        if steps.contains(&"build") {
            progress::step("build");
        }
        match src.build {
            Build::None => {}
            Build::Make(programs) => build_from_source(&tree, programs)?,
            Build::Postgres => {
                let openssl = openssl
                    .as_deref()
                    .ok_or_else(|| anyhow::anyhow!("build_failed"))?;
                let prefix = build_openssl(&tree, openssl)?;
                build_autotools(&tree, &postgres_flags(&prefix)?, &["contrib"])?;
                ensure!(postgres_extensions(&tree), "package_incomplete");
            }
        }
        if tree != staging {
            fs::remove_dir(&staging)?;
            move_tree(&tree, &staging)?;
        }
        if let Verify::Codesign(team) = src.verify {
            for exe in executables(tool) {
                crate::core::signature::verify_code(&staging.join(exe), team, false)?;
            }
        }
        for exe in executables(tool) {
            ensure!(staging.join(exe).exists(), "package_incomplete");
        }
        let manifest = ToolManifest {
            tool: tool.into(),
            version: version.into(),
            url: src.url.clone(),
            checksum_url: src.checksum_url.clone(),
            sha256: hash::sha256_file(&archive)?,
            installed_at: now_secs(),
            openssl: openssl.is_some().then(|| OPENSSL_VERSION.to_string()),
            extensions: None,
        };
        fs::write(
            staging.join("butake-manifest.json"),
            serde_json::to_vec_pretty(&manifest)?,
        )?;
        progress::check()?;
        progress::fixed_step("install");
        if target.exists() {
            // The extensions installed in the old copy go into the new one (P-43)…
            crate::runtimes::extensions::install::carry(&target, &staging)?;
            // …the old copy steps aside, the new one takes its place, and only then is it removed.
            fs::rename(&target, &previous)?;
            if let Err(error) = fs::rename(&staging, &target) {
                let _ = fs::rename(&previous, &target);
                return Err(error.into());
            }
            let _ = fs::remove_dir_all(&previous);
        } else {
            fs::rename(&staging, &target)?;
        }
        Ok(manifest)
    })();
    let _ = fs::remove_file(&archive);
    if let Some(path) = &openssl {
        let _ = fs::remove_file(path);
    }
    if staging.exists() {
        let _ = fs::remove_dir_all(&staging);
    }
    if let Some(work) = &work {
        let _ = fs::remove_dir_all(work);
    }
    result
}

/// Builds Redis in place with the system toolchain and keeps only the binaries and license.
pub(super) fn build_from_source(root: &Path, programs: &[&str]) -> Result<()> {
    let jobs = std::thread::available_parallelism()
        .map(|n| n.get().min(8))
        .unwrap_or(4);
    // Only the programs Stack runs, from `src/`: since Redis 8.10 the top-level make also builds
    // modules (RediSearch, RedisJSON…) that need GNU Make 4, newer than macOS's.
    let status = progress::run(
        Command::new("/usr/bin/make")
            .arg(format!("-j{jobs}"))
            .args(["-C", "src"])
            .args(programs)
            .args(["BUILD_TLS=no", "MALLOC=libc"])
            .current_dir(root)
            .env_clear()
            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
            .stdin(Stdio::null())
            .stdout(progress::output())
            .stderr(progress::output()),
        || {},
    )?;
    ensure!(status.success(), "build_failed");
    let bin = root.join("bin");
    fs::create_dir_all(&bin)?;
    for name in programs {
        fs::rename(root.join("src").join(name), bin.join(name))?;
    }
    for item in fs::read_dir(root)? {
        let item = item?;
        let name = item.file_name();
        if name != "bin" && name != "LICENSE.txt" && name != "README.md" && name != "COPYING" {
            let path = item.path();
            if item.file_type()?.is_dir() {
                fs::remove_dir_all(path)?
            } else {
                fs::remove_file(path)?
            }
        }
    }
    Ok(())
}

/// A new private folder to build `tool` in, outside Stack's data folder: build systems split
/// paths on spaces (PostgreSQL's `--with-includes`/`--with-libraries` take space- or
/// colon-separated lists; Makefiles do too), and the data folder is `Application Support`.
pub(crate) fn build_workspace(tool: &str, version: &str) -> Result<PathBuf> {
    let base = build_base(std::env::var_os("TMPDIR").map(PathBuf::from));
    let dir = base.join(format!(
        "butake-stack-build-{tool}-{version}-{}-{}",
        std::process::id(),
        now_secs()
    ));
    ensure!(no_whitespace(&dir), "unsafe_runtime_path");
    use std::os::unix::fs::DirBuilderExt;
    fs::DirBuilder::new().mode(0o700).create(&dir)?;
    ensure!(
        !dir.symlink_metadata()?.file_type().is_symlink(),
        "unsafe_runtime_path"
    );
    Ok(dir)
}

/// The system's temporary folder when it is absolute and has no spaces; otherwise `/private/tmp`.
pub(super) fn build_base(tmpdir: Option<PathBuf>) -> PathBuf {
    tmpdir
        .and_then(|dir| dir.canonicalize().ok())
        .filter(|dir| dir.is_absolute() && dir.is_dir() && no_whitespace(dir))
        .unwrap_or_else(|| PathBuf::from("/private/tmp"))
}

pub(crate) fn no_whitespace(path: &Path) -> bool {
    !path.to_string_lossy().chars().any(char::is_whitespace)
}

/// The built tree into its place: a rename on the same volume, a copy otherwise.
pub(super) fn move_tree(from: &Path, to: &Path) -> Result<()> {
    if fs::rename(from, to).is_err() {
        archive::copy_tree(from, to, "package_extract_failed")?;
        fs::remove_dir_all(from)?;
    }
    Ok(())
}

/// PostgreSQL's `configure` options with OpenSSL at `openssl` (its static build). The two lists
/// are split on spaces by `configure`, so a path with one is refused instead of breaking it.
pub(super) fn postgres_flags(openssl: &Path) -> Result<Vec<String>> {
    ensure!(no_whitespace(openssl), "unsafe_runtime_path");
    let mut flags: Vec<String> = POSTGRES_FLAGS.iter().map(|f| f.to_string()).collect();
    flags.push(format!(
        "--with-includes={}",
        openssl.join("include").display()
    ));
    flags.push(format!(
        "--with-libraries={}",
        openssl.join("lib").display()
    ));
    Ok(flags)
}

pub(crate) fn build_jobs() -> usize {
    std::thread::available_parallelism()
        .map(|n| n.get().min(8))
        .unwrap_or(4)
}

/// Runs one build command in `dir` with the system toolchain only (no inherited environment), its
/// output in the followed operation's log, stoppable by «Cancelar».
pub(super) fn build_step(dir: &Path, program: &str, args: Vec<String>) -> Result<()> {
    let status = progress::run(
        Command::new(program)
            .args(&args)
            .current_dir(dir)
            .env_clear()
            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
            .stdin(Stdio::null())
            .stdout(progress::output())
            .stderr(progress::output()),
        || {},
    )?;
    ensure!(status.success(), "build_failed");
    Ok(())
}

/// OpenSSL's verified source, built as static libraries only (no programs, no shared libraries, no
/// loadable modules: the legacy provider that `pgcrypto` uses for old ciphers is built in) into
/// `<root>/.openssl`, which goes away with the rest of the build tree. Returns that prefix.
/// Certificates and `openssl.cnf` are looked up in macOS's `/private/etc/ssl`.
pub(super) fn build_openssl(root: &Path, archive: &Path) -> Result<PathBuf> {
    let source = root.join(".openssl-src");
    let prefix = root.join(".openssl");
    fs::create_dir_all(&source)?;
    archive::extract_tar_gz(archive, &source, true, "package_extract_failed")?;
    archive::check_tree(&source, Links::Inside)?;
    build_step(
        &source,
        "/usr/bin/perl",
        vec![
            "Configure".into(),
            "darwin64-arm64-cc".into(),
            "no-shared".into(),
            "no-module".into(),
            "no-tests".into(),
            "no-docs".into(),
            // libpq refuses to link anything that calls `exit` (its build checks it): no exit
            // handler, and nothing that starts OpenSSL's own threads (`pthread_exit`): the thread
            // pool and QUIC, which PostgreSQL does not use.
            "no-atexit".into(),
            "no-thread-pool".into(),
            "no-quic".into(),
            format!("--prefix={}", prefix.display()),
            "--libdir=lib".into(),
            "--openssldir=/private/etc/ssl".into(),
        ],
    )?;
    build_step(
        &source,
        "/usr/bin/make",
        vec![format!("-j{}", build_jobs()), "build_libs".into()],
    )?;
    build_step(&source, "/usr/bin/make", vec!["install_dev".into()])?;
    ensure!(
        prefix.join("lib/libcrypto.a").is_file() && prefix.join("lib/libssl.a").is_file(),
        "build_failed"
    );
    Ok(prefix)
}

/// Where a PostgreSQL tree keeps its extensions' control files (`share/extension`, or
/// `share/postgresql/extension` when the prefix does not name PostgreSQL).
pub(crate) fn extension_dir(root: &Path) -> Option<PathBuf> {
    ["share/extension", "share/postgresql/extension"]
        .iter()
        .map(|dir| root.join(dir))
        .find(|dir| dir.is_dir())
}

/// Every module of [`POSTGRES_EXTENSIONS`] is installed in this PostgreSQL tree.
pub fn postgres_extensions(root: &Path) -> bool {
    extension_dir(root).is_some_and(|dir| {
        POSTGRES_EXTENSIONS
            .iter()
            .all(|name| dir.join(format!("{name}.control")).is_file())
    })
}

/// configure/make/install into `<root>/dist` (also in each of `extra`, such as `contrib`), then
/// keep only the installed tree. PostgreSQL finds its share and lib folders relative to its
/// binaries, so the result is relocatable.
pub(super) fn build_autotools(root: &Path, flags: &[String], extra: &[&str]) -> Result<()> {
    let dist = root.join("dist");
    ensure!(no_whitespace(&dist), "unsafe_runtime_path");
    let jobs = build_jobs();
    let mut configure = vec![
        "configure".to_string(),
        format!("--prefix={}", dist.display()),
    ];
    configure.extend(flags.iter().cloned());
    build_step(root, "/bin/sh", configure)?;
    build_step(root, "/usr/bin/make", vec![format!("-j{jobs}")])?;
    for dir in extra {
        build_step(
            root,
            "/usr/bin/make",
            vec![format!("-j{jobs}"), "-C".into(), dir.to_string()],
        )?;
    }
    build_step(root, "/usr/bin/make", vec!["install".into()])?;
    for dir in extra {
        build_step(
            root,
            "/usr/bin/make",
            vec!["-C".into(), dir.to_string(), "install".into()],
        )?;
    }
    relocate(&dist)?;
    let keep = root.join(".keep");
    fs::rename(&dist, &keep)?;
    for item in fs::read_dir(root)? {
        let item = item?;
        if item.file_name() != ".keep" {
            let path = item.path();
            if item.file_type()?.is_dir() {
                fs::remove_dir_all(path)?
            } else {
                fs::remove_file(path)?
            }
        }
    }
    for item in fs::read_dir(&keep)? {
        let item = item?;
        fs::rename(item.path(), root.join(item.file_name()))?;
    }
    fs::remove_dir(&keep)?;
    Ok(())
}

/// Rewrites absolute library references under `prefix` to `@loader_path` so the tree keeps
/// working after it moves, then re-signs ad hoc (arm64 refuses modified, unsigned Mach-O).
pub(super) fn relocate(prefix: &Path) -> Result<()> {
    let prefix_text = prefix.to_string_lossy().into_owned();
    let mut files = vec![];
    for folder in ["bin", "lib", "lib/postgresql"] {
        if let Ok(entries) = fs::read_dir(prefix.join(folder)) {
            for entry in entries.flatten() {
                let path = entry.path();
                if !entry.file_type().map(|t| t.is_file()).unwrap_or(false) {
                    continue;
                }
                // Static archives are only for linking extensions; a local server never uses them.
                if path.extension().is_some_and(|e| e == "a") {
                    fs::remove_file(&path)?;
                    continue;
                }
                files.push((folder, path));
            }
        }
    }
    for (folder, file) in files {
        let output = Command::new("/usr/bin/otool")
            .arg("-L")
            .arg(&file)
            .env_clear()
            .output()?;
        if !output.status.success() {
            continue; // not a Mach-O file
        }
        let text = String::from_utf8_lossy(&output.stdout).into_owned();
        let mut changed = false;
        for line in text.lines().skip(1) {
            let Some(dep) = line.trim().split(" (").next() else {
                continue;
            };
            let own = file
                .file_name()
                .map(|n| dep.ends_with(&format!("/{}", n.to_string_lossy())))
                .unwrap_or(false);
            if folder == "lib" && own {
                continue; // a library's own id is rewritten with -id below
            }
            if let Some(rest) = dep.strip_prefix(&format!("{prefix_text}/lib/")) {
                let up = match folder {
                    "bin" => "../lib/",
                    "lib" => "",
                    _ => "../",
                };
                let status = Command::new("/usr/bin/install_name_tool")
                    .args(["-change", dep, &format!("@loader_path/{up}{rest}")])
                    .arg(&file)
                    .env_clear()
                    .stderr(Stdio::null())
                    .status()?;
                ensure!(
                    status.success(),
                    "relocate_failed: {} <- {dep}",
                    file.display()
                );
                changed = true;
            }
        }
        if let (true, Some(name)) = (
            folder == "lib" && file.extension().is_some_and(|e| e == "dylib"),
            file.file_name().map(|n| n.to_string_lossy().into_owned()),
        ) {
            let _ = Command::new("/usr/bin/install_name_tool")
                .args(["-id", &format!("@rpath/{name}")])
                .arg(&file)
                .env_clear()
                .stderr(Stdio::null())
                .status()?;
            changed = true;
        }
        if changed {
            let status = Command::new("/usr/bin/codesign")
                .args(["--force", "--sign", "-"])
                .arg(&file)
                .env_clear()
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()?;
            ensure!(status.success(), "resign_failed");
        }
    }
    Ok(())
}
