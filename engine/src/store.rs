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
    pub fn list(&self) -> Result<Vec<Project>> {
        let mut projects = Vec::new();
        for entry in fs::read_dir(self.directory("projects")?)? {
            let path = entry?.path();
            if path.extension().is_some_and(|ext| ext == "json") {
                projects.push(
                    self.get(
                        path.file_stem()
                            .and_then(|s| s.to_str())
                            .ok_or_else(|| anyhow::anyhow!("invalid_id"))?,
                    )?,
                );
            }
        }
        projects.sort_by(|a, b| a.id.cmp(&b.id));
        Ok(projects)
    }
    pub fn save(&self, mut project: Project) -> Result<Project> {
        project.validate(&self.config()?)?;
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

#[cfg(test)]
mod tests {
    use super::*;
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
}
