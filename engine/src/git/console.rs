//! The Git console: the dictionary of commands (`commands.json`), what the installed Git offers,
//! its manual pages, and the policy every typed command goes through before it runs (protected
//! primary branch, no force or mass push, explicit push destination, no refs from stdin). Commands
//! run without a terminal through `gitRun`, or inside a tab of Stack's Terminal through the
//! `git-console` subcommand (the PTY belongs to the Terminal, not to this tool).
use super::protection::{current_branch, main_protected, primary_branch};
use super::runner::{error, git, isolate, isolate_std, Result};
use super::status::snapshot;
use super::words;
use serde::{Deserialize, Serialize};
use std::{collections::HashSet, ffi::OsString, path::Path};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CommandCapability {
    pub name: String,
    pub available: bool,
    pub library: bool,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Capabilities {
    pub version: String,
    pub commands: Vec<CommandCapability>,
}
#[derive(Deserialize)]
struct Catalog {
    commands: Vec<CatalogCommand>,
}
#[derive(Deserialize)]
struct CatalogCommand {
    name: String,
}
#[derive(Clone, Deserialize, Serialize)]
pub struct RebaseStep {
    pub hash: String,
    pub action: String,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RebasePlan {
    pub head: String,
    pub base: String,
    pub steps: Vec<RebaseStep>,
}
#[derive(Serialize)]
pub struct RebaseCandidates {
    pub head: String,
    pub base: String,
    pub commits: Vec<RebaseCommit>,
}
#[derive(Serialize)]
pub struct RebaseCommit {
    pub hash: String,
    pub subject: String,
}
#[derive(Clone, Debug, Serialize)]
pub struct PreparedCommand {
    pub command: String,
    pub args: Vec<String>,
    pub preview: String,
}

pub fn command_names() -> Vec<String> {
    serde_json::from_str::<Catalog>(include_str!("commands.json"))
        .map(|catalog| catalog.commands.into_iter().map(|c| c.name).collect())
        .unwrap_or_default()
}
fn known(name: &str) -> Result<()> {
    if command_names().iter().any(|n| n == name) {
        Ok(())
    } else {
        Err(error(
            "unknown_command",
            "Selecciona un comando del diccionario.",
        ))
    }
}
fn library(name: &str) -> bool {
    matches!(name, "sh-i18n" | "sh-setup" | "gitweb")
}
fn executable_exists(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    path.is_file()
        && path
            .metadata()
            .map(|m| m.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
}
fn program_on_path(name: &str) -> bool {
    std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).any(|d| executable_exists(&d.join(name))))
        .unwrap_or(false)
}
pub async fn capabilities() -> Result<Capabilities> {
    let cwd = std::env::temp_dir();
    let builtins = git(&cwd, &["--list-cmds=builtins"]).await?;
    let builtin: HashSet<_> = builtins.lines().collect();
    let exec = git(&cwd, &["--exec-path"]).await?;
    let commands = command_names()
        .into_iter()
        .map(|name| {
            let lib = library(&name);
            let available = !lib
                && (builtin.contains(name.as_str())
                    || executable_exists(&Path::new(exec.trim()).join(format!("git-{name}")))
                    || (name == "gitk" && program_on_path("gitk"))
                    || program_on_path(&format!("git-{name}")));
            CommandCapability {
                name,
                available,
                library: lib,
            }
        })
        .collect();
    Ok(Capabilities {
        version: git(&cwd, &["--version"]).await?.trim().into(),
        commands,
    })
}

/// The local manual page of a command of the dictionary, as plain text.
pub async fn command_help(name: &str) -> Result<String> {
    known(name)?;
    let mut command = tokio::process::Command::new("git");
    command
        .args(["--no-pager", "help", "--man", name])
        .env("MANPAGER", "cat")
        .env("PAGER", "cat")
        .env("MAN_KEEP_FORMATTING", "0")
        .stdin(std::process::Stdio::null())
        .kill_on_drop(true);
    isolate(&mut command);
    let output = tokio::time::timeout(std::time::Duration::from_secs(15), command.output())
        .await
        .map_err(|_| error("timeout", "La ayuda tardó demasiado."))?
        .map_err(|_| {
            error(
                "git_unavailable",
                "Git no está instalado o no se pudo iniciar.",
            )
        })?;
    if !output.status.success() {
        return Err(error(
            "help_unavailable",
            "Manual local no instalado; consulta el enlace oficial del diccionario.",
        ));
    }
    // Remove overstrikes produced by man while preserving the manual's contents.
    let mut text = String::new();
    for c in String::from_utf8_lossy(&output.stdout).chars() {
        if c == '\u{8}' {
            text.pop();
        } else {
            text.push(c);
        }
    }
    Ok(text)
}

fn explicitly_protected_ref(value: &str, primary: &str) -> bool {
    value == primary
        || value == format!("refs/heads/{primary}")
        || value.starts_with(&format!("{primary}:"))
        || value.ends_with(&format!(":{primary}"))
        || value.ends_with(&format!(":refs/heads/{primary}"))
}
/// Commands that reset or move the protected branch while standing on another one.
fn moves_protected_branch(command: &str, args: &[String], primary: &str) -> bool {
    let named = |value: &str| value == primary || value == format!("refs/heads/{primary}");
    // `-C main`, `-Cmain`, `--force-create main`, `--force-create=main`.
    let forced = |flags: &[&str]| {
        args.iter().enumerate().any(|(index, arg)| {
            flags.iter().any(|flag| {
                (arg == flag && args.get(index + 1).is_some_and(|next| named(next)))
                    || arg
                        .strip_prefix(flag)
                        .is_some_and(|rest| named(rest.trim_start_matches('=')))
            })
        })
    };
    match command {
        "switch" => forced(&["-C", "--force-create"]),
        "checkout" => forced(&["-B"]),
        "worktree" => forced(&["-B"]),
        "pull" => args.iter().any(|a| {
            a.ends_with(&format!(":{primary}")) || a.ends_with(&format!(":refs/heads/{primary}"))
        }),
        // `rebase <upstream> <branch>` checks out and rewrites <branch>.
        "rebase" => {
            let mut operands = Vec::new();
            let mut skip = false;
            for arg in args {
                if skip {
                    skip = false;
                } else if matches!(
                    arg.as_str(),
                    "--onto" | "-x" | "--exec" | "-s" | "--strategy" | "-X" | "--strategy-option"
                ) {
                    skip = true;
                } else if !arg.starts_with('-') {
                    operands.push(arg.as_str());
                }
            }
            operands.len() >= 2 && operands.last().is_some_and(|last| named(last))
        }
        _ => false,
    }
}
/// Commands that only read the repository.
pub fn read_command(command: &str) -> bool {
    matches!(
        command,
        "status"
            | "log"
            | "show"
            | "diff"
            | "blame"
            | "annotate"
            | "grep"
            | "shortlog"
            | "describe"
            | "range-diff"
            | "show-branch"
            | "version"
            | "help"
            | "ls-files"
            | "ls-tree"
            | "ls-remote"
            | "show-ref"
            | "rev-parse"
            | "rev-list"
            | "merge-base"
            | "cat-file"
            | "cherry"
            | "count-objects"
            | "check-attr"
            | "check-ignore"
            | "check-mailmap"
            | "check-ref-format"
            | "for-each-ref"
            | "name-rev"
            | "verify-commit"
            | "verify-tag"
            | "verify-pack"
            | "diff-files"
            | "diff-index"
            | "diff-tree"
            | "diff-pairs"
            | "repo"
            | "last-modified"
            | "whatchanged"
    )
}

/// Checks a typed command against the policy and returns it as separate arguments with its preview.
pub fn prepare(
    command: &str,
    arguments: &str,
    current_branch: &str,
    primary: &str,
    main_protected: bool,
) -> Result<PreparedCommand> {
    known(command)?;
    if library(command) {
        return Err(error("library_command", "Esta entrada documenta una biblioteca o componente servidor; no es una acción CLI autónoma."));
    }
    let args = words::split(arguments).ok_or_else(|| {
        error(
            "invalid_arguments",
            "Hay comillas sin cerrar en los argumentos.",
        )
    })?;
    if args.len() > 256 || arguments.len() > 32_768 || args.iter().any(|a| a.contains('\0')) {
        return Err(error(
            "invalid_arguments",
            "Argumentos fuera del límite permitido.",
        ));
    }
    let reads = read_command(command)
        || match command {
            "branch" => {
                args.is_empty()
                    || args.iter().all(|a| {
                        matches!(
                            a.as_str(),
                            "--list"
                                | "-l"
                                | "-a"
                                | "--all"
                                | "-r"
                                | "--remotes"
                                | "-v"
                                | "-vv"
                                | "--show-current"
                        ) || a.starts_with("--format=")
                    })
            }
            "tag" => args.first().is_some_and(|a| a == "--list" || a == "-l"),
            "stash" => args.first().is_some_and(|a| a == "list" || a == "show"),
            "worktree" => args.first().is_some_and(|a| a == "list"),
            "remote" => {
                args.is_empty()
                    || args.first().is_some_and(|a| {
                        matches!(a.as_str(), "-v" | "--verbose" | "show" | "get-url")
                    })
            }
            "reflog" => {
                args.is_empty()
                    || args
                        .first()
                        .is_some_and(|a| a == "show" || a == "list" || a.starts_with("--format="))
            }
            "config" => args.first().is_some_and(|a| {
                matches!(
                    a.as_str(),
                    "get" | "list" | "--get" | "--get-all" | "--get-regexp" | "--list"
                )
            }),
            _ => false,
        };
    let blocked = || {
        error(
            "protected_branch",
            "No se permite modificar main ni múltiples referencias implícitas desde la consola.",
        )
    };
    if !reads && main_protected && current_branch == primary {
        return Err(error(
            "protected_branch",
            "main está protegida. Cambia a develop o una rama de trabajo.",
        ));
    }
    if !reads
        && ((matches!(
            command,
            "branch"
                | "update-ref"
                | "symbolic-ref"
                | "refs"
                | "history"
                | "replay"
                | "filter-branch"
                | "push"
                | "send-pack"
                | "fetch"
        ) && main_protected
            && args.iter().any(|a| explicitly_protected_ref(a, primary)))
            || (matches!(
                command,
                "branch" | "filter-branch" | "history" | "push" | "send-pack"
            ) && args.iter().any(|a| a == "--mirror" || a == "--all")))
    {
        return Err(blocked());
    }
    if !reads && main_protected && moves_protected_branch(command, &args, primary) {
        return Err(blocked());
    }
    // These modes can write refs received later through stdin, beyond the visible preview.
    if matches!(
        command,
        "update-ref" | "symbolic-ref" | "fast-import" | "receive-pack"
    ) && (args.iter().any(|a| a == "--stdin") || command == "fast-import")
    {
        return Err(error("protected_branch", "Este modo admite referencias por stdin y requiere una herramienta externa con revisión explícita de main."));
    }
    if matches!(command, "push" | "send-pack") {
        if args.iter().any(|a| {
            a == "--force"
                || a == "-f"
                || a.starts_with("--force-with-lease")
                || a.starts_with('+')
                || a.contains('*')
                || a == "--delete"
                || a == "-d"
                || a == "--tags"
                || a == "--follow-tags"
                || a.starts_with("--repo")
                || a.starts_with("--recurse-submodules")
        }) {
            return Err(error(
                "protected_branch",
                "Force-push y publicación masiva no están habilitados.",
            ));
        }
        // Require an explicit, reviewed destination; ignore remote.push and push.default.
        let operands: Vec<_> = args.iter().filter(|a| !a.starts_with('-')).collect();
        if operands.len() != 2
            || args.iter().any(|a| {
                a.starts_with('-')
                    && !matches!(
                        a.as_str(),
                        "-u" | "--set-upstream" | "--dry-run" | "--porcelain" | "--verbose"
                    )
            })
        {
            return Err(error(
                "explicit_push_required",
                "Usa destino y refspec explícitos: origin refs/heads/develop:refs/heads/develop.",
            ));
        }
        let refs: Vec<_> = operands[1].split(':').collect();
        if refs.len() != 2
            || refs
                .iter()
                .any(|r| r.is_empty() || !r.starts_with("refs/heads/") || r.ends_with("/main"))
        {
            return Err(error(
                "explicit_push_required",
                "Push requiere origen y destino explícitos en refs/heads/, sin main.",
            ));
        }
    }
    if command == "remote" && args.first().is_some_and(|a| a == "update") {
        return Err(error(
            "explicit_remote_required",
            "Usa fetch con remoto explícito para revisar el destino.",
        ));
    }
    let mut argv = vec![command.to_string()];
    argv.extend(args.clone());
    Ok(PreparedCommand {
        command: command.into(),
        args,
        preview: format!("git {}", words::join(&argv)),
    })
}

/// `prepare` with the repository's own branch and protection.
pub async fn prepare_in(root: &Path, command: &str, arguments: &str) -> Result<PreparedCommand> {
    prepare(
        command,
        arguments,
        &current_branch(root).await,
        &primary_branch(root).await,
        main_protected(root).await,
    )
}

/// The read-only queries the app makes without a confirmation; anything that could write files,
/// refs or the reflog is refused.
/// `git grep` options of a query: the pattern after `-e` is text; any other option that opens a
/// pager (`-O`), reads patterns from a file (`-f`) or leaves the repository (`--no-index`) is refused.
fn grep_is_safe(args: &[String]) -> bool {
    let mut pattern_next = false;
    let mut operands = false;
    for arg in args {
        if pattern_next || operands {
            pattern_next = false;
            continue;
        }
        match arg.as_str() {
            "-e" => pattern_next = true,
            "--" => operands = true,
            long if long.starts_with("--") => {
                if ["--open-files-in-pager", "--file", "--no-index", "--output"]
                    .iter()
                    .any(|refused| long.starts_with(refused))
                {
                    return false;
                }
            }
            short if short.starts_with('-') && (short.contains('O') || short.contains('f')) => {
                return false;
            }
            _ => {}
        }
    }
    true
}

pub fn check_query(args: &[String]) -> Result<()> {
    let command = args.first().map(String::as_str).unwrap_or("");
    let refused = || error("invalid_query", "Esta operación requiere confirmación.");
    if !matches!(
        command,
        "worktree"
            | "tag"
            | "stash"
            | "remote"
            | "reflog"
            | "show"
            | "log"
            | "diff"
            | "ls-files"
            | "config"
            | "grep"
    ) {
        return Err(error("invalid_query", "Consulta desconocida."));
    }
    // Text in the repository's files («Contenido»): never in a pager or an editor, never patterns
    // read from a file outside the request.
    if command == "grep" && !grep_is_safe(&args[1..]) {
        return Err(error("invalid_query", "Consulta no permitida."));
    }
    if !matches!(
        command,
        "show" | "log" | "diff" | "ls-files" | "reflog" | "grep"
    ) && !matches!(
        args.get(1).map(String::as_str),
        Some("list" | "--list" | "-v" | "--get" | "get")
    ) {
        return Err(refused());
    }
    let rest = &args[1..];
    let writes = rest.iter().any(|a| a.starts_with("--output"))
        || (command == "tag" && !matches!(rest.first().map(String::as_str), Some("--list" | "-l")))
        || (command == "reflog"
            && !matches!(rest.first().map(String::as_str), Some("show") | None)
            && !rest.first().is_some_and(|a| a.starts_with('-')))
        || (command == "reflog"
            && rest
                .iter()
                .any(|a| matches!(a.as_str(), "expire" | "delete" | "drop")));
    if writes {
        return Err(refused());
    }
    Ok(())
}

/// Output of a console command or query as the app receives it: what can hold credentials (remote
/// URLs, configuration) goes through the same filter as error details; file content and history
/// stay as Git wrote them.
pub fn public_output(command: &str, output: String) -> String {
    let content = matches!(
        command,
        "show"
            | "log"
            | "diff"
            | "ls-files"
            | "ls-tree"
            | "grep"
            | "blame"
            | "annotate"
            | "cat-file"
            | "range-diff"
            | "shortlog"
            | "whatchanged"
            | "diff-files"
            | "diff-index"
            | "diff-tree"
            | "diff-pairs"
    );
    if content {
        output
    } else {
        output
            .lines()
            .map(crate::daemon::redact::redact)
            .collect::<Vec<_>>()
            .join("\n")
    }
}

pub async fn rebase_candidates(root: &Path, base: &str) -> Result<RebaseCandidates> {
    if base.is_empty() || base.starts_with('-') {
        return Err(error("invalid_ref", "Elige una base válida."));
    }
    let base = git(
        root,
        &[
            "rev-parse",
            "--verify",
            "--end-of-options",
            &format!("{base}^{{commit}}"),
        ],
    )
    .await?
    .trim()
    .to_string();
    let head = git(root, &["rev-parse", "--verify", "HEAD"])
        .await?
        .trim()
        .to_string();
    let range = format!("{base}..{head}");
    let merges = git(root, &["rev-list", "--merges", &range]).await?;
    if !merges.trim().is_empty() {
        return Err(error("merge_plan", "Entre esos commits hay combinaciones de ramas, que no se reordenan desde aquí. Elige commits posteriores a la última combinación."));
    }
    let raw = git(
        root,
        &[
            "log",
            "--reverse",
            "--topo-order",
            "--format=%H%x1f%s",
            &range,
        ],
    )
    .await?;
    let commits = raw
        .lines()
        .filter_map(|line| {
            line.split_once('\x1f').map(|(hash, subject)| RebaseCommit {
                hash: hash.into(),
                subject: subject.into(),
            })
        })
        .collect();
    Ok(RebaseCandidates {
        head,
        base,
        commits,
    })
}

/// Checks an interactive rebase plan and returns its todo list.
pub async fn validate_rebase(root: &Path, plan: &RebasePlan) -> Result<String> {
    let state = snapshot(root).await?;
    if (state.branch == state.primary_branch && state.main_protected) || state.branch == "HEAD" {
        return Err(error(
            "protected_branch",
            "Rebase visual requiere una rama de trabajo activa.",
        ));
    }
    if !state.files.is_empty() || !state.operation.is_empty() {
        return Err(error(
            "dirty_rebase",
            "Confirma tus cambios o guárdalos aparte y termina la operación a medias antes de reorganizar la rama.",
        ));
    }
    let current = rebase_candidates(root, &plan.base).await?;
    if current.head != plan.head || current.base != plan.base {
        return Err(error(
            "stale_plan",
            "El historial cambió. Vuelve a cargar el plan.",
        ));
    }
    let expected: HashSet<_> = current.commits.iter().map(|c| c.hash.as_str()).collect();
    let supplied: HashSet<_> = plan.steps.iter().map(|s| s.hash.as_str()).collect();
    if plan.steps.is_empty() || plan.steps.len() != expected.len() || supplied != expected {
        return Err(error(
            "invalid_plan",
            "El plan debe contener cada commit original exactamente una vez.",
        ));
    }
    let mut previous = false;
    let mut lines = Vec::new();
    for step in &plan.steps {
        if !matches!(
            step.action.as_str(),
            "pick" | "reword" | "edit" | "squash" | "fixup" | "drop"
        ) {
            return Err(error("invalid_plan", "Acción de rebase no permitida."));
        }
        if matches!(step.action.as_str(), "squash" | "fixup") && !previous {
            return Err(error(
                "invalid_plan",
                "Squash/fixup necesitan un commit previo que se conserve.",
            ));
        }
        if step.action != "drop" {
            previous = true;
        }
        lines.push(format!("{} {}", step.action, step.hash));
    }
    Ok(lines.join("\n") + "\n")
}

/// `butake-stack git-write-plan <plan> <todo>`: the sequence editor of a validated rebase copies
/// the plan over Git's todo list.
pub fn write_plan(args: &[OsString]) -> i32 {
    match args {
        [plan, todo] if std::fs::copy(plan, todo).is_ok() => 0,
        _ => 1,
    }
}

/// `butake-stack git-console <repository> <command> <arguments> [rebase plan]`: runs a console
/// command in the terminal that started it (a tab of Stack's Terminal), after the same policy as
/// `gitPrepare`. Returns Git's exit code.
pub async fn run_console(args: &[OsString]) -> Result<i32> {
    let text = |i: usize| args.get(i).and_then(|a| a.to_str());
    let (Some(path), Some(command), Some(arguments)) = (text(0), text(1), text(2)) else {
        return Err(error("invalid_arguments", "Faltan argumentos de terminal."));
    };
    let root = Path::new(path).canonicalize().map_err(|_| {
        error(
            "invalid_path",
            "La carpeta no existe o no se puede leer. Elige otra o revisa sus permisos.",
        )
    })?;
    let prepared = prepare_in(&root, command, arguments).await?;
    let mut process = std::process::Command::new(if prepared.command == "gitk" {
        "gitk"
    } else {
        "git"
    });
    if prepared.command != "gitk" {
        process.arg("--no-pager").arg(&prepared.command);
    }
    process
        .args(&prepared.args)
        .current_dir(&root)
        .env("GIT_PAGER", "cat")
        .env("TERM", "xterm-256color");
    isolate_std(&mut process);
    let mut plan_folder = None;
    if let Some(plan) = text(3) {
        if prepared.command != "rebase" {
            return Err(error("invalid_plan", "El plan solo aplica a rebase."));
        }
        let plan: RebasePlan =
            serde_json::from_str(plan).map_err(|_| error("invalid_plan", "Plan inválido."))?;
        let content = validate_rebase(&root, &plan).await?;
        let expected = [
            "--interactive",
            "--reapply-cherry-picks",
            "--keep-empty",
            &plan.base,
        ]
        .map(String::from);
        if prepared.args != expected {
            return Err(error(
                "invalid_plan",
                "La base del comando difiere del plan validado.",
            ));
        }
        let failed = || error("plan_file", "No se pudo preparar el plan.");
        let folder = std::env::temp_dir().join(format!(
            "stack-git-plan-{}-{}",
            std::process::id(),
            crate::core::time::now_secs()
        ));
        {
            use std::os::unix::fs::DirBuilderExt;
            std::fs::DirBuilder::new()
                .mode(0o700)
                .create(&folder)
                .map_err(|_| failed())?;
        }
        let todo = folder.join("todo");
        std::fs::write(&todo, content).map_err(|_| failed())?;
        let executable = std::env::current_exe().map_err(|_| failed())?;
        process.env(
            "GIT_SEQUENCE_EDITOR",
            format!(
                "{} git-write-plan {}",
                words::quote(&executable.to_string_lossy()),
                words::quote(&todo.to_string_lossy())
            ),
        );
        plan_folder = Some(folder);
    }
    let status = process.status();
    if let Some(folder) = plan_folder {
        let _ = std::fs::remove_dir_all(folder);
    }
    let status = status.map_err(|_| error("git_failed", "No se pudo iniciar Git."))?;
    Ok(status.code().unwrap_or(1))
}
