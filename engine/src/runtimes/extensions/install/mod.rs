//! First level: an extension *installed in the engine*, its files placed in one installed version
//! of the engine (`runtimes/<engine>/<version>/`). What each extension placed is recorded next to
//! the engine's manifest (`butake-extensions.json`), so it can be updated, carried over when the
//! engine is rebuilt and removed without touching anything else.
//!
//! How an extension is built: its verified archives are extracted in a work folder without spaces
//! (`catalog::build_workspace`, P-29), next to a copy of the engine; it is built against that copy
//! and installed into it; what changed in the copy is what the extension brings. Libraries are
//! relinked relative to the engine (`@loader_path`) and signed ad hoc, the work folder's path must
//! not remain in any of them, and only then are the files placed in the engine itself.
mod build;
mod place;

use build::*;
use place::*;

use super::catalog::{self, Archive, Build, Recipe, Role};
use crate::core::{
    archive::{self, Links},
    fsutil::write_private,
    hash, progress,
    store::Store,
    time::now_secs,
};
use crate::runtimes::utilities::catalog as tools;
use anyhow::{anyhow, bail, ensure, Result};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    os::unix::fs::MetadataExt,
    path::{Component, Path, PathBuf},
    process::{Command, Stdio},
};

pub const STATE_FILE: &str = "butake-extensions.json";

/// An installed version of an engine extensions go into.
#[derive(Debug, Clone)]
pub struct Engine {
    pub component: String,
    pub version: String,
    pub root: PathBuf,
}

/// The installed version `version` of `component`; without one, the version the service uses (its
/// wanted version, when it is on) or else the newest installed.
pub fn engine(store: &Store, component: &str, version: Option<&str>) -> Result<Engine> {
    ensure!(component == "postgres", "extension_component_unsupported");
    let installed = tools::installed(store, component)?;
    let wanted = match version.filter(|v| !v.is_empty()) {
        Some(version) => {
            tools::validate_version(version)?;
            installed.iter().find(|m| m.version == version)
        }
        None => {
            let config = store.config()?;
            let wanted = config
                .engines
                .get(component)
                .map(|e| e.version.clone())
                .unwrap_or_default();
            installed
                .iter()
                .find(|m| {
                    wanted.is_empty()
                        || m.version == wanted
                        || m.version.starts_with(&format!("{wanted}."))
                })
                .or_else(|| installed.first())
        }
    }
    .ok_or_else(|| anyhow!("postgres_not_installed"))?;
    Ok(Engine {
        component: component.into(),
        version: wanted.version.clone(),
        root: store
            .directory("runtimes")?
            .join(component)
            .join(&wanted.version),
    })
}

/// Where an installed extension came from.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Origin {
    pub id: String,
    pub version: String,
    pub url: String,
    pub sha256: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Installed {
    pub version: String,
    pub installed_at: u64,
    /// Paths it placed, relative to the engine's folder.
    pub files: Vec<String>,
    pub sources: Vec<Origin>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct State {
    #[serde(default)]
    pub extensions: BTreeMap<String, Installed>,
}

pub fn state(root: &Path) -> State {
    fs::read(root.join(STATE_FILE))
        .ok()
        .and_then(|data| serde_json::from_slice(&data).ok())
        .unwrap_or_default()
}

fn save_state(root: &Path, state: &State) -> Result<()> {
    write_private(
        &root.join(STATE_FILE),
        &serde_json::to_string_pretty(state)?,
    )
}

/// A relative path that stays inside its folder.
fn safe_relative(path: &str) -> bool {
    let path = Path::new(path);
    !path.as_os_str().is_empty() && path.components().all(|c| matches!(c, Component::Normal(_)))
}

/// What a file of a tree is, to tell what a build changed.
#[derive(Debug, PartialEq, Eq)]
enum Entry {
    File(u64, i64, i64),
    Link(PathBuf),
}

fn snapshot(root: &Path) -> Result<BTreeMap<String, Entry>> {
    let mut out = BTreeMap::new();
    let mut pending = vec![root.to_path_buf()];
    while let Some(dir) = pending.pop() {
        for item in fs::read_dir(&dir)? {
            let item = item?;
            let path = item.path();
            let kind = item.file_type()?;
            let rel = path.strip_prefix(root)?.to_string_lossy().into_owned();
            if rel == STATE_FILE || rel == "butake-manifest.json" {
                continue;
            }
            if kind.is_symlink() {
                out.insert(rel, Entry::Link(fs::read_link(&path)?));
            } else if kind.is_dir() {
                pending.push(path);
            } else {
                let meta = item.metadata()?;
                out.insert(
                    rel,
                    Entry::File(meta.len(), meta.mtime(), meta.mtime_nsec()),
                );
            }
        }
    }
    Ok(out)
}

/// Runs one build command in `dir` with the system's tools only (cleared environment, `HOME` in the
/// work folder), its output in the followed operation's log, stoppable by «Cancelar».
fn run(work: &Path, dir: &Path, program: &Path, args: &[String]) -> Result<()> {
    run_with(work, dir, program, args, &[])
}

/// The same, with variables a build reads instead of asking `pkg-config` (which Stack does not use).
fn run_with(
    work: &Path,
    dir: &Path,
    program: &Path,
    args: &[String],
    variables: &[(&str, String)],
) -> Result<()> {
    let tmp = work.join("tmp");
    fs::create_dir_all(&tmp)?;
    let status = progress::run(
        Command::new(program)
            .args(args)
            .current_dir(dir)
            .env_clear()
            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
            .env("HOME", work)
            .env("TMPDIR", &tmp)
            .envs(variables.iter().map(|(k, v)| (*k, v.as_str())))
            .stdin(Stdio::null())
            .stdout(progress::output())
            .stderr(progress::output()),
        || {},
    )?;
    ensure!(status.success(), "build_failed");
    Ok(())
}

fn output(program: &str, args: &[&str]) -> Result<String> {
    let out = Command::new(program)
        .args(args)
        .env_clear()
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()?;
    ensure!(out.status.success(), "build_failed");
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// Where Stack keeps CMake between builds (never in the system): `build-tools/cmake/<version>`.
fn cmake_dir(store: &Store) -> Result<PathBuf> {
    Ok(store
        .directory("build-tools")?
        .join("cmake")
        .join(catalog::CMAKE.version))
}

fn cmake_bin(dir: &Path) -> PathBuf {
    dir.join("CMake.app/Contents/bin/cmake")
}

/// Fetches an archive into `target`: the official origin over HTTPS (tests pass a local one).
pub type Fetch<'a> = &'a dyn Fn(&Archive, &Path) -> Result<()>;

pub fn fetch_official(archive: &Archive, target: &Path) -> Result<()> {
    // A connection that drops halfway is tried again (three times in all); a stop is not.
    let mut attempt = 0;
    loop {
        attempt += 1;
        match crate::core::download::download(archive.url, target) {
            Err(error)
                if attempt < 3
                    && ["download_failed", "download_offline"]
                        .contains(&error.to_string().as_str()) =>
            {
                let _ = fs::remove_file(target);
                progress::check()?;
            }
            other => return other,
        }
    }
}

/// Installs (or updates) `recipe` into `engine`, followed step by step. What it needs is
/// downloaded and checked first; nothing reaches the engine until the build is complete and clean.
pub fn install(
    store: &Store,
    engine: &Engine,
    recipe: &Recipe,
    fetch: Fetch<'_>,
) -> Result<Installed> {
    ensure!(recipe.component == engine.component, "unknown_extension");
    ensure!(recipe.supports(&engine.version), "extension_unsupported");
    crate::runtimes::utilities::ensure_apple_toolchain()?;
    let plan = recipe.plan();
    progress::step(plan[0]);
    let cache = store.directory("cache")?;
    let cmake = cmake_dir(store)?;
    let needs_cmake = recipe
        .dependencies
        .iter()
        .any(|d| d.role == Role::BuildTool)
        && !cmake_bin(&cmake).is_file();
    let archives: Vec<(Option<&'static str>, Archive)> = std::iter::once((None, recipe.archive))
        .chain(
            recipe
                .dependencies
                .iter()
                .filter(|d| d.role == Role::Library || needs_cmake)
                .map(|d| (Some(d.id), d.archive)),
        )
        .collect();
    let paths: Vec<PathBuf> = archives
        .iter()
        .map(|(_, a)| cache.join(format!("ext-{}", a.file)))
        .collect();
    let work = tools::build_workspace(&format!("ext-{}", recipe.id), &engine.version)?;
    let result = (|| -> Result<Installed> {
        for ((_, archive), path) in archives.iter().zip(&paths) {
            let _ = fs::remove_file(path);
            fetch(archive, path)?;
            progress::check()?;
        }
        progress::step(plan[1]);
        for ((_, archive), path) in archives.iter().zip(&paths) {
            ensure!(
                hash::sha256_file(path)? == archive.sha256,
                "checksum_mismatch"
            );
        }
        let src = work.join("src");
        for ((id, archive), path) in archives.iter().zip(&paths) {
            let into = src.join(id.unwrap_or(recipe.id));
            fs::create_dir_all(&into)?;
            archive::extract_tar_gz(path, &into, archive.strip, "package_extract_failed")?;
            archive::check_tree(&into, Links::Inside)?;
        }
        if needs_cmake {
            place_cmake(&src.join("cmake"), &cmake)?;
        }
        let pg = work.join("pg");
        archive::copy_tree(&engine.root, &pg, "package_extract_failed")?;
        let before = snapshot(&pg)?;
        match recipe.build {
            Build::Pgxs => build_pgxs(&work, &src.join(recipe.id), &pg)?,
            Build::Postgis => {
                progress::step("buildDependencies");
                let deps = build_libraries(&work, &src, &cmake_bin(&cmake), recipe)?;
                place_libraries(&deps, &pg)?;
                progress::step("build");
                build_postgis(&work, &src.join(recipe.id), &pg, &deps)?;
            }
        }
        let after = snapshot(&pg)?;
        let current = state(&engine.root);
        let previous = current.extensions.get(recipe.id);
        let mut files = vec![];
        for (rel, entry) in &after {
            if before.get(rel) == Some(entry) {
                continue;
            }
            // A file of the engine (or of another extension) rewritten with the same content is no
            // change; a different one is a conflict, unless it is this extension's own (an update).
            if before.contains_key(rel) && !previous.is_some_and(|p| p.files.contains(rel)) {
                let same = matches!(entry, Entry::File(..))
                    && hash::sha256_file(&pg.join(rel))?
                        == hash::sha256_file(&engine.root.join(rel)).unwrap_or_default();
                ensure!(same, "extension_conflict");
                continue;
            }
            files.push(rel.clone());
        }
        ensure!(!files.is_empty(), "package_incomplete");
        for rel in &files {
            if matches!(after.get(rel), Some(Entry::File(..))) {
                relink(&pg, rel, &work)?;
            }
        }
        progress::check()?;
        progress::fixed_step("install");
        place(&engine.root, &pg, &files, previous, &current)?;
        let installed = Installed {
            version: recipe.version.into(),
            installed_at: now_secs(),
            files,
            sources: archives
                .iter()
                .map(|(id, a)| {
                    let (id, version) = match id {
                        Some(id) => (
                            *id,
                            recipe
                                .dependencies
                                .iter()
                                .find(|d| d.id == *id)
                                .map_or("", |d| d.version),
                        ),
                        None => (recipe.id, recipe.version),
                    };
                    Origin {
                        id: id.into(),
                        version: version.into(),
                        url: a.url.into(),
                        sha256: a.sha256.into(),
                    }
                })
                .collect(),
        };
        let mut next = state(&engine.root);
        next.extensions.insert(recipe.id.into(), installed.clone());
        save_state(&engine.root, &next)?;
        Ok(installed)
    })();
    for path in &paths {
        let _ = fs::remove_file(path);
    }
    let _ = fs::remove_dir_all(&work);
    result
}

/// Files another installed extension also placed (a shared library).
fn owned_by_others<'a>(state: &'a State, this: &Installed) -> BTreeSet<&'a String> {
    state
        .extensions
        .values()
        .filter(|other| *other != this)
        .flat_map(|other| other.files.iter())
        .collect()
}

/// Removes an installed extension's files from the engine. `in_use` are the databases where it is
/// active: while there is one, nothing is removed and the answer says which.
pub fn remove(engine: &Engine, id: &str, in_use: &[String]) -> Result<()> {
    let mut current = state(&engine.root);
    let installed = current
        .extensions
        .get(id)
        .cloned()
        .ok_or_else(|| anyhow!("extension_not_installed"))?;
    if !in_use.is_empty() {
        bail!("extension_in_use:{}", in_use.join(", "));
    }
    let others = owned_by_others(&current, &installed);
    for rel in &installed.files {
        if !others.contains(rel) && safe_relative(rel) {
            let path = engine.root.join(rel);
            if fs::symlink_metadata(&path).is_ok() {
                fs::remove_file(path)?;
            }
        }
    }
    current.extensions.remove(id);
    save_state(&engine.root, &current)
}

/// A rebuilt engine (same version, «Reinstalar con extensiones») keeps the extensions the old copy
/// had: their files and record are copied into the new tree before it takes the old one's place.
pub fn carry(old: &Path, new: &Path) -> Result<()> {
    let current = state(old);
    if current.extensions.is_empty() {
        return Ok(());
    }
    for installed in current.extensions.values() {
        for rel in &installed.files {
            ensure!(safe_relative(rel), "unsafe_package_member");
            let (from, to) = (old.join(rel), new.join(rel));
            if fs::symlink_metadata(&to).is_ok() || fs::symlink_metadata(&from).is_err() {
                continue;
            }
            if let Some(parent) = to.parent() {
                fs::create_dir_all(parent)?;
            }
            if fs::symlink_metadata(&from)?.file_type().is_symlink() {
                std::os::unix::fs::symlink(fs::read_link(&from)?, &to)?;
            } else {
                fs::copy(&from, &to)?;
            }
        }
    }
    save_state(new, &current)
}

/// `CREATE EXTENSION` names a component's engine copy offers, from its control files, and which of
/// them an installed extension placed (`postgis` → `postgis`).
pub fn control_names(root: &Path) -> BTreeMap<String, Option<String>> {
    let placed: BTreeMap<String, String> = state(root)
        .extensions
        .into_iter()
        .flat_map(|(id, installed)| {
            installed
                .files
                .into_iter()
                .map(move |file| (file, id.clone()))
        })
        .collect();
    let Some(dir) = tools::extension_dir(root) else {
        return BTreeMap::new();
    };
    let rel_dir = dir
        .strip_prefix(root)
        .map(Path::to_path_buf)
        .unwrap_or_default();
    fs::read_dir(&dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|item| {
            let file = item.file_name().to_string_lossy().into_owned();
            let name = file.strip_suffix(".control")?.to_string();
            let rel = rel_dir.join(&file).to_string_lossy().into_owned();
            Some((name, placed.get(&rel).cloned()))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn paths_to_the_engines_lib() {
        assert_eq!(up_to_lib("lib/libgeos.dylib"), "");
        assert_eq!(up_to_lib("lib/postgresql/postgis-3.so"), "../");
        assert_eq!(up_to_lib("bin/shp2pgsql"), "../lib/");
        assert!(safe_relative("lib/x.so"));
        for bad in ["", "/etc/passwd", "../x", "lib/../../x"] {
            assert!(!safe_relative(bad), "{bad}");
        }
        assert_eq!(
            normal(Path::new("/a/lib/../lib/x")),
            PathBuf::from("/a/lib/x")
        );
    }
}
