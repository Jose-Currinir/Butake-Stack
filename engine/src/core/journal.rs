//! A change of several of Stack's own files that is applied whole or not at all: each step
//! remembers what was there, and [`Journal::rollback`] puts it back in reverse order. Used where
//! one action touches many files (renaming or moving a project).

use super::{fsutil, json};
use anyhow::{ensure, Result};
use serde::Serialize;
use std::{
    fs,
    path::{Path, PathBuf},
};

enum Undo {
    /// The file's content before the step (`None`: it did not exist).
    Restore(PathBuf, Option<Vec<u8>>),
    /// A file moved from `.0` to `.1`.
    Moved(PathBuf, PathBuf),
}

#[derive(Default)]
pub struct Journal {
    undo: Vec<Undo>,
}

#[cfg(test)]
thread_local! {
    /// Tests only: the step that fails, counting from 1, to prove nothing is left half done.
    pub static FAIL_AT: std::cell::Cell<Option<usize>> = const { std::cell::Cell::new(None) };
}

impl Journal {
    pub fn new() -> Self {
        Self::default()
    }

    fn step(&self) -> Result<()> {
        #[cfg(test)]
        if FAIL_AT.with(|fail| fail.get()) == Some(self.undo.len() + 1) {
            anyhow::bail!("journal_test_failure");
        }
        Ok(())
    }

    /// What `path` holds now: a regular file (never a link) or nothing.
    fn current(path: &Path) -> Result<Option<Vec<u8>>> {
        match fs::symlink_metadata(path) {
            Ok(meta) => {
                ensure!(meta.is_file(), "unsafe_store_path");
                Ok(Some(fs::read(path)?))
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error.into()),
        }
    }

    /// Replaces `path` with `value` as JSON (private, atomic).
    pub fn write_json<T: Serialize + ?Sized>(&mut self, path: &Path, value: &T) -> Result<()> {
        self.step()?;
        let before = Self::current(path)?;
        json::write(path, value)?;
        self.undo.push(Undo::Restore(path.to_path_buf(), before));
        Ok(())
    }

    /// Replaces `path` with `content` (private, atomic).
    pub fn write_bytes(&mut self, path: &Path, content: &[u8]) -> Result<()> {
        self.step()?;
        let before = Self::current(path)?;
        fsutil::write_private_bytes(path, content)?;
        self.undo.push(Undo::Restore(path.to_path_buf(), before));
        Ok(())
    }

    /// Moves a regular file to a name that is free (`target_exists` otherwise).
    pub fn rename(&mut self, from: &Path, to: &Path) -> Result<()> {
        self.step()?;
        ensure!(
            fs::symlink_metadata(from).is_ok_and(|m| m.is_file()),
            "unsafe_store_path"
        );
        ensure!(fs::symlink_metadata(to).is_err(), "target_exists");
        fs::rename(from, to)?;
        self.undo
            .push(Undo::Moved(from.to_path_buf(), to.to_path_buf()));
        Ok(())
    }

    /// Removes a regular file, keeping its content to put it back.
    pub fn remove(&mut self, path: &Path) -> Result<()> {
        self.step()?;
        let Some(before) = Self::current(path)? else {
            return Ok(());
        };
        fs::remove_file(path)?;
        self.undo
            .push(Undo::Restore(path.to_path_buf(), Some(before)));
        Ok(())
    }

    /// Puts every file back as it was, last step first. Best effort: a step that cannot be
    /// undone does not stop the others.
    pub fn rollback(self) {
        for undo in self.undo.into_iter().rev() {
            match undo {
                Undo::Restore(path, Some(content)) => {
                    let _ = fsutil::write_private_bytes(&path, &content);
                }
                Undo::Restore(path, None) => {
                    let _ = fs::remove_file(path);
                }
                Undo::Moved(from, to) => {
                    let _ = fs::rename(to, from);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_failed_change_leaves_every_file_as_it_was() {
        let dir = tempfile::tempdir().unwrap();
        let (a, b, c, d) = (
            dir.path().join("a.json"),
            dir.path().join("b.log"),
            dir.path().join("c.log"),
            dir.path().join("new.json"),
        );
        fs::write(&a, "[1]").unwrap();
        fs::write(&b, "uno").unwrap();
        fs::write(&c, "dos").unwrap();
        let mut journal = Journal::new();
        journal.write_json(&a, &[2]).unwrap();
        journal.rename(&b, &dir.path().join("b2.log")).unwrap();
        journal.remove(&c).unwrap();
        journal.write_bytes(&d, b"nuevo").unwrap();
        assert!(journal.rename(&a, &d).is_err(), "never over another file");
        assert_eq!(journal.undo.len(), 4);
        journal.rollback();
        assert_eq!(fs::read_to_string(&a).unwrap(), "[1]");
        assert_eq!(fs::read_to_string(&b).unwrap(), "uno");
        assert_eq!(fs::read_to_string(&c).unwrap(), "dos");
        assert!(!d.exists() && !dir.path().join("b2.log").exists());
        let link = dir.path().join("link");
        std::os::unix::fs::symlink(&a, &link).unwrap();
        assert!(Journal::new().write_bytes(&link, b"x").is_err());
    }
}
