use crate::model::{validate_id, Project, StackConfig};
use anyhow::{ensure, Result};
use serde::{de::DeserializeOwned, Serialize};
use std::{
    fs::{self, OpenOptions},
    io::Write,
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
};

pub struct Store {
    root: PathBuf,
}
static SEQUENCE: AtomicU64 = AtomicU64::new(0);

impl Store {
    pub fn root(&self) -> &Path {
        &self.root
    }
    pub fn from_environment() -> Result<Self> {
        let root = match std::env::var_os("BUTAKE_STACK_HOME") {
            Some(root) => PathBuf::from(root),
            None => dirs::home_dir()
                .ok_or_else(|| anyhow::anyhow!("home_unavailable"))?
                .join("Library/Application Support/Butake Stack"),
        };
        Self::new(root)
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
        if !path.exists() {
            fs::create_dir(&path)?;
        }
        ensure!(
            !fs::symlink_metadata(&path)?.file_type().is_symlink() && path.is_dir(),
            "unsafe_store_path"
        );
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700))?;
        Ok(path)
    }
    fn read<T: DeserializeOwned>(&self, path: &Path) -> Result<T> {
        ensure!(
            !fs::symlink_metadata(path)?.file_type().is_symlink(),
            "unsafe_store_path"
        );
        ensure!(fs::metadata(path)?.len() <= 1_048_576, "store_too_large");
        Ok(serde_json::from_slice(&fs::read(path)?)?)
    }
    fn write(&self, path: &Path, value: &impl Serialize) -> Result<()> {
        let temp = path.with_extension(format!(
            "{}.{}.tmp",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        let result = (|| -> Result<()> {
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&temp)?;
            file.write_all(&serde_json::to_vec_pretty(value)?)?;
            file.sync_all()?;
            fs::rename(&temp, path)?;
            fs::File::open(path.parent().unwrap())?.sync_all()?;
            Ok(())
        })();
        if result.is_err() {
            let _ = fs::remove_file(temp);
        }
        result
    }
    pub fn config(&self) -> Result<StackConfig> {
        let path = self.root.join("stack.json");
        let config: StackConfig = if path.try_exists()? {
            self.read(&path)?
        } else {
            StackConfig::default()
        };
        config.validate()?;
        Ok(config)
    }
    pub fn save_config(&self, config: &StackConfig) -> Result<()> {
        config.validate()?;
        for project in self.list()? {
            let mut p = project;
            p.validate(config)?;
        }
        self.write(&self.root.join("stack.json"), config)
    }
    fn project_path(&self, id: &str) -> Result<PathBuf> {
        validate_id(id)?;
        Ok(self.directory("projects")?.join(format!("{id}.json")))
    }
    pub fn get(&self, id: &str) -> Result<Project> {
        let mut project: Project = self.read(&self.project_path(id)?)?;
        ensure!(project.id == id, "project_id_mismatch");
        project.validate(&self.config()?)?;
        Ok(project)
    }
    /// Every site whose folder is there. One whose folder went away (deleted, moved, a drive that
    /// is not connected) is left out without touching its record, so it never takes the whole list
    /// (and the daemon) down, and comes back when the folder does; `missing` names them.
    pub fn list(&self) -> Result<Vec<Project>> {
        let mut projects = Vec::new();
        for id in self.ids()? {
            if let Ok(project) = self.get(&id) {
                projects.push(project);
            }
        }
        projects.sort_by(|a, b| a.id.cmp(&b.id));
        Ok(projects)
    }
    /// Sites left out of `list` because their folder is not there: id and the path it had.
    pub fn missing(&self) -> Result<Vec<(String, std::path::PathBuf)>> {
        let mut out = vec![];
        for id in self.ids()? {
            if self.get(&id).is_err() {
                if let Ok(project) = self.read::<Project>(&self.project_path(&id)?) {
                    out.push((id, project.path));
                }
            }
        }
        out.sort();
        Ok(out)
    }
    fn ids(&self) -> Result<Vec<String>> {
        let mut ids = vec![];
        for entry in fs::read_dir(self.directory("projects")?)? {
            let path = entry?.path();
            if path.extension().is_some_and(|ext| ext == "json") {
                if let Some(id) = path.file_stem().and_then(|s| s.to_str()) {
                    ids.push(id.to_string());
                }
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
            .filter_map(|p| p.upstream)
            .chain(config.engines.keys().map(|e| crate::engines::port(config, e)))
            .collect();
        let range = if project.kind == crate::model::ProjectKind::Kmp { 18100..19000 } else { 4400..5000 };
        range
            .filter(|p| !taken.contains(p))
            .find(|p| crate::listeners::port_owner(*p, false).is_none())
            .ok_or_else(|| anyhow::anyhow!("no_free_port"))
    }
    pub fn save(&self, mut project: Project) -> Result<Project> {
        let config = self.config()?;
        if project.kind.proxied() && project.upstream.is_none() {
            project.upstream = Some(self.free_port(&project, &config)?);
        }
        project.validate(&config)?;
        for other in self.list()? {
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
        fs::remove_file(self.project_path(id)?)?;
        Ok(())
    }
}

/// Folders that group sites in the app. Kept with the stack's data so they survive reinstalls; a
/// site id may stay listed while its folder is missing, so it comes back in its place.
#[derive(Clone, Debug, Default, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct SiteGroup {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub sites: Vec<String>,
}

impl Store {
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
            crate::model::validate_id(&group.id)?;
            ensure!(ids.insert(group.id.clone()), "duplicate_group");
            group.name = group.name.trim().to_string();
            ensure!(!group.name.is_empty() && group.name.chars().count() <= 60 && !group.name.chars().any(char::is_control), "invalid_group_name");
            let mut sites = vec![];
            for site in group.sites {
                crate::model::validate_id(&site)?;
                if placed.insert(site.clone()) {
                    sites.push(site);
                }
            }
            group.sites = sites;
            clean.push(group);
        }
        self.write(&self.root.join("groups.json"), &clean)?;
        Ok(clean)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn groups_are_validated_and_each_site_is_in_one() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::new(temp.path().join("store")).unwrap();
        assert!(store.groups().unwrap().is_empty());
        let saved = store.save_groups(vec![
            SiteGroup { id: "clientes".into(), name: "  Clientes ".into(), sites: vec!["one".into(), "crew".into()] },
            SiteGroup { id: "internos".into(), name: "Internos".into(), sites: vec!["crew".into(), "gestion".into()] },
        ]).unwrap();
        assert_eq!(saved[0].name, "Clientes");
        assert_eq!(saved[1].sites, vec!["gestion".to_string()]);
        assert_eq!(store.groups().unwrap(), saved);
        assert!(store.save_groups(vec![SiteGroup { id: "x".into(), name: "".into(), sites: vec![] }]).is_err());
        assert!(store.save_groups(vec![SiteGroup { id: "../x".into(), name: "X".into(), sites: vec![] }]).is_err());
        assert!(store.save_groups(vec![SiteGroup { id: "x".into(), name: "X".into(), sites: vec!["a b".into()] }]).is_err());
    }
    #[test]
    fn a_missing_folder_never_breaks_the_list() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::new(temp.path().join("store")).unwrap();
        let folder = temp.path().join("gone");
        fs::create_dir_all(&folder).unwrap();
        let p: Project = serde_json::from_value(serde_json::json!({"id":"gone","name":"Gone","path":folder,"domains":["gone.test"],"https":false,"kind":"static","runtime":{},"docroot":".","services":[],"databases":[],"processes":[]})).unwrap();
        store.save(p).unwrap();
        fs::remove_dir(&folder).unwrap();
        assert!(store.list().unwrap().is_empty());
        assert_eq!(store.missing().unwrap().len(), 1);
        fs::create_dir_all(&folder).unwrap();
        assert_eq!(store.list().unwrap().len(), 1);
        assert!(store.missing().unwrap().is_empty());
    }
    #[test]
    fn round_trip_and_reject_symlinks() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::new(temp.path().join("store")).unwrap();
        let p: Project = serde_json::from_value(serde_json::json!({"id":"demo","name":"Demo","path":temp.path(),"domains":["demo.test"],"https":true,"kind":"static","runtime":{},"docroot":".","services":[],"databases":[],"processes":[]})).unwrap();
        let p = store.save(p).unwrap();
        assert_eq!(store.get("demo").unwrap(), p);
        assert_eq!(store.list().unwrap(), vec![p]);
        let mut config = StackConfig::default();
        config.ports.http = 8080;
        store.save_config(&config).unwrap();
        assert_eq!(store.config().unwrap(), config);
        assert!(store.delete("../demo").is_err());
        store.delete("demo").unwrap();
        assert!(store.list().unwrap().is_empty());
        std::os::unix::fs::symlink(
            temp.path().join("outside"),
            store.project_path("demo").unwrap(),
        )
        .unwrap();
        assert!(store.get("demo").is_err());
        assert!(!temp.path().join("outside").exists());
        assert_eq!(
            fs::metadata(&store.root).unwrap().permissions().mode() & 0o777,
            0o700
        );
    }
    #[test]
    fn proxied_sites_get_distinct_free_ports() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::new(temp.path().join("store")).unwrap();
        let mk = |id: &str| -> Project { serde_json::from_value(serde_json::json!({"id":id,"name":id,"path":temp.path(),"domains":[format!("{id}.test")],"https":true,"kind":"astro","runtime":{},"docroot":".","services":[],"databases":[],"processes":[]})).unwrap() };
        let a = store.save(mk("uno")).unwrap();
        let b = store.save(mk("dos")).unwrap();
        let (pa, pb) = (a.upstream.unwrap(), b.upstream.unwrap());
        assert!(pa != pb && (4400..5000).contains(&pa) && (4400..5000).contains(&pb));
        assert_eq!(store.save(a.clone()).unwrap().upstream, Some(pa), "an assigned port is kept");
    }

}
