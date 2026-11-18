//! Shared types of the skills tool: the context of one request, the index and the limits.
use crate::core::{store::Store, validate};
use anyhow::{Result, anyhow};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
};

pub const INDEX_VERSION: u32 = 1;
/// Largest SKILL.md the tool reads, saves or exports.
pub const MAX_TEXT: u64 = 256 * 1024;
pub const MAX_ID: usize = 64;
pub const TRASH_DAYS: u64 = 30;

/// A skill or group id: `[a-z0-9-]`, 1 to 64 characters, not starting or ending with a dash.
pub fn valid_id(id: &str) -> bool {
    validate::id(id, MAX_ID) && !id.starts_with('-') && !id.ends_with('-')
}

/// An error carrying only a fixed code (the app shows `error.<code>`).
pub fn fail<T>(code: &str) -> Result<T> {
    Err(anyhow!(code.to_string()))
}

/// Where one request works: Stack's data folder and the (canonical) home the AI folders live under.
/// Tests build it with temporary folders; the engine builds it from the real home.
pub struct Ctx {
    pub root: PathBuf,
    pub skills: PathBuf,
    pub trash: PathBuf,
    pub home: PathBuf,
}

impl Ctx {
    pub fn new(store: &Store, home: &Path) -> Result<Self> {
        let home = home
            .canonicalize()
            .map_err(|_| anyhow!("home_unavailable"))?;
        Ok(Self {
            root: store.root().to_path_buf(),
            skills: store.directory("skills")?,
            trash: store.directory("skills-trash")?,
            home,
        })
    }

    /// The folder of a skill; the id is validated, so it can never leave the skills folder.
    pub fn dir(&self, id: &str) -> Result<PathBuf> {
        if !valid_id(id) {
            return fail("skills_invalid_id");
        }
        Ok(self.skills.join(id))
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Group {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub order: i64,
}

fn yes() -> bool {
    true
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Entry {
    pub group: String,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default = "yes")]
    pub enabled: bool,
    #[serde(default)]
    pub agents: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AgentCfg {
    pub folder: String,
    /// Only custom agents carry a name; the built-in ones have theirs in the code.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Index {
    pub version: u32,
    pub groups: Vec<Group>,
    pub skills: BTreeMap<String, Entry>,
    pub agents: BTreeMap<String, AgentCfg>,
}

impl Index {
    pub fn has_group(&self, id: &str) -> bool {
        self.groups.iter().any(|g| g.id == id)
    }
}
