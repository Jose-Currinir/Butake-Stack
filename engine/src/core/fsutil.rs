//! Private (0600) files: atomic replacement, fresh log files and the open options the rest
//! of the engine builds on.

use anyhow::Result;
use std::{
    fs::{self, File, OpenOptions},
    io::Write,
    os::unix::fs::OpenOptionsExt,
    path::Path,
    sync::atomic::{AtomicU64, Ordering},
};

static SEQUENCE: AtomicU64 = AtomicU64::new(0);

/// Open options for writing a file only the user can read; callers add `create`, `truncate`...
pub fn private_options() -> OpenOptions {
    let mut options = OpenOptions::new();
    options.write(true).mode(0o600);
    options
}

/// Replaces `path` atomically with `content`, readable only by the user: written to a private
/// temporary file next to it, flushed, renamed over the target, and the folder flushed.
pub fn write_private_bytes(path: &Path, content: &[u8]) -> Result<()> {
    let temporary = path.with_extension(format!(
        "{}.{}.tmp",
        std::process::id(),
        SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ));
    let result = (|| -> Result<()> {
        let mut file = private_options().create_new(true).open(&temporary)?;
        file.write_all(content)?;
        file.sync_all()?;
        fs::rename(&temporary, path)?;
        if let Some(folder) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
            File::open(folder)?.sync_all()?;
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(temporary);
    }
    result
}

/// [`write_private_bytes`] for text.
pub fn write_private(path: &Path, content: &str) -> Result<()> {
    write_private_bytes(path, content.as_bytes())
}

/// A fresh file (any previous one is removed), readable only by the user: for the stderr of
/// child processes, which names hosts and users.
pub fn private_log(path: &Path) -> Result<File> {
    let _ = fs::remove_file(path);
    Ok(private_options().create_new(true).open(path)?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn writes_are_private_atomic_and_leave_no_temporaries() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("a.json");
        write_private(&file, "one").unwrap();
        write_private(&file, "two").unwrap();
        assert_eq!(fs::read_to_string(&file).unwrap(), "two");
        assert_eq!(
            fs::metadata(&file).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 1);
    }

    #[test]
    fn a_failed_write_leaves_the_target_and_no_temporary() {
        let dir = tempfile::tempdir().unwrap();
        assert!(write_private(&dir.path().join("missing/a"), "x").is_err());
        assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 0);
    }

    #[test]
    fn private_log_starts_empty_and_private() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("log");
        fs::write(&path, "old").unwrap();
        drop(private_log(&path).unwrap());
        assert_eq!(fs::read_to_string(&path).unwrap(), "");
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
}
