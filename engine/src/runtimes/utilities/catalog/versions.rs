//! The versions each piece's official source publishes, and the support dates of its release lines.

use super::*;

pub fn available(store: &Store, tool: &str) -> Result<Vec<Available>> {
    validate_tool(tool)?;
    match tool {
        "jdk" => {
            // Eclipse Temurin GA builds for Apple Silicon: the LTS lines and the newest one, three
            // versions each; stored as "major.minor.security.build" (21.0.5+11 -> 21.0.5.11).
            let base = "https://api.adoptium.net/v3/info";
            let info: serde_json::Value =
                serde_json::from_slice(&fetch(&format!("{base}/available_releases"), 200_000)?)?;
            let newest = info["most_recent_feature_release"].as_u64().unwrap_or(25);
            let lts: Vec<u64> = info["available_lts_releases"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|v| v.as_u64())
                .filter(|m| *m >= 17)
                .collect();
            let mut majors: Vec<u64> = lts.clone();
            if !majors.contains(&newest) {
                majors.push(newest);
            }
            majors.sort_by(|a, b| b.cmp(a));
            let mut out = vec![];
            for major in majors {
                let url = format!("{base}/release_versions?architecture=aarch64&os=mac&image_type=jdk&vendor=eclipse&release_type=ga&page_size=10&sort_order=DESC&project=jdk&version=%5B{major}%2C{}%29", major + 1);
                let data: serde_json::Value = serde_json::from_slice(&fetch(&url, 500_000)?)?;
                let mut count = 0;
                for v in data["versions"].as_array().into_iter().flatten() {
                    let (Some(m), Some(minor), Some(security), Some(build)) = (
                        v["major"].as_u64(),
                        v["minor"].as_u64(),
                        v["security"].as_u64(),
                        v["build"].as_u64(),
                    ) else {
                        continue;
                    };
                    if m != major || v["patch"].as_u64().is_some_and(|p| p > 0) || count >= 3 {
                        continue;
                    }
                    count += 1;
                    out.push(Available {
                        version: format!("{major}.{minor}.{security}.{build}"),
                        label: Some(if lts.contains(&major) {
                            format!("LTS · Java {major}")
                        } else {
                            format!("Java {major}")
                        }),
                        date: None,
                    });
                }
            }
            Ok(out)
        }
        "node" => {
            let index: serde_json::Value =
                serde_json::from_slice(&fetch("https://nodejs.org/dist/index.json", 8_000_000)?)?;
            let mut out = vec![];
            let mut per_major = std::collections::BTreeMap::<String, usize>::new();
            for entry in index.as_array().into_iter().flatten() {
                let version = entry["version"]
                    .as_str()
                    .unwrap_or("")
                    .trim_start_matches('v');
                if validate_version(version).is_err()
                    || !entry["files"]
                        .as_array()
                        .is_some_and(|f| f.iter().any(|x| x == "osx-arm64-tar"))
                {
                    continue;
                }
                let major = version.split('.').next().unwrap_or_default().to_string();
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
            let releases = crate::core::github::api(
                store,
                "https://api.github.com/repos/caddyserver/caddy/releases?per_page=15",
            )?;
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
                        date: r["published_at"]
                            .as_str()
                            .map(|d| d[..10.min(d.len())].into()),
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
                .args([
                    "--proto",
                    "=https",
                    "-sI",
                    "--parallel",
                    "--parallel-max",
                    "16",
                ])
                .args([
                    "--max-time",
                    "20",
                    "-o",
                    "/dev/null",
                    "-w",
                    "%{url} %{http_code}\\n",
                ])
                .args(&urls)
                .env_clear();
            let output = command.output()?;
            let text = String::from_utf8_lossy(&output.stdout);
            let mut found: Vec<String> = text
                .lines()
                .filter(|l| l.ends_with(" 200"))
                .filter_map(|l| {
                    l.split("/mysql-")
                        .nth(1)?
                        .split("-macos")
                        .next()
                        .map(str::to_string)
                })
                .filter(|v| validate_version(v).is_ok())
                .collect();
            found.sort_by_key(|v| std::cmp::Reverse(version_key(v)));
            Ok(found
                .into_iter()
                .map(|version| Available {
                    label: Some(if version.starts_with("8.4.") {
                        "LTS".into()
                    } else {
                        "Sin soporte".into()
                    }),
                    version,
                    date: None,
                })
                .collect())
        }
        "redis" => {
            let text = String::from_utf8(fetch(REDIS_HASHES, 2_000_000)?)?;
            let mut versions: Vec<String> = text
                .lines()
                .filter_map(|l| {
                    l.split_whitespace()
                        .nth(1)?
                        .strip_prefix("redis-")?
                        .strip_suffix(".tar.gz")
                        .map(str::to_string)
                })
                .filter(|v| validate_version(v).is_ok() && v.starts_with(|c: char| c >= '7'))
                .collect();
            versions.sort_by_key(|v| std::cmp::Reverse(version_key(v)));
            versions.dedup();
            let mut per_minor = std::collections::BTreeMap::<String, usize>::new();
            Ok(versions
                .into_iter()
                .filter(|v| {
                    let minor = v
                        .rsplit_once('.')
                        .map_or(v.as_str(), |(minor, _)| minor)
                        .to_string();
                    let count = per_minor.entry(minor).or_default();
                    *count += 1;
                    *count <= 2
                })
                .map(|version| Available {
                    version,
                    label: None,
                    date: None,
                })
                .collect())
        }
        "postgres" => {
            // The official source index lists one folder per release (v17.6/ …).
            let index =
                String::from_utf8(fetch("https://ftp.postgresql.org/pub/source/", 2_000_000)?)?;
            let mut versions: Vec<String> = index
                .split("href=\"v")
                .skip(1)
                .filter_map(|chunk| chunk.split('/').next().map(str::to_string))
                .filter(|v| {
                    let parts: Vec<_> = v.split('.').collect();
                    parts.len() == 2
                        && parts.iter().all(|p| p.bytes().all(|c| c.is_ascii_digit()))
                        && parts[0].parse::<u32>().unwrap_or(0) >= 15
                })
                .collect();
            versions.sort_by_key(|v| std::cmp::Reverse(version_key(v)));
            versions.dedup();
            let mut per_major = std::collections::BTreeMap::<String, usize>::new();
            Ok(versions
                .into_iter()
                .filter(|v| {
                    let count = per_major
                        .entry(v.split('.').next().unwrap_or_default().to_string())
                        .or_default();
                    *count += 1;
                    *count <= 2
                })
                .map(|version| Available {
                    version,
                    label: None,
                    date: None,
                })
                .collect())
        }
        "mongodb" => {
            let index: serde_json::Value = serde_json::from_slice(&fetch(
                "https://downloads.mongodb.org/full.json",
                80_000_000,
            )?)?;
            let mut out = vec![];
            for entry in index["versions"].as_array().into_iter().flatten() {
                let version = entry["version"].as_str().unwrap_or("");
                let has_mac = entry["downloads"].as_array().is_some_and(|d| {
                    d.iter()
                        .any(|x| x["target"] == "macos" && x["arch"] == "arm64")
                });
                if entry["production_release"] == true
                    && has_mac
                    && validate_version(version).is_ok()
                    && out.len() < 8
                {
                    out.push(Available {
                        version: version.into(),
                        label: (entry["current"] == true).then(|| "Actual".into()),
                        date: entry["date"].as_str().map(|d| d[..10.min(d.len())].into()),
                    });
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
            let releases = crate::core::github::api(
                store,
                &format!("https://api.github.com/repos/{repo}/releases?per_page=8"),
            )?;
            Ok(releases
                .as_array()
                .into_iter()
                .flatten()
                .filter(|r| r["prerelease"] == false && r["draft"] == false)
                // Meilisearch sometimes publishes a release before its Apple Silicon binary.
                .filter(|r| {
                    tool != "meilisearch"
                        || r["assets"].as_array().is_some_and(|a| {
                            a.iter()
                                .any(|x| x["name"] == "meilisearch-macos-apple-silicon")
                        })
                })
                .filter_map(|r| {
                    let version = r["tag_name"].as_str()?.trim_start_matches('v');
                    validate_version(version).ok()?;
                    Some(Available {
                        version: version.into(),
                        label: (tool == "typesense").then(|| "Sólo HTTPS".into()),
                        date: r["published_at"]
                            .as_str()
                            .map(|d| d[..10.min(d.len())].into()),
                    })
                })
                .collect())
        }
        _ => unreachable!(),
    }
}

/// Release lines of a tool with their support dates, from endoflife.date (which tracks each
/// project's official policy). Tools it does not cover return an empty list.
pub fn lifecycle(tool: &str) -> Result<serde_json::Value> {
    let product = match tool {
        "node" => "nodejs",
        "jdk" => "eclipse-temurin",
        "postgres" => "postgresql",
        "mysql" | "redis" | "mongodb" | "valkey" | "php" | "caddy" | "meilisearch" | "python"
        | "rust" => tool,
        _ => return Ok(serde_json::json!([])),
    };
    let data: serde_json::Value = serde_json::from_slice(&fetch(
        &format!("https://endoflife.date/api/{product}.json"),
        2_000_000,
    )?)?;
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
