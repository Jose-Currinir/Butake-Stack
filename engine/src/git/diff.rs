//! The patch of one changed file, as shown and as `git apply` needs it.
use super::runner::{error, git, git_bytes, git_lossy, Result};
use super::status::{status, validate_path};
use std::path::Path;

/// Biggest untracked file shown whole in the diff view.
const UNTRACKED_PREVIEW_LIMIT: u64 = 1_000_000;

/// Arguments of the patch for one changed file, or `None` when the file is untracked (no patch).
async fn diff_arguments(root: &Path, path: &str, staged: bool) -> Result<Option<Vec<String>>> {
    validate_path(path)?;
    let files = status(root).await?;
    let file = files
        .iter()
        .find(|f| f.path == path)
        .ok_or_else(|| error("stale_file", "Actualiza la selección."))?;
    if file.index == "?" {
        return Ok(None);
    }
    // Explicit prefixes: `diff.noprefix` / `diff.mnemonicPrefix` would make `git apply` strip a path component.
    let mut args: Vec<String> = [
        "diff",
        "--no-ext-diff",
        "--no-textconv",
        "--no-color",
        "--src-prefix=a/",
        "--dst-prefix=b/",
    ]
    .map(String::from)
    .to_vec();
    if staged {
        args.push("--cached".into());
    }
    // A moved file is diffed against its old path so Git reports a rename (and only real edits).
    let original = file.original_path.clone().filter(|_| staged);
    if original.is_some() {
        args.push("-M".into());
    }
    args.extend(["--".to_string(), path.to_string()]);
    args.extend(original);
    Ok(Some(args))
}

/// The patch exactly as Git wrote it (any encoding), for `git apply`. Untracked files have none.
pub async fn diff_bytes(root: &Path, path: &str, staged: bool) -> Result<Vec<u8>> {
    let Some(args) = diff_arguments(root, path, staged).await? else {
        return Err(error(
            "invalid_hunk",
            "Un archivo nuevo se prepara completo, no por bloques.",
        ));
    };
    git_bytes(root, &args.iter().map(String::as_str).collect::<Vec<_>>()).await
}

/// The working-tree file against the last commit. For a file that was staged when created (an IDE
/// adding a copy) and edited afterwards, the unstaged patch alone shows the edits made to the staged
/// copy, as if an existing file had been modified; this one shows what the commit would really bring
/// in: the whole new file.
pub async fn diff_whole(root: &Path, path: &str) -> Result<String> {
    validate_path(path)?;
    let head = git(root, &["rev-parse", "--verify", "--quiet", "HEAD"])
        .await
        .unwrap_or_default();
    // Without commits yet, compare against the empty tree.
    let base = if head.trim().is_empty() {
        git(root, &["hash-object", "-t", "tree", "/dev/null"])
            .await?
            .trim()
            .to_string()
    } else {
        head.trim().to_string()
    };
    git_lossy(
        root,
        &[
            "diff",
            "--no-ext-diff",
            "--no-textconv",
            "--no-color",
            "--no-renames",
            "--src-prefix=a/",
            "--dst-prefix=b/",
            &base,
            "--",
            path,
        ],
    )
    .await
}

pub async fn diff(root: &Path, path: &str, staged: bool) -> Result<String> {
    let Some(args) = diff_arguments(root, path, staged).await? else {
        let outside = || error("invalid_path", "Archivo fuera del repositorio.");
        let full = std::fs::canonicalize(root.join(path)).map_err(|_| outside())?;
        if !full.starts_with(root) || !full.is_file() {
            return Err(outside());
        }
        let metadata = std::fs::metadata(&full).map_err(|_| outside())?;
        if metadata.len() > UNTRACKED_PREVIEW_LIMIT {
            return Ok("[Archivo mayor a 1 MB: vista previa omitida]".into());
        }
        let bytes = std::fs::read(full).map_err(|_| outside())?;
        return Ok(String::from_utf8(bytes).unwrap_or_else(|_| "[Archivo binario]".into()));
    };
    // Content in another encoding (Latin-1…) is shown with replacement characters instead of failing.
    git_lossy(root, &args.iter().map(String::as_str).collect::<Vec<_>>()).await
}
