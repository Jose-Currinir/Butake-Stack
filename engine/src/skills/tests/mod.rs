//! The skills tool with a temporary Stack folder and a temporary home: nothing of the real AI folders.
mod dispatch;
mod health_export;
mod import;
mod import_trash;
mod links;
mod plans;
mod skills;
mod trash_groups;

use super::dispatch_in;
use crate::core::store::Store;
use serde_json::{Value, json};
use std::path::PathBuf;

pub struct Env {
    /// Kept only so the folder lives as long as the test; paths come from `root`.
    _temp: tempfile::TempDir,
    /// The temporary folder with its links resolved. macOS's default `TMPDIR` (`/var/folders/…`)
    /// is itself a link to `/private/var/folders/…`, and the engine answers canonical paths, so
    /// every path a test builds or compares starts here.
    pub root: PathBuf,
    pub store: Store,
    pub home: PathBuf,
}

pub fn env() -> Env {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().canonicalize().unwrap();
    let home = root.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let store = Store::new(root.join("store")).unwrap();
    Env {
        _temp: temp,
        root,
        store,
        home,
    }
}

impl Env {
    pub fn call(&self, method: &str, request: Value) -> anyhow::Result<Value> {
        dispatch_in(&self.store, &self.home, method, &request)
    }
    pub fn ok(&self, method: &str, request: Value) -> Value {
        self.call(method, request).unwrap()
    }
    pub fn code(&self, method: &str, request: Value) -> String {
        self.call(method, request).unwrap_err().to_string()
    }
    pub fn skills_dir(&self) -> PathBuf {
        self.store.root().join("skills")
    }
    pub fn create(&self, id: &str) -> Value {
        self.ok(
            "skillsCreate",
            json!({"id": id, "group": "personal", "template": "blank", "name": id, "description": "Hace algo"}),
        )
    }
    /// Links `skill` into `agent` through the plan/apply pair.
    pub fn link(&self, skill: &str, agent: &str) -> Value {
        self.ok(
            "skillsLinkApply",
            json!({"changes": [{"skill": skill, "agent": agent, "on": true}], "confirmed": true}),
        )
    }
    pub fn link_path(&self, agent_folder: &str, skill: &str) -> PathBuf {
        self.home.join(agent_folder).join(skill)
    }
}
