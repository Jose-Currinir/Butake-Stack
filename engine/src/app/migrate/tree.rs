//! The folder as a tree: its size, a verifiable backup (APFS clones on the same volume, copies
//! checked by SHA-256 otherwise) and the free space of a volume.

use anyhow::{ensure, Result};
use std::{
    collections::BTreeMap,
    ffi::CString,
    fs,
    os::unix::{
        ffi::OsStrExt,
        fs::{MetadataExt, PermissionsExt},
    },
    path::{Path, PathBuf},
};

/// What a backup must reproduce of each entry: its type, size, permissions and link target.
#[derive(Debug, PartialEq, Eq)]
enum Entry {
    Folder(u32),
    File(u64, u32),
    Link(PathBuf),
}

/// Every entry under `root` by its relative path. Sockets and pipes are left out: they belong to
/// running processes, which are stopped by then, and a copy of them means nothing.
fn entries(root: &Path) -> Result<BTreeMap<PathBuf, Entry>> {
    let mut found = BTreeMap::new();
    let mut pending = vec![root.to_path_buf()];
    while let Some(folder) = pending.pop() {
        for item in fs::read_dir(&folder)? {
            let item = item?;
            let path = item.path();
            let meta = fs::symlink_metadata(&path)?;
            let relative = path.strip_prefix(root)?.to_path_buf();
            let mode = meta.permissions().mode() & 0o7777;
            if meta.file_type().is_symlink() {
                found.insert(relative, Entry::Link(fs::read_link(&path)?));
            } else if meta.is_dir() {
                found.insert(relative, Entry::Folder(mode));
                pending.push(path);
            } else if meta.is_file() {
                found.insert(relative, Entry::File(meta.len(), mode));
            }
        }
    }
    Ok(found)
}

/// Bytes and files under `root` (links count as nothing).
pub fn size(root: &Path) -> Result<(u64, u64)> {
    let mut bytes = 0;
    let mut files = 0;
    for entry in entries(root)?.values() {
        if let Entry::File(length, _) = entry {
            bytes += length;
            files += 1;
        }
    }
    Ok((bytes, files))
}

/// Free bytes for the user on the volume of `path`.
pub fn free_space(path: &Path) -> Result<u64> {
    let text = CString::new(path.as_os_str().as_bytes())?;
    // SAFETY: `statvfs` is a plain C struct of integers, for which all-zero bytes are valid.
    let mut stat: libc::statvfs = unsafe { std::mem::zeroed() };
    ensure!(
        // SAFETY: `text` is a NUL-terminated `CString` alive for the call and `stat` is a live,
        // writable `statvfs`; the call only reads the path and fills the struct.
        unsafe { libc::statvfs(text.as_ptr(), &mut stat) } == 0,
        std::io::Error::last_os_error()
    );
    Ok(stat.f_bavail as u64 * stat.f_frsize as u64)
}

/// Whether two existing paths are on the same volume (a rename between them is atomic).
pub fn same_volume(a: &Path, b: &Path) -> Result<bool> {
    Ok(fs::metadata(a)?.dev() == fs::metadata(b)?.dev())
}

/// clonefile(2) without following a link at the source: the copy shares the blocks (APFS).
fn clone(from: &Path, to: &Path) -> bool {
    const CLONE_NOFOLLOW: u32 = 0x0001;
    let (Ok(from), Ok(to)) = (
        CString::new(from.as_os_str().as_bytes()),
        CString::new(to.as_os_str().as_bytes()),
    ) else {
        return false;
    };
    // SAFETY: `from` and `to` are NUL-terminated `CString`s alive for the call; `clonefile` only
    // reads the two paths.
    unsafe { libc::clonefile(from.as_ptr(), to.as_ptr(), CLONE_NOFOLLOW) == 0 }
}

/// How a backup was made.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Backup {
    pub files: u64,
    pub cloned: u64,
    pub copied: u64,
}

/// Copies `from` into the new folder `to` (which must not exist): each file is an APFS clone
/// when the volume allows it, a plain copy otherwise; then the copy is verified entry by entry
/// (type, size, permissions, link target) and every plain copy by its SHA-256. A copy that does
/// not verify is an error; the caller removes it.
pub fn backup(from: &Path, to: &Path) -> Result<Backup> {
    ensure!(!to.exists(), "migration_backup_failed");
    let source = entries(from)?;
    let mut done = Backup::default();
    let mut copied = vec![];
    fs::create_dir(to)?;
    fs::set_permissions(to, fs::Permissions::from_mode(0o700))?;
    for (relative, entry) in &source {
        let (origin, target) = (from.join(relative), to.join(relative));
        match entry {
            Entry::Folder(_) => fs::create_dir(&target)?,
            Entry::Link(destination) => std::os::unix::fs::symlink(destination, &target)?,
            Entry::File(..) => {
                done.files += 1;
                if clone(&origin, &target) {
                    done.cloned += 1;
                } else {
                    fs::copy(&origin, &target)?;
                    done.copied += 1;
                    copied.push(relative.clone());
                }
            }
        }
    }
    // Permissions last, deepest first: a read-only folder must not stop its own contents.
    for (relative, entry) in source.iter().rev() {
        if let Entry::Folder(mode) | Entry::File(_, mode) = entry {
            fs::set_permissions(to.join(relative), fs::Permissions::from_mode(*mode))?;
        }
    }
    fs::set_permissions(
        to,
        fs::Permissions::from_mode(fs::metadata(from)?.permissions().mode() & 0o7777),
    )?;
    ensure!(entries(to)? == source, "migration_backup_failed");
    for relative in copied {
        ensure!(
            crate::core::hash::sha256_file(&from.join(&relative))?
                == crate::core::hash::sha256_file(&to.join(&relative))?,
            "migration_backup_failed"
        );
    }
    Ok(done)
}

/// Removes `root` only if it holds nothing but empty folders (what a process that resolved the
/// old folder a moment before the move may leave behind). Anything else is kept.
pub fn remove_if_empty(root: &Path) -> Result<bool> {
    if !root.is_dir() || fs::symlink_metadata(root)?.file_type().is_symlink() {
        return Ok(false);
    }
    let found = entries(root)?;
    if found.values().any(|e| !matches!(e, Entry::Folder(_))) {
        return Ok(false);
    }
    fs::remove_dir_all(root)?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_backup_reproduces_the_tree_and_verifies() {
        let temp = tempfile::tempdir().unwrap();
        let from = temp.path().join("datos");
        fs::create_dir_all(from.join("data/mysql")).unwrap();
        fs::write(from.join("data/mysql/ibdata1"), vec![7u8; 70_000]).unwrap();
        fs::write(from.join("stack.json"), "{}").unwrap();
        fs::set_permissions(from.join("stack.json"), fs::Permissions::from_mode(0o600)).unwrap();
        std::os::unix::fs::symlink("data/mysql", from.join("enlace")).unwrap();
        let to = temp.path().join("copia");
        let done = backup(&from, &to).unwrap();
        assert_eq!(done.files, 2);
        assert_eq!(done.cloned + done.copied, 2);
        assert_eq!(entries(&from).unwrap(), entries(&to).unwrap());
        assert_eq!(
            fs::read(to.join("data/mysql/ibdata1")).unwrap(),
            vec![7u8; 70_000]
        );
        assert_eq!(size(&from).unwrap(), (70_002, 2));
        assert!(backup(&from, &to).is_err(), "never over an existing folder");
        assert!(!remove_if_empty(&to).unwrap());
        let empty = temp.path().join("vacia");
        fs::create_dir_all(empty.join("projects")).unwrap();
        assert!(remove_if_empty(&empty).unwrap() && !empty.exists());
    }
}
