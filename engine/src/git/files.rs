//! A repository's file read for the viewer, with its guards: inside the repository, never `.git`
//! or a symbolic link, text of 2 MB or less, and the branch and HEAD it was read at.
use super::runner::{Result, error, git};
use serde_json::{Value, json};
use std::path::{Component, Path, PathBuf};

/// Biggest file the viewer reads.
const EDITOR_LIMIT: u64 = 2_000_000;

fn file_path(root: &Path, file: &str) -> Result<PathBuf> {
    let invalid = || error("invalid_path", "Ruta protegida o inválida.");
    if file.is_empty() || Path::new(file).is_absolute() {
        return Err(invalid());
    }
    let mut path = root.to_path_buf();
    for component in Path::new(file).components() {
        match component {
            Component::Normal(name) if !name.eq_ignore_ascii_case(".git") => path.push(name),
            _ => return Err(invalid()),
        }
        if std::fs::symlink_metadata(&path)
            .map_err(|_| invalid())?
            .file_type()
            .is_symlink()
        {
            return Err(error("invalid_path", "No se editan enlaces simbólicos."));
        }
    }
    if !path.is_file()
        || !path
            .canonicalize()
            .map_err(|_| invalid())?
            .starts_with(root)
    {
        return Err(error("invalid_path", "Archivo fuera del repositorio."));
    }
    Ok(path)
}
async fn head(root: &Path) -> String {
    git(root, &["rev-parse", "--verify", "HEAD"])
        .await
        .unwrap_or_default()
        .trim()
        .to_string()
}
fn read(path: &Path) -> Result<String> {
    let size = std::fs::metadata(path)
        .map_err(|_| error("read_failed", "No se pudo leer el archivo."))?
        .len();
    if size > EDITOR_LIMIT {
        return Err(error(
            "large_file",
            "El editor abre archivos de hasta 2 MB: abre este en tu editor de código.",
        ));
    }
    let bytes =
        std::fs::read(path).map_err(|_| error("read_failed", "No se pudo leer el archivo."))?;
    let text = String::from_utf8(bytes).map_err(|failure| {
        if failure.as_bytes().contains(&0) {
            error(
                "binary_file",
                "Este archivo no es texto que el editor pueda abrir: ábrelo en tu editor de código.",
            )
        } else {
            error(
                "file_not_utf8",
                "Este archivo no está en UTF-8 (por ejemplo, Latin-1): el editor no lo abre para no dañarlo. Ábrelo en tu editor de código.",
            )
        }
    })?;
    if text.contains('\0') {
        return Err(error(
            "binary_file",
            "El archivo no es texto (es binario): ábrelo con su aplicación.",
        ));
    }
    Ok(text)
}
async fn branch_name(root: &Path) -> String {
    git(root, &["symbolic-ref", "--quiet", "--short", "HEAD"])
        .await
        .unwrap_or_default()
        .trim()
        .to_string()
}
pub async fn read_file(root: &Path, file: &str) -> Result<Value> {
    let revision = head(root).await;
    let branch = branch_name(root).await;
    let content = read(&file_path(root, file)?)?;
    if revision != head(root).await || branch != branch_name(root).await {
        return Err(error(
            "stale_file",
            "La rama cambió mientras se leía el archivo.",
        ));
    }
    Ok(json!({"content": content, "head": revision, "branch": branch}))
}
