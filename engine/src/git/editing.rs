//! Staging one block of a file and resolving conflicts, both checked against what the app showed.
use super::actions::{execute, Action};
use super::diff::diff_bytes;
use super::runner::{error, git, git_input, git_lossy, GitError, Result};
use super::status::validate_path;
use serde::Serialize;
use std::path::Path;

/// Biggest resolution saved from the conflict assistant.
const RESOLUTION_LIMIT: usize = 8_000_000;

fn stale_hunk() -> GitError {
    error(
        "invalid_hunk",
        "Ese bloque cambió o no se puede incluir por separado. Vuelve a abrir el archivo e inténtalo otra vez.",
    )
}
/// Header plus the `index`-th hunk of a single-file patch, byte for byte (the patch may not be
/// UTF-8). `expected` is the hunk's `@@ … @@` line as the UI showed it: a different one means the
/// file changed since.
pub fn select_hunk_bytes(
    diff: &[u8],
    index: usize,
    expected: Option<&str>,
) -> Result<(Vec<u8>, Vec<u8>)> {
    let mut header = Vec::new();
    let mut hunks: Vec<Vec<u8>> = Vec::new();
    for line in diff.split_inclusive(|byte| *byte == b'\n') {
        if line.starts_with(b"@@ ") {
            hunks.push(line.to_vec());
        } else if let Some(hunk) = hunks.last_mut() {
            hunk.extend_from_slice(line);
        } else {
            header.extend_from_slice(line);
        }
    }
    let selected = hunks.into_iter().nth(index).ok_or_else(stale_hunk)?;
    if let Some(expected) = expected.map(str::trim).filter(|e| !e.is_empty()) {
        let first = selected.split(|byte| *byte == b'\n').next().unwrap_or(&[]);
        let first = String::from_utf8_lossy(first);
        // Compare the ranges only: the text after the second `@@` is context that display code may trim.
        let ranges = |line: &str| line.split("@@").nth(1).map(|r| r.trim().to_string());
        if ranges(first.trim_end_matches('\r')) != ranges(expected) {
            return Err(stale_hunk());
        }
    }
    Ok((header, selected))
}
async fn apply(root: &Path, patch: &[u8], reverse: bool, check: bool) -> Result<()> {
    // --whitespace=nowarn: `apply.whitespace=fix` must not rewrite what the user chose to stage.
    let mut args = vec!["apply", "--cached", "--whitespace=nowarn", "-p1"];
    if reverse {
        args.push("--reverse");
    }
    if check {
        args.push("--check");
    }
    args.push("-");
    git_input(root, &args, patch).await.map(|_| ())
}
pub async fn stage_hunk(
    root: &Path,
    file: &str,
    staged: bool,
    index: usize,
    expected: Option<&str>,
) -> Result<()> {
    let diff = diff_bytes(root, file, staged).await?;
    let (mut header, hunk) = select_hunk_bytes(&diff, index, expected)?;
    if header.windows(13).any(|w| w == b"\nrename from ") {
        // A staged rename: reversing its header with one hunk would undo the whole move. The hunk
        // is applied as a plain edit of the new path instead, so only that block leaves the index.
        if file
            .chars()
            .any(|c| !c.is_ascii() || c.is_control() || c == '"' || c == '\\')
        {
            return Err(stale_hunk());
        }
        header = format!("diff --git a/{file} b/{file}\n--- a/{file}\n+++ b/{file}\n").into_bytes();
    }
    header.extend_from_slice(&hunk);
    apply(root, &header, staged, true).await?;
    apply(root, &header, staged, false).await
}
#[derive(Debug, Serialize)]
pub struct ConflictVersions {
    pub base: String,
    pub ours: String,
    pub theirs: String,
    pub working: String,
}
fn checked_path(root: &Path, path: &str) -> Result<std::path::PathBuf> {
    validate_path(path)?;
    let outside = || {
        error(
            "invalid_path",
            "La resolución debe quedar dentro del repositorio.",
        )
    };
    let full = root.join(path).canonicalize().map_err(|_| outside())?;
    if !full.starts_with(root) || !full.is_file() {
        return Err(outside());
    }
    Ok(full)
}
async fn assert_conflict(root: &Path, file: &str) -> Result<()> {
    validate_path(file)?;
    let entries = git(root, &["ls-files", "--unmerged", "-z", "--", file]).await?;
    if entries.is_empty() {
        return Err(error(
            "stale_conflict",
            "El archivo ya no tiene un conflicto registrado en el índice.",
        ));
    }
    Ok(())
}
pub async fn conflict(root: &Path, file: &str) -> Result<ConflictVersions> {
    assert_conflict(root, file).await?;
    let full = checked_path(root, file)?;
    let mut versions = Vec::new();
    for stage in [1, 2, 3] {
        let spec = format!(":{stage}:{file}");
        // A side that does not exist (added on one branch only) reads as empty; other encodings are shown lossy.
        versions.push(git_lossy(root, &["show", &spec]).await.unwrap_or_default());
    }
    let working = std::fs::read(full)
        .map_err(|_| error("read_failed", "No se pudo leer el archivo."))
        .and_then(|bytes| {
            String::from_utf8(bytes).map_err(|failure| {
                if failure.as_bytes().contains(&0) {
                    error(
                        "binary_conflict",
                        "Este archivo requiere un resolvedor externo compatible con su formato.",
                    )
                } else {
                    error(
                        "file_not_utf8",
                        "Este archivo no está en UTF-8: resuelve el conflicto en tu editor de código.",
                    )
                }
            })
        })?;
    Ok(ConflictVersions {
        base: versions.remove(0),
        ours: versions.remove(0),
        theirs: versions.remove(0),
        working,
    })
}
pub async fn resolve(root: &Path, file: &str, content: &str, expected: &str) -> Result<()> {
    assert_conflict(root, file).await?;
    let full = checked_path(root, file)?;
    if content.len() > RESOLUTION_LIMIT {
        return Err(error(
            "invalid_content",
            "El resultado es demasiado grande para guardarlo desde aquí.",
        ));
    }
    // A line of `=======` alone is legitimate content (Markdown/RST headings): only the opening and
    // closing markers prove an unresolved conflict.
    if content
        .lines()
        .any(|line| line.starts_with("<<<<<<< ") || line.starts_with(">>>>>>> "))
    {
        return Err(error(
            "conflict_markers",
            "Todavía hay marcadores de conflicto en el resultado.",
        ));
    }
    let failed = || error("write_failed", "No se pudo guardar el archivo.");
    if std::fs::read_to_string(&full).map_err(|_| failed())? != expected {
        return Err(error(
            "stale_conflict",
            "El archivo cambió mientras lo editabas. Vuelve a cargar la resolución.",
        ));
    }
    std::fs::write(full, content).map_err(|_| failed())?;
    execute(root, Action::Stage, file, false).await?;
    Ok(())
}
