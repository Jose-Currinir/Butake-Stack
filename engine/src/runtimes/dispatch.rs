//! Requests about languages and tools: versions, installs, toolchains and the terminal links.

use crate::{core::store::Store, daemon, runtimes, web};
use anyhow::Result;
use serde_json::{json, Value};

/// Requests of this domain; `None` when `method` is not one of them.
pub fn dispatch(store: &Store, method: &str, request: &Value) -> Result<Option<Value>> {
    let id = request["id"].as_str().unwrap_or("");
    let result: Result<Value> = match method {
        "installPhpPackage" => {
            anyhow::ensure!(request["confirmed"] == true, "confirmation_required");
            let path = std::path::PathBuf::from(request["path"].as_str().unwrap_or(""));
            anyhow::ensure!(path.is_absolute(), "invalid_package");
            follow(store, "install-php-package")?;
            let manifest = runtimes::languages::php::install_package(store, &path)?;
            runtimes::languages::php::generate_ini(store, &manifest.series)?;
            Ok(serde_json::to_value(manifest)?)
        }
        // Used by scripts/php/build_php.py after a build: writes the runtime's php.ini.
        "generatePhpIni" => Ok(json!(runtimes::languages::php::generate_ini(
            store,
            request["series"].as_str().unwrap_or("")
        )?)),
        // Catalogs are cached on disk (6 h / 12 h / 24 h); "refresh": true asks the source again.
        "phpCatalog" => crate::core::cache::cached(
            store,
            "php-catalog",
            6 * 3600,
            request["refresh"] == true,
            || {
                Ok(serde_json::to_value(
                    runtimes::languages::php::php_catalog()?,
                )?)
            },
        ),
        "downloadPhp" => {
            anyhow::ensure!(request["confirmed"] == true, "confirmation_required");
            follow(store, "install-php")?;
            let manifest = runtimes::languages::php::download_php(
                store,
                request["version"].as_str().unwrap_or(""),
            )?;
            let _ = daemon::request_sync(store, "reload", json!({}), false);
            Ok(serde_json::to_value(manifest)?)
        }
        "devTools" => runtimes::utilities::catalog::dev_tools(store),
        "installDevTool" => {
            anyhow::ensure!(request["confirmed"] == true, "confirmation_required");
            runtimes::utilities::devtools::install(
                store,
                &runtimes::utilities::devtools::Options {
                    tool: request["tool"].as_str().unwrap_or("").into(),
                    version: request["version"].as_str().unwrap_or("").into(),
                    shell_path: request["shellPath"].as_bool().unwrap_or(false),
                    accept_licenses: request["acceptLicenses"] == true,
                },
            )
        }
        // Only what Stack installed (its record lists the paths); a copy installed some other way
        // answers `not_managed` and is left alone.
        "removeDevTool" => {
            anyhow::ensure!(request["confirmed"] == true, "confirmation_required");
            runtimes::utilities::remove(store, request["tool"].as_str().unwrap_or(""))?;
            Ok(json!(true))
        }
        // Where a followed install is: its steps, download and output (core/progress.rs).
        "installProgress" => {
            let name = request["name"].as_str().unwrap_or("");
            anyhow::ensure!(
                !name.is_empty()
                    && name.len() <= 60
                    && name.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-'),
                "invalid_name"
            );
            let path = store.directory("logs")?.join(format!("{name}.log"));
            // Only the tail is read: the log of a long install can be large.
            let text = read_tail(&path, 32_000_000).unwrap_or_default();
            Ok(crate::core::progress::read(
                &text,
                runtimes::utilities::devtools::home().ok().as_deref(),
            ))
        }
        // The steps an install reports while the app follows it (core/progress.rs).
        "installSteps" => {
            let tool = request["tool"].as_str().unwrap_or("");
            Ok(match tool {
                "php" => json!(runtimes::languages::php::DOWNLOAD_PLAN),
                "php-package" => json!(runtimes::languages::php::PACKAGE_PLAN),
                "rust-toolchain" | "swift-toolchain" => {
                    json!(runtimes::languages::toolchains::TOOLCHAIN_PLAN)
                }
                _ if runtimes::utilities::devtools::known(tool) => {
                    json!(runtimes::utilities::devtools::plan(tool))
                }
                _ => {
                    runtimes::utilities::catalog::validate_tool(tool)?;
                    json!(runtimes::utilities::catalog::plan(tool))
                }
            })
        }
        "devToolUpdates" => {
            // A source that does not answer now keeps the version it said last time.
            let previous = crate::core::cache::peek(store, "devtools-latest");
            let latest = crate::core::cache::cached(
                store,
                "devtools-latest",
                6 * 3600,
                request["refresh"] == true,
                || {
                    Ok(runtimes::utilities::devtools::keep_known(
                        runtimes::utilities::devtools::latest()?,
                        previous,
                    ))
                },
            )?;
            runtimes::utilities::devtools::updates(store, &latest)
        }
        "pythonVersions" => crate::core::cache::cached(
            store,
            "python-versions",
            24 * 3600,
            request["refresh"] == true,
            runtimes::languages::python::versions,
        ),
        "availableTools" => {
            let tool = request["tool"].as_str().unwrap_or("");
            runtimes::utilities::catalog::validate_tool(tool)?;
            crate::core::cache::cached(
                store,
                &format!("available-{tool}"),
                12 * 3600,
                request["refresh"] == true,
                || {
                    Ok(serde_json::to_value(
                        runtimes::utilities::catalog::available(store, tool)?,
                    )?)
                },
            )
        }
        "lifecycle" => {
            let tool = request["tool"].as_str().unwrap_or("");
            anyhow::ensure!(
                runtimes::utilities::catalog::validate_tool(tool).is_ok()
                    || ["php", "python", "rust"].contains(&tool),
                "unknown_tool"
            );
            crate::core::cache::cached(
                store,
                &format!("lifecycle-{tool}"),
                24 * 3600,
                request["refresh"] == true,
                || runtimes::utilities::catalog::lifecycle(tool),
            )
        }
        "installedTools" => {
            let tool = request["tool"].as_str().unwrap_or("");
            Ok(serde_json::to_value(
                runtimes::utilities::catalog::installed(store, tool)?,
            )?)
        }
        "installTool" => {
            anyhow::ensure!(request["confirmed"] == true, "confirmation_required");
            let tool = request["tool"].as_str().unwrap_or("");
            runtimes::utilities::catalog::validate_tool(tool)?;
            follow(store, &format!("install-{tool}"))?;
            // `replace`: rebuild an installed version in place (PostgreSQL without extensions).
            let replace = request["replace"] == true;
            let manifest = runtimes::utilities::catalog::install(
                store,
                tool,
                request["version"].as_str().unwrap_or(""),
                replace,
            )?;
            let _ = daemon::request_sync(store, "reload", json!({}), false);
            // The running service keeps the old binaries until it restarts.
            if replace {
                let _ = daemon::request_sync(
                    store,
                    "restart",
                    json!({"id": format!("stack.{tool}")}),
                    false,
                );
            }
            Ok(serde_json::to_value(manifest)?)
        }
        "removeTool" => {
            anyhow::ensure!(request["confirmed"] == true, "confirmation_required");
            let tool = request["tool"].as_str().unwrap_or("");
            let version = request["version"].as_str().unwrap_or("");
            // A language version a project (or the global setting) uses stays (P-42).
            if ["node", "jdk"].contains(&tool) {
                let others: Vec<String> = runtimes::utilities::catalog::installed(store, tool)?
                    .into_iter()
                    .map(|m| m.version)
                    .filter(|v| v != version)
                    .collect();
                runtimes::languages::usage::ensure_unused(store, tool, version, &others)?;
            }
            runtimes::utilities::catalog::remove(store, tool, version)?;
            let _ = daemon::request_sync(store, "reload", json!({}), false);
            Ok(json!(true))
        }
        // A PHP line, with the same guard as the other languages.
        "removePhp" => {
            anyhow::ensure!(request["confirmed"] == true, "confirmation_required");
            runtimes::languages::php::remove(store, request["series"].as_str().unwrap_or(""))?;
            let _ = daemon::request_sync(store, "reload", json!({}), false);
            Ok(json!(true))
        }
        // ---- Python (python-build-standalone) and versions per language ----
        "pythonCatalog" => crate::core::cache::cached(
            store,
            "python-catalog",
            6 * 3600,
            request["refresh"] == true,
            runtimes::languages::python::catalog,
        ),
        "listPythonRuntimes" => Ok(serde_json::to_value(
            runtimes::languages::python::installed(store),
        )?),
        "installPython" => {
            anyhow::ensure!(request["confirmed"] == true, "confirmation_required");
            follow(store, "install-python")?;
            let manifest = runtimes::languages::python::install(
                store,
                request["line"].as_str().unwrap_or(""),
            )?;
            let _ = daemon::request_sync(store, "reload", json!({}), false);
            Ok(serde_json::to_value(manifest)?)
        }
        "removePython" => {
            anyhow::ensure!(request["confirmed"] == true, "confirmation_required");
            let line = request["line"].as_str().unwrap_or("");
            let others: Vec<String> = runtimes::languages::python::installed(store)
                .into_iter()
                .map(|runtime| runtime.line)
                .filter(|other| other != line)
                .collect();
            runtimes::languages::usage::ensure_unused(store, "python", line, &others)?;
            runtimes::languages::python::remove(store, line)?;
            let _ = daemon::request_sync(store, "reload", json!({}), false);
            Ok(json!(true))
        }
        "preparePython" => {
            let project = store.get(id)?;
            let log = store.directory("logs")?.join(format!("python-{id}.log"));
            let _ = std::fs::remove_file(&log);
            let result = runtimes::languages::python::prepare(
                store,
                &project,
                request["manager"].as_str().unwrap_or("pip"),
                request["recreate"] == true,
                &log,
            )?;
            let _ = daemon::request_sync(store, "reload", json!({}), false);
            for process in &project.processes {
                let _ = daemon::request_sync(
                    store,
                    "restart",
                    json!({"id": format!("{}.{}", id, process.name)}),
                    false,
                );
            }
            Ok(result)
        }
        "frameworkRequirement" => {
            let framework = request["framework"].as_str().unwrap_or("");
            anyhow::ensure!(
                ["django", "fastapi", "laravel"].contains(&framework),
                "unknown_framework"
            );
            let mut info = crate::core::cache::cached(
                store,
                &format!("requires-{framework}"),
                12 * 3600,
                request["refresh"] == true,
                || runtimes::languages::python::framework_requirement(framework),
            )?;
            let requirement = info["requirement"].as_str().unwrap_or("").to_string();
            // Lines Stack offers for that language, compatible or not.
            let lines: Vec<String> = if info["language"] == "python" {
                let catalog = crate::core::cache::cached(
                    store,
                    "python-catalog",
                    6 * 3600,
                    false,
                    runtimes::languages::python::catalog,
                )
                .unwrap_or(json!([]));
                let mut lines: Vec<String> = catalog
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|c| c["line"].as_str().map(str::to_string))
                    .collect();
                lines.extend(
                    runtimes::languages::python::installed(store)
                        .into_iter()
                        .map(|m| m.line),
                );
                lines
            } else {
                let catalog =
                    crate::core::cache::cached(store, "php-catalog", 6 * 3600, false, || {
                        Ok(json!(runtimes::languages::php::php_catalog()?))
                    })
                    .unwrap_or(json!([]));
                let mut lines: Vec<String> = catalog
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|c| c["series"].as_str().map(str::to_string))
                    .collect();
                lines.extend(
                    runtimes::languages::php::list(store)
                        .into_iter()
                        .filter(|r| r.installed)
                        .map(|r| r.series),
                );
                lines
            };
            let mut lines: Vec<String> = lines
                .into_iter()
                .collect::<std::collections::BTreeSet<_>>()
                .into_iter()
                .collect();
            lines.sort_by_key(|l| {
                std::cmp::Reverse(
                    l.split('.')
                        .map(|p| p.parse::<u32>().unwrap_or(0))
                        .collect::<Vec<_>>(),
                )
            });
            // Each supported line of the framework with the language lines it accepts.
            let versions = crate::core::cache::cached(
                store,
                &format!("framework-{framework}"),
                12 * 3600,
                request["refresh"] == true,
                || runtimes::languages::python::framework_versions(framework),
            )
            .unwrap_or(json!([]));
            let versions: Vec<Value> = versions
                .as_array()
                .cloned()
                .unwrap_or_default()
                .into_iter()
                .map(|mut v| {
                    let spec = v["requirement"].as_str().unwrap_or("").to_string();
                    v["compatible"] = json!(lines
                        .iter()
                        .filter(|l| runtimes::languages::python::satisfies(&spec, l))
                        .collect::<Vec<_>>());
                    v
                })
                .collect();
            // A language line is usable if some supported framework line accepts it.
            let compatible: Vec<&String> = lines
                .iter()
                .filter(|l| {
                    if versions.is_empty() {
                        runtimes::languages::python::satisfies(&requirement, l)
                    } else {
                        versions.iter().any(|v| {
                            v["compatible"]
                                .as_array()
                                .is_some_and(|c| c.iter().any(|x| x == l.as_str()))
                        })
                    }
                })
                .collect();
            info["lines"] = json!(lines);
            info["compatible"] = json!(compatible);
            info["versions"] = json!(versions);
            Ok(info)
        }
        "setGlobalVersion" => {
            let language = request["language"].as_str().unwrap_or("");
            anyhow::ensure!(
                ["php", "node", "jdk", "python"].contains(&language),
                "unknown_language"
            );
            let version = request["version"].as_str().unwrap_or("");
            let mut config = store.config()?;
            if version.is_empty() {
                config.versions.remove(language);
            } else {
                config.versions.insert(language.into(), version.into());
            }
            store.save_config(&config)?;
            // The terminal follows the global version when the user linked that language.
            if runtimes::languages::toolchains::terminal_status(store)
                .get(language)
                .is_some()
                && !version.is_empty()
            {
                runtimes::languages::toolchains::link_terminal(store, language, version)?;
            }
            let _ = daemon::request_sync(store, "reload", json!({}), false);
            Ok(serde_json::to_value(config)?)
        }
        "terminalStatus" => Ok(runtimes::languages::toolchains::terminal_status(store)),
        "linkTerminal" => {
            anyhow::ensure!(request["confirmed"] == true, "confirmation_required");
            runtimes::languages::toolchains::link_terminal(
                store,
                request["language"].as_str().unwrap_or(""),
                request["version"].as_str().unwrap_or(""),
            )
        }
        "unlinkTerminal" => {
            anyhow::ensure!(request["confirmed"] == true, "confirmation_required");
            runtimes::languages::toolchains::unlink_terminal(
                store,
                request["language"].as_str().unwrap_or(""),
            )
        }
        "setSiteVersion" => {
            let project = runtimes::languages::toolchains::set_site_version(
                store,
                id,
                request["language"].as_str().unwrap_or(""),
                request["version"].as_str().unwrap_or(""),
            )?;
            let _ = daemon::request_sync(store, "reload", json!({}), false);
            Ok(serde_json::to_value(project)?)
        }
        "siteVersionFiles" => Ok(runtimes::languages::toolchains::site_files(
            &store.get(id)?.path,
        )),
        "rustToolchains" => runtimes::languages::toolchains::rust_toolchains(),
        "rustToolchain" => {
            let action = request["action"].as_str().unwrap_or("");
            anyhow::ensure!(
                action == "default" || request["confirmed"] == true,
                "confirmation_required"
            );
            if action == "install" {
                follow(store, "install-rust-toolchain")?;
            }
            runtimes::languages::toolchains::rust_action(
                action,
                request["toolchain"].as_str().unwrap_or(""),
            )
        }
        "swiftToolchains" => {
            runtimes::languages::toolchains::swift_toolchains(request["available"] == true)
        }
        "swiftToolchain" => {
            let action = request["action"].as_str().unwrap_or("");
            anyhow::ensure!(
                action == "default" || request["confirmed"] == true,
                "confirmation_required"
            );
            if action == "install" {
                follow(store, "install-swift-toolchain")?;
            }
            runtimes::languages::toolchains::swift_action(
                action,
                request["version"].as_str().unwrap_or(""),
            )
        }
        "listPhpRuntimes" => Ok(serde_json::to_value(runtimes::languages::php::list(store))?),
        "projectVersions" => crate::core::cache::cached(
            store,
            "project-versions",
            12 * 3600,
            request["refresh"] == true,
            web::projects::scaffold::versions,
        ),
        // ---- Xdebug per PHP line ----
        "setXdebug" => {
            let series = request["series"].as_str().unwrap_or("");
            runtimes::languages::php::validate_series(series)?;
            let mode = request["mode"].as_str().unwrap_or("");
            let mut config = store.config()?;
            if mode.is_empty() {
                config.xdebug.remove(series);
            } else {
                anyhow::ensure!(
                    runtimes::languages::php::manifest(store, series)?
                        .sha256
                        .contains_key("xdebug.so"),
                    "xdebug_missing"
                );
                config.xdebug.insert(series.into(), mode.into());
            }
            store.save_config(&config)?;
            // php.ini now; the daemon restarts only this line's php-fpm (its ini changed).
            if runtimes::languages::php::manifest(store, series).is_ok() {
                runtimes::languages::php::generate_ini(store, series)?;
            }
            let _ = daemon::request_sync(store, "reload", json!({}), false);
            Ok(serde_json::to_value(runtimes::languages::php::list(store))?)
        }
        _ => return Ok(None),
    };
    result.map(Some)
}

/// A fresh log for an install the app follows (`stepLog` reads it) and stops if asked.
fn follow(store: &Store, name: &str) -> Result<()> {
    let log = store.directory("logs")?.join(format!("{name}.log"));
    let _ = std::fs::remove_file(&log);
    crate::core::progress::begin(&log);
    Ok(())
}

/// The last `limit` bytes of a file as text (a cut inside a character is replaced, not an error).
fn read_tail(path: &std::path::Path, limit: u64) -> std::io::Result<String> {
    use std::io::{Read, Seek, SeekFrom};
    let mut file = std::fs::File::open(path)?;
    let length = file.metadata()?.len();
    file.seek(SeekFrom::Start(length.saturating_sub(limit)))?;
    let mut bytes = Vec::new();
    file.take(limit).read_to_end(&mut bytes)?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

#[cfg(test)]
mod tail_tests {
    use super::read_tail;

    #[test]
    fn reads_only_the_end_of_a_file() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("a.log");
        std::fs::write(&file, "0123456789").unwrap();
        assert_eq!(read_tail(&file, 4).unwrap(), "6789");
        assert_eq!(read_tail(&file, 100).unwrap(), "0123456789");
        assert!(read_tail(&dir.path().join("falta.log"), 4).is_err());
    }
}
