//! JSON files on disk: read whole, written pretty-printed through a private atomic write.

use super::fsutil;
use anyhow::{ensure, Result};
use serde::{de::DeserializeOwned, Serialize};
use std::{fs, path::Path};

/// Reads and parses a JSON file.
pub fn read<T: DeserializeOwned>(path: &Path) -> Result<T> {
    Ok(serde_json::from_slice(&fs::read(path)?)?)
}

/// [`read`] for the stack's own data files: a symbolic link is refused (`unsafe_store_path`),
/// and so is a file above `max` bytes (`store_too_large`) when a limit is given.
pub fn read_regular<T: DeserializeOwned>(path: &Path, max: Option<u64>) -> Result<T> {
    ensure!(
        !fs::symlink_metadata(path)?.file_type().is_symlink(),
        "unsafe_store_path"
    );
    if let Some(max) = max {
        ensure!(fs::metadata(path)?.len() <= max, "store_too_large");
    }
    read(path)
}

/// Writes `value` as pretty JSON, readable only by the user, replacing the file atomically.
pub fn write<T: Serialize + ?Sized>(path: &Path, value: &T) -> Result<()> {
    fsutil::write_private_bytes(path, &serde_json::to_vec_pretty(value)?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn round_trips_privately_and_reports_bad_files() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("a.json");
        write(&file, &vec!["a", "b"]).unwrap();
        assert_eq!(read::<Vec<String>>(&file).unwrap(), ["a", "b"]);
        assert_eq!(
            fs::metadata(&file).unwrap().permissions().mode() & 0o777,
            0o600
        );
        fs::write(&file, "{").unwrap();
        assert!(read::<Vec<String>>(&file).is_err());
        assert!(read::<Vec<String>>(&dir.path().join("none")).is_err());
        write(&file, &vec!["a"; 10]).unwrap();
        assert!(read_regular::<Vec<String>>(&file, Some(5)).is_err());
        assert_eq!(read_regular::<Vec<String>>(&file, None).unwrap().len(), 10);
        let link = dir.path().join("link.json");
        std::os::unix::fs::symlink(&file, &link).unwrap();
        assert!(read_regular::<Vec<String>>(&link, None).is_err());
    }
}
