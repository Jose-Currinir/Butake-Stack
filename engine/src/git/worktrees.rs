//! Other working folders of a repository (`git worktree`): adding one on a branch and taking one
//! out. Git does the work with separate arguments; the folder of a new one must not exist yet, the
//! main working folder is never removed, and a folder with uncommitted changes is never forced out.
use super::actions::validate_branch;
use super::runner::{error, git, Result};
use std::path::{Component, Path, PathBuf};

/// `path\nbranch`: a new working folder at `path` on `branch` (created from the current commit when
/// it does not exist).
pub async fn add(root: &Path, value: &str) -> Result<String> {
    let (path, branch) = value.split_once('\n').ok_or_else(|| {
        error(
            "invalid_arguments",
            "Escribe la carpeta y la rama de la nueva carpeta de trabajo.",
        )
    })?;
    let (path, branch) = (path.trim(), branch.trim());
    let target = new_folder(root, path)?;
    validate_branch(root, branch).await?;
    let exists = git(
        root,
        &[
            "show-ref",
            "--verify",
            "--quiet",
            &format!("refs/heads/{branch}"),
        ],
    )
    .await
    .is_ok();
    let target = target.to_string_lossy().to_string();
    let args: Vec<&str> = if exists {
        vec!["worktree", "add", "--", &target, branch]
    } else {
        vec!["worktree", "add", "-b", branch, "--", &target]
    };
    git(root, &args).await.map_err(|failure| {
        if failure.detail.contains("already checked out")
            || failure.detail.contains("already used by worktree")
        {
            error(
                "branch_in_use",
                format!("La rama {branch} ya está abierta en otra carpeta de trabajo. Elige otra rama o crea una nueva."),
            )
        } else {
            failure
        }
    })
}

/// `path`: takes out a working folder added before. Its branch and commits stay in the repository.
pub async fn remove(root: &Path, value: &str) -> Result<String> {
    let wanted = canonical(Path::new(value.trim()));
    let listed = git(root, &["worktree", "list", "--porcelain"]).await?;
    let folders: Vec<PathBuf> = listed
        .lines()
        .filter_map(|line| line.strip_prefix("worktree "))
        .map(|path| canonical(Path::new(path)))
        .collect();
    // The first one is the main working folder: it is the repository itself.
    if folders.first() == Some(&wanted) || canonical(root) == wanted {
        return Err(error(
            "main_worktree",
            "Esa es la carpeta principal del repositorio: no se quita desde aquí.",
        ));
    }
    let Some(found) = folders.iter().skip(1).find(|folder| **folder == wanted) else {
        return Err(error(
            "invalid_path",
            "Esa carpeta no es una carpeta de trabajo de este repositorio. Actualiza la lista y vuelve a elegirla.",
        ));
    };
    let target = found.to_string_lossy().to_string();
    git(root, &["worktree", "remove", "--", &target])
        .await
        .map_err(|failure| {
            if failure.detail.contains("modified or untracked files") {
                error(
                    "worktree_dirty",
                    "Esa carpeta tiene cambios que no están en un commit. Confírmalos o descártalos en ella y vuelve a intentar.",
                )
            } else if failure.detail.contains("locked") {
                error(
                    "worktree_locked",
                    "Esa carpeta está bloqueada para que nadie la quite. Desbloquéala con Git y vuelve a intentar.",
                )
            } else {
                failure
            }
        })
}

/// A folder that does not exist yet, in a folder that does, outside the repository.
fn new_folder(root: &Path, path: &str) -> Result<PathBuf> {
    let candidate = Path::new(path);
    if !candidate.is_absolute()
        || path.chars().any(char::is_control)
        || candidate
            .components()
            .any(|part| matches!(part, Component::ParentDir | Component::CurDir))
    {
        return Err(error(
            "invalid_path",
            "Elige una carpeta nueva con su ruta completa.",
        ));
    }
    let (Some(parent), Some(name)) = (candidate.parent(), candidate.file_name()) else {
        return Err(error("invalid_path", "Elige una carpeta nueva."));
    };
    let parent = parent.canonicalize().map_err(|_| {
        error(
            "invalid_path",
            "La carpeta donde irá la nueva no existe. Elige otra.",
        )
    })?;
    let target = parent.join(name);
    if std::fs::symlink_metadata(&target).is_ok() {
        return Err(error(
            "path_exists",
            "Ya hay algo con ese nombre en esa carpeta. Elige otro nombre.",
        ));
    }
    if target.starts_with(canonical(root)) {
        return Err(error(
            "invalid_path",
            "La carpeta de trabajo va fuera del repositorio. Elige una carpeta junto a él.",
        ));
    }
    Ok(target)
}

fn canonical(path: &Path) -> PathBuf {
    path.canonicalize().unwrap_or_else(|_| path.to_path_buf())
}
