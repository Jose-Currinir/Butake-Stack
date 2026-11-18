//! Building an extension and its libraries against the engine's copy: PGXS, CMake and configure projects, and PostGIS.

use super::*;

/// CMake's verified tree into `build-tools/cmake/<version>`, whole or not at all.
pub(super) fn place_cmake(extracted: &Path, target: &Path) -> Result<()> {
    ensure!(cmake_bin(extracted).is_file(), "package_incomplete");
    let parent = target
        .parent()
        .ok_or_else(|| anyhow!("unsafe_runtime_path"))?;
    fs::create_dir_all(parent)?;
    let staging = parent.join(format!(".new-{}", std::process::id()));
    let _ = fs::remove_dir_all(&staging);
    archive::copy_tree(extracted, &staging, "package_extract_failed")?;
    if target.exists() {
        fs::remove_dir_all(target)?;
    }
    fs::rename(&staging, target)?;
    Ok(())
}

/// PostgreSQL's extension makefiles, against the engine's copy in the work folder.
pub(super) fn build_pgxs(work: &Path, src: &Path, pg: &Path) -> Result<()> {
    progress::step("build");
    let make = Path::new("/usr/bin/make");
    let config = format!("PG_CONFIG={}", pg.join("bin/pg_config").display());
    run(
        work,
        src,
        make,
        &[
            format!("-j{}", tools::build_jobs()),
            config.clone(),
            "OPTFLAGS=".into(),
        ],
    )?;
    run(
        work,
        src,
        make,
        &[config, "OPTFLAGS=".into(), "install".into()],
    )
}

/// GEOS, PROJ and JSON-C as shared libraries into `<work>/deps`. Their install names are absolute
/// there (so PostGIS's `configure` can run what it links) and are relinked when placed.
pub(super) fn build_libraries(
    work: &Path,
    src: &Path,
    cmake: &Path,
    recipe: &Recipe,
) -> Result<PathBuf> {
    let deps = work.join("deps");
    let sdk = output("/usr/bin/xcrun", &["--show-sdk-path"])?;
    for dependency in recipe
        .dependencies
        .iter()
        .filter(|d| d.role == Role::Library)
    {
        let source = src.join(dependency.id);
        if dependency.builder == catalog::Builder::Configure {
            build_configure(work, &source, &deps)?;
            progress::check()?;
            continue;
        }
        let build = work.join("b").join(dependency.id);
        let mut args = vec![
            "-S".to_string(),
            source.display().to_string(),
            "-B".into(),
            build.display().to_string(),
            "-DCMAKE_BUILD_TYPE=Release".into(),
            format!("-DCMAKE_INSTALL_PREFIX={}", deps.display()),
            "-DCMAKE_INSTALL_LIBDIR=lib".into(),
            format!("-DCMAKE_INSTALL_NAME_DIR={}", deps.join("lib").display()),
            "-DCMAKE_OSX_ARCHITECTURES=arm64".into(),
            format!("-DCMAKE_OSX_SYSROOT={sdk}"),
            "-DBUILD_SHARED_LIBS=ON".into(),
            "-DBUILD_TESTING=OFF".into(),
        ];
        args.extend(
            match dependency.id {
                "geos" => &["-DBUILD_DOCUMENTATION=OFF", "-DBUILD_GEOSOP=OFF"][..],
                "proj" => &[
                    "-DENABLE_TIFF=OFF",
                    "-DENABLE_CURL=OFF",
                    "-DBUILD_APPS=OFF",
                    "-DEXE_SQLITE3=/usr/bin/sqlite3",
                ][..],
                "json-c" => &[
                    "-DBUILD_STATIC_LIBS=OFF",
                    "-DDISABLE_WERROR=ON",
                    "-DBUILD_APPS=OFF",
                ][..],
                _ => &[][..],
            }
            .iter()
            .map(|a| a.to_string()),
        );
        run(work, work, cmake, &args)?;
        run(
            work,
            work,
            cmake,
            &[
                "--build".into(),
                build.display().to_string(),
                "--parallel".into(),
                tools::build_jobs().to_string(),
            ],
        )?;
        run(
            work,
            work,
            cmake,
            &["--install".into(), build.display().to_string()],
        )?;
        progress::check()?;
    }
    Ok(deps)
}

/// A library built the classic way (GMP): shared only, into `deps`.
pub(super) fn build_configure(work: &Path, source: &Path, deps: &Path) -> Result<()> {
    run(
        work,
        source,
        Path::new("/bin/sh"),
        &[
            "configure".into(),
            format!("--prefix={}", deps.display()),
            "--enable-shared".into(),
            "--disable-static".into(),
        ],
    )?;
    let make = Path::new("/usr/bin/make");
    run(work, source, make, &[format!("-j{}", tools::build_jobs())])?;
    run(work, source, make, &["install".into()])
}

/// The libraries' shared files into the engine's `lib/` and PROJ's data into `share/proj`, where
/// PROJ looks next to its own library (`<lib>/../share/proj`).
pub(super) fn place_libraries(deps: &Path, pg: &Path) -> Result<()> {
    for item in fs::read_dir(deps.join("lib"))? {
        let item = item?;
        let name = item.file_name().to_string_lossy().into_owned();
        if !name.ends_with(".dylib") {
            continue;
        }
        let target = pg.join("lib").join(&name);
        if item.file_type()?.is_symlink() {
            let link = fs::read_link(item.path())?;
            ensure!(link.components().count() == 1, "unsafe_package_member");
            std::os::unix::fs::symlink(link, target)?;
        } else {
            fs::copy(item.path(), target)?;
        }
    }
    let proj = deps.join("share/proj");
    if proj.is_dir() {
        archive::copy_tree(&proj, &pg.join("share/proj"), "package_extract_failed")?;
    }
    Ok(())
}

/// PostGIS's own build: no raster (GDAL), no vector tiles (protobuf), no translations.
pub(super) fn build_postgis(work: &Path, src: &Path, pg: &Path, deps: &Path) -> Result<()> {
    let args = vec![
        "configure".to_string(),
        // Everything goes where `pg_config` says, except its manual pages and documents, which
        // would go to the system's `/usr/local`: they stay in the work folder and are left out.
        // (Not `--prefix`: PostGIS would then look for the server's binary there.)
        format!("--mandir={}", work.join("extra/man").display()),
        format!("--docdir={}", work.join("extra/doc").display()),
        format!("--with-pgconfig={}", pg.join("bin/pg_config").display()),
        format!(
            "--with-geosconfig={}",
            deps.join("bin/geos-config").display()
        ),
        format!("--with-projdir={}", deps.display()),
        format!("--with-jsondir={}", deps.display()),
        "--with-xml2config=/usr/bin/xml2-config".into(),
        "--without-protobuf".into(),
        "--without-raster".into(),
        "--without-interrupt-tests".into(),
        "--disable-nls".into(),
    ];
    for arg in &args {
        ensure!(tools::no_whitespace(Path::new(arg)), "unsafe_runtime_path");
    }
    // GMP is looked up with `pkg-config` unless these say where it is.
    let gmp = [
        (
            "GMP_CFLAGS",
            format!("-I{}", deps.join("include").display()),
        ),
        (
            "GMP_LIBS",
            format!("-L{} -lgmp", deps.join("lib").display()),
        ),
    ];
    run_with(work, src, Path::new("/bin/sh"), &args, &gmp)?;
    let make = Path::new("/usr/bin/make");
    run(work, src, make, &[format!("-j{}", tools::build_jobs())])?;
    run(work, src, make, &["install".into()])
}
