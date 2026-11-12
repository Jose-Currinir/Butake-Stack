//! Downloadable tools (Node, Caddy). Nothing is pinned in code: the user lists the versions
//! published by the official source, picks one, and the engine verifies the archive against
//! that version's official checksum file before it becomes usable.
use crate::store::Store;
use anyhow::{ensure, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256, Sha512};
use std::{
    fs,
    io::Read,
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

pub const TOOLS: [&str; 9] = ["node", "caddy", "mysql", "redis", "postgres", "mongodb", "valkey", "meilisearch", "typesense"];
pub const TOOLS_EXTRA: [&str; 1] = ["rustfs"];

/// Oracle signs and notarizes its macOS MySQL binaries; this is its Apple Team ID.
const ORACLE_TEAM: &str = "VB5E2TV963";
const REDIS_HASHES: &str = "https://raw.githubusercontent.com/redis/redis-hashes/master/README";

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
}

pub fn validate_tool(tool: &str) -> Result<()> {
    ensure!(TOOLS.contains(&tool) || TOOLS_EXTRA.contains(&tool), "unknown_tool");
    Ok(())
}

pub fn validate_version(version: &str) -> Result<()> {
    let parts: Vec<_> = version.split('.').collect();
    ensure!(
        (2..=3).contains(&parts.len())
            && parts
                .iter()
                .all(|p| !p.is_empty() && p.len() <= 6 && p.bytes().all(|c| c.is_ascii_digit())),
        "invalid_version"
    );
    Ok(())
}

/// HTTPS-only fetch through the system curl, with a hard size limit.
pub fn fetch(url: &str, limit: u64) -> Result<Vec<u8>> {
    ensure!(url.starts_with("https://"), "insecure_url");
    let mut child = Command::new("/usr/bin/curl")
        .args(["--proto", "=https", "--tlsv1.2", "-fsSL", "--max-time", "60"])
        .args(["-H", "User-Agent: butake-stack"])
        .arg(url)
        .env_clear()
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    let mut data = Vec::new();
    child
        .stdout
        .take()
        .unwrap()
        .take(limit + 1)
        .read_to_end(&mut data)?;
    let status = child.wait()?;
    ensure!(status.success(), "download_failed");
    ensure!(data.len() as u64 <= limit, "download_too_large");
    Ok(data)
}

pub fn download(url: &str, target: &Path) -> Result<()> {
    ensure!(url.starts_with("https://"), "insecure_url");
    let status = Command::new("/usr/bin/curl")
        .args(["--proto", "=https", "--tlsv1.2", "-fsSL", "--max-time", "900"])
        .args(["--max-filesize", "500000000", "-o"])
        .arg(target)
        .arg(url)
        .env_clear()
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()?;
    ensure!(status.success(), "download_failed");
    Ok(())
}

fn digest<D: Digest>(path: &Path) -> Result<String> {
    let mut file = fs::File::open(path)?;
    let mut hash = D::new();
    let mut buffer = [0; 65536];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        hash.update(&buffer[..count]);
    }
    Ok(hash
        .finalize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect())
}

pub fn available(tool: &str) -> Result<Vec<Available>> {
    validate_tool(tool)?;
    match tool {
        "node" => {
            let index: serde_json::Value =
                serde_json::from_slice(&fetch("https://nodejs.org/dist/index.json", 8_000_000)?)?;
            let mut out = vec![];
            let mut per_major = std::collections::BTreeMap::<String, usize>::new();
            for entry in index.as_array().into_iter().flatten() {
                let version = entry["version"].as_str().unwrap_or("").trim_start_matches('v');
                if validate_version(version).is_err()
                    || !entry["files"]
                        .as_array()
                        .is_some_and(|f| f.iter().any(|x| x == "osx-arm64-tar"))
                {
                    continue;
                }
                let major = version.split('.').next().unwrap().to_string();
                if major.parse::<u32>().unwrap_or(0) < 18 {
                    continue;
                }
                let count = per_major.entry(major).or_default();
                if *count >= 3 {
                    continue;
                }
                *count += 1;
                out.push(Available {
                    version: version.into(),
                    label: entry["lts"].as_str().map(|s| format!("LTS {s}")),
                    date: entry["date"].as_str().map(Into::into),
                });
            }
            Ok(out)
        }
        "caddy" => {
            let releases: serde_json::Value = serde_json::from_slice(&fetch(
                "https://api.github.com/repos/caddyserver/caddy/releases?per_page=15",
                12_000_000,
            )?)?;
            Ok(releases
                .as_array()
                .into_iter()
                .flatten()
                .filter(|r| r["prerelease"] == false && r["draft"] == false)
                .filter_map(|r| {
                    let version = r["tag_name"].as_str()?.trim_start_matches('v');
                    validate_version(version).ok()?;
                    Some(Available {
                        version: version.into(),
                        label: None,
                        date: r["published_at"].as_str().map(|d| d[..10.min(d.len())].into()),
                    })
                })
                .collect())
        }
        "mysql" => {
            // Oracle has no version API: probe its CDN for every patch of the supported series.
            let mut urls = vec![];
            for series in ["8.4", "8.0"] {
                for patch in 0..=60 {
                    urls.push(mysql_url(&format!("{series}.{patch}")));
                }
            }
            let mut command = Command::new("/usr/bin/curl");
            command
                .args(["--proto", "=https", "-sI", "--parallel", "--parallel-max", "16"])
                .args(["--max-time", "20", "-o", "/dev/null", "-w", "%{url} %{http_code}\\n"])
                .args(&urls)
                .env_clear();
            let output = command.output()?;
            let text = String::from_utf8_lossy(&output.stdout);
            let mut found: Vec<String> = text
                .lines()
                .filter(|l| l.ends_with(" 200"))
                .filter_map(|l| l.split("/mysql-").nth(1)?.split("-macos").next().map(str::to_string))
                .filter(|v| validate_version(v).is_ok())
                .collect();
            found.sort_by_key(|v| std::cmp::Reverse(version_key(v)));
            Ok(found
                .into_iter()
                .map(|version| Available {
                    label: Some(if version.starts_with("8.4.") { "LTS".into() } else { "Sin soporte".into() }),
                    version,
                    date: None,
                })
                .collect())
        }
        "redis" => {
            let text = String::from_utf8(fetch(REDIS_HASHES, 2_000_000)?)?;
            let mut versions: Vec<String> = text
                .lines()
                .filter_map(|l| l.split_whitespace().nth(1)?.strip_prefix("redis-")?.strip_suffix(".tar.gz").map(str::to_string))
                .filter(|v| validate_version(v).is_ok() && v.starts_with(|c: char| c >= '7'))
                .collect();
            versions.sort_by_key(|v| std::cmp::Reverse(version_key(v)));
            versions.dedup();
            let mut per_minor = std::collections::BTreeMap::<String, usize>::new();
            Ok(versions
                .into_iter()
                .filter(|v| {
                    let minor = v.rsplit_once('.').unwrap().0.to_string();
                    let count = per_minor.entry(minor).or_default();
                    *count += 1;
                    *count <= 2
                })
                .map(|version| Available { version, label: None, date: None })
                .collect())
        }
        "postgres" => {
            // The official source index lists one folder per release (v17.6/ …).
            let index = String::from_utf8(fetch("https://ftp.postgresql.org/pub/source/", 2_000_000)?)?;
            let mut versions: Vec<String> = index
                .split("href=\"v")
                .skip(1)
                .filter_map(|chunk| chunk.split('/').next().map(str::to_string))
                .filter(|v| {
                    let parts: Vec<_> = v.split('.').collect();
                    parts.len() == 2 && parts.iter().all(|p| p.bytes().all(|c| c.is_ascii_digit()))
                        && parts[0].parse::<u32>().unwrap_or(0) >= 15
                })
                .collect();
            versions.sort_by_key(|v| std::cmp::Reverse(version_key(v)));
            versions.dedup();
            let mut per_major = std::collections::BTreeMap::<String, usize>::new();
            Ok(versions
                .into_iter()
                .filter(|v| {
                    let count = per_major.entry(v.split('.').next().unwrap().to_string()).or_default();
                    *count += 1;
                    *count <= 2
                })
                .map(|version| Available { version, label: None, date: None })
                .collect())
        }
        "mongodb" => {
            let index: serde_json::Value = serde_json::from_slice(&fetch("https://downloads.mongodb.org/full.json", 80_000_000)?)?;
            let mut out = vec![];
            for entry in index["versions"].as_array().into_iter().flatten() {
                let version = entry["version"].as_str().unwrap_or("");
                let has_mac = entry["downloads"].as_array().is_some_and(|d| d.iter().any(|x| x["target"] == "macos" && x["arch"] == "arm64"));
                if entry["production_release"] == true && has_mac && validate_version(version).is_ok() && out.len() < 8 {
                    out.push(Available { version: version.into(), label: (entry["current"] == true).then(|| "Actual".into()), date: entry["date"].as_str().map(|d| d[..10.min(d.len())].into()) });
                }
            }
            Ok(out)
        }
        "valkey" | "meilisearch" | "typesense" | "rustfs" => {
            let repo = match tool {
                "valkey" => "valkey-io/valkey",
                "meilisearch" => "meilisearch/meilisearch",
                "typesense" => "typesense/typesense",
                _ => "rustfs/rustfs",
            };
            let releases: serde_json::Value = serde_json::from_slice(&fetch(&format!("https://api.github.com/repos/{repo}/releases?per_page=8"), 30_000_000)?)?;
            Ok(releases
                .as_array()
                .into_iter()
                .flatten()
                .filter(|r| r["prerelease"] == false && r["draft"] == false)
                // Meilisearch sometimes publishes a release before its Apple Silicon binary.
                .filter(|r| tool != "meilisearch" || r["assets"].as_array().is_some_and(|a| a.iter().any(|x| x["name"] == "meilisearch-macos-apple-silicon")))
                .filter_map(|r| {
                    let version = r["tag_name"].as_str()?.trim_start_matches('v');
                    validate_version(version).ok()?;
                    Some(Available { version: version.into(), label: (tool == "typesense").then(|| "Sólo HTTPS".into()), date: r["published_at"].as_str().map(|d| d[..10.min(d.len())].into()) })
                })
                .collect())
        }
        _ => unreachable!(),
    }
}

fn mysql_url(version: &str) -> String {
    let series = version.rsplit_once('.').map(|x| x.0).unwrap_or(version);
    format!("https://cdn.mysql.com/Downloads/MySQL-{series}/mysql-{version}-macos15-arm64.tar.gz")
}

enum Verify {
    /// The vendor publishes no checksum; only HTTPS protects the download (shown in the UI).
    HttpsOnly,
    /// SHA-256 taken from the GitHub release asset's `digest` (`api` = release endpoint).
    GithubDigest(String),
    Sha256,
    Sha512,
    /// Apple code signature with the vendor's Team ID (vendor publishes no checksum file).
    Codesign(&'static str),
}

/// Release lines of a tool with their support dates, from endoflife.date (which tracks each
/// project's official policy). Tools it does not cover return an empty list.
pub fn lifecycle(tool: &str) -> Result<serde_json::Value> {
    let product = match tool {
        "node" => "nodejs",
        "postgres" => "postgresql",
        "mysql" | "redis" | "mongodb" | "valkey" | "php" | "caddy" | "meilisearch" => tool,
        _ => return Ok(serde_json::json!([])),
    };
    let data: serde_json::Value = serde_json::from_slice(&fetch(&format!("https://endoflife.date/api/{product}.json"), 2_000_000)?)?;
    let cycles: Vec<serde_json::Value> = data
        .as_array()
        .into_iter()
        .flatten()
        .take(16)
        .map(|c| serde_json::json!({"cycle": c["cycle"].as_str().map(str::to_string).unwrap_or_else(|| c["cycle"].to_string()),
            "lts": c["lts"], "support": c["support"], "eol": c["eol"], "latest": c["latest"]}))
        .collect();
    Ok(serde_json::json!(cycles))
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
    /// `configure && make && make install` into the version folder (PostgreSQL).
    Autotools(&'static [&'static str]),
}

fn source(tool: &str, version: &str) -> Source {
    match tool {
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
            build: Build::Autotools(&["--without-icu", "--without-readline"]),
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
            checksum_url: "https".into(),
            verify: Verify::HttpsOnly,
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
        "mysql" => &["bin/mysqld", "bin/mysql", "bin/mysqldump"],
        "redis" => &["bin/redis-server", "bin/redis-cli"],
        "postgres" => &["bin/postgres", "bin/initdb", "bin/psql", "bin/pg_dump", "bin/pg_isready"],
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

fn check_tree(root: &Path) -> Result<()> {
    let base = root.canonicalize()?;
    let mut pending = vec![base.clone()];
    while let Some(dir) = pending.pop() {
        for item in fs::read_dir(&dir)? {
            let item = item?;
            let kind = item.file_type()?;
            if kind.is_symlink() {
                // npm and npx are relative links inside the Node tree; nothing may point out.
                let target = item.path().canonicalize()?;
                ensure!(target.starts_with(&base), "unsafe_package_member");
            } else if kind.is_dir() {
                pending.push(item.path());
            }
        }
    }
    Ok(())
}

pub fn install(store: &Store, tool: &str, version: &str) -> Result<ToolManifest> {
    validate_tool(tool)?;
    validate_version(version)?;
    let root = tool_root(store, tool)?;
    let target = root.join(version);
    ensure!(!target.exists(), "runtime_exists");
    let src = source(tool, version);
    let expected = match &src.verify {
        Verify::Codesign(_) | Verify::HttpsOnly => None,
        Verify::GithubDigest(api) => {
            let release: serde_json::Value = serde_json::from_slice(&fetch(api, 30_000_000)?)?;
            let digest = release["assets"]
                .as_array()
                .and_then(|a| a.iter().find(|x| x["name"] == src.archive.as_str()))
                .and_then(|x| x["digest"].as_str())
                .and_then(|d| d.strip_prefix("sha256:"))
                .ok_or_else(|| anyhow::anyhow!("checksum_missing"))?;
            Some(digest.to_ascii_lowercase())
        }
        _ => {
            let sums = String::from_utf8(fetch(&src.checksum_url, 2_000_000)?)?;
            Some(
                sums.lines()
                    .find_map(|line| {
                        let parts: Vec<&str> = line.split_whitespace().collect();
                        // "HASH  name" (nodejs.org, Caddy) or "hash name sha256 HASH url" (Redis).
                        match parts.as_slice() {
                            ["hash", name, "sha256", hash, ..] if *name == src.archive => Some(hash.to_ascii_lowercase()),
                            [hash, name, ..] if name.trim_start_matches('*') == src.archive => Some(hash.to_ascii_lowercase()),
                            _ => None,
                        }
                    })
                    .ok_or_else(|| anyhow::anyhow!("checksum_missing"))?,
            )
        }
    };
    let cache = store.directory("cache")?;
    let archive = cache.join(&src.archive);
    let _ = fs::remove_file(&archive);
    let staging = root.join(format!(".install-{version}-{}", std::process::id()));
    let result = (|| -> Result<ToolManifest> {
        download(&src.url, &archive)?;
        match src.verify {
            Verify::Sha256 | Verify::GithubDigest(_) => ensure!(Some(digest::<Sha256>(&archive)?) == expected, "checksum_mismatch"),
            Verify::HttpsOnly => {}
            Verify::Sha512 => ensure!(Some(digest::<Sha512>(&archive)?) == expected, "checksum_mismatch"),
            Verify::Codesign(_) => {}
        }
        if staging.exists() {
            fs::remove_dir_all(&staging)?;
        }
        fs::create_dir(&staging)?;
        let bin = staging.join("bin");
        match src.layout {
            Layout::Binary(name) => {
                fs::create_dir_all(&bin)?;
                fs::copy(&archive, bin.join(name))?;
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(bin.join(name), fs::Permissions::from_mode(0o755))?;
            }
            Layout::ZipIntoBin => {
                fs::create_dir_all(&bin)?;
                let status = Command::new("/usr/bin/unzip").args(["-q", "-o"]).arg(&archive).arg("-d").arg(&bin).env_clear().status()?;
                ensure!(status.success(), "package_extract_failed");
            }
            Layout::Tar | Layout::TarIntoBin => {
                let into = if src.layout == Layout::TarIntoBin { fs::create_dir_all(&bin)?; bin.clone() } else { staging.clone() };
                let mut tar = Command::new("/usr/bin/tar");
                tar.arg("-xzf").arg(&archive).arg("-C").arg(&into).arg("--no-same-owner");
                if src.strip {
                    tar.args(["--strip-components", "1"]);
                }
                ensure!(tar.env_clear().status()?.success(), "package_extract_failed");
            }
        }
        check_tree(&staging)?;
        match src.build {
            Build::None => {}
            Build::Make(programs) => build_from_source(&staging, programs)?,
            Build::Autotools(flags) => build_autotools(&staging, flags)?,
        }
        if let Verify::Codesign(team) = src.verify {
            for exe in executables(tool) {
                verify_signature(&staging.join(exe), team)?;
            }
        }
        for exe in executables(tool) {
            ensure!(staging.join(exe).exists(), "package_incomplete");
        }
        let manifest = ToolManifest {
            tool: tool.into(),
            version: version.into(),
            url: src.url.clone(),
            checksum_url: src.checksum_url.clone(),
            sha256: digest::<Sha256>(&archive)?,
            installed_at: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)?
                .as_secs(),
        };
        fs::write(
            staging.join("butake-manifest.json"),
            serde_json::to_vec_pretty(&manifest)?,
        )?;
        fs::rename(&staging, &target)?;
        Ok(manifest)
    })();
    let _ = fs::remove_file(&archive);
    if staging.exists() {
        let _ = fs::remove_dir_all(&staging);
    }
    result
}

/// `codesign` checks the signature chain up to Apple and that the leaf belongs to `team`.
fn verify_signature(path: &Path, team: &str) -> Result<()> {
    let requirement = format!("=anchor apple generic and certificate leaf[subject.OU] = \"{team}\"");
    let status = Command::new("/usr/bin/codesign")
        .args(["--verify", "--strict", "-R", &requirement])
        .arg(path)
        .env_clear()
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()?;
    ensure!(status.success(), "signature_invalid");
    Ok(())
}

/// Builds Redis in place with the system toolchain and keeps only the binaries and license.
fn build_from_source(root: &Path, programs: &[&str]) -> Result<()> {
    let jobs = std::thread::available_parallelism().map(|n| n.get().min(8)).unwrap_or(4);
    let status = Command::new("/usr/bin/make")
        .arg(format!("-j{jobs}"))
        .args(["BUILD_TLS=no", "MALLOC=libc"])
        .current_dir(root)
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()?;
    ensure!(status.success(), "build_failed");
    let bin = root.join("bin");
    fs::create_dir_all(&bin)?;
    for name in programs {
        fs::rename(root.join("src").join(name), bin.join(name))?;
    }
    for item in fs::read_dir(root)? {
        let item = item?;
        let name = item.file_name();
        if name != "bin" && name != "LICENSE.txt" && name != "README.md" && name != "COPYING" {
            let path = item.path();
            if item.file_type()?.is_dir() { fs::remove_dir_all(path)? } else { fs::remove_file(path)? }
        }
    }
    Ok(())
}

/// configure/make/install into `<root>/dist`, then keep only the installed tree. PostgreSQL
/// finds its share and lib folders relative to its binaries, so the result is relocatable.
fn build_autotools(root: &Path, flags: &[&str]) -> Result<()> {
    let dist = root.join("dist");
    let jobs = std::thread::available_parallelism().map(|n| n.get().min(8)).unwrap_or(4);
    let run = |program: &str, args: Vec<String>| -> Result<()> {
        let status = Command::new(program)
            .args(&args)
            .current_dir(root)
            .env_clear()
            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()?;
        ensure!(status.success(), "build_failed");
        Ok(())
    };
    let mut configure = vec!["configure".to_string(), format!("--prefix={}", dist.display())];
    configure.extend(flags.iter().map(|f| f.to_string()));
    run("/bin/sh", configure)?;
    run("/usr/bin/make", vec![format!("-j{jobs}")])?;
    run("/usr/bin/make", vec!["install".into()])?;
    relocate(&dist)?;
    let keep = root.join(".keep");
    fs::rename(&dist, &keep)?;
    for item in fs::read_dir(root)? {
        let item = item?;
        if item.file_name() != ".keep" {
            let path = item.path();
            if item.file_type()?.is_dir() { fs::remove_dir_all(path)? } else { fs::remove_file(path)? }
        }
    }
    for item in fs::read_dir(&keep)? {
        let item = item?;
        fs::rename(item.path(), root.join(item.file_name()))?;
    }
    fs::remove_dir(&keep)?;
    Ok(())
}

/// Rewrites absolute library references under `prefix` to `@loader_path` so the tree keeps
/// working after it moves, then re-signs ad hoc (arm64 refuses modified, unsigned Mach-O).
fn relocate(prefix: &Path) -> Result<()> {
    let prefix_text = prefix.to_string_lossy().into_owned();
    let mut files = vec![];
    for folder in ["bin", "lib", "lib/postgresql"] {
        if let Ok(entries) = fs::read_dir(prefix.join(folder)) {
            for entry in entries.flatten() {
                let path = entry.path();
                if !entry.file_type().map(|t| t.is_file()).unwrap_or(false) {
                    continue;
                }
                // Static archives are only for linking extensions; a local server never uses them.
                if path.extension().is_some_and(|e| e == "a") {
                    fs::remove_file(&path)?;
                    continue;
                }
                files.push((folder, path));
            }
        }
    }
    for (folder, file) in files {
        let output = Command::new("/usr/bin/otool").arg("-L").arg(&file).env_clear().output()?;
        if !output.status.success() {
            continue; // not a Mach-O file
        }
        let text = String::from_utf8_lossy(&output.stdout).into_owned();
        let mut changed = false;
        for line in text.lines().skip(1) {
            let Some(dep) = line.trim().split(" (").next() else { continue };
            let own = file.file_name().map(|n| dep.ends_with(&format!("/{}", n.to_string_lossy()))).unwrap_or(false);
            if folder == "lib" && own {
                continue; // a library's own id is rewritten with -id below
            }
            if let Some(rest) = dep.strip_prefix(&format!("{prefix_text}/lib/")) {
                let up = match folder {
                    "bin" => "../lib/",
                    "lib" => "",
                    _ => "../",
                };
                let status = Command::new("/usr/bin/install_name_tool")
                    .args(["-change", dep, &format!("@loader_path/{up}{rest}")])
                    .arg(&file)
                    .env_clear()
                    .stderr(Stdio::null())
                    .status()?;
                ensure!(status.success(), "relocate_failed: {} <- {dep}", file.display());
                changed = true;
            }
        }
        if folder == "lib" && file.extension().is_some_and(|e| e == "dylib") {
            let name = file.file_name().unwrap().to_string_lossy().into_owned();
            let _ = Command::new("/usr/bin/install_name_tool")
                .args(["-id", &format!("@rpath/{name}")])
                .arg(&file)
                .env_clear()
                .stderr(Stdio::null())
                .status()?;
            changed = true;
        }
        if changed {
            let status = Command::new("/usr/bin/codesign")
                .args(["--force", "--sign", "-"])
                .arg(&file)
                .env_clear()
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()?;
            ensure!(status.success(), "resign_failed");
        }
    }
    Ok(())
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
            if let Ok(manifest) = serde_json::from_slice::<ToolManifest>(&data) {
                if manifest.version == name
                    && manifest.tool == tool
                    && executables(tool).iter().all(|e| item.path().join(e).exists())
                {
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

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn validates_and_resolves_versions() {
        for v in ["22.23.5", "2.11.9"] {
            validate_version(v).unwrap();
        }
        validate_version("17.11").unwrap();
        for v in ["22", "1.2.3.4", "1.2.x", "../1.2.3", "1.2.3; rm", "17."] {
            assert!(validate_version(v).is_err(), "{v}");
        }
        assert!(validate_tool("php").is_err());
        let temp = tempfile::tempdir().unwrap();
        let store = Store::new(temp.path().join("s")).unwrap();
        for v in ["22.1.0", "22.23.5", "24.2.0"] {
            let dir = temp.path().join("s/runtimes/node").join(v);
            fs::create_dir_all(dir.join("bin")).unwrap();
            for e in executables("node") {
                fs::write(dir.join(e), "").unwrap();
            }
            let m = ToolManifest {
                tool: "node".into(),
                version: v.into(),
                url: String::new(),
                checksum_url: String::new(),
                sha256: String::new(),
                installed_at: 0,
            };
            fs::write(dir.join("butake-manifest.json"), serde_json::to_vec(&m).unwrap()).unwrap();
        }
        assert!(resolve(&store, "node", "22").unwrap().ends_with("22.23.5"));
        assert!(resolve(&store, "node", "").unwrap().ends_with("24.2.0"));
        assert!(resolve(&store, "node", "20").is_none());
        // A link pointing outside the tool tree is rejected.
        let dir = temp.path().join("s/runtimes/node/24.2.0");
        std::os::unix::fs::symlink("/etc", dir.join("bin/escape")).unwrap();
        assert!(check_tree(&dir).is_err());
        remove(&store, "node", "22.1.0").unwrap();
        assert_eq!(installed(&store, "node").unwrap().len(), 2);
        assert!(remove(&store, "node", "../x").is_err());
    }
}
