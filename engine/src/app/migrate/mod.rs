//! Moving the data from `Application Support/Butake Stack` (the name the product had) to
//! `Application Support/Stack`. Nothing moves by itself: the user asks for it in Ajustes ›
//! Avanzado or with `butake-stack migrate-data --confirm`, after seeing the plan
//! (`--plan`, which changes nothing).
//!
//! Steps: check the space; stop every process and the daemon (and its LaunchAgent) and check
//! that the services shut down cleanly and nothing keeps a file open there; make a verified backup
//! next to the folder (APFS clones: instant, no extra space); rename the folder (atomic on the same
//! volume); rewrite every absolute path that named it, inside and outside (service configuration,
//! LaunchAgent, `~/.zprofile`, AWS `credential_process` lines, links in `~/.local/bin`, the links of
//! the AI folders to Stack's skills, Python environments of projects), keeping each original; start again and check that every service
//! that ran runs and answers. If any step fails, everything goes back to the old folder as it was.
//! A journal (`migration.json`, inside the folder) makes it idempotent and lets a run that was cut
//! short be resumed.

mod control;
mod rewrite;
#[cfg(test)]
mod tests;
mod tree;

use anyhow::{Result, bail, ensure};
pub use control::{Control, Live};
use rewrite::Change;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    fs,
    path::{Path, PathBuf},
};

/// Where the folders are: the data folder before and after, and the home whose LaunchAgents,
/// `~/.zprofile`, `~/.local/bin` and AWS files may point into it.
#[derive(Debug, Clone)]
pub struct Layout {
    pub old: PathBuf,
    pub new: PathBuf,
    pub home: PathBuf,
    pub aws_config: Option<PathBuf>,
}

impl Layout {
    pub fn for_home(home: &Path) -> Self {
        use crate::core::store::Store;
        Self {
            old: Store::old_data_folder(home),
            new: Store::data_folder(home),
            home: home.to_path_buf(),
            aws_config: Some(home.join(".aws/config")),
        }
    }
    /// The real home, or the isolated one of `BUTAKE_DEVTOOLS_HOME` (QA: no launchctl). An isolated
    /// store (`BUTAKE_STACK_HOME` alone) has nothing to migrate.
    pub fn from_environment() -> Result<(Self, Live)> {
        let isolated = std::env::var_os("BUTAKE_DEVTOOLS_HOME").is_some();
        ensure!(
            isolated || std::env::var_os("BUTAKE_STACK_HOME").is_none(),
            "migration_isolated"
        );
        let home = crate::runtimes::utilities::devtools::home()?;
        let mut layout = Self::for_home(&home);
        layout.aws_config = crate::aws::Files::from_environment().ok().map(|f| f.config);
        Ok((layout, Live { launchd: !isolated }))
    }
    pub fn launch_agent(&self) -> PathBuf {
        self.home
            .join("Library/LaunchAgents/cl.butake.stack.daemon.plist")
    }
}

/// The journal of a migration, kept in the data folder (it moves with it).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct Journal {
    /// `stopping`, `backup`, `moved`, `rewriting`, `starting`, `done` or `reverted`.
    phase: String,
    from: PathBuf,
    to: PathBuf,
    #[serde(default)]
    backup: Option<PathBuf>,
    #[serde(default)]
    running: Vec<String>,
    #[serde(default)]
    agent: bool,
    #[serde(default)]
    changes: Vec<Change>,
    #[serde(default)]
    error: Option<String>,
    #[serde(default)]
    report: Vec<Value>,
}

const JOURNAL: &str = "migration.json";
const ORIGINALS: &str = ".migration/originals";

fn journal(root: &Path) -> Option<Journal> {
    crate::core::json::read_regular(&root.join(JOURNAL), Some(16 * 1024 * 1024)).ok()
}
fn save(root: &Path, journal: &Journal) -> Result<()> {
    crate::core::json::write(&root.join(JOURNAL), journal)
}

/// While a migration has the folder half done, no daemon may start on it. Before the folder is
/// renamed (`stopping`, `backup`, `moved` still under the old name) the data is where it was, so
/// only a run that is alive (it holds `migration.lock`) blocks: after a power cut or a kill the
/// daemon starts again. After the rename, a half-rewritten folder waits for the run to resume.
pub fn blocks_daemon(root: &Path) -> bool {
    let Some(journal) = journal(root) else {
        return false;
    };
    if !["stopping", "backup", "moved", "rewriting"].contains(&journal.phase.as_str()) {
        return false;
    }
    journal.to == root || lock_held(root)
}

const LOCK: &str = "migration.lock";

/// Held by a run for as long as it works on the folder; the system releases it if the process dies.
fn lock(root: &Path) -> Result<fs::File> {
    use std::os::{fd::AsRawFd, unix::fs::OpenOptionsExt};
    let file = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(root.join(LOCK))?;
    ensure!(
        // SAFETY: `flock` takes a descriptor and flags and touches no memory; the descriptor
        // belongs to `file`, which is open for the whole call.
        unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0,
        "migration_failed"
    );
    Ok(file)
}

/// Whether a run holds the lock of `root` right now.
fn lock_held(root: &Path) -> bool {
    use std::os::{fd::AsRawFd, unix::fs::OpenOptionsExt};
    let Ok(file) = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(root.join(LOCK))
    else {
        return false;
    };
    // SAFETY: `flock` takes a descriptor and flags and touches no memory; the descriptor belongs
    // to `file`, which is open for the whole call.
    let free = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0;
    // Closing `file` releases the lock taken just now.
    !free
}

/// What a run would find: `ready`, `resume` (a run was cut short after the move), `done` (the data
/// is already in the new folder) or `conflict` (both folders hold data).
fn state(layout: &Layout) -> &'static str {
    use crate::core::store::Store;
    let (old, new) = (
        Store::holds_data(&layout.old),
        Store::holds_data(&layout.new),
    );
    let resumable = journal(&layout.new)
        .is_some_and(|j| ["moved", "rewriting", "starting"].contains(&j.phase.as_str()));
    match (old, new) {
        (_, true) if resumable => "resume",
        (true, true) => "conflict",
        (true, false) => "ready",
        (false, true) => "done",
        (false, false) => "nothing",
    }
}

fn backup_path(layout: &Layout) -> PathBuf {
    let stamp = crate::core::time::utc_stamp(crate::core::time::now_secs());
    let name = layout
        .old
        .file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .into_owned();
    let mut path = layout.old.with_file_name(format!("{name} (copia {stamp})"));
    let mut count = 2;
    while path.exists() || PathBuf::from(format!("{}.partial", path.display())).exists() {
        path = layout
            .old
            .with_file_name(format!("{name} (copia {stamp} {count})"));
        count += 1;
    }
    path
}

/// Space the backup needs: clones share their blocks, so on a volume that makes them it costs only
/// its metadata; anywhere else every file is copied in full.
fn needed_space(bytes: u64, clones: bool) -> u64 {
    if clones {
        256 << 20
    } else {
        bytes + (256 << 20)
    }
}

/// What a migration would do, changing nothing.
pub fn plan(layout: &Layout, control: &dyn Control) -> Result<Value> {
    let state = state(layout);
    let mut value = json!({
        "state": state,
        "from": layout.old,
        "to": layout.new,
    });
    if state != "ready" {
        return Ok(value);
    }
    let (bytes, files) = tree::size(&layout.old)?;
    let parent = layout.new.parent().unwrap_or(&layout.old);
    let same_volume = tree::same_volume(&layout.old, parent)?;
    let free = tree::free_space(parent)?;
    let needed = needed_space(bytes, same_volume && tree::can_clone(parent));
    let running = control.running(&layout.old);
    let changes = rewrite::find(layout, &layout.old)?;
    let agent = control.agent_loaded() && agent_points_at(layout, &layout.old);
    value.as_object_mut().unwrap().extend([
        ("bytes".into(), json!(bytes)),
        ("files".into(), json!(files)),
        ("free".into(), json!(free)),
        ("needed".into(), json!(needed)),
        ("sameVolume".into(), json!(same_volume)),
        ("enoughSpace".into(), json!(free >= needed)),
        ("running".into(), json!(running)),
        ("agent".into(), json!(agent)),
        ("backup".into(), json!(backup_path(layout))),
        // Files that name the folder but are links: they are left alone and keep the old path.
        ("skippedLinks".into(), json!(rewrite::skipped_links(layout))),
        (
            "rewrites".into(),
            json!(changes
                .iter()
                .map(|c| json!({"path": c.location(&layout.old), "kind": c.kind, "place": c.place}))
                .collect::<Vec<_>>()),
        ),
        // Stopping (MySQL takes up to two minutes), cloning and starting again.
        (
            "seconds".into(),
            json!(10 + 15 * running.len() as u64 + files / 20_000),
        ),
    ]);
    Ok(value)
}

fn agent_points_at(layout: &Layout, root: &Path) -> bool {
    fs::read_to_string(layout.launch_agent())
        .is_ok_and(|text| rewrite::replace(&text, &root.to_string_lossy(), "\u{0}").is_some())
}

/// Where a test makes the run stop as if the process had been killed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Cut {
    None,
    AfterMove,
}

/// Runs the migration (or finishes one that was cut short). The answer says how it ended: on
/// failure, `ok: false`, the failed `step`, the `error` code and whether it was `reverted`.
pub fn run(layout: &Layout, control: &dyn Control, cut: Cut) -> Result<Value> {
    let result = run_locked(layout, control, cut);
    // The lock is released (its file closed) by now: no trace of it is left, whichever folder it
    // ended up in.
    for root in [&layout.old, &layout.new] {
        let _ = fs::remove_file(root.join(LOCK));
    }
    result
}

fn run_locked(layout: &Layout, control: &dyn Control, cut: Cut) -> Result<Value> {
    match state(layout) {
        "done" | "nothing" => {
            let journal = journal(&layout.new).unwrap_or_default();
            return Ok(
                json!({"ok": true, "already": true, "to": layout.new, "backup": journal.backup}),
            );
        }
        "conflict" => bail!("migration_conflict"),
        "resume" => {
            let _lock = lock(&layout.new)?;
            let journal = journal(&layout.new).unwrap_or_default();
            return finish(layout, control, journal);
        }
        _ => {}
    }
    let _lock = lock(&layout.old)?;
    let mut journal = Journal {
        phase: "stopping".into(),
        from: layout.old.clone(),
        to: layout.new.clone(),
        ..Journal::default()
    };
    // A run cut short before the move left at most a partial backup of its own.
    if let Some(previous) = self::journal(&layout.old)
        && let Some(partial) = previous
            .backup
            .filter(|b| previous.phase != "reverted" && b.to_string_lossy().ends_with(".partial"))
    {
        let _ = fs::remove_dir_all(partial);
    }
    let plan = plan(layout, control)?;
    ensure!(plan["sameVolume"] == true, "migration_cross_volume");
    ensure!(plan["enoughSpace"] == true, "migration_no_space");
    // An empty folder of the new name holds nothing and would only be in the way of the rename.
    tree::remove_if_empty(&layout.new)?;
    ensure!(!layout.new.exists(), "migration_target_exists");
    journal.running = control.running(&layout.old);
    journal.agent = plan["agent"] == true;
    save(&layout.old, &journal)?;

    let before_move = (|| -> Result<PathBuf> {
        control.stop(&layout.old, journal.agent)?;
        let open = control.open_files(&layout.old)?;
        ensure!(open.is_empty(), "migration_files_open:{}", open.join(", "));
        ensure!(shut_down_cleanly(&layout.old), "migration_unclean_shutdown");
        journal.phase = "backup".into();
        let backup = backup_path(layout);
        let partial = PathBuf::from(format!("{}.partial", backup.to_string_lossy()));
        journal.backup = Some(partial.clone());
        save(&layout.old, &journal)?;
        if let Err(error) = tree::backup(&layout.old, &partial) {
            let _ = fs::remove_dir_all(&partial);
            return Err(error.context("migration_backup_failed"));
        }
        fs::rename(&partial, &backup)?;
        Ok(backup)
    })();
    let backup = match before_move {
        Ok(backup) => backup,
        Err(error) => {
            // Nothing moved: the folder is as it was; what ran runs again.
            let step = if journal.phase == "backup" {
                "backup"
            } else {
                "stop"
            };
            journal.phase = "reverted".into();
            if let Some(b) = &journal.backup
                && b.to_string_lossy().ends_with(".partial")
            {
                journal.backup = None;
            }
            return Ok(failure(layout, control, journal, step, &error, &layout.old));
        }
    };
    journal.backup = Some(backup);
    journal.phase = "moved".into();
    save(&layout.old, &journal)?;
    if let Err(error) = fs::rename(&layout.old, &layout.new) {
        journal.phase = "reverted".into();
        return Ok(failure(
            layout,
            control,
            journal,
            "move",
            &error.into(),
            &layout.old,
        ));
    }
    if cut == Cut::AfterMove {
        return Ok(json!({"ok": false, "cut": true}));
    }
    finish(layout, control, journal)
}

/// After the move: rewrite, start and verify; or put everything back.
fn finish(layout: &Layout, control: &dyn Control, mut journal: Journal) -> Result<Value> {
    let root = layout.new.clone();
    let originals = root.join(ORIGINALS);
    let rewritten = (|| -> Result<()> {
        // A daemon started meanwhile (resume) must not run on a half-rewritten folder.
        control.stop(&root, journal.agent)?;
        journal.phase = "rewriting".into();
        save(&root, &journal)?;
        for change in rewrite::find(layout, &root)? {
            let known = journal
                .changes
                .iter()
                .any(|c| c.path == change.path && c.inside == change.inside);
            if !known {
                let kept =
                    rewrite::keep_original(&change, &root, &originals, journal.changes.len())?;
                journal.changes.push(kept);
                save(&root, &journal)?;
            }
        }
        for change in &journal.changes {
            rewrite::apply(change, &root, &layout.old, &layout.new)?;
        }
        journal.phase = "starting".into();
        save(&root, &journal)
    })();
    if let Err(error) = rewritten {
        return Ok(revert_and_fail(layout, control, journal, "rewrite", &error));
    }
    match control.start(
        &root,
        journal.agent,
        &layout.launch_agent(),
        &journal.running,
    ) {
        Ok(report) => {
            journal.report = report;
            journal.phase = "done".into();
            save(&root, &journal)?;
            let _ = fs::remove_dir_all(root.join(".migration"));
            // A process that resolved the old folder an instant before the move may have made it again.
            tree::remove_if_empty(&layout.old)?;
            Ok(json!({
                "ok": true,
                "to": root,
                "backup": journal.backup,
                "rewritten": journal.changes.iter().map(|c| c.location(&root)).collect::<Vec<_>>(),
                "report": journal.report,
            }))
        }
        Err(error) => {
            if let Some(report) = error.to_string().strip_prefix("migration_start_failed:") {
                journal.report = serde_json::from_str(report).unwrap_or_default();
            }
            Ok(revert_and_fail(layout, control, journal, "start", &error))
        }
    }
}

/// After a failure past the move: back to the old folder, or (if even that fails) a report that
/// leaves the journal in place so the next run resumes it.
fn revert_and_fail(
    layout: &Layout,
    control: &dyn Control,
    mut journal: Journal,
    step: &str,
    error: &anyhow::Error,
) -> Value {
    match revert(layout, control, &mut journal) {
        Ok(()) => failure(layout, control, journal, step, error, &layout.old),
        Err(problem) => json!({
            "ok": false,
            "step": step,
            "error": "migration_revert_failed",
            "cause": problem.to_string().split(':').next().unwrap_or("").to_string(),
            "reverted": false,
            "to": layout.new,
            "backup": journal.backup,
        }),
    }
}

/// Back to the old folder exactly as it was: stop what started, put every original back, rename.
fn revert(layout: &Layout, control: &dyn Control, journal: &mut Journal) -> Result<()> {
    let root = &layout.new;
    control.stop(root, journal.agent)?;
    let originals = root.join(ORIGINALS);
    for change in journal.changes.iter().rev() {
        rewrite::undo(change, root, &originals)?;
    }
    let _ = fs::remove_dir_all(root.join(".migration"));
    tree::remove_if_empty(&layout.old)?;
    fs::rename(root, &layout.old)?;
    journal.phase = "reverted".into();
    journal.changes.clear();
    Ok(())
}

/// The answer of a failed run, after starting again what ran on the folder it is back in.
fn failure(
    layout: &Layout,
    control: &dyn Control,
    mut journal: Journal,
    step: &str,
    error: &anyhow::Error,
    root: &Path,
) -> Value {
    let code = error.to_string();
    let (code, detail) = code
        .split_once(':')
        .map_or((code.as_str(), None), |(c, d)| (c, Some(d)));
    let code = if code.starts_with("migration_") {
        code.to_string()
    } else {
        "migration_failed".into()
    };
    journal.error = Some(code.clone());
    journal.phase = "reverted".into();
    let _ = save(root, &journal);
    let restarted = control.start(
        root,
        journal.agent,
        &layout.launch_agent(),
        &journal.running,
    );
    json!({
        "ok": false,
        "step": step,
        "error": code,
        "detail": detail.filter(|_| code == "migration_files_open"),
        "reverted": true,
        "from": layout.old,
        "backup": journal.backup,
        "report": journal.report,
        "restarted": restarted.is_ok(),
    })
}

/// A database stopped by SIGKILL leaves its mark: MySQL and Redis their pid file in `run/`,
/// PostgreSQL `postmaster.pid`, MongoDB a non-empty `mongod.lock`, the supervisor its `run/pids/`
/// entry. Moving or cloning a datadir is only safe after a clean shutdown.
fn shut_down_cleanly(root: &Path) -> bool {
    let names = |folder: PathBuf| -> Vec<(String, u64)> {
        fs::read_dir(folder)
            .into_iter()
            .flatten()
            .flatten()
            .map(|e| {
                (
                    e.file_name().to_string_lossy().into_owned(),
                    e.metadata().map_or(0, |m| m.len()),
                )
            })
            .collect()
    };
    if names(root.join("run"))
        .iter()
        .any(|(n, _)| n.ends_with(".pid"))
        || !names(root.join("run/pids")).is_empty()
    {
        return false;
    }
    !fs::read_dir(root.join("data"))
        .into_iter()
        .flatten()
        .flatten()
        .any(|service| {
            names(service.path())
                .iter()
                .any(|(n, len)| n == "postmaster.pid" || (n == "mongod.lock" && *len > 0))
        })
}

/// `migrateDataPlan` and `migrateData` (the latter with `confirmed`).
pub fn dispatch(method: &str, request: &Value) -> Result<Option<Value>> {
    let (layout, control) = match method {
        "migrateDataPlan" | "migrateData" => Layout::from_environment()?,
        _ => return Ok(None),
    };
    if method == "migrateDataPlan" {
        return plan(&layout, &control).map(Some);
    }
    ensure!(request["confirmed"] == true, "confirmation_required");
    run(&layout, &control, Cut::None).map(Some)
}

/// `butake-stack migrate-data --plan | --confirm`: the same, for the terminal (JSON on stdout).
pub fn command(arguments: &[std::ffi::OsString]) -> i32 {
    let flag = arguments.first().and_then(|a| a.to_str()).unwrap_or("");
    let result = match flag {
        "--plan" => dispatch("migrateDataPlan", &json!({})),
        "--confirm" => dispatch("migrateData", &json!({"confirmed": true})),
        _ => {
            eprintln!("uso: butake-stack migrate-data --plan | --confirm");
            return 2;
        }
    };
    match result {
        Ok(Some(value)) => {
            println!(
                "{}",
                serde_json::to_string_pretty(&value).unwrap_or_default()
            );
            i32::from(value["ok"] == false)
        }
        Ok(None) => 2,
        Err(error) => {
            eprintln!("{error}");
            1
        }
    }
}
