//! The message store: one `.eml` per message in `mail/` (0600), retention and the id format.
use crate::core::fsutil::private_options;
use crate::core::model::MailConfig;
use crate::core::time::now_millis;
use anyhow::{Result, ensure};
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
    time::Duration,
};

static SEQUENCE: AtomicU64 = AtomicU64::new(0);

/// Message ids are `<millis>-<sequence>`: digits and one dash, nothing that can leave the folder.
fn validate_id(id: &str) -> Result<()> {
    let mut parts = id.split('-');
    let ok = id.len() <= 40
        && matches!((parts.next(), parts.next(), parts.next()), (Some(a), Some(b), None)
            if !a.is_empty() && !b.is_empty() && a.bytes().chain(b.bytes()).all(|c| c.is_ascii_digit()));
    ensure!(ok, "invalid_message");
    Ok(())
}

pub(super) fn ids(dir: &Path) -> Vec<String> {
    let mut ids: Vec<String> = fs::read_dir(dir)
        .map(|entries| {
            entries
                .flatten()
                .filter_map(|e| {
                    e.file_name()
                        .to_str()?
                        .strip_suffix(".eml")
                        .map(str::to_string)
                })
                .filter(|id| validate_id(id).is_ok())
                .collect()
        })
        .unwrap_or_default();
    // Newest first: ids start with the arrival time.
    ids.sort_by_key(|id| {
        std::cmp::Reverse(
            id.split('-')
                .map(|p| p.parse::<u128>().unwrap_or(0))
                .collect::<Vec<_>>(),
        )
    });
    ids
}

/// Removes expired messages and the oldest beyond the limit.
pub(super) fn prune(dir: &Path, config: &MailConfig) {
    // A temporary file left by an interrupted save (never one still being written).
    if let Ok(entries) = fs::read_dir(dir) {
        for entry in entries.flatten() {
            let name = entry.file_name();
            let stale = name
                .to_str()
                .is_some_and(|n| n.starts_with('.') && n.ends_with(".tmp"))
                && entry
                    .metadata()
                    .and_then(|m| m.modified())
                    .ok()
                    .and_then(|t| t.elapsed().ok())
                    .is_some_and(|age| age > Duration::from_secs(3600));
            if stale {
                let _ = fs::remove_file(entry.path());
            }
        }
    }
    let cutoff = now_millis().saturating_sub(config.retention_days as u128 * 86_400_000);
    for (index, id) in ids(dir).iter().enumerate() {
        let time: u128 = id
            .split('-')
            .next()
            .and_then(|t| t.parse().ok())
            .unwrap_or(0);
        if index >= config.max_messages as usize || time < cutoff {
            let _ = fs::remove_file(dir.join(format!("{id}.eml")));
        }
    }
}

/// Keeps one message: written to a temporary name and renamed, so readers never see half of it.
pub(super) fn save(
    dir: &Path,
    envelope_from: &str,
    recipients: &[String],
    data: &[u8],
    config: &MailConfig,
) -> Result<String> {
    let id = format!(
        "{}-{}",
        now_millis(),
        SEQUENCE.fetch_add(1, Ordering::Relaxed)
    );
    let temporary = dir.join(format!(".{id}.tmp"));
    let mut file = private_options().create_new(true).open(&temporary)?;
    // The envelope (Bcc recipients only exist there) as headers of our own, before the message.
    let clean = |s: &str| {
        s.chars()
            .filter(|c| !c.is_control())
            .take(320)
            .collect::<String>()
    };
    write!(
        file,
        "X-Butake-Envelope-From: {}\r\nX-Butake-Envelope-To: {}\r\n",
        clean(envelope_from),
        clean(&recipients.join(", "))
    )?;
    file.write_all(data)?;
    file.sync_all()?;
    fs::rename(&temporary, dir.join(format!("{id}.eml")))?;
    prune(dir, config);
    Ok(id)
}

pub fn count(dir: &Path) -> usize {
    ids(dir).len()
}

pub(super) fn message_path(dir: &Path, id: &str) -> Result<PathBuf> {
    validate_id(id)?;
    let path = dir.join(format!("{id}.eml"));
    ensure!(
        path.is_file() && !path.symlink_metadata()?.file_type().is_symlink(),
        "message_not_found"
    );
    Ok(path)
}

pub fn delete(dir: &Path, id: Option<&str>) -> Result<()> {
    match id {
        Some(id) => fs::remove_file(message_path(dir, id)?)?,
        None => {
            for id in ids(dir) {
                let _ = fs::remove_file(dir.join(format!("{id}.eml")));
            }
        }
    }
    Ok(())
}
