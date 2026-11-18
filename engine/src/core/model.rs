use anyhow::{Result, ensure};
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
    /// Xdebug per PHP line ("8.2" → "debug"); a line not listed runs without Xdebug.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub xdebug: BTreeMap<String, String>,
    /// Local mail catcher (SMTP on 127.0.0.1).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mail: Option<MailConfig>,
    /// Receiver of `dump()` calls (VarDumper server protocol on 127.0.0.1).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dumps: Option<DumpsConfig>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct MailConfig {
    pub enabled: bool,
    pub port: u16,
    /// Messages older than this are removed.
    pub retention_days: u16,
    /// Oldest messages go first beyond this count.
    pub max_messages: u32,
}
impl Default for MailConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            port: 2525,
            retention_days: 7,
            max_messages: 500,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct DumpsConfig {
    pub enabled: bool,
    pub port: u16,
}
impl Default for DumpsConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            port: 9912,
        }
    }
}

/// Xdebug modes offered per PHP line.
pub const XDEBUG_MODES: &[&str] = &["debug", "develop", "coverage", "debug,develop"];

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
    /// A per-service usage switch written by an earlier build (the AWS emulator, since retired):
    /// read so that `stack.json` still loads, never written again.
    #[serde(default, rename = "telemetry", skip_serializing)]
    pub retired_telemetry: Option<serde::de::IgnoredAny>,
}

/// Services that earlier builds offered and Stack no longer runs: their entry in `stack.json` is
/// dropped when it is read instead of failing validation.
pub const RETIRED_ENGINES: &[&str] = &["aws-emulator"];

/// Entries of `versions` that nothing reads any more: `mysql` (the wanted MySQL lives in
/// `engines.mysql.version` since services became engines). Dropped when `stack.json` is read, so
/// the next save writes the file without them and it never says a version Stack does not use.
pub const RETIRED_VERSIONS: &[&str] = &["mysql"];

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
            versions: [("php".into(), "8.2".into()), ("node".into(), "24".into())].into(),
            engines: BTreeMap::new(),
            xdebug: BTreeMap::new(),
            mail: None,
            dumps: None,
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
    ensure!(crate::core::validate::id(id, 40), "invalid_id");
    Ok(())
}

/// Projects named by `{port:<id>}` markers in `text`, in order (the id as written; a malformed one
/// fails when it is filled).
pub fn port_references(text: &str) -> Vec<&str> {
    marker_references(text, "{port:")
}

/// Projects named by `{public:<id>}` markers in `text`, in order (see [`fill_public_addresses`]).
pub fn public_references(text: &str) -> Vec<&str> {
    marker_references(text, "{public:")
}

/// Projects named by `{port:<id>}` or `{public:<id>}`: what a value depends on.
pub fn project_references(text: &str) -> Vec<&str> {
    let mut out = port_references(text);
    out.extend(public_references(text));
    out
}

/// `text` with each `{port:<from>}` and `{public:<from>}` naming `to` instead (a project renamed);
/// any other marker stays as it was.
pub fn rename_references(text: &str, from: &str, to: &str) -> String {
    text.replace(&format!("{{port:{from}}}"), &format!("{{port:{to}}}"))
        .replace(&format!("{{public:{from}}}"), &format!("{{public:{to}}}"))
}

fn marker_references<'a>(text: &'a str, opening: &str) -> Vec<&'a str> {
    let mut out = vec![];
    let mut rest = text;
    while let Some(start) = rest.find(opening) {
        let after = &rest[start + opening.len()..];
        let Some(end) = after.find('}') else { break };
        out.push(&after[..end]);
        rest = &after[end + 1..];
    }
    out
}

/// Replaces each `{public:<id>}` in `text` with `https://<fixed address of <id>>` (P-35), from
/// `addresses` (project id → host name). `unknown_public_project` when no such project exists;
/// `project_without_public_address` when it has no fixed address yet (the value is pending).
pub fn fill_public_addresses(
    text: &str,
    projects: &[Project],
    addresses: &BTreeMap<String, String>,
) -> Result<String> {
    let mut out = text.to_string();
    for id in public_references(text) {
        ensure!(
            validate_id(id).is_ok() && projects.iter().any(|p| p.id == id),
            "unknown_public_project"
        );
        let host = addresses
            .get(id)
            .ok_or_else(|| anyhow::anyhow!("project_without_public_address"))?;
        out = out.replace(&format!("{{public:{id}}}"), &format!("https://{host}"));
    }
    Ok(out)
}

/// Replaces each `{port:<id>}` in `text` with the port of project `<id>` (the `upstream` Caddy
/// proxies to). `unknown_port_project` when no such project exists, `project_without_port` when it
/// has no server of its own.
pub fn fill_project_ports(text: &str, projects: &[Project]) -> Result<String> {
    let mut out = text.to_string();
    for id in port_references(text) {
        ensure!(validate_id(id).is_ok(), "unknown_port_project");
        let project = projects
            .iter()
            .find(|p| p.id == id)
            .ok_or_else(|| anyhow::anyhow!("unknown_port_project"))?;
        let port = project
            .upstream
            .ok_or_else(|| anyhow::anyhow!("project_without_port"))?;
        out = out.replace(&format!("{{port:{id}}}"), &port.to_string());
    }
    Ok(out)
}

impl StackConfig {
    /// Leaves out what earlier builds wrote and Stack no longer uses ([`RETIRED_ENGINES`],
    /// [`RETIRED_VERSIONS`]): the silent migration of every read and every save.
    pub fn drop_retired(&mut self) {
        for retired in RETIRED_ENGINES {
            self.engines.remove(*retired);
        }
        for retired in RETIRED_VERSIONS {
            self.versions.remove(*retired);
        }
    }

    pub fn validate(&self) -> Result<()> {
        ensure!(
            !self.tld.is_empty() && self.tld.iter().all(|t| label(t)),
            "invalid_tld"
        );
        let mut tlds = self.tld.clone();
        tlds.sort();
        tlds.dedup();
        ensure!(tlds.len() == self.tld.len(), "duplicate_tld");
        ensure!(
            self.ports.mysql != 0 && self.ports.redis != 0,
            "invalid_port"
        );
        let ports = self.reserved_ports();
        ensure!(!ports.contains(&0), "invalid_port");
        for port in [
            self.mail.as_ref().map(|m| m.port),
            self.dumps.as_ref().map(|d| d.port),
        ]
        .into_iter()
        .flatten()
        {
            ensure!(port >= 1024, "invalid_port");
        }
        if let Some(mail) = &self.mail {
            ensure!(
                (1..=365).contains(&mail.retention_days)
                    && (1..=10_000).contains(&mail.max_messages),
                "invalid_mail"
            );
        }
        ensure!(
            self.xdebug.iter().all(|(series, mode)| {
                crate::runtimes::languages::php::validate_series(series).is_ok()
                    && XDEBUG_MODES.contains(&mode.as_str())
            }),
            "invalid_xdebug"
        );
        let mut unique = ports.clone();
        unique.sort();
        unique.dedup();
        ensure!(unique.len() == ports.len(), "duplicate_port");
        ensure!(
            self.engines
                .iter()
                .all(
                    |(name, engine)| crate::web::services::engines::recipe(name).is_some()
                        && engine.port != Some(0)
                        && engine.version.len() <= 20
                        && engine
                            .version
                            .bytes()
                            .all(|c| c.is_ascii_digit() || c == b'.')
                ),
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

    /// Stack reservations shared by configuration validation and project port allocation.
    pub fn reserved_ports(&self) -> Vec<u16> {
        let mut ports = vec![self.ports.http, self.ports.https, self.ports.dns];
        ports.extend(
            [
                self.mail.as_ref().map(|m| m.port),
                self.dumps.as_ref().map(|d| d.port),
            ]
            .into_iter()
            .flatten(),
        );
        ports.extend(
            ["mysql", "redis"].map(|engine| crate::web::services::engines::port(self, engine)),
        );
        ports.extend(
            self.engines
                .keys()
                .filter(|engine| !matches!(engine.as_str(), "mysql" | "redis"))
                .map(|engine| crate::web::services::engines::port(self, engine)),
        );
        ports
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
    /// Django: `manage.py runserver` with the project's `.venv/bin/python`, behind Caddy.
    Django,
    /// FastAPI: uvicorn with the project's `.venv/bin/python`, behind Caddy.
    Fastapi,
    /// Rust web server (axum, actix-web, rocket…): `cargo run` behind Caddy.
    Rust,
    /// A project Stack never serves (an app, a library, a tool, a template): no domain, no web
    /// server and no switch. Its processes are commands the user runs by hand («Comprobar»,
    /// «Compilar»), each one once, never on its own.
    Unserved,
}

impl ProjectKind {
    /// Every kind but [`Self::Unserved`] has a domain, is served by Caddy and is turned on and off.
    pub fn served(&self) -> bool {
        *self != Self::Unserved
    }
    /// Kinds served by proxying to a process of their own (a port Stack assigns).
    pub fn proxied(&self) -> bool {
        matches!(
            self,
            Self::Astro
                | Self::Emdash
                | Self::Next
                | Self::Kmp
                | Self::Node
                | Self::Proxy
                | Self::Django
                | Self::Fastapi
                | Self::Rust
        )
    }
}

/// Programs a project's process may run: Stack's runtimes (PHP, Node and its package managers,
/// the project's Python), the project's own Gradle wrapper, the user's toolchains (uv, cargo) and
/// the command line tools of the Mac (`/usr/bin`: swift, xcodebuild, make).
pub const PROGRAMS: &[&str] = &[
    "php",
    "node",
    "npm",
    "npx",
    "corepack",
    "composer",
    "gradlew",
    "uv",
    "cargo",
    "python",
    "swift",
    "xcodebuild",
    "make",
];

/// Programs of [`PROGRAMS`] that are the Mac's own, run from `/usr/bin`.
pub const SYSTEM_PROGRAMS: &[&str] = &["swift", "xcodebuild", "make"];

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
    /// Its databases, each with the extensions it needs (`core::project_database`).
    pub databases: Vec<crate::core::project_database::ProjectDatabase>,
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
    /// The Google Cloud account and project this project works with (the Google Cloud tool).
    /// Not secret: an address and a project id. Its processes and consoles get them as
    /// [`GcpLink::VARIABLES`]; gcloud's own configuration is never changed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gcp: Option<GcpLink>,
}

/// `gcp` of a project: `{"account": "<correo>", "project": "<id del proyecto de Google>"}`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct GcpLink {
    pub account: String,
    pub project: String,
}

impl GcpLink {
    /// What the project's processes receive: gcloud reads the first two over its active
    /// configuration, and Google's client libraries the third.
    pub const VARIABLES: [&'static str; 3] = [
        "CLOUDSDK_CORE_ACCOUNT",
        "CLOUDSDK_CORE_PROJECT",
        "GOOGLE_CLOUD_PROJECT",
    ];

    pub fn validate(&self) -> Result<()> {
        ensure!(
            crate::core::validate::gcp_account(&self.account),
            "gcp_invalid_account"
        );
        ensure!(
            crate::core::validate::gcp_project(&self.project),
            "gcp_invalid_project"
        );
        Ok(())
    }

    pub fn environment(&self) -> [(&'static str, &str); 3] {
        [
            (Self::VARIABLES[0], self.account.as_str()),
            (Self::VARIABLES[1], self.project.as_str()),
            (Self::VARIABLES[2], self.project.as_str()),
        ]
    }
}

/// Variables a server reads its own port from (the ones detection fills with `{port}`): a number
/// written in one of them is a port the project listens on. Other `*_PORT` variables (`DB_PORT`,
/// `REDIS_PORT`) name someone else's port and never count.
pub const LISTENING_PORT_VARIABLES: &[&str] = &[
    "PORT",
    "SERVER_PORT",
    "HTTP_PORT",
    "NITRO_PORT",
    "ROCKET_PORT",
    "APP_PORT",
];

impl Project {
    /// Ports this project takes as written in its record: its own server's (`upstream`), a number
    /// in a [`LISTENING_PORT_VARIABLES`] variable and one after `--port`/`-p` (or `--port=`) in
    /// its processes' arguments. `{port}` markers are the upstream itself and are not repeated.
    pub fn fixed_ports(&self) -> std::collections::BTreeSet<u16> {
        let mut out: std::collections::BTreeSet<u16> = self.upstream.into_iter().collect();
        let number = |text: &str| text.trim().parse::<u16>().ok().filter(|p| *p != 0);
        for name in LISTENING_PORT_VARIABLES {
            if let Some(port) = self.env.get(*name).and_then(|v| number(v)) {
                out.insert(port);
            }
        }
        for process in &self.processes {
            let mut args = process.args.iter().peekable();
            while let Some(arg) = args.next() {
                let inline = ["--port=", "-p="]
                    .iter()
                    .find_map(|flag| arg.strip_prefix(flag));
                let port = match inline {
                    Some(value) => number(value),
                    None if arg == "--port" || arg == "-p" => args.peek().and_then(|v| number(v)),
                    None => None,
                };
                out.extend(port);
            }
        }
        out
    }

    /// What the project's processes and consoles get of its Google Cloud link: the link's
    /// variables, each one replaced by the project's own `env` when it sets it by hand (what the
    /// project says wins). Without a link of its own, the one it inherits from the project of
    /// several parts it belongs to (`inherited`); without either, only what `env` sets. Never
    /// stored: `env` is the user's.
    pub fn gcp_environment_with(&self, inherited: Option<&GcpLink>) -> BTreeMap<String, String> {
        let mut out = BTreeMap::new();
        if let Some(link) = self.gcp.as_ref().or(inherited) {
            for (name, value) in link.environment() {
                out.insert(name.to_string(), value.to_string());
            }
        }
        for name in GcpLink::VARIABLES {
            if let Some(value) = self.env.get(name) {
                out.insert(name.to_string(), value.clone());
            }
        }
        out
    }

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
        // A project that is not served keeps the domains it had (switching its kind back gives
        // them again) but needs none; it is never on and has no port of its own.
        if self.kind.served() {
            ensure!(!self.domains.is_empty(), "invalid_domain");
        } else {
            self.enabled = false;
            self.upstream = None;
        }
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
                .all(
                    |(key, value)| ["php", "node", "jdk", "python"].contains(&key.as_str())
                        && !value.is_empty()
                        && value.bytes().all(|c| c.is_ascii_digit() || c == b'.')
                ),
            "invalid_runtime"
        );
        ensure!(
            self.services
                .iter()
                .all(|s| ["mysql", "redis", "postgres"].contains(&s.as_str())),
            "invalid_service"
        );
        ensure!(
            self.databases
                .iter()
                .all(crate::core::project_database::ProjectDatabase::valid),
            "invalid_database"
        );
        ensure!(self.upstream.is_none_or(|p| p >= 1024), "invalid_port");
        ensure!(
            self.env.len() <= 64
                && self.env.iter().all(|(k, v)| {
                    !k.is_empty()
                        && k.len() <= 128
                        && k.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'_')
                        && !k.as_bytes()[0].is_ascii_digit()
                        && v.len() <= 4096
                        && !v.contains('\0')
                        && !v.contains('\n')
                        && !v.contains('\r')
                }),
            "invalid_env"
        );
        if self.processes.iter().any(|p| p.program == "gradlew") {
            let gradlew = self.path.join("gradlew");
            ensure!(
                gradlew.is_file()
                    && !std::fs::symlink_metadata(&gradlew)?
                        .file_type()
                        .is_symlink(),
                "gradlew_missing"
            );
        }
        let mut names = std::collections::HashSet::new();
        for process in &self.processes {
            validate_id(&process.name)?;
            ensure!(names.insert(&process.name), "duplicate_process");
            ensure!(
                PROGRAMS.contains(&process.program.as_str()),
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
        if let Some(link) = &self.gcp {
            link.validate()?;
        }
        Ok(())
    }
}

#[cfg(test)]
#[path = "model_tests.rs"]
mod tests;
