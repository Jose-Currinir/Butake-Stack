//! Runs the installed Git with separate arguments (never a shell line), without optional locks,
//! without prompts and with a time limit per kind of command. Errors carry a fixed code and a
//! detail (a message of this engine or Git's own output) that `public_detail` cleans before it
//! leaves the engine.
use serde::Serialize;
use std::{
    path::Path,
    sync::{
        atomic::{AtomicBool, AtomicI32, Ordering},
        Arc,
    },
    time::Duration,
};
use tokio::process::Command;

#[derive(Debug, Serialize)]
pub struct GitError {
    pub code: String,
    pub detail: String,
}
pub type Result<T> = std::result::Result<T, GitError>;
pub fn error(code: &str, detail: impl Into<String>) -> GitError {
    GitError {
        code: code.into(),
        detail: detail.into(),
    }
}
/// Only the code: the detail goes to the app through `public_detail`, never to logs.
impl std::fmt::Display for GitError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.code)
    }
}
impl std::error::Error for GitError {}

/// The detail of an error as the app may show it: credentials in URLs, tokens and secret
/// assignments hidden line by line (`daemon::redact`), and at most 4.000 characters.
pub fn public_detail(detail: &str) -> String {
    let clean: Vec<String> = detail.lines().map(crate::daemon::redact::redact).collect();
    clean.join("\n").chars().take(4_000).collect()
}

/// Tests never see the user's Git configuration, keys or agent: a private HOME and global
/// configuration, no system configuration and no SSH agent.
#[cfg(test)]
pub(crate) fn isolate(command: &mut Command) {
    isolate_std(command.as_std_mut());
}
#[cfg(not(test))]
pub(crate) fn isolate(_command: &mut Command) {}

/// [`isolate`] for a blocking command (the console subcommand).
#[cfg(test)]
pub(crate) fn isolate_std(command: &mut std::process::Command) {
    let home = test_home();
    command
        .env("HOME", home)
        .env("XDG_CONFIG_HOME", home.join(".config"))
        .env("GIT_CONFIG_GLOBAL", home.join(".gitconfig"))
        .env("GIT_CONFIG_SYSTEM", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env_remove("SSH_AUTH_SOCK")
        .env_remove("GIT_ASKPASS")
        .env_remove("SSH_ASKPASS");
}
#[cfg(not(test))]
pub(crate) fn isolate_std(_command: &mut std::process::Command) {}

#[cfg(test)]
pub(crate) fn test_home() -> &'static Path {
    static HOME: std::sync::OnceLock<std::path::PathBuf> = std::sync::OnceLock::new();
    HOME.get_or_init(|| {
        let dir = std::env::temp_dir().join(format!("stack-git-tests-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        // An identity of its own and nothing else: no signing, hooks, helpers or aliases of the user.
        std::fs::write(
            dir.join(".gitconfig"),
            "[user]\n\tname = Stack Test\n\temail = test@example.invalid\n[commit]\n\tgpgsign = false\n",
        )
        .unwrap();
        dir
    })
}

/// The most output of one Git command that is kept (stdout and stderr each): a diff or log of a
/// huge file fails with `output_too_large` instead of filling memory.
const OUTPUT_LIMIT: usize = 32 * 1024 * 1024;

/// The parent the engine had when the app asked to be able to stop this request (0: it can't).
static STOP_PARENT: AtomicI32 = AtomicI32::new(0);

/// From now on a network transfer (clone, fetch, pull, push) of this request ends when the app
/// stops it: SIGTERM only asks to stop, and the transfer's whole process group (Git and its SSH or
/// credential helpers) is ended instead of being left running alone.
pub fn stop_on_request() {
    STOP_PARENT.store(crate::core::watch::listen(), Ordering::SeqCst);
}

/// Asks whether to stop, for a command that may be stopped halfway: only network transfers, and
/// only while the app follows the request. Local commands always finish (a write is never cut).
type StopCheck = Box<dyn Fn() -> bool + Send>;
fn stop_check(args: &[&str]) -> Option<StopCheck> {
    stop_check_for(STOP_PARENT.load(Ordering::SeqCst), args)
}
fn stop_check_for(parent: libc::pid_t, args: &[&str]) -> Option<StopCheck> {
    let network = matches!(
        args.first().copied(),
        Some("clone" | "push" | "pull" | "fetch")
    );
    (parent != 0 && network)
        .then(|| Box::new(move || crate::core::watch::stop_requested(parent)) as StopCheck)
}

/// Waits for the child; with `stop`, checks it every 200 ms and ends the child's group when it
/// says so.
async fn wait(
    child: &mut tokio::process::Child,
    stop: Option<StopCheck>,
) -> Result<std::process::ExitStatus> {
    let ended = |_| error("git_unavailable", "Git terminó sin estado.");
    let Some(stop) = stop else {
        return child.wait().await.map_err(ended);
    };
    loop {
        tokio::select! {
            status = child.wait() => return status.map_err(ended),
            _ = tokio::time::sleep(Duration::from_millis(200)) => {
                if stop() {
                    if let Some(pid) = child.id() {
                        crate::core::watch::end_group(pid as i32);
                    }
                    let _ = child.start_kill();
                    return Err(error("cancelled", "Se detuvo la operación."));
                }
            }
        }
    }
}

/// Runs a prepared Git command. Waits for the process itself, not for end-of-file on its pipes: a
/// hook that leaves a background process keeps them open, and waiting for EOF reported a timeout
/// for work that finished. Output is drained for a short grace period after the exit. With `stop`
/// the command runs in its own process group, so stopping it ends its helpers too.
async fn run(
    mut command: Command,
    input: Option<Vec<u8>>,
    seconds: u64,
    stop: Option<StopCheck>,
) -> Result<std::process::Output> {
    use std::process::Stdio;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    command
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    let grouped = stop.is_some();
    if grouped {
        command.process_group(0);
    }
    let mut child = command.spawn().map_err(|_| {
        error(
            "git_unavailable",
            "Git no está instalado o no se pudo iniciar.",
        )
    })?;
    let writer = match (input, child.stdin.take()) {
        (Some(payload), Some(mut stdin)) => Some(tokio::spawn(async move {
            let _ = stdin.write_all(&payload).await;
        })),
        _ => None,
    };
    let overflow = Arc::new(AtomicBool::new(false));
    fn drain<R: tokio::io::AsyncRead + Unpin + Send + 'static>(
        pipe: Option<R>,
        overflow: Arc<AtomicBool>,
    ) -> (Arc<std::sync::Mutex<Vec<u8>>>, tokio::task::JoinHandle<()>) {
        let buffer = Arc::new(std::sync::Mutex::new(Vec::new()));
        let sink = buffer.clone();
        let task = tokio::spawn(async move {
            let Some(mut pipe) = pipe else { return };
            let mut chunk = [0u8; 16_384];
            while let Ok(read) = pipe.read(&mut chunk).await {
                if read == 0 {
                    break;
                }
                // Past the cap the rest is read and dropped, so Git never blocks on a full pipe.
                if let Ok(mut sink) = sink.lock() {
                    if sink.len() + read > OUTPUT_LIMIT {
                        overflow.store(true, Ordering::Relaxed);
                        sink.clear();
                        sink.shrink_to_fit();
                    } else if !overflow.load(Ordering::Relaxed) {
                        sink.extend_from_slice(&chunk[..read]);
                    }
                }
            }
        });
        (buffer, task)
    }
    let (stdout, stdout_task) = drain(child.stdout.take(), overflow.clone());
    let (stderr, stderr_task) = drain(child.stderr.take(), overflow.clone());
    let status = match tokio::time::timeout(Duration::from_secs(seconds), wait(&mut child, stop))
        .await
    {
        Ok(status) => status?,
        Err(_) => {
            // The command's whole group (hooks, SSH and credential helpers) when it has one.
            if let (true, Some(pid)) = (grouped, child.id()) {
                crate::core::watch::end_group(pid as i32);
            }
            let _ = child.start_kill();
            return Err(error(
                "timeout",
                format!("Git excedió {seconds} segundos. Verifica el acceso a la carpeta y actualiza antes de reintentar."),
            ));
        }
    };
    if let Some(writer) = writer {
        writer.abort();
    }
    for task in [stdout_task, stderr_task] {
        let abort = task.abort_handle();
        if tokio::time::timeout(Duration::from_millis(1_500), task)
            .await
            .is_err()
        {
            abort.abort();
        }
    }
    if overflow.load(Ordering::Relaxed) {
        return Err(error(
            "output_too_large",
            "Git devolvió más de 32 MB de salida. Acota la consulta (un archivo, un rango o menos resultados).",
        ));
    }
    let take = |buffer: Arc<std::sync::Mutex<Vec<u8>>>| {
        buffer
            .lock()
            .map(|mut b| std::mem::take(&mut *b))
            .unwrap_or_default()
    };
    Ok(std::process::Output {
        status,
        stdout: take(stdout),
        stderr: take(stderr),
    })
}

/// Seconds a Git command may run: quick lookups, network transfers and commands that run hooks or
/// check out large trees (LFS) each get their own limit.
fn time_limit(args: &[&str]) -> u64 {
    match args.first().copied() {
        Some(
            "rev-parse" | "symbolic-ref" | "--version" | "--exec-path" | "--list-cmds=builtins",
        ) => 12,
        // Large repositories over slow links: network transfers get half an hour.
        Some("clone" | "push" | "pull" | "fetch") => 1_800,
        // Hooks (pre-commit, post-checkout…) and big checkouts can legitimately take minutes.
        Some(
            "commit" | "merge" | "rebase" | "cherry-pick" | "revert" | "switch" | "checkout"
            | "stash" | "reset" | "am",
        ) => 900,
        _ => 120,
    }
}

/// Git's own switch for `core.fsmonitor`: the configuration of a repository (a copied `.git`, a
/// clone of someone else) names a program Git would run on every `status`, so it is always off.
/// Hooks are different: they are how the user's own commit, push and checkout checks run, so they
/// stay on for the actions the user asks for (and do not run for reads).
pub(crate) const NO_FSMONITOR: [&str; 2] = ["-c", "core.fsmonitor=false"];

pub(crate) fn base_command(root: &Path, literal_pathspecs: bool) -> Command {
    let mut command = Command::new("git");
    command
        .current_dir(root)
        .args(NO_FSMONITOR)
        .arg("--no-pager");
    if literal_pathspecs {
        command.arg("--literal-pathspecs");
    }
    command
        .env("GIT_TERMINAL_PROMPT", "0")
        // Reads never take optional locks or rewrite the index: a GUI watching .git must not trigger itself.
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("LC_ALL", "C");
    isolate(&mut command);
    command
}

fn failure_detail(output: &std::process::Output) -> String {
    let detail = String::from_utf8_lossy(&output.stderr).trim().to_string();
    if detail.is_empty() {
        String::from_utf8_lossy(&output.stdout).trim().to_string()
    } else {
        detail
    }
}

pub async fn git_bytes(root: &Path, args: &[&str]) -> Result<Vec<u8>> {
    let mut command = base_command(root, true);
    let _session = super::credentials::attach(&mut command, args)?;
    command
        .args(args)
        .env("GIT_EDITOR", "true")
        .env("GIT_PAGER", "cat");
    let output = run(command, None, time_limit(args), stop_check(args)).await?;
    if !output.status.success() {
        return Err(error("git_failed", failure_detail(&output)));
    }
    Ok(output.stdout)
}

pub async fn git(root: &Path, args: &[&str]) -> Result<String> {
    // Git paths with invalid UTF-8 are rejected instead of targeting another file by lossy conversion.
    String::from_utf8(git_bytes(root, args).await?).map_err(|_| {
        error(
            "unsupported_encoding",
            "Este repositorio tiene nombres de archivo con caracteres que no se pueden leer. Renómbralos para usar Git aquí.",
        )
    })
}

/// Like `git`, for file content shown to the user: bytes that are not UTF-8 (Latin-1 sources…)
/// are replaced instead of failing. Never use the result to address paths.
pub async fn git_lossy(root: &Path, args: &[&str]) -> Result<String> {
    Ok(String::from_utf8_lossy(&git_bytes(root, args).await?).into_owned())
}

/// Runs a console command exactly as previewed: pathspecs keep their globs and magic, and the
/// text Git writes to stderr on success (push, fetch, switch…) is returned after stdout.
pub async fn git_console(root: &Path, args: &[&str]) -> Result<String> {
    let mut command = base_command(root, false);
    command
        .args(args)
        .env("GIT_EDITOR", "true")
        .env("GIT_PAGER", "cat");
    let output = run(command, None, time_limit(args), stop_check(args)).await?;
    if !output.status.success() {
        return Err(error("git_failed", failure_detail(&output)));
    }
    let mut text = String::from_utf8_lossy(&output.stdout).into_owned();
    let extra = String::from_utf8_lossy(&output.stderr);
    if !extra.trim().is_empty() {
        if !text.is_empty() && !text.ends_with('\n') {
            text.push('\n');
        }
        text.push_str(&extra);
    }
    Ok(text)
}

/// Runs Git with extra environment variables (e.g. a non-interactive sequence editor).
pub async fn git_env(root: &Path, args: &[&str], env: &[(&str, &str)]) -> Result<String> {
    let mut command = base_command(root, true);
    command.args(args);
    for (key, value) in env {
        command.env(key, value);
    }
    let output = run(command, None, time_limit(args).max(300), stop_check(args)).await?;
    if !output.status.success() {
        return Err(error("git_failed", failure_detail(&output)));
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

/// Runs Git feeding `input` on stdin (used for NUL-separated pathspecs, avoiding argv limits).
pub async fn git_input(root: &Path, args: &[&str], input: &[u8]) -> Result<String> {
    let mut command = base_command(root, true);
    command.args(args).env("GIT_EDITOR", "true");
    let output = run(command, Some(input.to_vec()), 120, None).await?;
    if !output.status.success() {
        return Err(error("git_failed", failure_detail(&output)));
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A repository whose `core.fsmonitor` names a program must not run it when Stack reads or
    /// acts on the repository; its hooks still run for the user's own commit.
    #[tokio::test]
    async fn the_fsmonitor_of_a_repository_never_runs_but_its_hooks_do() {
        use std::os::unix::fs::PermissionsExt;
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("repo");
        std::fs::create_dir(&root).unwrap();
        let script = |name: &str, marker: &str| {
            let path = temp.path().join(name);
            std::fs::write(
                &path,
                format!(
                    "#!/bin/sh\ntouch '{}'\n",
                    temp.path().join(marker).display()
                ),
            )
            .unwrap();
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
            path
        };
        let monitor = script("monitor.sh", "monitor-ran");
        git(&root, &["init", "-q"]).await.unwrap();
        git(
            &root,
            &["config", "core.fsmonitor", monitor.to_str().unwrap()],
        )
        .await
        .unwrap();
        git(&root, &["config", "user.name", "Prueba"])
            .await
            .unwrap();
        git(&root, &["config", "user.email", "prueba@example.test"])
            .await
            .unwrap();
        let hook = script("hook.sh", "hook-ran");
        std::fs::copy(&hook, root.join(".git/hooks/pre-commit")).unwrap();
        std::fs::write(root.join("a.txt"), "x").unwrap();
        for args in [
            &["status", "--porcelain"][..],
            &["add", "a.txt"][..],
            &["diff", "--cached", "--stat"][..],
            &["log", "--oneline", "-1"][..],
        ] {
            let _ = git(&root, args).await;
        }
        git_console(&root, &["commit", "-m", "uno"]).await.unwrap();
        assert!(
            !temp.path().join("monitor-ran").exists(),
            "core.fsmonitor ran"
        );
        assert!(
            temp.path().join("hook-ran").exists(),
            "the commit hook must still run"
        );
    }

    #[test]
    fn details_hide_credentials_and_stay_short() {
        let detail = "fatal: unable to access 'https://user:ghp_abcdefghijklmnopqrstuvwxyz0123456789@github.com/a/b.git/': 403\nAuthorization: Bearer abc.def.ghi";
        let clean = public_detail(detail);
        assert!(
            !clean.contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789"),
            "{clean}"
        );
        assert!(!clean.contains("abc.def.ghi"), "{clean}");
        assert!(clean.contains("github.com"));
        assert_eq!(public_detail(&"x".repeat(9_000)).len(), 4_000);
        // Only the code reaches Display (and with it, any debug log).
        assert_eq!(error("git_failed", "secret").to_string(), "git_failed");
    }

    #[test]
    fn only_followed_network_transfers_can_be_stopped() {
        // Nothing follows the request: no command is stoppable.
        assert!(stop_check_for(0, &["fetch", "--prune"]).is_none());
        let network = ["clone", "push", "pull", "fetch"].map(|c| stop_check_for(1, &[c]).is_some());
        let local = ["commit", "status", "rebase"].map(|c| stop_check_for(1, &[c]).is_some());
        assert_eq!(network, [true; 4]);
        assert_eq!(local, [false; 3]);
    }

    #[tokio::test]
    async fn a_stopped_transfer_ends_its_whole_group() {
        // A child that would outlive its parent (as SSH under Git): stopping ends both.
        let marker = tempfile::tempdir().unwrap();
        let pid_file = marker.path().join("child.pid");
        let mut command = Command::new("/bin/sh");
        command.args([
            "-c",
            &format!("sleep 30 & echo $! > '{}'; wait", pid_file.display()),
        ]);
        let started = std::time::Instant::now();
        let asked = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let flag = asked.clone();
        let stopper = tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(400)).await;
            flag.store(true, Ordering::SeqCst);
        });
        let stop: StopCheck = Box::new(move || asked.load(Ordering::SeqCst));
        let failure = run(command, None, 60, Some(stop)).await.unwrap_err();
        stopper.await.unwrap();
        assert_eq!(failure.code, "cancelled");
        assert!(started.elapsed() < Duration::from_secs(10));
        let pid: i32 = std::fs::read_to_string(&pid_file)
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        // The background child is gone (or a zombie of its ended group, never still sleeping).
        let alive = unsafe { libc::kill(pid, 0) } == 0;
        assert!(!alive || !crate::core::watch::group_alive(pid), "{pid}");
    }
}

#[cfg(test)]
mod limits {
    use super::*;

    #[tokio::test]
    async fn output_past_the_cap_is_an_error_not_memory() {
        let mut command = Command::new("/bin/sh");
        command.args(["-c", "head -c 40000000 /dev/zero"]);
        let failure = run(command, None, 60, None).await.unwrap_err();
        assert_eq!(failure.code, "output_too_large");
    }

    #[tokio::test]
    async fn a_failure_carries_what_git_wrote_to_stdout() {
        let mut command = Command::new("/bin/sh");
        command.args(["-c", "echo 'nothing to commit'; exit 1"]);
        let output = run(command, None, 10, None).await.unwrap();
        assert_eq!(failure_detail(&output), "nothing to commit");
    }
}
