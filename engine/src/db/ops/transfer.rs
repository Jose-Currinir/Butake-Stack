//! What backups, restores, imports and exports share: the progress file the app reads while a
//! long run goes on, and the destination a user picks.

use super::*;

/// Progress of a long run, read by the app while it waits: run/progress-<token>.json.
pub(super) struct Progress {
    path: Option<PathBuf>,
    total: u64,
    last: Instant,
    /// What `done` counts: bytes, or rows (exports, CSV imports).
    unit: &'static str,
}
impl Progress {
    pub(super) fn new(store: &Store, token: &str, total: u64) -> Result<Self> {
        let path = if token.is_empty() {
            None
        } else {
            ensure!(
                token.len() <= 40
                    && token
                        .bytes()
                        .all(|c| c.is_ascii_alphanumeric() || c == b'-'),
                "invalid_request"
            );
            Some(
                store
                    .directory("run")?
                    .join(format!("progress-{token}.json")),
            )
        };
        Ok(Self {
            path,
            total,
            last: Instant::now() - Duration::from_secs(1),
            unit: "bytes",
        })
    }
    pub(super) fn rows(mut self) -> Self {
        self.unit = "rows";
        self
    }
    pub(super) fn report(&mut self, done: u64, step: &str, force: bool) {
        if let Some(path) = &self.path {
            if force || self.last.elapsed() > Duration::from_millis(300) {
                self.last = Instant::now();
                let _ = write_private(
                    path,
                    &json!({"done": done, "total": self.total, "step": step, "unit": self.unit})
                        .to_string(),
                );
            }
        }
    }
}
impl Drop for Progress {
    fn drop(&mut self) {
        if let Some(path) = &self.path {
            let _ = std::fs::remove_file(path);
        }
    }
}

/// Destination chosen by the user in the save panel: absolute, in an existing folder.
pub(super) fn destination(path: &str) -> Result<PathBuf> {
    let path = PathBuf::from(path);
    ensure!(
        path.is_absolute() && path.file_name().is_some() && path.parent().is_some_and(Path::is_dir),
        "invalid_file"
    );
    ensure!(
        !std::fs::symlink_metadata(&path).is_ok_and(|m| m.file_type().is_symlink()),
        "invalid_file"
    );
    Ok(path)
}
