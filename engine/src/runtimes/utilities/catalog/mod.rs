//! Downloadable tools (Node, Caddy). No version is pinned in code: the user lists the versions
//! published by the official source, picks one, and the engine verifies the archive against
//! that version's official checksum file before it becomes usable. The one exception is the
//! OpenSSL built into PostgreSQL, a dependency pinned by version and SHA-256.
//!
//! Here: what each piece is and where it comes from, what is installed and the developer tools of
//! the profiles; `versions` lists what a source publishes and `install` downloads and builds.

mod install;
mod versions;

pub use install::*;
pub use versions::*;

use crate::core::store::Store;
use crate::core::time::now_secs;
use crate::core::{
    archive::{self, Links},
    download::{download, fetch},
    hash, progress,
};
use anyhow::{ensure, Result};
use serde::{Deserialize, Serialize};
use std::{
    fs,
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

pub const TOOLS: [&str; 10] = [
    "node",
    "jdk",
    "caddy",
    "mysql",
    "redis",
    "postgres",
    "mongodb",
    "valkey",
    "meilisearch",
    "typesense",
];
pub const TOOLS_EXTRA: [&str; 1] = ["rustfs"];

/// Oracle signs and notarizes its macOS MySQL binaries; this is its Apple Team ID.
const ORACLE_TEAM: &str = "VB5E2TV963";
const REDIS_HASHES: &str = "https://raw.githubusercontent.com/redis/redis-hashes/master/README";
/// OpenSSL for PostgreSQL (`pgcrypto`, `sslinfo`, TLS). Stack builds or downloads no other
/// OpenSSL it could reuse (PHP's package carries its own, linked into the binary; Redis and Valkey
/// build without TLS), so the official LTS source, pinned here by version and SHA-256 (the one
/// published next to it), is compiled statically into each PostgreSQL runtime.
const OPENSSL_VERSION: &str = "3.5.9";
const OPENSSL_SHA256: &str = "603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a";
/// PostgreSQL's `configure` options: the core plus what `contrib` needs (OpenSSL, the system's
/// UUID functions for `uuid-ossp`); no ICU or readline, which macOS does not ship for linking.
const POSTGRES_FLAGS: &[&str] = &[
    "--without-icu",
    "--without-readline",
    "--with-openssl",
    "--with-uuid=e2fs",
];
/// The `contrib` modules every PostgreSQL runtime from Stack must carry: an install without them
/// (built before P-29) is offered «Reinstalar con extensiones».
pub const POSTGRES_EXTENSIONS: &[&str] = &[
    "citext",
    "pgcrypto",
    "uuid-ossp",
    "pg_trgm",
    "unaccent",
    "hstore",
    "btree_gin",
    "btree_gist",
    "pg_stat_statements",
];

fn openssl_url() -> String {
    format!("https://github.com/openssl/openssl/releases/download/openssl-{OPENSSL_VERSION}/openssl-{OPENSSL_VERSION}.tar.gz")
}

#[derive(Debug, Serialize)]
pub struct Available {
    pub version: String,
    pub label: Option<String>,
    pub date: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct ToolManifest {
    pub tool: String,
    pub version: String,
    pub url: String,
    pub checksum_url: String,
    pub sha256: String,
    pub installed_at: u64,
    /// OpenSSL version compiled into the runtime (PostgreSQL).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub openssl: Option<String>,
    /// PostgreSQL only, filled when listing: whether every module of [`POSTGRES_EXTENSIONS`] is
    /// installed. Never written to the manifest.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub extensions: Option<bool>,
}

pub fn validate_tool(tool: &str) -> Result<()> {
    ensure!(
        TOOLS.contains(&tool) || TOOLS_EXTRA.contains(&tool),
        "unknown_tool"
    );
    Ok(())
}

pub fn validate_version(version: &str) -> Result<()> {
    let parts: Vec<_> = version.split('.').collect();
    ensure!(
        (2..=4).contains(&parts.len())
            && parts
                .iter()
                .all(|p| !p.is_empty() && p.len() <= 6 && p.bytes().all(|c| c.is_ascii_digit())),
        "invalid_version"
    );
    Ok(())
}

fn mysql_url(version: &str) -> String {
    let series = version.rsplit_once('.').map(|x| x.0).unwrap_or(version);
    format!("https://cdn.mysql.com/Downloads/MySQL-{series}/mysql-{version}-macos15-arm64.tar.gz")
}

enum Verify {
    /// The vendor publishes no checksum: the SHA-256 of a release is fixed here (see `TYPESENSE`).
    /// `None` is a version Stack has not pinned: refused (`checksum_missing`).
    Pinned(Option<&'static str>),
    /// SHA-256 taken from the GitHub release asset's `digest` (`api` = release endpoint).
    GithubDigest(String),
    Sha256,
    Sha512,
    /// Apple code signature with the vendor's Team ID (vendor publishes no checksum file).
    Codesign(&'static str),
}

struct Source {
    archive: String,
    url: String,
    checksum_url: String,
    verify: Verify,
    strip: bool,
    /// Built from source after extraction (no official macOS binaries).
    build: Build,
    /// How the download becomes the version folder.
    layout: Layout,
}

#[derive(PartialEq, Clone, Copy)]
enum Layout {
    /// tar.gz extracted at the version folder root.
    Tar,
    /// tar.gz whose files go into `bin/`.
    TarIntoBin,
    /// zip whose files go into `bin/`.
    ZipIntoBin,
    /// A single executable saved as `bin/<name>`.
    Binary(&'static str),
}

#[derive(PartialEq)]
enum Build {
    None,
    /// `make` in the source tree, keeping these programs from `src/` (Redis, Valkey).
    Make(&'static [&'static str]),
    /// OpenSSL (static), then PostgreSQL and its `contrib` modules, into the version folder.
    Postgres,
}

/// Typesense publishes no checksum or signature for its macOS builds (`dl.typesense.org` has no
/// `.sha256` and its GitHub releases carry no assets), so the releases Stack installs are pinned
/// with the SHA-256 of the archive downloaded from `https://dl.typesense.org/releases/<version>/
/// typesense-server-<version>-darwin-arm64.tar.gz`. A new release is added here after checking it.
pub(super) const TYPESENSE: &[(&str, &str)] = &[(
    "30.2",
    "7d8d6d0c33930ad20ea23dd184250547b16615944be891b2078e8a075152fa7e",
)];

fn source(tool: &str, version: &str) -> Source {
    match tool {
        "jdk" => {
            // 21.0.5.11 -> release jdk-21.0.5+11, file OpenJDK21U-jdk_aarch64_mac_hotspot_21.0.5_11.tar.gz
            let parts: Vec<&str> = version.split('.').collect();
            let (major, semver, build) = (parts[0], parts[..3].join("."), parts.get(3).copied().unwrap_or("0"));
            let archive = format!("OpenJDK{major}U-jdk_aarch64_mac_hotspot_{semver}_{build}.tar.gz");
            let url = format!("https://github.com/adoptium/temurin{major}-binaries/releases/download/jdk-{semver}%2B{build}/{archive}");
            Source {
                checksum_url: format!("{url}.sha256.txt"),
                url,
                archive,
                verify: Verify::Sha256,
                strip: true,
                build: Build::None,
                layout: Layout::Tar,
            }
        }
        "node" => {
            let archive = format!("node-v{version}-darwin-arm64.tar.gz");
            Source {
                url: format!("https://nodejs.org/dist/v{version}/{archive}"),
                checksum_url: format!("https://nodejs.org/dist/v{version}/SHASUMS256.txt"),
                archive,
                verify: Verify::Sha256,
                strip: true,
                build: Build::None,
                layout: Layout::Tar,
            }
        }
        "mysql" => Source {
            archive: format!("mysql-{version}-macos15-arm64.tar.gz"),
            url: mysql_url(version),
            checksum_url: format!("codesign:{ORACLE_TEAM}"),
            verify: Verify::Codesign(ORACLE_TEAM),
            strip: true,
            build: Build::None,
            layout: Layout::Tar,
        },
        "redis" => Source {
            archive: format!("redis-{version}.tar.gz"),
            url: format!("https://download.redis.io/releases/redis-{version}.tar.gz"),
            checksum_url: REDIS_HASHES.into(),
            verify: Verify::Sha256,
            strip: true,
            build: Build::Make(&["redis-server", "redis-cli"]),
            layout: Layout::Tar,
        },
        "postgres" => Source {
            archive: format!("postgresql-{version}.tar.gz"),
            url: format!("https://ftp.postgresql.org/pub/source/v{version}/postgresql-{version}.tar.gz"),
            checksum_url: format!("https://ftp.postgresql.org/pub/source/v{version}/postgresql-{version}.tar.gz.sha256"),
            verify: Verify::Sha256,
            strip: true,
            build: Build::Postgres,
            layout: Layout::Tar,
        },
        "mongodb" => {
            let archive = format!("mongodb-macos-arm64-{version}.tgz");
            Source {
                url: format!("https://fastdl.mongodb.org/osx/{archive}"),
                checksum_url: format!("https://fastdl.mongodb.org/osx/{archive}.sha256"),
                archive,
                verify: Verify::Sha256,
                strip: true,
                build: Build::None,
                layout: Layout::Tar,
            }
        }
        "valkey" => Source {
            archive: format!("valkey-{version}.tar.gz"),
            url: format!("https://github.com/valkey-io/valkey/archive/refs/tags/{version}.tar.gz"),
            checksum_url: "https://raw.githubusercontent.com/valkey-io/valkey-hashes/main/README".into(),
            verify: Verify::Sha256,
            strip: true,
            build: Build::Make(&["valkey-server", "valkey-cli"]),
            layout: Layout::Tar,
        },
        "meilisearch" => Source {
            archive: "meilisearch-macos-apple-silicon".into(),
            url: format!("https://github.com/meilisearch/meilisearch/releases/download/v{version}/meilisearch-macos-apple-silicon"),
            checksum_url: format!("https://api.github.com/repos/meilisearch/meilisearch/releases/tags/v{version}"),
            verify: Verify::GithubDigest(format!("https://api.github.com/repos/meilisearch/meilisearch/releases/tags/v{version}")),
            strip: false,
            build: Build::None,
            layout: Layout::Binary("meilisearch"),
        },
        "typesense" => Source {
            archive: format!("typesense-server-{version}-darwin-arm64.tar.gz"),
            url: format!("https://dl.typesense.org/releases/{version}/typesense-server-{version}-darwin-arm64.tar.gz"),
            checksum_url: String::new(),
            verify: Verify::Pinned(
                TYPESENSE
                    .iter()
                    .find(|(pinned, _)| *pinned == version)
                    .map(|(_, sum)| *sum),
            ),
            strip: false,
            build: Build::None,
            layout: Layout::TarIntoBin,
        },
        "rustfs" => Source {
            archive: format!("rustfs-macos-aarch64-v{version}.zip"),
            url: format!("https://github.com/rustfs/rustfs/releases/download/{version}/rustfs-macos-aarch64-v{version}.zip"),
            checksum_url: format!("https://github.com/rustfs/rustfs/releases/download/{version}/SHA256SUMS"),
            verify: Verify::Sha256,
            strip: false,
            build: Build::None,
            layout: Layout::ZipIntoBin,
        },
        _ => {
            let archive = format!("caddy_{version}_mac_arm64.tar.gz");
            Source {
                url: format!(
                    "https://github.com/caddyserver/caddy/releases/download/v{version}/{archive}"
                ),
                checksum_url: format!(
                    "https://github.com/caddyserver/caddy/releases/download/v{version}/caddy_{version}_checksums.txt"
                ),
                archive,
                verify: Verify::Sha512,
                strip: false,
                build: Build::None,
                layout: Layout::Tar,
            }
        }
    }
}

/// Executables a tool exposes, relative to its version folder.
pub fn executables(tool: &str) -> &'static [&'static str] {
    match tool {
        "node" => &["bin/node", "bin/npm", "bin/npx"],
        "jdk" => &["Contents/Home/bin/java", "Contents/Home/bin/javac"],
        "mysql" => &["bin/mysqld", "bin/mysql", "bin/mysqldump"],
        "redis" => &["bin/redis-server", "bin/redis-cli"],
        "postgres" => &[
            "bin/postgres",
            "bin/initdb",
            "bin/psql",
            "bin/pg_dump",
            "bin/pg_isready",
        ],
        "mongodb" => &["bin/mongod"],
        "valkey" => &["bin/valkey-server", "bin/valkey-cli"],
        "meilisearch" => &["bin/meilisearch"],
        "typesense" => &["bin/typesense-server"],
        "rustfs" => &["bin/rustfs"],
        _ => &["caddy"],
    }
}

fn tool_root(store: &Store, tool: &str) -> Result<PathBuf> {
    validate_tool(tool)?;
    let runtimes = store.directory("runtimes")?;
    let root = runtimes.join(tool);
    if !root.exists() {
        fs::create_dir(&root)?;
    }
    ensure!(
        !root.symlink_metadata()?.file_type().is_symlink(),
        "unsafe_runtime_path"
    );
    Ok(root)
}

/// The steps an install of `tool` reports (see `progress`): what is built from source says so.
pub fn plan(tool: &str) -> Vec<&'static str> {
    let src = source(tool, "1.0.0.0");
    let verify = match src.verify {
        Verify::Codesign(_) => "verifySignature",
        _ => "verifySum",
    };
    match src.build {
        Build::None => vec!["download", verify, "install"],
        _ => vec!["downloadSource", verify, "build", "install"],
    }
}

pub fn installed(store: &Store, tool: &str) -> Result<Vec<ToolManifest>> {
    let root = tool_root(store, tool)?;
    let mut out = vec![];
    for item in fs::read_dir(root)? {
        let item = item?;
        let name = item.file_name().to_string_lossy().into_owned();
        if validate_version(&name).is_err() || !item.file_type()?.is_dir() {
            continue;
        }
        let path = item.path().join("butake-manifest.json");
        if let Ok(data) = fs::read(&path) {
            if let Ok(mut manifest) = serde_json::from_slice::<ToolManifest>(&data) {
                if manifest.version == name
                    && manifest.tool == tool
                    && executables(tool)
                        .iter()
                        .all(|e| item.path().join(e).exists())
                {
                    manifest.extensions =
                        (tool == "postgres").then(|| postgres_extensions(&item.path()));
                    out.push(manifest);
                }
            }
        }
    }
    out.sort_by_key(|m| version_key(&m.version));
    out.reverse();
    Ok(out)
}

fn version_key(version: &str) -> Vec<u32> {
    version.split('.').map(|p| p.parse().unwrap_or(0)).collect()
}

/// Resolves a wanted version ("22", "22.23", "22.23.5" or empty for the newest) to the
/// folder of the newest installed match.
pub fn resolve(store: &Store, tool: &str, wanted: &str) -> Option<PathBuf> {
    let root = tool_root(store, tool).ok()?;
    installed(store, tool)
        .ok()?
        .into_iter()
        .find(|m| {
            wanted.is_empty() || m.version == wanted || m.version.starts_with(&format!("{wanted}."))
        })
        .map(|m| root.join(m.version))
}

pub fn remove(store: &Store, tool: &str, version: &str) -> Result<()> {
    validate_version(version)?;
    let root = tool_root(store, tool)?;
    let target = root.join(version);
    ensure!(
        target.symlink_metadata()?.is_dir() && target.canonicalize()?.starts_with(&root),
        "unsafe_runtime_path"
    );
    fs::remove_dir_all(target)?;
    Ok(())
}

/// A developer tool installed by its official installer in the user's home (rustup's `~/.cargo/bin`,
/// uv's `~/.local/bin`) or, failing that, in the usual system places.
pub fn user_tool(name: &str) -> Option<PathBuf> {
    let home = crate::runtimes::utilities::devtools::home().ok()?;
    // A temporary home (tests and QA) sees only itself, never the Mac's own installs.
    let isolated = std::env::var_os("BUTAKE_DEVTOOLS_HOME").is_some();
    [
        home.join(".cargo/bin"),
        home.join(".local/bin"),
        PathBuf::from("/opt/homebrew/bin"),
        PathBuf::from("/usr/local/bin"),
    ]
    .into_iter()
    .filter(|dir| !isolated || dir.starts_with(&home))
    .map(|dir| dir.join(name))
    .find(|path| path.is_file())
}

/// Developer tools for the work profiles, as installed on this Mac: where and which version. Only
/// paths and `--version` are read (each with a time limit); nothing is installed or changed.
pub fn dev_tools(store: &Store) -> Result<serde_json::Value> {
    let home = crate::runtimes::utilities::devtools::home().unwrap_or_default();
    let sdk = std::env::var_os("ANDROID_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join("Library/Android/sdk"));
    // Apps' Info.plist may be binary: plutil reads both forms.
    let app_version = |app: &str| -> Option<String> {
        let out = Command::new("/usr/bin/plutil")
            .args(["-extract", "CFBundleShortVersionString", "raw", "-o", "-"])
            .arg(PathBuf::from(app).join("Contents/Info.plist"))
            .stderr(Stdio::null())
            .output()
            .ok()?;
        out.status
            .success()
            .then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
            .filter(|v| !v.is_empty())
    };
    // (id, executable or app, version arguments)
    let checks: Vec<(&str, Option<PathBuf>, &[&str])> = vec![
        ("rustup", user_tool("rustc"), &["--version"]),
        ("uv", user_tool("uv"), &["--version"]),
        ("cloudflared", user_tool("cloudflared"), &["--version"]),
        (
            "wrangler",
            user_tool("wrangler").or_else(|| {
                resolve(store, "node", "")
                    .map(|d| d.join("bin/wrangler"))
                    .filter(|p| p.is_file())
            }),
            &["--version"],
        ),
        ("gh", user_tool("gh"), &["--version"]),
        ("codex", user_tool("codex"), &["--version"]),
        ("claude-code", user_tool("claude"), &["--version"]),
        ("aws", user_tool("aws"), &["--version"]),
        ("cocoapods", user_tool("pod"), &["--version"]),
        ("watchman", user_tool("watchman"), &["--version"]),
        (
            "adb",
            Some(sdk.join("platform-tools/adb")).filter(|p| p.is_file()),
            &["--version"],
        ),
    ];
    let node_path =
        resolve(store, "node", "").map(|d| d.join("bin").to_string_lossy().into_owned());
    let handles: Vec<_> = checks
        .into_iter()
        .map(|(id, path, args)| {
            let node_path = node_path.clone();
            let args: Vec<String> = args.iter().map(|a| a.to_string()).collect();
            std::thread::spawn(move || {
                let version = path.as_ref().and_then(|p| {
                    let mut command = Command::new(p);
                    // Scripts run by their `#!/usr/bin/env node` (Wrangler) find Stack's Node.
                    if let Some(node) = &node_path {
                        command.env(
                            "PATH",
                            format!(
                                "{}:{}",
                                node,
                                std::env::var("PATH").unwrap_or_else(|_| "/usr/bin:/bin".into())
                            ),
                        );
                    }
                    let mut child = command
                        .args(&args)
                        .stdout(Stdio::piped())
                        .stderr(Stdio::null())
                        .stdin(Stdio::null())
                        .spawn()
                        .ok()?;
                    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(8);
                    while child.try_wait().ok()?.is_none() {
                        if std::time::Instant::now() > deadline {
                            let _ = child.kill();
                            return None;
                        }
                        std::thread::sleep(std::time::Duration::from_millis(30));
                    }
                    let mut out = String::new();
                    std::io::Read::read_to_string(child.stdout.as_mut()?, &mut out).ok()?;
                    crate::runtimes::utilities::version_in(&out)
                });
                (id, path, version)
            })
        })
        .collect();
    let mut tools = serde_json::Map::new();
    for handle in handles {
        if let Ok((id, path, version)) = handle.join() {
            // Installed but its `--version` fails: there, but broken (a gem conflict, a missing library…).
            let broken = path.is_some() && version.is_none();
            tools.insert(id.into(), serde_json::json!({"installed": path.is_some(), "version": version, "path": path, "broken": broken}));
        }
    }
    for (id, status) in crate::runtimes::utilities::statuses() {
        tools.insert(id.into(), status);
    }
    crate::runtimes::utilities::mark_managed(store, &mut tools);
    let xcode = PathBuf::from("/Applications/Xcode.app");
    tools.insert("xcode".into(), serde_json::json!({"installed": xcode.is_dir(), "version": app_version("/Applications/Xcode.app"), "path": xcode.is_dir().then_some(xcode)}));
    let clt = Command::new("/usr/bin/xcode-select")
        .arg("-p")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success());
    tools.insert(
        "clt".into(),
        serde_json::json!({"installed": clt, "version": null, "path": null}),
    );
    let studio = "/Applications/Android Studio.app";
    tools.insert("android-studio".into(), serde_json::json!({"installed": PathBuf::from(studio).is_dir(), "version": app_version(studio), "path": PathBuf::from(studio).is_dir().then_some(studio)}));
    tools.insert("android-sdk".into(), serde_json::json!({"installed": sdk.join("platform-tools").is_dir(), "version": null, "path": sdk.is_dir().then_some(&sdk)}));
    for (id, tool) in [("jdk", "jdk"), ("node", "node")] {
        let versions = installed(store, tool).unwrap_or_default();
        let newest = versions
            .iter()
            .map(|m| m.version.clone())
            .max_by(|a, b| compare_versions(a, b));
        tools.insert(
            id.into(),
            serde_json::json!({"installed": newest.is_some(), "version": newest, "path": null}),
        );
    }
    let python = crate::runtimes::languages::python::installed(store);
    tools.insert("python".into(), serde_json::json!({"installed": !python.is_empty(), "version": python.first().map(|m| m.version.clone()), "path": null}));
    let swiftly = crate::runtimes::utilities::devtools::home()
        .map(|h| h.join(".swiftly/bin/swiftly"))
        .ok()
        .filter(|p| p.is_file());
    tools.insert(
        "swiftly".into(),
        serde_json::json!({"installed": swiftly.is_some(), "version": null, "path": swiftly}),
    );
    let php = crate::runtimes::languages::php::list(store);
    let newest_php = php
        .iter()
        .filter(|r| r.installed)
        .map(|r| r.series.clone())
        .max_by(|a, b| compare_versions(a, b));
    tools.insert(
        "php".into(),
        serde_json::json!({"installed": newest_php.is_some(), "version": newest_php, "path": null}),
    );
    Ok(serde_json::Value::Object(tools))
}

fn compare_versions(a: &str, b: &str) -> std::cmp::Ordering {
    let parse = |v: &str| {
        v.split('.')
            .map(|p| p.parse::<u64>().unwrap_or(0))
            .collect::<Vec<_>>()
    };
    parse(a).cmp(&parse(b))
}

#[cfg(test)]
mod tests;
