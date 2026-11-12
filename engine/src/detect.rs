//! Proposes a site configuration from a folder. Of `.env`
//! only an allowlist of non-secret keys is read; values of keys that look secret are never read.
use crate::model::{Project, ProjectKind, ProjectProcess};
use anyhow::{ensure, Result};
use serde::Serialize;
use serde_json::Value;
use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
};

const ENV_ALLOWED: [&str; 9] = [
    "APP_URL",
    "DB_CONNECTION",
    "DB_PORT",
    "REDIS_HOST",
    "REDIS_PORT",
    "REVERB_SERVER_PORT",
    "CACHE_STORE",
    "QUEUE_CONNECTION",
    "SESSION_DRIVER",
];

fn looks_secret(key: &str) -> bool {
    ["PASSWORD", "SECRET", "KEY", "TOKEN", "PASS"]
        .iter()
        .any(|marker| key.contains(marker))
}

fn read_small(path: &Path, limit: u64) -> Option<String> {
    let meta = path.symlink_metadata().ok()?;
    if !meta.is_file() || meta.len() > limit {
        return None;
    }
    fs::read_to_string(path).ok()
}

/// Allowlisted `.env` values plus the list of key names (names only, never values).
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
        if key.is_empty() || !key.bytes().all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == b'_') {
            continue;
        }
        if ENV_ALLOWED.contains(&key.as_str()) && !looks_secret(&key) {
            let value = value.trim().trim_matches('"').trim_matches('\'');
            if value.len() <= 200 && !value.chars().any(char::is_control) {
                values.insert(key.clone(), value.to_string());
            }
        }
        keys.push(key);
    }
    (values, keys)
}

fn sanitize_id(name: &str) -> String {
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

fn supervisor_processes(path: &Path, queue_connection: Option<&str>) -> Vec<ProjectProcess> {
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
        let Some(command) = text
            .lines()
            .find_map(|l| l.trim().strip_prefix("command="))
        else {
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
        // Only the queue on the app's own connection starts by default; the rest stay off.
        let autostart = args.get(1).map(String::as_str) == Some("queue:work")
            && args.get(2).map(String::as_str) == queue_connection
            && queue_connection.is_some_and(|c| c != "sync");
        if out.iter().any(|p: &ProjectProcess| p.name == name) {
            continue;
        }
        out.push(ProjectProcess {
            name,
            program: "php".into(),
            args,
            autostart,
        });
    }
    out
}

fn has_dep(package: &Value, name: &str) -> bool {
    package["dependencies"].get(name).is_some() || package["devDependencies"].get(name).is_some()
}

/// The runnable server module of a Kotlin Multiplatform build (`:server` or `:backend`).
fn kmp_server(path: &Path) -> Option<&'static str> {
    let settings = read_small(&path.join("settings.gradle.kts"), 262_144).or_else(|| read_small(&path.join("settings.gradle"), 262_144))?;
    if !path.join("gradlew").is_file() {
        return None;
    }
    [":server", ":backend"].into_iter().find(|m| settings.contains(&format!("\"{m}\"")) || settings.contains(&format!("'{m}'")))
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
    } else if kmp_server(&path).is_some() {
        (ProjectKind::Kmp, PathBuf::from("."))
    } else if has_dep(&package, "emdash") {
        (ProjectKind::Emdash, PathBuf::from("."))
    } else if has_dep(&package, "astro") || ["astro.config.mjs", "astro.config.ts", "astro.config.js"].iter().any(|f| path.join(f).is_file()) {
        (ProjectKind::Astro, PathBuf::from("."))
    } else if has_dep(&package, "next") {
        (ProjectKind::Next, PathBuf::from("."))
    } else if package.is_object() {
        (ProjectKind::Node, PathBuf::from("."))
    } else {
        (ProjectKind::Static, PathBuf::from("."))
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
    let mut services = vec![];
    match env.get("DB_CONNECTION").map(String::as_str) {
        Some("mysql") | Some("mariadb") => services.push("mysql".into()),
        Some("pgsql") => services.push("postgres".into()),
        _ => {}
    }
    let uses_redis = env.contains_key("REDIS_HOST")
        || ["CACHE_STORE", "QUEUE_CONNECTION", "SESSION_DRIVER"]
            .iter()
            .any(|k| env.get(*k).is_some_and(|v| v == "redis"));
    if uses_redis {
        services.push("redis".into());
    }
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
        processes.extend(supervisor_processes(
            &path,
            env.get("QUEUE_CONNECTION").map(String::as_str),
        ));
        if !processes.iter().any(|p| p.args.iter().any(|a| a == "schedule:work")) {
            processes.push(ProjectProcess {
                name: "scheduler".into(),
                program: "php".into(),
                args: vec!["artisan".into(), "schedule:work".into()],
                autostart: false,
            });
        }
    }
    let dev = package["scripts"]["dev"].as_str().unwrap_or("");
    if dev.split_whitespace().next() == Some("vite") {
        processes.push(ProjectProcess {
            name: "vite".into(),
            program: "npm".into(),
            args: vec!["run".into(), "dev".into()],
            autostart: true,
        });
        runtime.insert("node".into(), "22".into());
    } else if !dev.is_empty() {
        notes.push("dev_script_not_a_server".into());
    }
    let mut site_env = BTreeMap::new();
    // npm, or pnpm through corepack (Node's own) when the project declares or locks pnpm.
    let pnpm = path.join("pnpm-lock.yaml").is_file() || package["packageManager"].as_str().is_some_and(|p| p.starts_with("pnpm"));
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
        processes.push(ProjectProcess { name: name.into(), program, args, autostart });
    };
    match kind {
        ProjectKind::Astro => {
            push("dev", script("dev", &["--host", "127.0.0.1", "--port", "{port}"]), true);
            site_env.insert("PORT".into(), "{port}".into());
            runtime.insert("node".into(), "24".into());
        }
        ProjectKind::Next => {
            push("dev", script("dev", &["-H", "127.0.0.1", "-p", "{port}"]), true);
            site_env.insert("PORT".into(), "{port}".into());
            runtime.insert("node".into(), "24".into());
        }
        ProjectKind::Emdash => {
            // Build + `wrangler dev` on the port Stack assigns, with the .test address as the site URL.
            push("dev", script("dev", &[]), true);
            if has_script("dev:setup") { push("setup", script("dev:setup", &[]), false); }
            if has_script("dev:reset") { push("reset", script("dev:reset", &[]), false); }
            for (k, v) in [("PORT", "{port}"), ("PUBLIC_SITE_URL", "https://{domain}"), ("BUTAKE_DEV_ALLOWED_HOSTS", "{domain}"), ("EMDASH_URL", "http://127.0.0.1:{port}")] {
                site_env.insert(k.into(), v.into());
            }
            runtime.insert("node".into(), "24".into());
            notes.push("emdash_secrets_in_dev_vars".into());
        }
        ProjectKind::Kmp => {
            if let Some(module) = kmp_server(&path) {
                push("server", ("gradlew".into(), vec![format!("{module}:run")]), true);
            }
            // Backends read one of these; all point at the port Stack assigns.
            for k in ["PORT", "SERVER_PORT", "HTTP_PORT"] {
                site_env.insert(k.into(), "{port}".into());
            }
            site_env.insert("APP_HOST".into(), "127.0.0.1".into());
            runtime.insert("jdk".into(), "21".into());
            notes.push("kmp_database_external".into());
        }
        _ => {}
    }
    if let Some(url) = env.get("APP_URL") {
        if !url.contains(&format!("{id}.test")) {
            notes.push("app_url_differs".into());
        }
    }
    Ok(Detection {
        project: Project {
            id: id.clone(),
            name: folder,
            path,
            domains: vec![format!("{id}.test")],
            https: false,
            kind,
            runtime,
            docroot,
            services,
            databases: vec![],
            processes,
            enabled: false,
            upstream: None,
            env: site_env,
        },
        env_keys,
        notes,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn detects_laravel_without_leaking_secrets() {
        let temp = tempfile::tempdir().unwrap();
        let app = temp.path().join("Mi App");
        fs::create_dir_all(app.join("public")).unwrap();
        fs::create_dir_all(app.join("config/supervisor")).unwrap();
        fs::write(app.join("artisan"), "").unwrap();
        fs::write(app.join("composer.json"), r#"{"require":{"php":"^8.2","laravel/framework":"^12.0","laravel/reverb":"^1.0"}}"#).unwrap();
        fs::write(app.join("package.json"), r#"{"scripts":{"dev":"vite"}}"#).unwrap();
        fs::write(app.join(".env"), "APP_URL=http://mi-app.test\nDB_CONNECTION=mysql\nDB_PASSWORD=supersecreto123\nREDIS_PASSWORD=otrosecreto456\nAPP_KEY=base64:clavesecreta789\nQUEUE_CONNECTION=redis\nREVERB_SERVER_PORT=8082\nREVERB_APP_SECRET=reverbsecreto\n").unwrap();
        fs::write(app.join("config/supervisor/app-queue.conf"), "[program:q]\ncommand=@PHP_BIN@ artisan queue:work redis --queue=realtime,default --tries=3\n").unwrap();
        fs::write(app.join("config/supervisor/app-exports.conf"), "[program:e]\ncommand=/usr/bin/php /var/www/artisan queue:work redis-exports --tries=1\n").unwrap();
        let d = detect(&app).unwrap();
        let json = serde_json::to_string(&d).unwrap();
        for secret in ["supersecreto123", "otrosecreto456", "clavesecreta789", "reverbsecreto"] {
            assert!(!json.contains(secret), "{secret}");
        }
        assert!(d.env_keys.contains(&"DB_PASSWORD".to_string()));
        let p = &d.project;
        assert_eq!(p.id, "mi-app");
        assert_eq!(p.kind, ProjectKind::Laravel);
        assert_eq!(p.docroot, PathBuf::from("public"));
        assert_eq!(p.runtime.get("php").unwrap(), "8.2");
        assert_eq!(p.services, vec!["mysql", "redis"]);
        let on: Vec<_> = p.processes.iter().filter(|x| x.autostart).map(|x| x.name.as_str()).collect();
        assert_eq!(on, vec!["reverb", "app-queue", "vite"]);
        assert!(p.processes.iter().any(|x| x.name == "scheduler" && !x.autostart));
        assert!(p.processes.iter().any(|x| x.name == "app-exports" && !x.autostart && x.args[0] == "artisan"));
        assert!(p.processes.iter().find(|x| x.name == "reverb").unwrap().args.contains(&"--port=8082".to_string()));
    }
    #[test]
    fn detects_plain_php() {
        let temp = tempfile::tempdir().unwrap();
        let site = temp.path().join("Legacy");
        fs::create_dir_all(&site).unwrap();
        fs::write(site.join("index.php"), "<?php").unwrap();
        let d = detect(&site).unwrap();
        assert_eq!(d.project.kind, ProjectKind::Php);
        assert_eq!(d.project.docroot, PathBuf::from("."));
        assert_eq!(d.project.domains, vec!["legacy.test"]);
        assert!(d.project.processes.is_empty());
    }
    #[test]
    fn detects_astro_emdash_next_and_kmp_with_their_processes() {
        let temp = tempfile::tempdir().unwrap();
        let make = |name: &str, files: &[(&str, &str)]| {
            let dir = temp.path().join(name);
            fs::create_dir_all(&dir).unwrap();
            for (file, text) in files { fs::write(dir.join(file), text).unwrap(); }
            detect(&dir).unwrap().project
        };
        let astro = make("web", &[("package.json", r#"{"scripts":{"dev":"astro dev"},"dependencies":{"astro":"7.4.1"}}"#)]);
        assert_eq!(astro.kind, ProjectKind::Astro);
        assert_eq!(astro.processes[0].args, ["run", "dev", "--", "--host", "127.0.0.1", "--port", "{port}"]);
        let emdash = make("cms", &[("package.json", r#"{"packageManager":"pnpm@10.34.9","scripts":{"dev":"node x","dev:setup":"y","dev:reset":"z"},"dependencies":{"emdash":"1.3.1","astro":"7"}}"#)]);
        assert_eq!(emdash.kind, ProjectKind::Emdash);
        assert_eq!((emdash.processes[0].program.as_str(), emdash.processes.len()), ("corepack", 3));
        assert_eq!(emdash.env.get("PUBLIC_SITE_URL").unwrap(), "https://{domain}");
        let kmp = make("app", &[("settings.gradle.kts", r#"include(":core")
include(":server")"#), ("gradlew", "#!/bin/sh")]);
        assert_eq!(kmp.kind, ProjectKind::Kmp);
        assert_eq!((kmp.processes[0].program.as_str(), kmp.processes[0].args[0].as_str()), ("gradlew", ":server:run"));
        assert_eq!(kmp.runtime.get("jdk").unwrap(), "21");
        let next = make("next", &[("package.json", r#"{"dependencies":{"next":"15"}}"#)]);
        assert_eq!(next.kind, ProjectKind::Next);
    }

}
