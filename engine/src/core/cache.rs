//! Local cache of remote catalogs (PHP builds, tool versions, lifecycles): a small JSON file per
//! catalog under `cache/`, so pages open at once and GitHub and the other sources are asked only
//! when the copy is old. Offline, the last copy is used. `force` (the reload button) skips it.
use crate::core::fsutil::write_private;
use crate::core::store::Store;
use crate::core::time::now_secs;
use anyhow::{Result, ensure};
use serde_json::{Value, json};
use std::fs;

/// The copy on disk of a catalog, however old, with when it was fetched.
pub fn peek(store: &Store, key: &str) -> Option<(Value, u64)> {
    let file = store.directory("cache").ok()?.join(format!("{key}.json"));
    let entry: Value = fs::symlink_metadata(&file)
        .ok()
        .filter(|m| m.is_file() && m.len() <= 8 * 1024 * 1024)
        .and_then(|_| fs::read(&file).ok())
        .and_then(|data| serde_json::from_slice(&data).ok())?;
    Some((entry["value"].clone(), entry["fetched_at"].as_u64()?))
}

pub fn cached(
    store: &Store,
    key: &str,
    ttl: u64,
    force: bool,
    fetch: impl FnOnce() -> Result<Value>,
) -> Result<Value> {
    ensure!(
        !key.is_empty()
            && key.len() <= 64
            && key
                .bytes()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-' || c == b'.'),
        "invalid_cache_key"
    );
    let file = store.directory("cache")?.join(format!("{key}.json"));
    let previous: Option<Value> = fs::symlink_metadata(&file)
        .ok()
        .filter(|m| m.is_file() && m.len() <= 8 * 1024 * 1024)
        .and_then(|_| fs::read(&file).ok())
        .and_then(|data| serde_json::from_slice(&data).ok());
    if let Some(entry) = &previous {
        let fresh = entry["fetched_at"]
            .as_u64()
            .is_some_and(|t| now_secs().saturating_sub(t) < ttl);
        if fresh && !force {
            return Ok(entry["value"].clone());
        }
    }
    match fetch() {
        Ok(value) => {
            let _ = write_private(
                &file,
                &json!({"fetched_at": now_secs(), "value": value}).to_string(),
            );
            Ok(value)
        }
        // No network or a rate limit: the last good copy beats an error.
        Err(error) => previous.map(|entry| entry["value"].clone()).ok_or(error),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn serves_fresh_copies_refreshes_and_falls_back_offline() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::new(temp.path().join("store")).unwrap();
        let calls = std::cell::Cell::new(0);
        let fetch = |v: i64| {
            calls.set(calls.get() + 1);
            Ok(json!(v))
        };
        assert_eq!(
            cached(&store, "demo", 3600, false, || fetch(1)).unwrap(),
            json!(1)
        );
        assert_eq!(
            cached(&store, "demo", 3600, false, || fetch(2)).unwrap(),
            json!(1),
            "fresh copy, no fetch"
        );
        assert_eq!(calls.get(), 1);
        assert_eq!(
            cached(&store, "demo", 3600, true, || fetch(3)).unwrap(),
            json!(3),
            "forced refresh"
        );
        assert_eq!(
            cached(&store, "demo", 0, false, || anyhow::bail!("offline")).unwrap(),
            json!(3),
            "offline: last copy"
        );
        assert!(cached(&store, "otro", 0, false, || anyhow::bail!("offline")).is_err());
        assert!(cached(&store, "../x", 0, false, || fetch(4)).is_err());
    }
}
