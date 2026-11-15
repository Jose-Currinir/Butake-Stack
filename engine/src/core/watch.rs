//! Children that wait on the user or the network (a sign-in in the browser, a check against a
//! server) and must never outlive the request that started them.
//!
//! - The app stops such a request by sending SIGTERM to the engine process it started: the engine
//!   notices ([`stop_requested`]) and ends the child's whole process group.
//! - When the app dies (quit or crash) the engine is handed to launchd: its parent changes and the
//!   engine ends the group the same way.
//! - When the engine itself is killed without a chance to clean up, the record it left in the
//!   store ([`Record`]) lets the next request end the group ([`reap`]). Every process is matched by
//!   its exact pid, process group and start time, never by name.

use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, Instant},
};

static STOP: AtomicBool = AtomicBool::new(false);

extern "C" fn on_stop(_: libc::c_int) {
    STOP.store(true, Ordering::SeqCst);
}

/// From now on SIGTERM, SIGINT and SIGHUP only ask this process to stop (see [`stop_requested`]),
/// and the parent it has now is the one [`stop_requested`] compares against.
pub fn listen() -> libc::pid_t {
    for signal in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP] {
        unsafe {
            libc::signal(
                signal,
                on_stop as extern "C" fn(libc::c_int) as libc::sighandler_t,
            )
        };
    }
    unsafe { libc::getppid() }
}

/// Forgets a stop asked for (tests raise the signal in their own process).
#[cfg(test)]
pub fn clear_stop() {
    STOP.store(false, Ordering::SeqCst);
}

/// The app asked to stop (a signal) or is gone (the engine has another parent now).
pub fn stop_requested(parent: libc::pid_t) -> bool {
    STOP.load(Ordering::SeqCst) || unsafe { libc::getppid() } != parent
}

/// When a process started, in microseconds since 1970 (`None` when it does not exist).
#[cfg(target_os = "macos")]
pub fn started(pid: i32) -> Option<u64> {
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
    let read = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDTBSDINFO,
            0,
            &mut info as *mut _ as *mut libc::c_void,
            size,
        )
    };
    (read == size && info.pbi_pid as i32 == pid)
        .then(|| info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec)
}

#[cfg(not(target_os = "macos"))]
pub fn started(_pid: i32) -> Option<u64> {
    None
}

/// The processes of a group, with their start times.
#[cfg(target_os = "macos")]
fn members(group: i32) -> Vec<(i32, u64)> {
    const PROC_PGRP_ONLY: u32 = 2;
    let mut pids = vec![0i32; 512];
    let bytes = unsafe {
        libc::proc_listpids(
            PROC_PGRP_ONLY,
            group as u32,
            pids.as_mut_ptr() as *mut libc::c_void,
            (pids.len() * std::mem::size_of::<i32>()) as libc::c_int,
        )
    };
    let count = (bytes.max(0) as usize / std::mem::size_of::<i32>()).min(pids.len());
    pids[..count]
        .iter()
        .filter(|pid| **pid > 0)
        .filter_map(|pid| Some((*pid, started(*pid)?)))
        .collect()
}

#[cfg(not(target_os = "macos"))]
fn members(_group: i32) -> Vec<(i32, u64)> {
    vec![]
}

/// Whether any process of the group is still alive.
pub fn group_alive(group: i32) -> bool {
    unsafe { libc::kill(-group, 0) == 0 }
}

/// Ends a process group: SIGTERM, a moment to leave, then SIGKILL. Returns once the group is
/// empty (or after a few seconds, if something in it does not die).
pub fn end_group(group: i32) {
    if group <= 1 {
        return;
    }
    unsafe { libc::kill(-group, libc::SIGTERM) };
    let deadline = Instant::now() + Duration::from_millis(800);
    while group_alive(group) && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(20));
    }
    if group_alive(group) {
        unsafe { libc::kill(-group, libc::SIGKILL) };
    }
}

/// What a request leaves in the store while its child runs: who started it and the child's group.
#[derive(Serialize, Deserialize)]
pub struct Record {
    owner: i32,
    owner_started: u64,
    group: i32,
    group_started: u64,
}

impl Record {
    /// Writes the record of `group` (just started by this process) in `folder`.
    pub fn write(folder: &Path, group: i32) -> Result<PathBuf> {
        let owner = std::process::id() as i32;
        let record = Record {
            owner,
            owner_started: started(owner).unwrap_or_default(),
            group,
            group_started: started(group).unwrap_or_default(),
        };
        let path = folder.join(format!("{owner}-{group}.json"));
        crate::core::fsutil::write_private(&path, &serde_json::to_string(&record)?)?;
        Ok(path)
    }
}

/// Ends the children of requests that died without cleaning up: a record whose owner is gone (or
/// is another process with the same pid) has its group ended, process by process, only those
/// started with or after the recorded child. Records of requests still running stay.
pub fn reap(folder: &Path) {
    let Ok(entries) = fs::read_dir(folder) else {
        return;
    };
    for path in entries.filter_map(|e| e.ok().map(|e| e.path())) {
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let record = fs::read_to_string(&path)
            .ok()
            .and_then(|text| serde_json::from_str::<Record>(&text).ok());
        let Some(record) = record else {
            let _ = fs::remove_file(&path);
            continue;
        };
        if record.owner_started != 0 && started(record.owner) == Some(record.owner_started) {
            continue;
        }
        if record.group > 1 && record.group_started != 0 {
            for (pid, start) in members(record.group) {
                if start >= record.group_started {
                    unsafe { libc::kill(pid, libc::SIGKILL) };
                }
            }
        }
        let _ = fs::remove_file(&path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{os::unix::process::CommandExt, process::Command};

    #[test]
    fn a_record_left_by_a_dead_request_ends_its_group_only() {
        let temp = tempfile::tempdir().unwrap();
        // A group with a child and a grandchild, as an AWS CLI that started something.
        let mut child = Command::new("/bin/sh")
            .args(["-c", "/bin/sleep 30 & /bin/sleep 30"])
            .process_group(0)
            .spawn()
            .unwrap();
        let group = child.id() as i32;
        std::thread::sleep(Duration::from_millis(100));
        let path = Record::write(temp.path(), group).unwrap();
        // While its owner (this process) lives, the record stays and the group runs.
        reap(temp.path());
        assert!(path.exists() && group_alive(group));
        // An owner that is gone: the next request ends the group.
        let mut record: Record = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        record.owner_started += 1;
        fs::write(&path, serde_json::to_string(&record).unwrap()).unwrap();
        reap(temp.path());
        let _ = child.wait();
        let deadline = Instant::now() + Duration::from_secs(3);
        while group_alive(group) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(!group_alive(group) && !path.exists());
    }
}
