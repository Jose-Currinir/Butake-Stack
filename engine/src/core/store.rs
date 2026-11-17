use crate::core::json;
use crate::core::model::{Project, StackConfig, validate_id};
use anyhow::{Result, ensure};
use serde::{Serialize, de::DeserializeOwned};
use std::{
    fs::{self, OpenOptions},
    os::fd::AsRawFd,
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
};

/// Names of the data folder in `~/Library/Application Support`.
pub const DATA_FOLDER: &str = "Stack";
pub const OLD_DATA_FOLDER: &str = "Butake Stack";

pub struct Store {
    root: PathBuf,
}

impl Store {
    /// The user's real home folder: the one place the engine asks for it (`~/.ssh`, the
    /// launch agent, the environment of child processes).
    pub fn home() -> Option<PathBuf> {
        dirs::home_dir()
    }
    pub fn root(&self) -> &Path {
        &self.root
    }
    pub fn from_environment() -> Result<Self> {
        let root = match std::env::var_os("BUTAKE_STACK_HOME") {
            Some(root) => PathBuf::from(root),
            None => {
                Self::resolve(&Self::home().ok_or_else(|| anyhow::anyhow!("home_unavailable"))?)
            }
        };
        Self::new(root)
    }
    /// Where the data of `home` lives, the one rule for the engine and the app (`Folder` in
    /// Swift): the new folder once it holds Stack's data; else the old folder while it has not been
    /// moved (`migrate-data`), never touched here; else the new one, made by `Store::new`.
    /// `BUTAKE_STACK_HOME` (tests and QA) replaces all of this in `from_environment`.
    pub fn resolve(home: &Path) -> PathBuf {
        let new = Self::data_folder(home);
        let old = Self::old_data_folder(home);
        if !Self::holds_data(&new) && old.is_dir() {
            old
        } else {
            new
        }
    }
    /// `~/Library/Application Support/Stack`.
    pub fn data_folder(home: &Path) -> PathBuf {
        home.join("Library/Application Support").join(DATA_FOLDER)
    }
    /// The folder of the name the product had before (`~/Library/Application Support/Butake Stack`).
    pub fn old_data_folder(home: &Path) -> PathBuf {
        home.join("Library/Application Support")
            .join(OLD_DATA_FOLDER)
    }
    /// A folder holds Stack's data once it has its configuration or its projects.
    pub fn holds_data(root: &Path) -> bool {
        root.join("stack.json").is_file() || root.join("projects").is_dir()
    }
    pub fn new(root: PathBuf) -> Result<Self> {
        ensure!(root.is_absolute(), "invalid_store_path");
        fs::create_dir_all(&root)?;
        let root = root.canonicalize()?;
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700))?;
        let store = Self { root };
        store.directory("projects")?;
        Ok(store)
    }
    pub fn directory(&self, name: &str) -> Result<PathBuf> {
        validate_id(name)?;
        let path = self.root.join(name);
        // Two engine processes may create the same folder at once: losing that race is fine.
        if let Err(error) = fs::create_dir(&path) {
            ensure!(error.kind() == std::io::ErrorKind::AlreadyExists, error);
        }
        ensure!(
            !fs::symlink_metadata(&path)?.file_type().is_symlink() && path.is_dir(),
            "unsafe_store_path"
        );
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700))?;
        Ok(path)
    }
    fn read<T: DeserializeOwned>(&self, path: &Path) -> Result<T> {
        json::read_regular(path, Some(1_048_576))
    }
    fn write(&self, path: &Path, value: &impl Serialize) -> Result<()> {
        json::write(path, value)
    }
    pub fn config(&self) -> Result<StackConfig> {
        let path = self.root.join("stack.json");
        let mut config: StackConfig = if path.try_exists()? {
            self.read(&path)?
        } else {
            StackConfig::default()
        };
        config.drop_retired();
        config.validate()?;
        Ok(config)
    }
    /// The lock every change of the projects' records takes ([`Self::save`], [`Self::delete`]);
    /// a change of several files at once (renaming a project) holds it for the whole change.
    pub(crate) fn mutation_lock(&self) -> Result<fs::File> {
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(self.root.join("settings.lock"))?;
        loop {
            // SAFETY: `flock` takes a descriptor and a flag and touches no memory; the descriptor
            // belongs to `lock`, which is open for the whole call.
            if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) } == 0 {
                return Ok(lock);
            }
            let error = std::io::Error::last_os_error();
            if error.kind() != std::io::ErrorKind::Interrupted {
                return Err(error.into());
            }
        }
    }

    pub fn save_config(&self, config: &StackConfig) -> Result<()> {
        let _lock = self.mutation_lock()?;
        let mut config = config.clone();
        config.drop_retired();
        self.write_config(&config)
    }

    pub fn update_config(
        &self,
        change: impl FnOnce(&mut StackConfig) -> Result<()>,
    ) -> Result<StackConfig> {
        let _lock = self.mutation_lock()?;
        let mut config = self.config()?;
        change(&mut config)?;
        self.write_config(&config)?;
        Ok(config)
    }

    fn write_config(&self, config: &StackConfig) -> Result<()> {
        config.validate()?;
        for project in self.list()? {
            ensure!(
                project
                    .upstream
                    .is_none_or(|port| !config.reserved_ports().contains(&port)),
                "duplicate_port"
            );
            let mut p = project;
            p.validate(config)?;
        }
        self.write(&self.root.join("stack.json"), config)
    }
    pub(crate) fn project_path(&self, id: &str) -> Result<PathBuf> {
        validate_id(id)?;
        Ok(self.directory("projects")?.join(format!("{id}.json")))
    }
    /// A project's record as written, whether its folder is there or not (`get` also validates
    /// it). `unknown_project` when there is none.
    pub fn record(&self, id: &str) -> Result<Project> {
        let file = self.project_path(id)?;
        ensure!(
            fs::symlink_metadata(&file).is_ok_and(|m| m.is_file()),
            "unknown_project"
        );
        let project: Project = self.read(&file)?;
        ensure!(project.id == id, "project_id_mismatch");
        Ok(project)
    }
    /// Every record, its folder there or not, by id.
    pub fn records(&self) -> Result<Vec<Project>> {
        let mut out = vec![];
        for id in self.ids()? {
            if let Ok(project) = self.record(&id) {
                out.push(project);
            }
        }
        out.sort_by(|a, b| a.id.cmp(&b.id));
        Ok(out)
    }
    pub fn get(&self, id: &str) -> Result<Project> {
        self.get_with(&self.config()?, id)
    }
    /// `get` with a configuration already read (a loop over many projects reads it once).
    fn get_with(&self, config: &StackConfig, id: &str) -> Result<Project> {
        let mut project: Project = self.read(&self.project_path(id)?)?;
        ensure!(project.id == id, "project_id_mismatch");
        project.validate(config)?;
        Ok(project)
    }
    /// Every site whose folder is there. One whose folder went away (deleted, moved, a drive that
    /// is not connected) is left out without touching its record, so it never takes the whole list
    /// (and the daemon) down, and comes back when the folder does; `missing` names them.
    pub fn list(&self) -> Result<Vec<Project>> {
        self.list_with(&self.config()?)
    }
    /// `list` with a configuration already read.
    pub fn list_with(&self, config: &StackConfig) -> Result<Vec<Project>> {
        let mut projects = Vec::new();
        for id in self.ids()? {
            if let Ok(project) = self.get_with(config, &id) {
                projects.push(project);
            }
        }
        projects.sort_by(|a, b| a.id.cmp(&b.id));
        Ok(projects)
    }
    /// Sites left out of `list` (their folder is not there, or their record no longer validates),
    /// as their record says, untouched.
    pub fn missing(&self) -> Result<Vec<Project>> {
        let mut out = vec![];
        let config = self.config()?;
        for id in self.ids()? {
            if self.get_with(&config, &id).is_err()
                && let Ok(project) = self.read::<Project>(&self.project_path(&id)?)
            {
                out.push(project);
            }
        }
        out.sort_by(|a, b| a.id.cmp(&b.id));
        Ok(out)
    }
    /// Sites whose folder is not there (moved, renamed, deleted or on a drive that is not
    /// connected): they are never served nor started, and the app lists them marked so they can
    /// be found again or removed.
    pub fn folder_missing(&self) -> Result<Vec<Project>> {
        let mut out = self.missing()?;
        out.retain(|p| !p.path.is_dir());
        Ok(out)
    }
    /// Points a site whose folder went away at where it is now. The rest of its record stays as
    /// it was (it is served again if it was on).
    pub fn relocate(&self, id: &str, path: &Path) -> Result<Project> {
        let mut project = self
            .folder_missing()?
            .into_iter()
            .find(|p| p.id == id)
            .ok_or_else(|| anyhow::anyhow!("folder_not_missing"))?;
        let path = path
            .canonicalize()
            .map_err(|_| anyhow::anyhow!("invalid_path"))?;
        ensure!(path.is_dir(), "invalid_path");
        ensure!(
            !self.list()?.iter().any(|p| p.path == path),
            "folder_in_use"
        );
        project.path = path;
        self.save(project)
    }
    fn ids(&self) -> Result<Vec<String>> {
        let mut ids = vec![];
        for entry in fs::read_dir(self.directory("projects")?)? {
            let path = entry?.path();
            if path.extension().is_some_and(|ext| ext == "json")
                && let Some(id) = path.file_stem().and_then(|s| s.to_str())
            {
                ids.push(id.to_string());
            }
        }
        Ok(ids)
    }
    /// A free port for a proxied site: 4400-4999 for web dev servers, 18100-18999 for backends;
    /// never one another site, an engine or another program already uses.
    fn free_port(&self, project: &Project, config: &StackConfig) -> Result<u16> {
        let taken: std::collections::HashSet<u16> = self
            .list()?
            .iter()
            .filter(|p| p.id != project.id)
            .flat_map(|p| p.fixed_ports())
            .chain(config.reserved_ports())
            .collect();
        use crate::core::model::ProjectKind as K;
        let range = if matches!(project.kind, K::Kmp | K::Django | K::Fastapi | K::Rust) {
            18100..19000
        } else {
            4400..5000
        };
        range
            .filter(|p| !taken.contains(p))
            .find(|p| crate::web::net::listeners::port_owner(*p, false).is_none())
            .ok_or_else(|| anyhow::anyhow!("no_free_port"))
    }
    pub fn save(&self, mut project: Project) -> Result<Project> {
        let _lock = self.mutation_lock()?;
        let config = self.config()?;
        if project.kind.proxied() && project.upstream.is_none() {
            project.upstream = Some(self.free_port(&project, &config)?);
        }
        project.validate(&config)?;
        ensure!(
            project
                .upstream
                .is_none_or(|port| !config.reserved_ports().contains(&port)),
            "duplicate_port"
        );
        let others = self.list()?;
        // A fixed port (its server's, or one written in a variable or an argument) belongs to one
        // project, and the refusal names the other one. Beyond the server's port only what this
        // save adds is checked: a record saved before this check still turns on and off as it did
        // (its page says the conflict).
        let before = others
            .iter()
            .find(|p| p.id == project.id)
            .map(Project::fixed_ports)
            .unwrap_or_default();
        let added: std::collections::BTreeSet<u16> =
            project.fixed_ports().difference(&before).copied().collect();
        for other in others.iter().filter(|p| p.id != project.id) {
            let taken = other.fixed_ports();
            let clash = project
                .upstream
                .filter(|port| other.upstream == Some(*port))
                .or_else(|| added.iter().copied().find(|port| taken.contains(port)));
            if let Some(port) = clash {
                anyhow::bail!(port_in_use(port, other));
            }
        }
        // `{port:<id>}` must name a project with a port (this one included).
        let mut known = others.clone();
        known.retain(|p| p.id != project.id);
        known.push(project.clone());
        for value in project.env.values() {
            crate::core::model::fill_project_ports(value, &known)?;
        }
        for other in others {
            ensure!(
                other.id == project.id
                    || !other.domains.iter().any(|d| project.domains.contains(d)),
                "domain_in_use"
            );
        }
        self.write(&self.project_path(&project.id)?, &project)?;
        Ok(project)
    }
    pub fn delete(&self, id: &str) -> Result<()> {
        let _lock = self.mutation_lock()?;
        fs::remove_file(self.project_path(id)?)?;
        Ok(())
    }
}

/// `port_in_use:<port> · <name>`: the engine answers code `port_in_use` with that detail (the
/// other project's name is the user's own words, never a path).
pub fn port_in_use(port: u16, other: &Project) -> String {
    let name: String = other
        .name
        .chars()
        .filter(|c| !c.is_control())
        .take(200)
        .collect();
    format!("port_in_use:{port} · {name}")
}

/// Folders that group sites in the app. Kept with the stack's data so they survive reinstalls; a
/// site id may stay listed while its folder is missing, so it comes back in its place.
///
/// A folder may be a project of several parts (`kind: "project"`): its sites are its parts, in
/// the order they start when `ordered`, plus repositories that are not a site (`repositories`,
/// top folders) and the Google Cloud link its parts inherit (`gcp`). Every new field is written
/// only when it says something, so an older `groups.json` reads and saves the same; turning a
/// project back into a folder keeps them, unused, for when it is a project again.
#[derive(Clone, Debug, Default, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct SiteGroup {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub sites: Vec<String>,
    /// `"folder"` (also when missing or unknown) or `"project"`.
    #[serde(default, skip_serializing_if = "is_folder_kind")]
    pub kind: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub repositories: Vec<String>,
    /// Its parts start one after another, in the order of `sites`.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub ordered: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gcp: Option<crate::core::model::GcpLink>,
}

fn is_folder_kind(kind: &str) -> bool {
    kind != SiteGroup::PROJECT
}

impl SiteGroup {
    pub const PROJECT: &'static str = "project";
    /// Repositories that are not a site, per project: enough for a library and its tooling.
    const MAX_REPOSITORIES: usize = 50;

    pub fn is_project(&self) -> bool {
        self.kind == Self::PROJECT
    }

    /// Absolute folders, printable, each once.
    fn clean_repositories(repositories: Vec<String>) -> Result<Vec<String>> {
        ensure!(
            repositories.len() <= Self::MAX_REPOSITORIES,
            "too_many_repositories"
        );
        let mut clean: Vec<String> = Vec::with_capacity(repositories.len());
        for path in repositories {
            let path = path.trim_end_matches('/').to_string();
            ensure!(
                path.starts_with('/')
                    && path.len() > 1
                    && path.len() <= 1024
                    && !path.chars().any(char::is_control)
                    && !path.split('/').any(|part| part == ".."),
                "invalid_path"
            );
            if !clean.contains(&path) {
                clean.push(path);
            }
        }
        Ok(clean)
    }
}

impl Store {
    /// Small JSON documents of the store root (`watched.json`…), validated by their module.
    pub fn document<T: serde::de::DeserializeOwned + Default>(&self, name: &str) -> Result<T> {
        crate::core::model::validate_id(name)?;
        let file = self.root.join(format!("{name}.json"));
        if !file.exists() {
            return Ok(T::default());
        }
        self.read(&file)
    }
    pub fn save_document(&self, name: &str, value: &impl Serialize) -> Result<()> {
        crate::core::model::validate_id(name)?;
        self.write(&self.root.join(format!("{name}.json")), value)
    }
    pub fn groups(&self) -> Result<Vec<SiteGroup>> {
        let file = self.root.join("groups.json");
        if !file.exists() {
            return Ok(vec![]);
        }
        self.read(&file)
    }
    /// Validates and saves the folders: short printable names, valid ids, each site in one folder.
    pub fn save_groups(&self, groups: Vec<SiteGroup>) -> Result<Vec<SiteGroup>> {
        ensure!(groups.len() <= 200, "too_many_groups");
        let mut ids = std::collections::HashSet::new();
        let mut placed = std::collections::HashSet::new();
        let mut clean = Vec::with_capacity(groups.len());
        for mut group in groups {
            crate::core::model::validate_id(&group.id)?;
            ensure!(ids.insert(group.id.clone()), "duplicate_group");
            group.name = group.name.trim().to_string();
            ensure!(
                !group.name.is_empty()
                    && group.name.chars().count() <= 60
                    && !group.name.chars().any(char::is_control),
                "invalid_group_name"
            );
            let mut sites = vec![];
            for site in group.sites {
                crate::core::model::validate_id(&site)?;
                if placed.insert(site.clone()) {
                    sites.push(site);
                }
            }
            group.sites = sites;
            ensure!(
                group.kind.is_empty() || group.kind == "folder" || group.is_project(),
                "invalid_group_kind"
            );
            if !group.is_project() {
                group.kind = String::new();
            }
            group.repositories = SiteGroup::clean_repositories(group.repositories)?;
            if let Some(link) = &group.gcp {
                link.validate()?;
            }
            clean.push(group);
        }
        self.write(&self.root.join("groups.json"), &clean)?;
        Ok(clean)
    }

    /// The project of several parts a site belongs to, if any (a plain folder is not one).
    pub fn composite_of(&self, site: &str) -> Option<SiteGroup> {
        self.groups()
            .ok()?
            .into_iter()
            .find(|group| group.is_project() && group.sites.iter().any(|s| s == site))
    }

    /// What a site's processes and consoles get of Google Cloud: its own link, or the one of the
    /// project of several parts it belongs to; the site's own `env` wins over both.
    pub fn gcp_environment(&self, project: &Project) -> std::collections::BTreeMap<String, String> {
        let inherited = if project.gcp.is_none() {
            self.composite_of(&project.id).and_then(|group| group.gcp)
        } else {
            None
        };
        project.gcp_environment_with(inherited.as_ref())
    }

    /// Sets (or removes) the Google Cloud link of a project of several parts.
    pub fn set_group_gcp(
        &self,
        id: &str,
        link: Option<crate::core::model::GcpLink>,
    ) -> Result<SiteGroup> {
        let mut groups = self.groups()?;
        let group = groups
            .iter_mut()
            .find(|group| group.id == id)
            .ok_or_else(|| anyhow::anyhow!("unknown_group"))?;
        group.gcp = link;
        let saved = self.save_groups(groups)?;
        Ok(saved
            .into_iter()
            .find(|group| group.id == id)
            .unwrap_or_default())
    }
}

#[cfg(test)]
#[path = "store_tests.rs"]
mod tests;
