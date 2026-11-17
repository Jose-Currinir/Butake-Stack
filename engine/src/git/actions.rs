//! Typed actions (stage, commit, pull, push, branches…) with their guards: protected primary
//! branch, confirmations, explicit push destination and validated references.
use super::protection::{main_protected, primary_branch};
use super::remotes::access_failure;
use super::runner::{error, git, git_console, git_env, GitError, Result};
use super::status::{has_conflicts, operation, status, validate_path};
use serde::Deserialize;
use std::path::Path;

#[derive(Deserialize, Debug, Clone, Copy)]
#[serde(rename_all = "snake_case")]
pub enum Action {
    Stage,
    Unstage,
    Commit,
    Fetch,
    Pull,
    Push,
    CreateBranch,
    SwitchBranch,
    Merge,
    Rebase,
    RebaseContinue,
    RebaseAbort,
    Stash,
    StashPop,
    Revert,
    CherryPick,
    Discard,
    PullMerge,
    PullRebase,
    PullAutostash,
    /// `origin/feature/x` → local `feature/x` tracking it.
    TrackBranch,
    DeleteBranch,
    ForceDeleteBranch,
    DeleteRemoteBranch,
    /// `old:new` (':' is not allowed in branch names).
    RenameBranch,
    /// Replaces the last commit with the staged changes and the message in `value`. Only for a
    /// commit that is on no remote branch: changing a published one would need a forced push.
    CommitAmend,
    /// Takes back the last commit and leaves its changes staged (`reset --soft`). Only for a
    /// commit that is on no remote branch and has exactly one parent.
    UndoCommit,
    /// Finishes the operation left halfway (merge, rebase, copy or reversion of commits) once its
    /// conflicts are resolved, keeping Git's own message.
    ContinueOperation,
    /// Cancels the operation left halfway and goes back to the state before it.
    AbortOperation,
    /// `name:commit`: a branch that starts at that commit (the current branch does not change).
    CreateBranchAt,
    /// `name:commit` or `name` (at HEAD): a lightweight tag.
    CreateTag,
    DeleteTag,
    /// `stash@{n}`: puts a saved change back and keeps it in the list.
    StashApply,
    /// `stash@{n}`: deletes a saved change.
    StashDrop,
    /// `name\nurl`.
    AddRemote,
    RemoveRemote,
    /// `name\nemail`, for this repository only.
    SetIdentity,
    /// `name\nemail`, for every repository of this user (global configuration).
    SetGlobalIdentity,
    /// A path of the repository goes to `.gitignore` and leaves the index if it was only added.
    IgnorePath,
    /// `path\nbranch`: another working folder of the repository (`worktree add`) on that branch,
    /// created from the current commit when it does not exist yet. The folder must be new.
    AddWorktree,
    /// `path`: takes out a working folder added before (never the main one). Git refuses while it
    /// has changes that are not in a commit; nothing is forced.
    RemoveWorktree,
}

pub async fn validate_branch(root: &Path, value: &str) -> Result<()> {
    // `@{-1}` and friends pass `check-ref-format --branch` (it expands them) and would name another branch.
    if value.starts_with('-') || value.is_empty() || value == "@" || value.contains("@{") {
        return Err(error(
            "invalid_ref",
            "Nombre inválido: usa letras, números, guiones o barras, sin espacios.",
        ));
    }
    git(root, &["check-ref-format", "--branch", value])
        .await
        .map_err(|_| {
            error(
                "invalid_ref",
                format!("«{value}» no es un nombre de rama válido."),
            )
        })?;
    Ok(())
}

pub async fn validate_commit(root: &Path, value: &str) -> Result<String> {
    if value.is_empty() || !value.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err(error("invalid_ref", "Elige un commit de la lista."));
    }
    Ok(git(
        root,
        &["rev-parse", "--verify", &format!("{value}^{{commit}}")],
    )
    .await?
    .trim()
    .into())
}

pub async fn execute(root: &Path, action: Action, value: &str, confirmed: bool) -> Result<String> {
    use Action::*;
    let branch = git(root, &["symbolic-ref", "--quiet", "--short", "HEAD"])
        .await
        .unwrap_or_default();
    if branch.trim() == primary_branch(root).await
        && main_protected(root).await
        && !matches!(
            action,
            // Fast-forward pulls only move main to the remote state; they never create local commits.
            Fetch
                | Pull
                | PullAutostash
                | TrackBranch
                | DeleteBranch
                | ForceDeleteBranch
                | DeleteRemoteBranch
                | RenameBranch
                | SwitchBranch
                | CreateBranch
                | Stage
                | Unstage
                | Stash
                | Discard
                // None of these moves the protected branch.
                | AbortOperation
                | CreateBranchAt
                | CreateTag
                | DeleteTag
                | StashApply
                | StashDrop
                | AddRemote
                | RemoveRemote
                | SetIdentity
                | SetGlobalIdentity
                | IgnorePath
                | AddWorktree
                | RemoveWorktree
        )
    {
        return Err(error(
            "protected_branch",
            "main está protegida: trabaja en develop o una rama de cambio y promueve mediante PR.",
        ));
    }
    if matches!(
        action,
        ForceDeleteBranch | DeleteRemoteBranch | DeleteBranch
    ) && !confirmed
    {
        return Err(error(
            "confirmation_required",
            "Confirma la eliminación de la rama.",
        ));
    }
    if matches!(
        action,
        Push | Pull
            | Merge
            | Rebase
            | RebaseAbort
            | StashPop
            | Revert
            | CherryPick
            | Discard
            | PullMerge
            | PullRebase
            | PullAutostash
            | AbortOperation
            | DeleteTag
            | StashApply
            | StashDrop
            | RemoveRemote
            | RemoveWorktree
    ) && !confirmed
    {
        return Err(error(
            "confirmation_required",
            "Confirma la operación y su alcance.",
        ));
    }
    match action {
        Stage | Unstage => {
            validate_path(value)?;
            let files = status(root).await?;
            let file = files
                .iter()
                .find(|f| f.path == value)
                .ok_or_else(|| error("stale_file", "Ese archivo ya no figura entre los cambios. Actualiza la lista y vuelve a elegirlo."))?;
            let mut paths = vec![value];
            if let Some(original) = &file.original_path {
                paths.push(original);
            }
            let mut args = match action {
                Stage => vec!["add", "--"],
                _ if git(root, &["rev-parse", "--verify", "HEAD"]).await.is_ok() => {
                    vec!["restore", "--staged", "--"]
                }
                _ => vec!["rm", "--cached", "-f", "--"],
            };
            args.extend(paths);
            git(root, &args).await
        }
        Discard => {
            validate_path(value)?;
            let files = status(root).await?;
            let file = files
                .iter()
                .find(|f| f.path == value)
                .ok_or_else(|| error("stale_file", "Ese archivo ya no figura entre los cambios. Actualiza la lista y vuelve a elegirlo."))?;
            if file.conflicted() {
                return Err(error(
                    "conflict",
                    "Resuelve el conflicto antes de descartar cambios.",
                ));
            }
            if file.index == "?" {
                // Only the selected untracked file; never directories or ignored files.
                git(root, &["clean", "--force", "--", value]).await
            } else if file.worktree != " " {
                // Restores from the index, so staged content is preserved.
                git(root, &["restore", "--worktree", "--", value]).await
            } else {
                Err(error(
                    "nothing_to_discard",
                    "Ese archivo no tiene cambios fuera de lo que ya incluiste. Actualiza la lista y vuelve a intentar.",
                ))
            }
        }
        Commit => {
            if value.trim().is_empty() {
                return Err(error("empty_message", "Escribe el mensaje del commit."));
            }
            git(root, &["commit", "-m", value]).await
        }
        CommitAmend => {
            if value.trim().is_empty() {
                return Err(error("empty_message", "Escribe el mensaje del commit."));
            }
            local_head(root).await?;
            git(root, &["commit", "--amend", "-m", value]).await
        }
        UndoCommit => {
            local_head(root).await?;
            let parents = git(root, &["rev-list", "--parents", "-n", "1", "HEAD"]).await?;
            if parents.split_whitespace().count() != 2 {
                return Err(error(
                    "commit_not_undoable",
                    "El último commit es el primero del repositorio o une dos ramas: no se deshace desde aquí. Para deshacer su efecto, reviértelo desde Historial.",
                ));
            }
            git(root, &["reset", "--soft", "HEAD~1"]).await
        }
        Fetch | Pull | PullMerge | PullRebase | PullAutostash | Push | DeleteRemoteBranch
            if git(root, &["remote"]).await.unwrap_or_default().trim().is_empty() =>
        {
            Err(error(
                "no_remote",
                "Este repositorio sólo existe en tu Mac: no tiene remoto. Agrega uno en Remotos (por ejemplo origin) para buscar, bajar o subir cambios.",
            ))
        }
        Fetch => git(root, &["fetch", "--prune"]).await.map_err(access_failure),
        Pull => pull(root, &["pull", "--ff-only"]).await,
        PullMerge => pull(root, &["pull", "--no-rebase", "--no-edit"]).await,
        PullRebase => pull(root, &["pull", "--rebase"]).await,
        PullAutostash => pull(root, &["pull", "--ff-only", "--autostash"]).await,
        TrackBranch => {
            let (remote, short) = value
                .split_once('/')
                .ok_or_else(|| error("invalid_ref", "Elige una rama remota."))?;
            validate_branch(root, short).await?;
            if remote.starts_with('-') {
                return Err(error("invalid_ref", "Remoto inválido."));
            }
            git(
                root,
                &["show-ref", "--verify", &format!("refs/remotes/{value}")],
            )
            .await
            .map_err(|_| {
                error(
                    "invalid_ref",
                    format!("No existe {value} en este Mac. Pulsa «Actualizar» para traer las ramas del remoto y vuelve a intentar."),
                )
            })?;
            if git(
                root,
                &[
                    "show-ref",
                    "--verify",
                    "--quiet",
                    &format!("refs/heads/{short}"),
                ],
            )
            .await
            .is_ok()
            {
                return git(root, &["switch", short]).await;
            }
            git(root, &["switch", "--track", value]).await
        }
        DeleteBranch | ForceDeleteBranch => {
            validate_branch(root, value).await?;
            if value == primary_branch(root).await || value == branch.trim() {
                return Err(error(
                    "protected_branch",
                    "No se puede eliminar la rama principal ni la rama actual.",
                ));
            }
            let flag = if matches!(action, ForceDeleteBranch) {
                "-D"
            } else {
                "-d"
            };
            git(root, &["branch", flag, value]).await.map_err(|failure| {
                if failure.detail.contains("not fully merged") {
                    error(
                        "branch_not_merged",
                        format!("{value} tiene commits que no están en ninguna otra rama. Elimínala de todos modos sólo si ya no los necesitas."),
                    )
                } else {
                    failure
                }
            })
        }
        DeleteRemoteBranch => {
            let (remote, short) = value
                .split_once('/')
                .ok_or_else(|| error("invalid_ref", "Elige una rama remota."))?;
            validate_branch(root, short).await?;
            // Only a remote of this repository: any other value would become the push destination.
            let remotes = git(root, &["remote"]).await?;
            if remote.starts_with('-') || !remotes.lines().any(|name| name == remote) {
                return Err(error("invalid_ref", "Elige una rama de un remoto de este repositorio."));
            }
            if short == primary_branch(root).await || short == "develop"
            {
                return Err(error(
                    "protected_branch",
                    "La rama principal y develop no se eliminan desde aquí.",
                ));
            }
            git(root, &["push", remote, "--delete", short]).await
        }
        RenameBranch => {
            let (old, new) = value
                .split_once(':')
                .ok_or_else(|| error("invalid_ref", "Nombre inválido."))?;
            validate_branch(root, old).await?;
            validate_branch(root, new).await?;
            if old == primary_branch(root).await {
                return Err(error(
                    "protected_branch",
                    "La rama principal no se renombra.",
                ));
            }
            git(root, &["branch", "-m", old, new]).await
        }
        Push => {
            let name = branch.trim();
            validate_branch(root, name).await?;
            // Explicit destination prevents push.default / remote.push from promoting another branch.
            git(
                root,
                &[
                    "push",
                    "--set-upstream",
                    "origin",
                    &format!("refs/heads/{name}:refs/heads/{name}"),
                ],
            )
            .await
            .map_err(access_failure)
        }
        CreateBranch => {
            validate_branch(root, value).await?;
            git(root, &["switch", "-c", value]).await
        }
        SwitchBranch | Merge | Rebase => {
            validate_branch(root, value).await?;
            git(
                root,
                &["show-ref", "--verify", &format!("refs/heads/{value}")],
            )
            .await?;
            let verb = match action {
                SwitchBranch => "switch",
                Merge => "merge",
                _ => "rebase",
            };
            git(root, &[verb, value]).await
        }
        RebaseContinue => git(root, &["rebase", "--continue"]).await,
        RebaseAbort => git(root, &["rebase", "--abort"]).await,
        // Without `--literal-pathspecs` (there is no pathspec here): with it, Git saves untracked
        // files in the stash but leaves them in the folder, and popping it then fails.
        Stash => {
            git_console(
                root,
                &["stash", "push", "--include-untracked", "-m", "Stack Git"],
            )
            .await
        }
        StashPop => git(root, &["stash", "pop"]).await,
        Revert | CherryPick => {
            let hash = validate_commit(root, value).await?;
            let verb = if matches!(action, Revert) {
                "revert"
            } else {
                "cherry-pick"
            };
            git(root, &[verb, &hash]).await
        }
        ContinueOperation => continue_operation(root).await,
        AbortOperation => {
            let flag = match operation(root).await?.as_str() {
                "merge" => "merge",
                // `rebase-apply` is also the state of `git am`, which has its own abort.
                "rebase" if is_mailbox_apply(root).await => "am",
                "rebase" => "rebase",
                "cherry-pick" => "cherry-pick",
                "revert" => "revert",
                _ => return Err(nothing_halfway()),
            };
            git(root, &[flag, "--abort"]).await
        }
        CreateBranchAt => {
            let (name, commit) = value
                .split_once(':')
                .ok_or_else(|| error("invalid_ref", "Elige un nombre y un commit."))?;
            validate_branch(root, name).await?;
            let hash = validate_commit(root, commit).await?;
            git(root, &["branch", "--no-track", name, &hash]).await
        }
        CreateTag => {
            let (name, commit) = value.split_once(':').unwrap_or((value, ""));
            validate_tag(root, name).await?;
            let target = if commit.is_empty() {
                git(root, &["rev-parse", "--verify", "HEAD"])
                    .await?
                    .trim()
                    .to_string()
            } else {
                validate_commit(root, commit).await?
            };
            git(root, &["tag", name, &target]).await
        }
        DeleteTag => {
            validate_tag(root, value).await?;
            git(root, &["tag", "--delete", value]).await
        }
        StashApply | StashDrop => {
            validate_stash(value)?;
            let verb = if matches!(action, StashApply) {
                "apply"
            } else {
                "drop"
            };
            git(root, &["stash", verb, value]).await
        }
        AddRemote => {
            let (name, url) = value
                .split_once('\n')
                .ok_or_else(|| error("invalid_arguments", "Escribe el nombre y la dirección."))?;
            let (name, url) = (name.trim(), url.trim());
            validate_remote(root, name).await?;
            if url.is_empty() || url.starts_with('-') || url.contains(char::is_whitespace) {
                return Err(error("invalid_url", "La dirección del remoto no es válida."));
            }
            if super::remotes::embeds_credentials(url) {
                return Err(error(
                    "invalid_url",
                    "Quita el usuario y la clave de la dirección: Stack usa tu cuenta conectada.",
                ));
            }
            git(
                root,
                &["remote", "add", name, &super::remotes::stored_address(url)],
            )
            .await
        }
        RemoveRemote => {
            validate_remote(root, value).await?;
            git(root, &["remote", "remove", value]).await
        }
        SetIdentity | SetGlobalIdentity => {
            let (name, email) = value
                .split_once('\n')
                .ok_or_else(|| error("invalid_arguments", "Escribe tu nombre y tu correo."))?;
            let (name, email) = (name.trim(), email.trim());
            if name.is_empty()
                || name.contains('\n')
                || email.contains(char::is_whitespace)
                || !email.contains('@')
                || email.starts_with('@')
                || email.ends_with('@')
            {
                return Err(error(
                    "invalid_arguments",
                    "Escribe un nombre y un correo válidos.",
                ));
            }
            let scope = if matches!(action, SetGlobalIdentity) {
                "--global"
            } else {
                "--local"
            };
            git(root, &["config", scope, "user.name", name]).await?;
            git(root, &["config", scope, "user.email", email]).await
        }
        IgnorePath => ignore_path(root, value).await,
        AddWorktree => super::worktrees::add(root, value).await,
        RemoveWorktree => super::worktrees::remove(root, value).await,
    }
}

fn nothing_halfway() -> GitError {
    error(
        "no_operation",
        "No hay ninguna operación a medias en este repositorio.",
    )
}

/// The operation halfway, finished without an editor: Git's prepared message is kept.
/// The "rebase" found is really `git am` halfway: its folder (`rebase-apply`) holds `applying`
/// and not `rebasing`.
async fn is_mailbox_apply(root: &Path) -> bool {
    let Ok(paths) = git(
        root,
        &[
            "rev-parse",
            "--git-path",
            "rebase-apply/applying",
            "--git-path",
            "rebase-apply/rebasing",
        ],
    )
    .await
    else {
        return false;
    };
    let mut lines = paths.lines().map(|line| root.join(line.trim()));
    let (applying, rebasing) = (lines.next(), lines.next());
    applying.is_some_and(|path| path.exists()) && !rebasing.is_some_and(|path| path.exists())
}

async fn continue_operation(root: &Path) -> Result<String> {
    let current = operation(root).await?;
    if current.is_empty() {
        return Err(nothing_halfway());
    }
    if has_conflicts(root).await? {
        return Err(error(
            "conflict",
            "Todavía hay archivos en conflicto: resuélvelos antes de continuar.",
        ));
    }
    let editor = [("GIT_EDITOR", "true")];
    match current.as_str() {
        "rebase" if is_mailbox_apply(root).await => {
            git_env(root, &["am", "--continue"], &editor).await
        }
        "merge" => git_env(root, &["commit", "--no-edit"], &editor).await,
        "rebase" => git_env(root, &["rebase", "--continue"], &editor).await,
        "cherry-pick" => git_env(root, &["cherry-pick", "--continue"], &editor).await,
        _ => git_env(root, &["revert", "--continue"], &editor).await,
    }
}

/// A tag name Git accepts that can't be read as an option.
async fn validate_tag(root: &Path, value: &str) -> Result<()> {
    if value.is_empty() || value.starts_with('-') || value.contains("@{") {
        return Err(error(
            "invalid_ref",
            "Nombre de etiqueta inválido: usa letras, números, puntos o guiones, sin espacios.",
        ));
    }
    git(root, &["check-ref-format", &format!("refs/tags/{value}")])
        .await
        .map_err(|_| {
            error(
                "invalid_ref",
                format!("«{value}» no es un nombre de etiqueta válido."),
            )
        })?;
    Ok(())
}

/// `stash@{n}`, the only form a saved change is addressed by.
fn validate_stash(value: &str) -> Result<()> {
    let number = value
        .strip_prefix("stash@{")
        .and_then(|rest| rest.strip_suffix('}'));
    match number {
        Some(n) if !n.is_empty() && n.len() <= 6 && n.chars().all(|c| c.is_ascii_digit()) => Ok(()),
        _ => Err(error(
            "invalid_ref",
            "Elige un cambio guardado de la lista.",
        )),
    }
}

/// A remote name: like a branch name, without '/'.
async fn validate_remote(root: &Path, value: &str) -> Result<()> {
    if value.contains('/') {
        return Err(error(
            "invalid_ref",
            "Nombre de remoto inválido: usa letras, números o guiones, sin barras ni espacios.",
        ));
    }
    validate_branch(root, value).await
}

/// Adds the path to `.gitignore` (written as a literal, anchored pattern) and, when the file was
/// only added to the index (not in the last commit), takes it out of the index; the file stays.
async fn ignore_path(root: &Path, value: &str) -> Result<String> {
    validate_path(value)?;
    if value.contains('\n') || value.split('/').any(|part| part == ".git") {
        return Err(error("invalid_path", "Ruta inválida."));
    }
    let ignore = root.join(".gitignore");
    if std::fs::symlink_metadata(&ignore).is_ok_and(|meta| !meta.is_file()) {
        return Err(error("invalid_path", ".gitignore no es un archivo."));
    }
    let mut pattern = String::from("/");
    for character in value.trim_end_matches('/').chars() {
        if matches!(character, '*' | '?' | '[' | ']' | '\\' | '!' | '#' | ' ') {
            pattern.push('\\');
        }
        pattern.push(character);
    }
    // Raw bytes: a .gitignore that is not UTF-8 (a Latin-1 comment) is appended to, never rewritten.
    let current = match std::fs::read(&ignore) {
        Ok(bytes) => bytes,
        Err(failure) if failure.kind() == std::io::ErrorKind::NotFound => Vec::new(),
        Err(_) => return Err(error("write_failed", "No se pudo leer .gitignore.")),
    };
    let present = current
        .split(|byte| *byte == b'\n')
        .any(|line| line == pattern.as_bytes());
    if !present {
        use std::io::Write;
        let mut addition = Vec::new();
        if !current.is_empty() && !current.ends_with(b"\n") {
            addition.push(b'\n');
        }
        addition.extend_from_slice(pattern.as_bytes());
        addition.push(b'\n');
        std::fs::OpenOptions::new()
            .append(true)
            .create(true)
            .open(&ignore)
            .and_then(|mut file| file.write_all(&addition))
            .map_err(|_| error("write_failed", "No se pudo escribir .gitignore."))?;
    }
    let in_index = git(root, &["ls-files", "--cached", "--", value])
        .await
        .map(|out| !out.trim().is_empty())
        .unwrap_or(false);
    let committed = git(root, &["cat-file", "-e", &format!("HEAD:{value}")])
        .await
        .is_ok();
    if in_index && !committed {
        git(root, &["rm", "--cached", "--quiet", "--", value]).await?;
    }
    Ok(String::new())
}

/// The last commit exists and is on no remote branch: rewriting it never needs a forced push.
async fn local_head(root: &Path) -> Result<()> {
    git(root, &["rev-parse", "--verify", "HEAD"])
        .await
        .map_err(|_| error("commit_not_undoable", "Todavía no hay commits."))?;
    let published = git(
        root,
        &[
            "for-each-ref",
            "--contains",
            "HEAD",
            "--format=%(refname)",
            "refs/remotes/",
        ],
    )
    .await?;
    if published.trim().is_empty() {
        Ok(())
    } else {
        Err(error(
            "commit_published",
            "El último commit ya está en el remoto: cambiarlo obligaría a forzar la subida. Corrige con un commit nuevo.",
        ))
    }
}

/// Runs a pull and turns Git's failure into a stable code the UI can guide the user from.
async fn pull(root: &Path, args: &[&str]) -> Result<String> {
    match git(root, args).await {
        Ok(output) => Ok(output),
        Err(failure) => Err(classify_pull_failure(
            &failure.detail,
            has_conflicts(root).await?,
        )),
    }
}

pub fn classify_pull_failure(detail: &str, conflicted: bool) -> GitError {
    let text = detail.to_lowercase();
    let (code, message) = if conflicted || text.contains("conflict") {
        ("pull_conflicts", "Los cambios del remoto chocan con los tuyos en algunos archivos. Resuélvelos uno por uno y luego continúa.")
    } else if text.contains("not possible to fast-forward")
        || text.contains("diverg")
        || text.contains("need to specify how to reconcile")
    {
        (
            "pull_diverged",
            "Tu rama y la del remoto tienen commits distintos. Elige cómo combinarlas.",
        )
    } else if text.contains("would be overwritten")
        || text.contains("commit your changes or stash")
        || text.contains("unstaged changes")
        || text.contains("uncommitted changes")
    {
        ("pull_local_changes", "Tienes cambios sin guardar en commit que se pisarían al bajar. Puedes guardarlos temporalmente y recuperarlos después.")
    } else if text.contains("no tracking information") || text.contains("no such ref was fetched") {
        ("pull_no_upstream", "Esta rama todavía no está conectada con una rama del remoto. Súbela primero o configura su upstream.")
    } else if text.contains("could not read from remote")
        || text.contains("authentication")
        || text.contains("permission denied")
        || text.contains("could not resolve host")
    {
        (
            "pull_remote_unreachable",
            "No se pudo conectar con el remoto. Revisa tu conexión, VPN o credenciales SSH.",
        )
    } else {
        return error("git_failed", detail.to_string());
    };
    error(
        code,
        format!("{message}\n\nDetalle de Git: {}", detail.trim()),
    )
}
