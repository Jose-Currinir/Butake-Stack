//! Proposes a site configuration from a folder. Of `.env`
//! only variable names and selected numeric port values are used.
use crate::core::model::{Project, ProjectKind, ProjectProcess};
use anyhow::{ensure, Result};
use serde::Serialize;
use serde_json::Value;
use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
};

const ENV_PORTS: [&str; 3] = ["DB_PORT", "REDIS_PORT", "REVERB_SERVER_PORT"];

pub(crate) fn read_small(path: &Path, limit: u64) -> Option<String> {
    let meta = path.symlink_metadata().ok()?;
    if !meta.is_file() || meta.len() > limit {
        return None;
    }
    fs::read_to_string(path).ok()
}

/// Numeric ports and variable names declared by the project.
pub fn env_summary(project: &Path) -> (BTreeMap<String, String>, Vec<String>) {
    let mut values = BTreeMap::new();
    let mut keys = vec![];
    let Some(text) = read_small(&project.join(".env"), 1_048_576) else {
        return (values, keys);
    };
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let key = key.trim().trim_start_matches("export ").to_string();
        if key.is_empty()
            || !key
                .bytes()
                .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == b'_')
        {
            continue;
        }
        if ENV_PORTS.contains(&key.as_str()) {
            let value = value.trim().trim_matches('"').trim_matches('\'');
            if let Ok(port) = value.parse::<u16>() {
                if port != 0 {
                    values.insert(key.clone(), port.to_string());
                }
            }
        }
        keys.push(key);
    }
    (values, keys)
}

pub(crate) fn sanitize_id(name: &str) -> String {
    let mut id: String = name
        .to_ascii_lowercase()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect();
    while id.contains("--") {
        id = id.replace("--", "-");
    }
    let id = id.trim_matches('-');
    let id: String = id.chars().take(40).collect();
    if id.is_empty() {
        "sitio".into()
    } else {
        id.trim_end_matches('-').to_string()
    }
}

fn php_from_constraint(constraint: &str) -> Option<String> {
    // "^8.2", ">=8.1", "~8.3.0", "8.2.*" → "8.2"
    let digits: String = constraint
        .trim_start_matches(|c: char| !c.is_ascii_digit())
        .chars()
        .take_while(|c| c.is_ascii_digit() || *c == '.')
        .collect();
    let mut parts = digits.split('.');
    Some(format!("{}.{}", parts.next()?, parts.next()?))
}

#[derive(Serialize)]
pub struct Detection {
    pub project: Project,
    pub env_keys: Vec<String>,
    pub notes: Vec<String>,
}

fn supervisor_processes(path: &Path) -> Vec<ProjectProcess> {
    let mut out = vec![];
    let Ok(entries) = fs::read_dir(path.join("config/supervisor")) else {
        return out;
    };
    let mut files: Vec<PathBuf> = entries
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "conf"))
        .collect();
    files.sort();
    for file in files {
        let Some(text) = read_small(&file, 65_536) else {
            continue;
        };
        let Some(command) = text.lines().find_map(|l| l.trim().strip_prefix("command=")) else {
            continue;
        };
        let tokens: Vec<&str> = command.split_whitespace().collect();
        let Some(index) = tokens.iter().position(|t| t.ends_with("artisan")) else {
            continue;
        };
        let args: Vec<String> = std::iter::once("artisan".to_string())
            .chain(tokens[index + 1..].iter().map(|s| s.to_string()))
            .collect();
        let stem = file.file_stem().unwrap().to_string_lossy().into_owned();
        let name = sanitize_id(&stem);
        if out.iter().any(|p: &ProjectProcess| p.name == name) {
            continue;
        }
        out.push(ProjectProcess {
            name,
            program: "php".into(),
            args,
            autostart: false,
        });
    }
    out
}

fn has_dep(package: &Value, name: &str) -> bool {
    package["dependencies"].get(name).is_some() || package["devDependencies"].get(name).is_some()
}

/// The runnable server module of a Kotlin Multiplatform build (`:server` or `:backend`).
fn kmp_server(path: &Path) -> Option<&'static str> {
    let settings = read_small(&path.join("settings.gradle.kts"), 262_144)
        .or_else(|| read_small(&path.join("settings.gradle"), 262_144))?;
    if !path.join("gradlew").is_file() {
        return None;
    }
    [":server", ":backend"]
        .into_iter()
        .find(|m| settings.contains(&format!("\"{m}\"")) || settings.contains(&format!("'{m}'")))
}

/// Lowercased text of a Python project's dependency files (pyproject, requirements*.txt).
fn python_dependencies(path: &Path) -> String {
    let mut text = read_small(&path.join("pyproject.toml"), 1_048_576).unwrap_or_default();
    for name in [
        "requirements.txt",
        "requirements/base.txt",
        "requirements/dev.txt",
        "requirements-dev.txt",
    ] {
        text.push_str(&read_small(&path.join(name), 1_048_576).unwrap_or_default());
    }
    text.to_lowercase()
}
/// The module that creates the FastAPI app (`main`, `app.main`…).
fn fastapi_module(path: &Path) -> String {
    for (file, module) in [
        ("main.py", "main"),
        ("app/main.py", "app.main"),
        ("src/main.py", "src.main"),
        ("app.py", "app"),
        ("api/main.py", "api.main"),
    ] {
        if read_small(&path.join(file), 1_048_576).is_some_and(|t| t.contains("FastAPI(")) {
            return module.into();
        }
    }
    "main".into()
}
const RUST_WEB: [&str; 9] = [
    "axum",
    "actix-web",
    "rocket",
    "warp",
    "poem",
    "salvo",
    "tide",
    "loco-rs",
    "hyper",
];
fn rust_web(path: &Path) -> bool {
    read_small(&path.join("Cargo.toml"), 1_048_576).is_some_and(|toml| {
        let deps = toml.split("[dependencies]").nth(1).unwrap_or("");
        RUST_WEB.iter().any(|crate_name| {
            deps.lines().any(|l| {
                l.trim_start().starts_with(&format!("{crate_name} "))
                    || l.trim_start().starts_with(&format!("{crate_name}="))
            })
        })
    })
}
/// What a project is built with, also for projects Stack doesn't serve (apps, libraries, CLIs):
/// shown when importing a folder of projects.
pub fn technology(path: &Path) -> Option<&'static str> {
    let package: Value = read_small(&path.join("package.json"), 1_048_576)
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or(Value::Null);
    let gradle = [
        "build.gradle.kts",
        "build.gradle",
        "settings.gradle.kts",
        "settings.gradle",
    ]
    .iter()
    .filter_map(|f| read_small(&path.join(f), 1_048_576))
    .collect::<String>();
    let xcode = std::fs::read_dir(path).ok().is_some_and(|entries| {
        entries.flatten().any(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            name.ends_with(".xcodeproj") || name.ends_with(".xcworkspace")
        })
    });
    Some(
        if has_dep(&package, "react-native") || has_dep(&package, "expo") {
            "react-native"
        } else if path.join("Cargo.toml").is_file() {
            "rust"
        } else if path.join("manage.py").is_file()
            || path.join("pyproject.toml").is_file()
            || path.join("requirements.txt").is_file()
        {
            "python"
        } else if path.join("Package.swift").is_file() || xcode {
            "swift"
        } else if gradle.contains("multiplatform")
            || path.join("composeApp").is_dir()
            || path.join("shared").is_dir() && !gradle.is_empty()
        {
            "kmp"
        } else if gradle.contains("com.android.application")
            || path.join("app/src/main/AndroidManifest.xml").is_file()
        {
            "android"
        } else {
            return None;
        },
    )
}

/// An `index.*` page at the folder's root (what a static site serves first).
fn root_index(path: &Path) -> bool {
    ["index.html", "index.htm", "index.xhtml"]
        .iter()
        .any(|name| path.join(name).is_file())
}

/// A static site whose served folder holds a Git repository (`.git` at its root) would publish
/// the whole repository, history included, at its address: its page warns.
pub fn serves_repository(project: &Project) -> bool {
    project.kind == ProjectKind::Static
        && std::fs::symlink_metadata(project.path.join(&project.docroot).join(".git")).is_ok()
}

pub fn detect(path: &Path) -> Result<Detection> {
    let path = path.canonicalize()?;
    ensure!(path.is_dir(), "invalid_path");
    let folder = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "sitio".into());
    let id = sanitize_id(&folder);
    let mut notes = vec![];
    let composer: Value = read_small(&path.join("composer.json"), 1_048_576)
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or(Value::Null);
    let package: Value = read_small(&path.join("package.json"), 1_048_576)
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or(Value::Null);
    let require = &composer["require"];
    let laravel = path.join("artisan").is_file() && require.get("laravel/framework").is_some();
    let (kind, docroot) = if laravel {
        (ProjectKind::Laravel, PathBuf::from("public"))
    } else if path.join("index.php").is_file() || composer.is_object() {
        (ProjectKind::Php, PathBuf::from("."))
    } else if path.join("manage.py").is_file() && python_dependencies(&path).contains("django") {
        (ProjectKind::Django, PathBuf::from("."))
    } else if python_dependencies(&path).contains("fastapi") {
        (ProjectKind::Fastapi, PathBuf::from("."))
    } else if rust_web(&path) {
        (ProjectKind::Rust, PathBuf::from("."))
    } else if kmp_server(&path).is_some() {
        (ProjectKind::Kmp, PathBuf::from("."))
    } else if has_dep(&package, "emdash") {
        (ProjectKind::Emdash, PathBuf::from("."))
    } else if has_dep(&package, "astro")
        || ["astro.config.mjs", "astro.config.ts", "astro.config.js"]
            .iter()
            .any(|f| path.join(f).is_file())
    {
        (ProjectKind::Astro, PathBuf::from("."))
    } else if has_dep(&package, "next") {
        (ProjectKind::Next, PathBuf::from("."))
    } else if package.is_object()
        && !has_dep(&package, "react-native")
        && !has_dep(&package, "expo")
    {
        (ProjectKind::Node, PathBuf::from("."))
    } else if root_index(&path) {
        (ProjectKind::Static, PathBuf::from("."))
    } else if path.join("public").is_dir() {
        // The served folder is `public/`, never the repository around it.
        (ProjectKind::Static, PathBuf::from("public"))
    } else {
        // Nothing to serve (an app, a library, a tool): a project without a server.
        (ProjectKind::Unserved, PathBuf::from("."))
    };
    let mut runtime = BTreeMap::new();
    if matches!(kind, ProjectKind::Laravel | ProjectKind::Php) {
        let php = require["php"]
            .as_str()
            .and_then(php_from_constraint)
            .unwrap_or_else(|| "8.2".into());
        runtime.insert("php".into(), php);
    }
    let (env, env_keys) = env_summary(&path);
    // Generic dotenv keys do not identify a database driver. Ask the user to choose it.
    let services = vec![];
    let mut processes = vec![];
    if laravel {
        if require.get("laravel/reverb").is_some() {
            let port = env
                .get("REVERB_SERVER_PORT")
                .filter(|p| p.parse::<u16>().is_ok())
                .cloned()
                .unwrap_or_else(|| "8080".into());
            processes.push(ProjectProcess {
                name: "reverb".into(),
                program: "php".into(),
                args: vec![
                    "artisan".into(),
                    "reverb:start".into(),
                    "--host=127.0.0.1".into(),
                    format!("--port={port}"),
                ],
                autostart: true,
            });
        }
        processes.extend(supervisor_processes(&path));
        if !processes
            .iter()
            .any(|p| p.args.iter().any(|a| a == "schedule:work"))
        {
            processes.push(ProjectProcess {
                name: "scheduler".into(),
                program: "php".into(),
                args: vec!["artisan".into(), "schedule:work".into()],
                autostart: false,
            });
        }
    }
    // Node line from .nvmrc (24.13.0 -> 24), else 24.
    let node_line = read_small(&path.join(".nvmrc"), 64)
        .and_then(|t| {
            t.trim()
                .trim_start_matches('v')
                .split('.')
                .next()
                .filter(|m| m.parse::<u32>().is_ok())
                .map(str::to_string)
        })
        .unwrap_or_else(|| "24".into());
    let dev = package["scripts"]["dev"].as_str().unwrap_or("");
    // Vite, or Vite+ (`vp dev`, Laravel's current starter kits).
    let vite_dev = matches!(dev.split_whitespace().next(), Some("vite") | Some("vp"));
    if matches!(kind, ProjectKind::Laravel | ProjectKind::Php) && vite_dev {
        processes.push(ProjectProcess {
            name: "vite".into(),
            program: "npm".into(),
            args: vec!["run".into(), "dev".into()],
            autostart: true,
        });
        runtime.insert("node".into(), node_line.clone());
    } else if !dev.is_empty() && !kind.proxied() {
        notes.push("dev_script_not_a_server".into());
    }
    let mut site_env = BTreeMap::new();
    // npm, or pnpm through corepack (Node's own) when the project declares or locks pnpm.
    let pnpm = path.join("pnpm-lock.yaml").is_file()
        || package["packageManager"]
            .as_str()
            .is_some_and(|p| p.starts_with("pnpm"));
    let script = |name: &str, extra: &[&str]| -> (String, Vec<String>) {
        if pnpm {
            let mut args = vec!["pnpm".to_string(), "run".into(), name.into()];
            args.extend(extra.iter().map(|s| s.to_string()));
            ("corepack".into(), args)
        } else {
            let mut args = vec!["run".to_string(), name.into()];
            if !extra.is_empty() {
                args.push("--".into());
                args.extend(extra.iter().map(|s| s.to_string()));
            }
            ("npm".into(), args)
        }
    };
    let has_script = |name: &str| package["scripts"][name].is_string();
    let mut push = |name: &str, (program, args): (String, Vec<String>), autostart: bool| {
        processes.push(ProjectProcess {
            name: name.into(),
            program,
            args,
            autostart,
        });
    };
    match kind {
        ProjectKind::Astro => {
            push(
                "dev",
                script("dev", &["--host", "127.0.0.1", "--port", "{port}"]),
                true,
            );
            site_env.insert("PORT".into(), "{port}".into());
            runtime.insert("node".into(), node_line.clone());
        }
        ProjectKind::Next => {
            push(
                "dev",
                script("dev", &["-H", "127.0.0.1", "-p", "{port}"]),
                true,
            );
            site_env.insert("PORT".into(), "{port}".into());
            runtime.insert("node".into(), node_line.clone());
        }
        ProjectKind::Emdash => {
            // Build + `wrangler dev` on the port Stack assigns (PORT), with the .test address as the
            // site URL. On the Node platform `dev` is `astro dev`, which takes the port as flags.
            let astro_dev = dev.split_whitespace().next() == Some("astro");
            push(
                "dev",
                script(
                    "dev",
                    if astro_dev {
                        &["--host", "127.0.0.1", "--port", "{port}"]
                    } else {
                        &[]
                    },
                ),
                true,
            );
            if has_script("dev:setup") {
                push("setup", script("dev:setup", &[]), false);
            }
            if has_script("dev:reset") {
                push("reset", script("dev:reset", &[]), false);
            }
            for (k, v) in [
                ("PORT", "{port}"),
                ("PUBLIC_SITE_URL", "https://{domain}"),
                ("BUTAKE_DEV_ALLOWED_HOSTS", "{domain}"),
                ("EMDASH_URL", "http://127.0.0.1:{port}"),
            ] {
                site_env.insert(k.into(), v.into());
            }
            runtime.insert("node".into(), node_line.clone());
            notes.push("emdash_secrets_in_dev_vars".into());
        }
        ProjectKind::Node => {
            // Any Node server: `dev` if there is one, else `start`. Vite-based tools (Vite, SvelteKit,
            // Remix on Vite) take the port as flags; Nuxt, Express and the rest read PORT and HOST.
            let name = ["dev", "start"].into_iter().find(|n| has_script(n));
            match name {
                Some(name) => {
                    let command = package["scripts"][name].as_str().unwrap_or("");
                    let vite =
                        matches!(command.split_whitespace().next(), Some("vite") | Some("vp"));
                    let extra: &[&str] = if vite {
                        &["--host", "127.0.0.1", "--port", "{port}", "--strictPort"]
                    } else {
                        &[]
                    };
                    push(name, script(name, extra), true);
                }
                None => notes.push("node_no_script".into()),
            }
            for (k, v) in [
                ("PORT", "{port}"),
                ("HOST", "127.0.0.1"),
                ("NITRO_PORT", "{port}"),
                ("NITRO_HOST", "127.0.0.1"),
            ] {
                site_env.insert(k.into(), v.into());
            }
            runtime.insert("node".into(), node_line.clone());
        }
        ProjectKind::Django | ProjectKind::Fastapi => {
            // The project's own interpreter (`.venv/bin/python`, made by Stack with the Python the
            // project asks for), run directly: no uv or other launcher in between.
            let args: Vec<String> = if kind == ProjectKind::Django {
                ["manage.py", "runserver", "127.0.0.1:{port}"]
                    .map(String::from)
                    .to_vec()
            } else {
                let module = fastapi_module(&path);
                vec![
                    "-m".into(),
                    "uvicorn".into(),
                    format!("{module}:app"),
                    "--host".into(),
                    "127.0.0.1".into(),
                    "--port".into(),
                    "{port}".into(),
                    "--reload".into(),
                ]
            };
            push("server", ("python".into(), args), true);
            site_env.insert("PORT".into(), "{port}".into());
            // `.python-version` (uv, pyenv): only a plain version number is kept.
            if let Some(version) = read_small(&path.join(".python-version"), 64)
                .map(|v| v.trim().to_string())
                .filter(|v| !v.is_empty() && v.bytes().all(|c| c.is_ascii_digit() || c == b'.'))
            {
                runtime.insert("python".into(), version);
            }
        }
        ProjectKind::Rust => {
            push("server", ("cargo".into(), vec!["run".into()]), true);
            // The usual ways Rust servers read their address; a hard-coded port needs editing the code.
            for (k, v) in [
                ("PORT", "{port}"),
                ("HOST", "127.0.0.1"),
                ("ROCKET_PORT", "{port}"),
                ("ROCKET_ADDRESS", "127.0.0.1"),
                ("BIND_ADDRESS", "127.0.0.1:{port}"),
            ] {
                site_env.insert(k.into(), v.into());
            }
            notes.push("rust_port".into());
        }
        ProjectKind::Kmp => {
            if let Some(module) = kmp_server(&path) {
                push(
                    "server",
                    ("gradlew".into(), vec![format!("{module}:run")]),
                    true,
                );
            }
            // Backends read one of these; all point at the port Stack assigns.
            for k in ["PORT", "SERVER_PORT", "HTTP_PORT"] {
                site_env.insert(k.into(), "{port}".into());
            }
            site_env.insert("APP_HOST".into(), "127.0.0.1".into());
            runtime.insert("jdk".into(), "21".into());
            notes.push("kmp_database_external".into());
        }
        ProjectKind::Unserved => {
            // Its checks, run by hand from its page: «Comprobar» (tests) and «Compilar» (build),
            // with the tool the project is built with. Nothing starts on its own.
            type Command = Option<(String, Vec<String>)>;
            let (check, build): (Command, Command) = if path.join("Cargo.toml").is_file() {
                (
                    Some(("cargo".into(), vec!["test".into()])),
                    Some(("cargo".into(), vec!["build".into()])),
                )
            } else if path.join("Package.swift").is_file() {
                (
                    Some(("swift".into(), vec!["test".into()])),
                    Some(("swift".into(), vec!["build".into()])),
                )
            } else if path.join("gradlew").is_file() {
                runtime.insert("jdk".into(), "21".into());
                (
                    Some(("gradlew".into(), vec!["check".into()])),
                    Some(("gradlew".into(), vec!["build".into()])),
                )
            } else if package.is_object() {
                runtime.insert("node".into(), node_line.clone());
                (
                    has_script("test").then(|| script("test", &[])),
                    has_script("build").then(|| script("build", &[])),
                )
            } else if path.join("Makefile").is_file() {
                (None, Some(("make".into(), vec![])))
            } else {
                (None, None)
            };
            for (name, command) in [("check", check), ("build", build)] {
                if let Some(command) = command {
                    push(name, command, false);
                }
            }
        }
        _ => {}
    }
    Ok(Detection {
        project: Project {
            id: id.clone(),
            name: folder,
            path,
            // A project without a server has no address.
            domains: if kind.served() {
                vec![format!("{id}.test")]
            } else {
                vec![]
            },
            // Proxied sites get HTTPS (the URLs Stack passes them are https://<domain>).
            https: kind.proxied(),
            kind,
            runtime,
            docroot,
            services,
            databases: vec![],
            processes,
            enabled: false,
            upstream: None,
            env: site_env,
            gcp: None,
        },
        env_keys,
        notes,
    })
}

/// Files that mark a folder as a project (any of them).
const PROJECT_MARKERS: [&str; 16] = [
    "composer.json",
    "package.json",
    "artisan",
    "index.php",
    "index.html",
    "gradlew",
    "settings.gradle.kts",
    "settings.gradle",
    ".git",
    "public/index.php",
    "astro.config.mjs",
    "Cargo.toml",
    "pyproject.toml",
    "manage.py",
    "requirements.txt",
    "Package.swift",
];
const SKIP: [&str; 6] = [
    "node_modules",
    "vendor",
    "build",
    "dist",
    "target",
    "Library",
];

pub fn looks_like_project(path: &Path) -> bool {
    PROJECT_MARKERS.iter().any(|m| path.join(m).exists())
}

/// Projects inside a folder that holds several (e.g. ~/Proyectos): its subfolders, and theirs one level
/// down for folders that only organize (Apps/, Web/…), which become the suggested group. Hidden and
/// dependency folders are skipped; at most 300 projects.
pub fn scan(root: &Path) -> Result<serde_json::Value> {
    let root = root.canonicalize()?;
    ensure!(root.is_dir(), "invalid_path");
    let children = |dir: &Path| -> Vec<PathBuf> {
        let mut list: Vec<PathBuf> = std::fs::read_dir(dir)
            .map(|entries| entries.flatten().map(|e| e.path()).collect())
            .unwrap_or_default();
        list.retain(|p| {
            let name = p
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default();
            // Real folders only: a symlink could point anywhere.
            !name.starts_with('.')
                && !SKIP.contains(&name.as_str())
                && std::fs::symlink_metadata(p).is_ok_and(|m| m.is_dir())
        });
        list.sort_by_key(|p| p.file_name().map(|n| n.to_string_lossy().to_lowercase()));
        list
    };
    let mut found = vec![];
    let mut push = |path: &Path, group: &str| {
        if found.len() >= 300 {
            return;
        }
        if let Ok(detection) = detect(path) {
            // Something a browser can show: a kind with a server, or a static site with its index.html.
            let web = detection.project.kind.served()
                && (detection.project.kind != ProjectKind::Static
                    || root_index(&path.join(&detection.project.docroot)));
            found.push(serde_json::json!({"group": group, "web": web, "tech": technology(path), "detection": detection}));
        }
    };
    for child in children(&root) {
        if looks_like_project(&child) {
            push(&child, "");
        } else {
            let group = child
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default();
            for grandchild in children(&child) {
                if looks_like_project(&grandchild) {
                    push(&grandchild, &group);
                }
            }
        }
    }
    Ok(serde_json::json!({
        "root": root,
        "name": root.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default(),
        "rootIsProject": looks_like_project(&root),
        "projects": found,
    }))
}

#[cfg(test)]
#[path = "detect_tests.rs"]
mod tests;
