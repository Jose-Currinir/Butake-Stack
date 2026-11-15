//! Watched folders: a folder imported with "Abrir carpeta de proyectos" can stay watched, so new
//! projects that appear in it are offered to the user (never added on their own). Projects the
//! user turned down are remembered and not offered again.
use crate::core::store::Store;
use anyhow::{ensure, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{collections::BTreeSet, path::PathBuf};

const MAX_FOLDERS: usize = 30;
const MAX_IGNORED: usize = 2000;

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Watched {
    pub path: PathBuf,
    #[serde(default)]
    pub ignored: BTreeSet<PathBuf>,
}

pub fn load(store: &Store) -> Result<Vec<Watched>> {
    store.document("watched")
}

fn save(store: &Store, folders: &[Watched]) -> Result<()> {
    ensure!(
        folders.len() <= MAX_FOLDERS && folders.iter().all(|f| f.ignored.len() <= MAX_IGNORED),
        "too_many_watched"
    );
    store.save_document("watched", &folders)
}

/// Starts or stops watching a folder (canonical path; it must exist to be watched).
pub fn set(store: &Store, path: &std::path::Path, watched: bool) -> Result<Vec<Watched>> {
    ensure!(path.is_absolute(), "invalid_path");
    let mut folders = load(store)?;
    if watched {
        let path = path.canonicalize()?;
        ensure!(path.is_dir(), "invalid_path");
        if !folders.iter().any(|f| f.path == path) {
            folders.push(Watched {
                path,
                ignored: BTreeSet::new(),
            });
        }
    } else {
        let canonical = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
        folders.retain(|f| f.path != canonical && f.path != path);
    }
    save(store, &folders)?;
    Ok(folders)
}

/// Remembers projects of a watched folder the user does not want offered again.
pub fn ignore(store: &Store, folder: &std::path::Path, paths: &[PathBuf]) -> Result<()> {
    let mut folders = load(store)?;
    let entry = folders
        .iter_mut()
        .find(|f| f.path == folder)
        .ok_or_else(|| anyhow::anyhow!("not_watched"))?;
    for path in paths {
        ensure!(
            path.is_absolute() && path.starts_with(&entry.path),
            "invalid_path"
        );
        entry.ignored.insert(path.clone());
    }
    save(store, &folders)
}

/// Each watched folder with the projects in it that are neither sites nor turned down. A folder
/// that is not there (a disconnected drive) is reported as missing and left alone.
pub fn scan(store: &Store) -> Result<Vec<Value>> {
    let mut known: BTreeSet<PathBuf> = store.list()?.into_iter().map(|p| p.path).collect();
    known.extend(store.missing()?.into_iter().map(|p| p.path));
    let mut out = vec![];
    for folder in load(store)? {
        if !folder.path.is_dir() {
            out.push(json!({"root": folder.path, "missing": true, "scan": null}));
            continue;
        }
        let mut scan = crate::web::projects::detect::scan(&folder.path)?;
        if let Some(projects) = scan["projects"].as_array_mut() {
            projects.retain(|p| {
                let path = PathBuf::from(p["detection"]["project"]["path"].as_str().unwrap_or(""));
                let path = path.canonicalize().unwrap_or(path);
                !known.contains(&path) && !folder.ignored.contains(&path)
            });
        }
        scan["rootIsProject"] = json!(false);
        out.push(json!({"root": folder.path, "missing": false, "scan": scan}));
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn offers_only_new_projects() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::new(temp.path().join("store")).unwrap();
        let root = temp.path().join("Proyectos");
        for name in ["uno", "dos"] {
            std::fs::create_dir_all(root.join(name)).unwrap();
            std::fs::write(root.join(name).join("index.html"), "<h1>hola</h1>").unwrap();
            std::fs::write(root.join(name).join("package.json"), "{}").unwrap();
        }
        set(&store, &root, true).unwrap();
        set(&store, &root, true).unwrap();
        assert_eq!(load(&store).unwrap().len(), 1);
        let root = root.canonicalize().unwrap();
        let found = scan(&store).unwrap();
        let count = |v: &Vec<Value>| v[0]["scan"]["projects"].as_array().unwrap().len();
        let before = count(&found);
        assert!(before >= 1, "{found:?}");
        let first = PathBuf::from(
            found[0]["scan"]["projects"][0]["detection"]["project"]["path"]
                .as_str()
                .unwrap(),
        );
        ignore(&store, &root, &[first]).unwrap();
        assert_eq!(count(&scan(&store).unwrap()), before - 1);
        assert!(ignore(&store, &root, &[PathBuf::from("/etc")]).is_err());
        set(&store, &root, false).unwrap();
        assert!(scan(&store).unwrap().is_empty());
    }
}
