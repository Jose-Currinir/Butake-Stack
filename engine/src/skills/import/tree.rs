//! Digest of a skill folder for the import: every regular file is hashed, links are never followed
//! and never counted (the copy skips them too, so they are listed in `skipped` to warn about them),
//! with the same limits as `skill_file::copy_tree`.
use crate::skills::model::fail;
use anyhow::Result;
use sha2::{Digest, Sha256};
use std::{collections::BTreeMap, fs, io::Read, os::unix::fs::OpenOptionsExt, path::Path};

const MAX_DEPTH: usize = 6;
const MAX_FILES: usize = 500;
pub const MAX_BYTES: u64 = 10 * 1024 * 1024;

pub struct Tree {
    /// Relative path of every regular file with the SHA-256 of its bytes.
    pub files: BTreeMap<String, String>,
    pub bytes: u64,
    /// Relative path of every link and special file the copy leaves out (sorted, at most 200).
    pub skipped: Vec<String>,
    /// One digest of the whole listing.
    pub hash: String,
}

fn file_hash(path: &Path) -> Result<String> {
    let mut file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    if !file.metadata()?.is_file() {
        return fail("unsafe_store_path");
    }
    let mut hash = Sha256::new();
    let mut buffer = [0u8; 65536];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        hash.update(&buffer[..count]);
    }
    Ok(hex(&hash.finalize()))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn walk(base: &Path, dir: &Path, depth: usize, tree: &mut Tree) -> Result<()> {
    if depth > MAX_DEPTH {
        return fail("skills_too_large");
    }
    for item in fs::read_dir(dir)?.flatten() {
        let kind = item.file_type()?;
        let path = item.path();
        if kind.is_dir() {
            walk(base, &path, depth + 1, tree)?;
        } else if kind.is_file() {
            tree.bytes += item.metadata()?.len();
            if tree.files.len() >= MAX_FILES || tree.bytes > MAX_BYTES {
                return fail("skills_too_large");
            }
            let rel = path
                .strip_prefix(base)
                .map(|p| p.to_string_lossy().to_string())
                .unwrap_or_default();
            tree.files.insert(rel, file_hash(&path)?);
        } else if tree.skipped.len() < 200 {
            let rel = path
                .strip_prefix(base)
                .map(|p| p.to_string_lossy().to_string())
                .unwrap_or_default();
            tree.skipped.push(rel);
        }
    }
    Ok(())
}

/// Hashes the folder `root` (a real folder, not a link).
pub fn digest(root: &Path) -> Result<Tree> {
    let mut tree = Tree {
        files: BTreeMap::new(),
        bytes: 0,
        skipped: vec![],
        hash: String::new(),
    };
    walk(root, root, 0, &mut tree)?;
    tree.skipped.sort();
    let mut all = Sha256::new();
    for (rel, hash) in &tree.files {
        all.update(rel.as_bytes());
        all.update([0]);
        all.update(hash.as_bytes());
        all.update(b"\n");
    }
    tree.hash = hex(&all.finalize());
    Ok(tree)
}
