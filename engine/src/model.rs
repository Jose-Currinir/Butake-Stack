use anyhow::{ensure, Result};
use serde::{Deserialize, Serialize};
use std::{collections::BTreeMap, path::PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct StackConfig {
    pub tld: Vec<String>,
    pub ports: Ports,
    pub versions: BTreeMap<String, String>,
    /// Database and cache engines run directly by the stack (`mysql`, `redis`).
    #[serde(default)]
    pub engines: BTreeMap<String, EngineConfig>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(deny_unknown_fields)]
pub struct EngineConfig {
    pub enabled: bool,
    /// Wanted version ("8.4", "8.4.13" or empty for the newest installed).
    #[serde(default)]
    pub version: String,
    /// Own port; none = the engine's default.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub port: Option<u16>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Ports {
    pub http: u16,
    pub https: u16,
    pub dns: u16,
    pub mysql: u16,
    pub redis: u16,
}

impl Default for StackConfig {
    fn default() -> Self {
        Self {
            tld: vec!["test".into()],
            ports: Ports {
                http: 80,
                https: 443,
                dns: 53,
                mysql: 3306,
                redis: 6379,
            },
            versions: [
                ("php".into(), "8.2".into()),
                ("node".into(), "24".into()),
                ("mysql".into(), "8.0".into()),
            ]
            .into(),
            engines: BTreeMap::new(),
        }
    }
}

fn label(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 63
        && !value.starts_with('-')
        && !value.ends_with('-')
        && value
            .bytes()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-')
}

pub fn validate_id(id: &str) -> Result<()> {
    ensure!(
        !id.is_empty()
            && id.len() <= 40
            && id
                .bytes()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-'),
        "invalid_id"
    );
    Ok(())
}

impl StackConfig {
    pub fn validate(&self) -> Result<()> {
        ensure!(
            !self.tld.is_empty() && self.tld.iter().all(|t| label(t)),
            "invalid_tld"
        );
        let mut tlds = self.tld.clone();
        tlds.sort();
        tlds.dedup();
        ensure!(tlds.len() == self.tld.len(), "duplicate_tld");
        let ports = [
            self.ports.http,
            self.ports.https,
            self.ports.dns,
            self.ports.mysql,
            self.ports.redis,
        ];
        ensure!(!ports.contains(&0), "invalid_port");
        let mut unique = ports.to_vec();
        unique.sort();
        unique.dedup();
        ensure!(unique.len() == ports.len(), "duplicate_port");
        ensure!(
            self.engines.iter().all(|(name, engine)| crate::engines::recipe(name).is_some()
                && engine.port != Some(0)
                && engine.version.len() <= 20
                && engine.version.bytes().all(|c| c.is_ascii_digit() || c == b'.')),
            "invalid_engine"
        );
        ensure!(
            self.versions.iter().all(|(key, value)| label(key)
                && !value.is_empty()
                && value.bytes().all(|c| c.is_ascii_digit() || c == b'.')),
            "invalid_version"
        );
        Ok(())
    }

    pub fn validate_domain(&self, domain: &str) -> Result<()> {
        let parts: Vec<_> = domain.split('.').collect();
        ensure!(
            domain.len() <= 253
                && parts.len() >= 2
                && parts.iter().all(|p| label(p))
                && self
                    .tld
                    .iter()
                    .any(|t| Some(t.as_str()) == parts.last().copied()),
            "invalid_domain"
        );
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum ProjectKind {
    Laravel,
    Php,
    Node,
    Static,
    Proxy,
    /// Astro site: its dev server behind Caddy.
    Astro,
    /// EmDash (Astro + Cloudflare): build + `wrangler dev` behind Caddy.
    Emdash,
    /// Next.js: `next dev` behind Caddy.
    Next,
    /// Kotlin Multiplatform: the server module (`./gradlew :server:run`) behind Caddy.
    Kmp,
    /// Django: `manage.py runserver` through uv, behind Caddy.
    Django,
    /// FastAPI: uvicorn through uv, behind Caddy.
    Fastapi,
    /// Rust web server (axum, actix-web, rocket…): `cargo run` behind Caddy.
    Rust,
}

impl ProjectKind {
    /// Kinds served by proxying to a process of their own (a port Stack assigns).
    pub fn proxied(&self) -> bool {
        matches!(self, Self::Astro | Self::Emdash | Self::Next | Self::Kmp | Self::Node | Self::Proxy | Self::Django | Self::Fastapi | Self::Rust)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ProjectProcess {
    pub name: String,
    pub program: String,
    pub args: Vec<String>,
    pub autostart: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Project {
    pub id: String,
    pub name: String,
    pub path: PathBuf,
    pub domains: Vec<String>,
    pub https: bool,
    pub kind: ProjectKind,
    pub runtime: BTreeMap<String, String>,
    pub docroot: PathBuf,
    pub services: Vec<String>,
    pub databases: Vec<String>,
    pub processes: Vec<ProjectProcess>,
    /// Sites start off; the user turns each one on (served and its processes running).
    #[serde(default)]
    pub enabled: bool,
    /// Port of the site's own server (dev server, backend) that Caddy proxies to; Stack assigns
    /// a free one so projects that all default to 4321 or 8080 never collide.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub upstream: Option<u16>,
    /// Environment for the site's processes (no secrets: those stay in the project's own files).
    /// `{port}` and `{domain}` are replaced when a process starts.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub env: BTreeMap<String, String>,
}

impl Project {
    pub fn validate(&mut self, config: &StackConfig) -> Result<()> {
        config.validate()?;
        validate_id(&self.id)?;
        ensure!(
            !self.name.trim().is_empty()
                && self.name.len() <= 200
                && !self.name.chars().any(char::is_control),
            "invalid_name"
        );
        self.path = self
            .path
            .canonicalize()
            .map_err(|_| anyhow::anyhow!("invalid_path"))?;
        ensure!(self.path.is_dir(), "invalid_path");
        ensure!(!self.domains.is_empty(), "invalid_domain");
        let mut domains = std::collections::HashSet::new();
        for domain in &self.domains {
            config.validate_domain(domain)?;
            ensure!(domains.insert(domain), "duplicate_domain");
        }
        ensure!(
            !self.docroot.is_absolute() && !self.docroot.as_os_str().is_empty(),
            "invalid_docroot"
        );
        ensure!(
            self.docroot.components().all(|c| matches!(
                c,
                std::path::Component::Normal(_) | std::path::Component::CurDir
            )),
            "invalid_docroot"
        );
        let root = self
            .path
            .join(&self.docroot)
            .canonicalize()
            .map_err(|_| anyhow::anyhow!("invalid_docroot"))?;
        ensure!(
            root.is_dir() && root.starts_with(&self.path),
            "invalid_docroot"
        );
        ensure!(
            self.runtime
                .iter()
                .all(|(key, value)| ["php", "node", "jdk", "python"].contains(&key.as_str())
                    && !value.is_empty()
                    && value.bytes().all(|c| c.is_ascii_digit() || c == b'.')),
            "invalid_runtime"
        );
        ensure!(
            self.services
                .iter()
                .all(|s| ["mysql", "redis", "postgres"].contains(&s.as_str())),
            "invalid_service"
        );
        ensure!(
            self.databases.iter().all(|s| !s.is_empty()
                && s.len() <= 64
                && s.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'_')),
            "invalid_database"
        );
        ensure!(self.upstream.is_none_or(|p| p >= 1024), "invalid_port");
        ensure!(
            self.env.len() <= 64
                && self.env.iter().all(|(k, v)| {
                    !k.is_empty() && k.len() <= 128 && k.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'_') && !k.as_bytes()[0].is_ascii_digit()
                        && v.len() <= 4096 && !v.contains('\0') && !v.contains('\n')
                }),
            "invalid_env"
        );
        if self.processes.iter().any(|p| p.program == "gradlew") {
            let gradlew = self.path.join("gradlew");
            ensure!(gradlew.is_file() && !std::fs::symlink_metadata(&gradlew)?.file_type().is_symlink(), "gradlew_missing");
        }
        let mut names = std::collections::HashSet::new();
        for process in &self.processes {
            validate_id(&process.name)?;
            ensure!(names.insert(&process.name), "duplicate_process");
            ensure!(
                ["php", "node", "npm", "npx", "corepack", "composer", "gradlew", "uv", "cargo"].contains(&process.program.as_str()),
                "invalid_program"
            );
            ensure!(
                process.args.len() <= 128
                    && process
                        .args
                        .iter()
                        .all(|arg| arg.len() <= 8192 && !arg.contains('\0')),
                "invalid_arguments"
            );
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    pub fn project(path: &std::path::Path) -> Project {
        Project {
            id: "demo".into(),
            name: "Demostración".into(),
            path: path.into(),
            domains: vec!["demo.test".into()],
            https: true,
            kind: ProjectKind::Laravel,
            runtime: [("php".into(), "8.2".into())].into(),
            docroot: ".".into(),
            services: vec!["mysql".into()],
            databases: vec!["demo_db".into()],
            processes: vec![ProjectProcess {
                name: "queue".into(),
                program: "php".into(),
                args: vec!["artisan".into()],
                autostart: false,
            }],
            enabled: false,
            upstream: None,
            env: BTreeMap::new(),
        }
    }
    #[test]
    fn validates_ids_domains_and_ports() {
        for id in ["demo", "a-1", "-"] {
            assert!(validate_id(id).is_ok());
        }
        for id in ["", "../x", "A", "a/b", &"x".repeat(41)] {
            assert!(validate_id(id).is_err());
        }
        let mut config = StackConfig::default();
        assert!(config.validate().is_ok());
        for domain in ["demo.test", "sub.demo.test"] {
            assert!(config.validate_domain(domain).is_ok());
        }
        for domain in [
            "demo.com",
            "test",
            "-a.test",
            "a..test",
            "x.test;id",
            "X.test",
            "a.test/",
            "a.local",
        ] {
            assert!(config.validate_domain(domain).is_err());
        }
        config.ports.http = 0;
        assert!(config.validate().is_err());
        config.ports.http = 443;
        assert!(config.validate().is_err());
        config.ports.http = 65535;
        assert!(config.validate().is_ok());
    }
    #[test]
    fn validates_paths_programs_and_docroot_escape() {
        let temp = tempfile::tempdir().unwrap();
        let mut p = project(temp.path());
        p.path = temp.path().join(".");
        p.validate(&StackConfig::default()).unwrap();
        assert_eq!(p.path, temp.path().canonicalize().unwrap());
        p.processes[0].program = "sh".into();
        assert!(p.validate(&StackConfig::default()).is_err());
        p.processes[0].program = "php".into();
        p.docroot = "..".into();
        assert!(p.validate(&StackConfig::default()).is_err());
        let outside = tempfile::tempdir().unwrap();
        std::os::unix::fs::symlink(outside.path(), temp.path().join("escape")).unwrap();
        p.docroot = "escape".into();
        assert!(p.validate(&StackConfig::default()).is_err());
        p.path = temp.path().join("missing");
        assert!(p.validate(&StackConfig::default()).is_err());
    }
}
