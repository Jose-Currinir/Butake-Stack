//! The absolute paths into the data folder that are written down somewhere: found before the move,
//! rewritten after it, each with its original kept so it can be put back byte for byte.

use super::Layout;
use anyhow::{ensure, Result};
use serde::{Deserialize, Serialize};
use std::{
    fs,
    io::Write,
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
};

/// Folders of the data that hold no paths worth rewriting: databases, logs, mail, the encrypted
/// vault, the AWS backups (copies of what the files said then), live sockets, the migration's own
/// journal and originals.
const SKIPPED: &[&str] = &[
    "data",
    "logs",
    "mail",
    "vault",
    "aws-backups",
    "run",
    ".migration",
    "migration.json",
];
/// Larger files are data, not configuration.
const LARGEST: u64 = 4 * 1024 * 1024;

/// One place that points into the data folder.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Change {
    /// Relative to the data folder when `inside`, absolute otherwise.
    pub path: PathBuf,
    pub inside: bool,
    /// `file` (text rewritten) or `link` (symbolic link pointed elsewhere).
    pub kind: String,
    /// `data` (inside the folder), `launchAgent`, `terminal` (~/.zprofile), `aws` (only the
    /// `credential_process` lines), `links` (~/.local/bin), `project` (a project's .venv) or
    /// `skills` (a link in an AI folder to a skill of Stack).
    pub place: String,
    /// The link's original target, or the file under `.migration/originals/` with its bytes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub original: Option<String>,
}

impl Change {
    pub fn location(&self, root: &Path) -> PathBuf {
        if self.inside {
            root.join(&self.path)
        } else {
            self.path.clone()
        }
    }
}

/// `text` with every `from` that ends a path component replaced by `to`; `None` if nothing
/// changed. `…/Butake Stack` is replaced in `…/Butake Stack/run` but not in `…/Butake Stack 2`.
pub fn replace(text: &str, from: &str, to: &str) -> Option<String> {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    let mut changed = false;
    while let Some(index) = rest.find(from) {
        let after = rest[index + from.len()..].chars().next();
        out.push_str(&rest[..index]);
        if after.is_none_or(|c| !(c.is_alphanumeric() || " _.-".contains(c))) {
            out.push_str(to);
            changed = true;
        } else {
            out.push_str(from);
        }
        rest = &rest[index + from.len()..];
    }
    out.push_str(rest);
    changed.then_some(out)
}

/// The new text of a file of `place`: for AWS only the `credential_process` lines change.
fn rewritten(place: &str, text: &str, from: &str, to: &str) -> Option<String> {
    if place != "aws" {
        return replace(text, from, to);
    }
    let mut changed = false;
    let lines: Vec<String> = text
        .split_inclusive('\n')
        .map(|line| {
            let key = line
                .trim_start()
                .split(['=', ' ', '\t'])
                .next()
                .unwrap_or("");
            match (key == "credential_process")
                .then(|| replace(line, from, to))
                .flatten()
            {
                Some(new) => {
                    changed = true;
                    new
                }
                None => line.to_string(),
            }
        })
        .collect();
    changed.then(|| lines.concat())
}

fn text_of(path: &Path) -> Option<String> {
    let meta = fs::symlink_metadata(path).ok()?;
    if !meta.is_file() || meta.len() > LARGEST {
        return None;
    }
    String::from_utf8(fs::read(path).ok()?).ok()
}

fn file_change(path: &Path, inside: Option<&Path>, place: &str, from: &str) -> Option<Change> {
    let text = text_of(path)?;
    rewritten(place, &text, from, "\u{0}")?;
    Some(Change {
        path: inside.map_or(path.to_path_buf(), |root| {
            path.strip_prefix(root).unwrap_or(path).to_path_buf()
        }),
        inside: inside.is_some(),
        kind: "file".into(),
        place: place.into(),
        original: None,
    })
}

fn link_change(path: &Path, inside: Option<&Path>, place: &str, from: &Path) -> Option<Change> {
    let target = fs::read_link(path).ok()?;
    (target.is_absolute() && target.starts_with(from)).then(|| Change {
        path: inside.map_or(path.to_path_buf(), |root| {
            path.strip_prefix(root).unwrap_or(path).to_path_buf()
        }),
        inside: inside.is_some(),
        kind: "link".into(),
        place: place.into(),
        original: None,
    })
}

/// Every place that names `layout.old`, looking inside `root` (the data folder, wherever it is
/// now) and outside it. Nothing is changed.
pub fn find(layout: &Layout, root: &Path) -> Result<Vec<Change>> {
    let from = layout.old.to_string_lossy().into_owned();
    let mut changes = vec![];
    let mut pending: Vec<PathBuf> = fs::read_dir(root)?
        .flatten()
        .filter(|e| !SKIPPED.contains(&e.file_name().to_string_lossy().as_ref()))
        .map(|e| e.path())
        .collect();
    while let Some(path) = pending.pop() {
        let Ok(meta) = fs::symlink_metadata(&path) else {
            continue;
        };
        if meta.file_type().is_symlink() {
            changes.extend(link_change(&path, Some(root), "data", &layout.old));
        } else if meta.is_dir() {
            pending.extend(fs::read_dir(&path)?.flatten().map(|e| e.path()));
        } else {
            changes.extend(file_change(&path, Some(root), "data", &from));
        }
    }
    let home = &layout.home;
    for (path, place) in [
        (layout.launch_agent(), "launchAgent"),
        (home.join(".zprofile"), "terminal"),
    ] {
        changes.extend(file_change(&path, None, place, &from));
    }
    if let Some(config) = &layout.aws_config {
        changes.extend(file_change(config, None, "aws", &from));
    }
    let links = |folder: &Path, place: &str, changes: &mut Vec<Change>| {
        for entry in fs::read_dir(folder).into_iter().flatten().flatten() {
            changes.extend(link_change(&entry.path(), None, place, &layout.old));
        }
    };
    links(&home.join(".local/bin"), "links", &mut changes);
    // The links of the AI folders to Stack's skills hold the absolute path of the data folder.
    let skills = layout.old.join("skills");
    for folder in skill_folders(layout, root) {
        for entry in fs::read_dir(folder).into_iter().flatten().flatten() {
            changes.extend(link_change(&entry.path(), None, "skills", &skills));
        }
    }
    // A Python environment of a project names the interpreter it was made with.
    for project in project_folders(root) {
        let venv = project.join(".venv");
        changes.extend(file_change(
            &venv.join("pyvenv.cfg"),
            None,
            "project",
            &from,
        ));
        links(&venv.join("bin"), "project", &mut changes);
    }
    changes.sort_by(|a, b| (a.inside, &a.path).cmp(&(b.inside, &b.path)).reverse());
    Ok(changes)
}

/// Files outside the folder that are links to a file naming the old folder: `find` leaves them
/// alone (a link is not rewritten), so the plan lists them.
pub fn skipped_links(layout: &Layout) -> Vec<PathBuf> {
    let from = layout.old.to_string_lossy().into_owned();
    let mut candidates = vec![layout.launch_agent(), layout.home.join(".zprofile")];
    candidates.extend(layout.aws_config.clone());
    candidates
        .into_iter()
        .filter(|path| fs::symlink_metadata(path).is_ok_and(|meta| meta.file_type().is_symlink()))
        .filter(|path| {
            fs::metadata(path)
                .ok()
                .filter(|meta| meta.is_file() && meta.len() <= LARGEST)
                .and_then(|_| fs::read(path).ok())
                .and_then(|bytes| String::from_utf8(bytes).ok())
                .is_some_and(|text| replace(&text, &from, "\u{0}").is_some())
        })
        .collect()
}

/// The folders of the AIs that get skills: the built-in ones and the custom ones of the skills
/// index (`skills/index.json` in `root`). Only folders under the home count.
fn skill_folders(layout: &Layout, root: &Path) -> Vec<PathBuf> {
    let mut raw: Vec<String> = ["~/.claude/skills", "~/.agents/skills", "~/.gemini/skills"]
        .map(String::from)
        .to_vec();
    let index: Option<serde_json::Value> =
        crate::core::json::read_regular(&root.join("skills/index.json"), Some(1_048_576)).ok();
    if let Some(agents) = index.as_ref().and_then(|v| v["agents"].as_object()) {
        raw.extend(
            agents
                .values()
                .filter_map(|a| a["folder"].as_str().map(String::from)),
        );
    }
    let mut folders: Vec<PathBuf> = vec![];
    for text in raw {
        let path = match text.strip_prefix("~/") {
            Some(rest) => layout.home.join(rest),
            None => PathBuf::from(&text),
        };
        let plain = path.is_absolute()
            && path
                .components()
                .all(|c| !matches!(c, std::path::Component::ParentDir));
        if plain && path.starts_with(&layout.home) && !folders.contains(&path) {
            folders.push(path);
        }
    }
    folders
}

/// The folders of the registered projects (`projects/<id>.json`).
fn project_folders(root: &Path) -> Vec<PathBuf> {
    let mut folders = vec![];
    for entry in fs::read_dir(root.join("projects"))
        .into_iter()
        .flatten()
        .flatten()
    {
        let value: Option<serde_json::Value> =
            crate::core::json::read_regular(&entry.path(), Some(1_048_576)).ok();
        if let Some(path) = value.as_ref().and_then(|v| v["path"].as_str()) {
            let path = PathBuf::from(path);
            if path.is_absolute() && path.is_dir() {
                folders.push(path);
            }
        }
    }
    folders
}

/// Writes `content` over `path` atomically with `mode`, or replaces the link at `path`.
fn replace_file(path: &Path, content: &[u8], mode: u32) -> Result<()> {
    let temporary = path.with_file_name(format!(
        ".{}.migration.tmp",
        path.file_name().unwrap_or_default().to_string_lossy()
    ));
    let _ = fs::remove_file(&temporary);
    // Created for the owner only, so the content is never readable by more than the original
    // allowed; the exact mode (and its group and others bits) is set once it is complete.
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(mode & 0o700)
        .open(&temporary)?;
    let written = (|| -> Result<()> {
        file.write_all(content)?;
        file.set_permissions(fs::Permissions::from_mode(mode))?;
        file.sync_all()?;
        fs::rename(&temporary, path)?;
        Ok(())
    })();
    if written.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    written
}
fn replace_link(path: &Path, target: &Path) -> Result<()> {
    let temporary = path.with_file_name(format!(
        ".{}.migration.tmp",
        path.file_name().unwrap_or_default().to_string_lossy()
    ));
    let _ = fs::remove_file(&temporary);
    std::os::unix::fs::symlink(target, &temporary)?;
    fs::rename(&temporary, path)?;
    Ok(())
}

/// Keeps the original of `change` (in `originals`, a private folder of the data) and returns the
/// change that records it. Called before `apply`, so a crash between the two can still be undone.
pub fn keep_original(
    change: &Change,
    root: &Path,
    originals: &Path,
    index: usize,
) -> Result<Change> {
    let path = change.location(root);
    let mut kept = change.clone();
    if change.kind == "link" {
        kept.original = Some(fs::read_link(&path)?.to_string_lossy().into_owned());
    } else {
        fs::create_dir_all(originals)?;
        fs::set_permissions(originals, fs::Permissions::from_mode(0o700))?;
        let name = format!("{index:04}");
        let mode = fs::metadata(&path)?.permissions().mode() & 0o7777;
        crate::core::fsutil::write_private_bytes(&originals.join(&name), &fs::read(&path)?)?;
        kept.original = Some(format!("{name}:{mode:o}"));
    }
    Ok(kept)
}

/// Points the place of `change` at `to` instead of `from`. Idempotent: a place already rewritten
/// is left as it is.
pub fn apply(change: &Change, root: &Path, from: &Path, to: &Path) -> Result<()> {
    let path = change.location(root);
    if change.kind == "link" {
        let target = fs::read_link(&path)?;
        if let Ok(rest) = target.strip_prefix(from) {
            replace_link(&path, &to.join(rest))?;
        }
        return Ok(());
    }
    let mode = fs::metadata(&path)?.permissions().mode() & 0o7777;
    let text = text_of(&path).ok_or_else(|| anyhow::anyhow!("migration_rewrite_failed"))?;
    if let Some(new) = rewritten(
        &change.place,
        &text,
        &from.to_string_lossy(),
        &to.to_string_lossy(),
    ) {
        replace_file(&path, new.as_bytes(), mode)?;
    }
    Ok(())
}

/// Puts back exactly what `change` found (bytes and permissions, or the link's target).
pub fn undo(change: &Change, root: &Path, originals: &Path) -> Result<()> {
    let path = change.location(root);
    let original = change
        .original
        .as_deref()
        .ok_or_else(|| anyhow::anyhow!("migration_original_missing"))?;
    if change.kind == "link" {
        return replace_link(&path, Path::new(original));
    }
    let (name, mode) = original
        .split_once(':')
        .ok_or_else(|| anyhow::anyhow!("migration_original_missing"))?;
    ensure!(!name.contains('/'), "migration_original_missing");
    let mode = u32::from_str_radix(mode, 8)?;
    let bytes = fs::read(originals.join(name))?;
    replace_file(&path, &bytes, mode)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_whole_path_components_are_replaced() {
        let old = "/U/a/Application Support/Butake Stack";
        let new = "/U/a/Application Support/Stack";
        assert_eq!(
            replace(
                &format!("datadir={old}/data\nsocket={old}/run/x.sock\nother={old} 2/x\n"),
                old,
                new
            )
            .unwrap(),
            format!("datadir={new}/data\nsocket={new}/run/x.sock\nother={old} 2/x\n")
        );
        assert_eq!(
            replace(&format!("<string>{old}</string>"), old, new).unwrap(),
            format!("<string>{new}</string>")
        );
        assert!(replace("nada que ver", old, new).is_none());
        let aws = format!(
            "[profile a]\ncredential_process = \"{old}/bin/x\" aws-credential a\nnote = {old}\n"
        );
        assert_eq!(
            rewritten("aws", &aws, old, new).unwrap(),
            format!("[profile a]\ncredential_process = \"{new}/bin/x\" aws-credential a\nnote = {old}\n")
        );
    }
}

#[cfg(test)]
mod replace_tests {
    use super::*;

    #[test]
    fn a_replaced_file_keeps_its_mode_and_leaves_no_temporary() {
        let dir = tempfile::tempdir().unwrap();
        for mode in [0o600, 0o644, 0o755] {
            let path = dir.path().join(format!("file-{mode:o}"));
            fs::write(&path, "old").unwrap();
            replace_file(&path, b"new", mode).unwrap();
            assert_eq!(fs::read_to_string(&path).unwrap(), "new");
            assert_eq!(
                fs::metadata(&path).unwrap().permissions().mode() & 0o777,
                mode
            );
        }
        assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 3);
    }
}
