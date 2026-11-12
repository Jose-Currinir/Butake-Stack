//! Python as a Stack language, like PHP: CPython builds from python-build-standalone (the builds uv
//! and Rye use), downloaded straight from its GitHub releases and checked against both the release's
//! `SHA256SUMS` and the asset's `digest`. Each line lives in `runtimes/python/<line>` ("3.13"), so
//! updating a line to its newest patch keeps every `.venv` made from it working (a venv points at
//! `runtimes/python/3.13/bin/python3.13`). Projects run with their own `.venv/bin/python`, made with
//! pip and venv (they come with CPython) or with uv when the user prefers it.
use crate::{store::Store, tools};
use anyhow::{ensure, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    fs,
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

const REPO: &str = "astral-sh/python-build-standalone";

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct PythonManifest {
    pub line: String,
    pub version: String,
    /// Release of python-build-standalone ("20261110").
    pub release: String,
    pub url: String,
    pub sha256: String,
    pub installed_at: u64,
}

fn triple() -> &'static str {
    if std::env::consts::ARCH == "aarch64" { "aarch64-apple-darwin" } else { "x86_64-apple-darwin" }
}

/// "3.13" (a line) or "3.13.18" (a version); nothing else reaches a path or a command line.
pub fn validate_line(line: &str) -> Result<()> {
    let parts: Vec<&str> = line.split('.').collect();
    ensure!(
        (2..=3).contains(&parts.len()) && parts[0] == "3"
            && parts.iter().all(|p| !p.is_empty() && p.len() <= 3 && p.bytes().all(|c| c.is_ascii_digit())),
        "invalid_version"
    );
    Ok(())
}
pub fn line_of(version: &str) -> String {
    version.split('.').take(2).collect::<Vec<_>>().join(".")
}

fn release(tag: Option<&str>) -> Result<Value> {
    let url = match tag {
        Some(tag) => {
            ensure!(tag.len() == 8 && tag.bytes().all(|c| c.is_ascii_digit()), "invalid_release");
            format!("https://api.github.com/repos/{REPO}/releases/tags/{tag}")
        }
        None => format!("https://api.github.com/repos/{REPO}/releases/latest"),
    };
    Ok(serde_json::from_slice(&tools::fetch(&url, 30_000_000)?)?)
}

/// The CPython builds of a release for this Mac: (version, asset name), stable versions only.
fn builds(release: &Value) -> Vec<(String, String)> {
    let tag = release["tag_name"].as_str().unwrap_or("");
    let suffix = format!("+{tag}-{}-install_only.tar.gz", triple());
    release["assets"].as_array().into_iter().flatten()
        .filter_map(|a| a["name"].as_str())
        .filter_map(|name| {
            let version = name.strip_prefix("cpython-")?.strip_suffix(&suffix)?;
            (validate_line(version).is_ok() && version.split('.').count() == 3).then(|| (version.to_string(), name.to_string()))
        })
        .collect()
}

/// The newest patch of each line in the newest release, with its support status (endoflife.date).
pub fn catalog() -> Result<Value> {
    let latest = release(None)?;
    let tag = latest["tag_name"].as_str().unwrap_or("").to_string();
    let cycles = tools::lifecycle("python").unwrap_or(json!([]));
    let mut out: Vec<Value> = builds(&latest).into_iter().map(|(version, name)| {
        let line = line_of(&version);
        let cycle = cycles.as_array().into_iter().flatten().find(|c| c["cycle"] == line.as_str()).cloned().unwrap_or(Value::Null);
        let size = latest["assets"].as_array().into_iter().flatten().find(|a| a["name"] == name.as_str()).and_then(|a| a["size"].as_u64());
        json!({"line": line, "version": version, "release": tag, "size_bytes": size, "eol": cycle["eol"], "support": cycle["support"]})
    }).collect();
    out.sort_by(|a, b| key(b["version"].as_str().unwrap_or("")).cmp(&key(a["version"].as_str().unwrap_or(""))));
    Ok(Value::Array(out))
}
fn key(version: &str) -> Vec<u32> {
    version.split('.').map(|p| p.parse().unwrap_or(0)).collect()
}

fn root(store: &Store) -> Result<PathBuf> {
    let runtimes = store.directory("runtimes")?;
    let root = runtimes.join("python");
    if !root.exists() {
        fs::create_dir(&root)?;
    }
    ensure!(!root.symlink_metadata()?.file_type().is_symlink(), "unsafe_runtime_path");
    Ok(root)
}

/// Installed lines, newest first; only those whose manifest and interpreter are in place.
pub fn installed(store: &Store) -> Vec<PythonManifest> {
    let Ok(root) = root(store) else { return vec![] };
    let mut out: Vec<PythonManifest> = fs::read_dir(&root).into_iter().flatten().flatten()
        .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
        .filter_map(|e| {
            let line = e.file_name().into_string().ok()?;
            validate_line(&line).ok()?;
            let manifest: PythonManifest = serde_json::from_slice(&fs::read(e.path().join("butake-manifest.json")).ok()?).ok()?;
            (manifest.line == line && e.path().join("bin/python3").is_file()).then_some(manifest)
        })
        .collect();
    out.sort_by(|a, b| key(&b.version).cmp(&key(&a.version)));
    out
}

/// Interpreter for a wanted version ("3", "3.13", "3.13.18" or empty for the global, else the newest).
pub fn resolve(store: &Store, wanted: &str) -> Option<PathBuf> {
    let root = root(store).ok()?;
    let global = store.config().ok().and_then(|c| c.versions.get("python").cloned()).unwrap_or_default();
    let wanted = if wanted.is_empty() { global.as_str() } else { wanted };
    let all = installed(store);
    all.iter()
        .find(|m| wanted.is_empty() || m.line == wanted || m.version == wanted || m.line.starts_with(&format!("{wanted}.")) || (wanted.split('.').count() == 3 && m.line == line_of(wanted)))
        .or_else(|| if wanted.is_empty() { all.first() } else { None })
        .map(|m| root.join(&m.line).join("bin/python3"))
}

/// Downloads the newest patch of a line and installs (or updates) it. The archive must match the
/// release's SHA256SUMS and the asset's GitHub digest; extraction is staged and checked first.
pub fn install(store: &Store, line: &str) -> Result<PythonManifest> {
    validate_line(line)?;
    let line = line_of(line);
    let latest = release(None)?;
    let (version, name) = builds(&latest).into_iter()
        .filter(|(v, _)| line_of(v) == line)
        .max_by(|a, b| key(&a.0).cmp(&key(&b.0)))
        .context("version_not_in_catalog")?;
    let tag = latest["tag_name"].as_str().unwrap_or("").to_string();
    let asset = |n: &str| latest["assets"].as_array().into_iter().flatten().find(|a| a["name"] == n).cloned();
    let digest = asset(&name).and_then(|a| a["digest"].as_str().and_then(|d| d.strip_prefix("sha256:")).map(str::to_lowercase)).context("checksum_not_found")?;
    let sums_url = asset("SHA256SUMS").and_then(|a| a["browser_download_url"].as_str().map(str::to_string)).context("checksum_not_found")?;
    let sums = String::from_utf8(tools::fetch(&sums_url, 4_000_000)?)?;
    let listed = sums.lines().find_map(|l| {
        let mut parts = l.split_whitespace();
        let hash = parts.next()?;
        (parts.next()?.trim_start_matches('*') == name).then(|| hash.to_lowercase())
    }).context("checksum_not_found")?;
    ensure!(listed == digest, "checksum_mismatch");
    let url = format!("https://github.com/{REPO}/releases/download/{tag}/{}", name.replace('+', "%2B"));
    let root = root(store)?;
    let target = root.join(&line);
    let staging = root.join(format!(".install-{line}-{}", std::process::id()));
    let archive = store.directory("cache")?.join(&name);
    let _ = fs::remove_file(&archive);
    let result = (|| -> Result<PythonManifest> {
        tools::download(&url, &archive)?;
        ensure!(tools::sha256_file(&archive)? == listed, "checksum_mismatch");
        if staging.exists() { fs::remove_dir_all(&staging)?; }
        fs::create_dir(&staging)?;
        let status = Command::new("/usr/bin/tar").arg("-xzf").arg(&archive).arg("-C").arg(&staging)
            .args(["--no-same-owner", "--strip-components", "1"]).env_clear().status()?;
        ensure!(status.success(), "package_extract_failed");
        tools::check_tree(&staging)?;
        // It must run and say it is the version it claims to be.
        let out = Command::new(staging.join("bin/python3")).args(["-I", "-c", "import platform;print(platform.python_version())"])
            .env_clear().stderr(Stdio::null()).output()?;
        ensure!(out.status.success() && String::from_utf8_lossy(&out.stdout).trim() == version, "package_incomplete");
        let manifest = PythonManifest {
            line: line.clone(), version: version.clone(), release: tag.clone(), url: url.clone(), sha256: listed.clone(),
            installed_at: std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_secs(),
        };
        fs::write(staging.join("butake-manifest.json"), serde_json::to_vec_pretty(&manifest)?)?;
        // An update swaps the folder in place: venvs keep pointing at the same path.
        let old = root.join(format!(".old-{line}-{}", std::process::id()));
        if target.exists() { fs::rename(&target, &old)?; }
        if let Err(error) = fs::rename(&staging, &target) {
            if old.exists() { let _ = fs::rename(&old, &target); }
            return Err(error.into());
        }
        let _ = fs::remove_dir_all(&old);
        Ok(manifest)
    })();
    let _ = fs::remove_file(&archive);
    if staging.exists() { let _ = fs::remove_dir_all(&staging); }
    result
}

pub fn remove(store: &Store, line: &str) -> Result<()> {
    validate_line(line)?;
    ensure!(line.split('.').count() == 2, "invalid_version");
    let root = root(store)?;
    let target = root.join(line);
    ensure!(target.symlink_metadata()?.is_dir() && target.canonicalize()?.starts_with(root.canonicalize()?), "unsafe_runtime_path");
    fs::remove_dir_all(target)?;
    Ok(())
}

/// Python line a project asks for: Stack's setting for the site, else `.python-version`.
pub fn project_line(store: &Store, project: &crate::model::Project) -> String {
    project.runtime.get("python").cloned()
        .or_else(|| fs::read_to_string(project.path.join(".python-version")).ok().map(|v| v.trim().to_string()).filter(|v| validate_line(v).is_ok()))
        .unwrap_or_else(|| store.config().ok().and_then(|c| c.versions.get("python").cloned()).unwrap_or_default())
}

/// The interpreter a venv was made from (`home` in pyvenv.cfg), to tell if it matches a line.
fn venv_home(project: &Path) -> Option<String> {
    let cfg = fs::read_to_string(project.join(".venv/pyvenv.cfg")).ok()?;
    cfg.lines().find_map(|l| l.strip_prefix("home")).map(|r| r.trim_start_matches([' ', '=']).trim().to_string())
}

/// Makes (or remakes) the project's `.venv` with the Python it asks for and installs its
/// dependencies: `uv sync` when the project is managed by uv (uv.lock) and uv is chosen, else pip
/// from requirements*.txt or the `[project].dependencies` of pyproject.toml. A FastAPI project also
/// gets uvicorn if it lacks it. Returns the interpreter used.
pub fn prepare(store: &Store, project: &crate::model::Project, manager: &str, recreate: bool, log: &Path) -> Result<Value> {
    ensure!(["pip", "uv"].contains(&manager), "invalid_manager");
    let line = project_line(store, project);
    let python = resolve(store, &line).context("python_not_installed")?;
    let base_bin = python.parent().unwrap().to_path_buf();
    let dir = &project.path;
    let venv = dir.join(".venv");
    let matches = venv_home(dir).is_some_and(|home| Path::new(&home) == base_bin);
    if venv.exists() && (recreate || !matches || !venv.join("bin/python").exists()) {
        ensure!(!venv.symlink_metadata()?.file_type().is_symlink(), "unsafe_path");
        fs::remove_dir_all(&venv)?;
    }
    let home = dirs::home_dir().unwrap_or_default();
    let run = |program: &Path, args: &[&str]| -> Result<()> {
        use std::io::Write;
        let mut out = fs::OpenOptions::new().create(true).append(true).open(log)?;
        writeln!(out, "$ {} {}", program.file_name().unwrap_or_default().to_string_lossy(), args.join(" "))?;
        let status = Command::new(program).args(args).current_dir(dir).env_clear()
            .env("HOME", &home).env("PATH", format!("{}:{}:/usr/bin:/bin", venv.join("bin").display(), base_bin.display()))
            .env("LANG", "en_US.UTF-8").env("PIP_DISABLE_PIP_VERSION_CHECK", "1")
            .env("UV_PYTHON", &python).env("UV_PYTHON_DOWNLOADS", "never").env("UV_PROJECT_ENVIRONMENT", &venv)
            .stdin(Stdio::null()).stdout(out.try_clone()?).stderr(out).status()?;
        ensure!(status.success(), "scaffold_step_failed");
        Ok(())
    };
    let uv = (manager == "uv").then(|| tools::user_tool("uv")).flatten();
    ensure!(manager != "uv" || uv.is_some(), "uv_not_installed");
    let venv_python = venv.join("bin/python");
    if let Some(uv) = &uv {
        if dir.join("uv.lock").is_file() || (dir.join("pyproject.toml").is_file() && !has_requirements(dir)) {
            run(uv, &["sync", "--python", &python.to_string_lossy()])?;
        } else {
            if !venv_python.exists() { run(uv, &["venv", "--python", &python.to_string_lossy(), ".venv"])?; }
            for file in requirement_files(dir) { run(uv, &["pip", "install", "--python", &venv_python.to_string_lossy(), "-r", &file])?; }
        }
    } else {
        if !venv_python.exists() { run(&python, &["-m", "venv", ".venv"])?; }
        let files = requirement_files(dir);
        if !files.is_empty() {
            for file in files { run(&venv_python, &["-m", "pip", "install", "-r", &file])?; }
        } else if dir.join("pyproject.toml").is_file() {
            // The project's own dependencies, read by Python's tomllib (no build of the project).
            let deps = Command::new(&venv_python).args(["-I", "-c", "import tomllib,sys;print('\\n'.join(tomllib.load(open('pyproject.toml','rb')).get('project',{}).get('dependencies',[])))"])
                .current_dir(dir).env_clear().output()?;
            let list = String::from_utf8_lossy(&deps.stdout).to_string();
            if deps.status.success() && !list.trim().is_empty() {
                let file = store.directory("cache")?.join(format!("requirements-{}.txt", project.id));
                fs::write(&file, list)?;
                let result = run(&venv_python, &["-m", "pip", "install", "-r", &file.to_string_lossy()]);
                let _ = fs::remove_file(&file);
                result?;
            }
        }
    }
    ensure!(venv_python.exists(), "scaffold_step_failed");
    if project.kind == crate::model::ProjectKind::Fastapi {
        let check = Command::new(&venv_python).args(["-c", "import uvicorn"]).current_dir(dir).env_clear().stderr(Stdio::null()).status()?;
        if !check.success() {
            match &uv {
                Some(uv) => run(uv, &["pip", "install", "--python", &venv_python.to_string_lossy(), "uvicorn"])?,
                None => run(&venv_python, &["-m", "pip", "install", "uvicorn"])?,
            }
        }
    }
    Ok(json!({"python": python, "line": line}))
}
fn has_requirements(dir: &Path) -> bool {
    !requirement_files(dir).is_empty()
}
fn requirement_files(dir: &Path) -> Vec<String> {
    ["requirements.txt", "requirements/dev.txt", "requirements-dev.txt", "requirements/base.txt"].into_iter()
        .filter(|f| dir.join(f).is_file()).take(1).map(str::to_string).collect()
}

/// Whether a version line satisfies a requirement: PEP 440 (`>=3.10,<4`, `~=3.11`, `!=3.12.*`) or
/// Composer (`^8.2`, `~8.2.0`, `>=8.1 <9`, `8.2.*|^8.3`). Evaluated at line level (major.minor).
pub fn satisfies(requirement: &str, line: &str) -> bool {
    let v = key(line);
    let cmp = |op: &str, target: &str| -> bool {
        let target = target.trim().trim_start_matches('v');
        let star = target.ends_with(".*");
        let t: Vec<u32> = target.trim_end_matches(".*").split('.').filter_map(|p| p.parse().ok()).collect();
        if t.is_empty() { return true; }
        let n = t.len().min(2);
        let mine: Vec<u32> = v.iter().copied().chain(std::iter::repeat(0)).take(n).collect();
        let theirs: Vec<u32> = t.iter().copied().take(n).collect();
        // Comparing a line with a patch bound: "3.12" satisfies ">=3.12.1" (some patch does).
        match op {
            ">=" => mine >= theirs,
            ">" => if t.len() > 2 { mine >= theirs } else { mine > theirs },
            "<=" => mine <= theirs,
            "<" => mine < theirs || (t.len() > 2 && mine == theirs && t[2] > 0),
            "!=" => !(star || t.len() <= 2) || mine != theirs,
            "==" | "=" => if star || t.len() <= 2 { mine == theirs } else { v.len() < 3 && mine == theirs },
            "~=" => { let lo = t.len().saturating_sub(1).max(1); mine >= theirs && v[..lo.min(v.len())] == t[..lo] }
            "^" => !v.is_empty() && v[0] == t[0] && mine >= theirs,
            "~" => if t.len() >= 3 { mine == theirs } else { !v.is_empty() && v[0] == t[0] && mine >= theirs },
            _ => true,
        }
    };
    let clause = |c: &str| -> bool {
        c.split([',', ' ']).filter(|p| !p.trim().is_empty()).all(|p| {
            let p = p.trim();
            if p == "*" { return true; }
            for op in [">=", "<=", "==", "!=", "~=", ">", "<", "^", "~", "="] {
                if let Some(rest) = p.strip_prefix(op) { return cmp(op, rest); }
            }
            cmp("==", p)
        })
    };
    let requirement = requirement.trim();
    requirement.is_empty() || requirement.split("||").flat_map(|a| a.split('|')).any(|alt| clause(alt.trim()))
}

/// What the newest version of a framework needs: `requires_python` on PyPI (Django, FastAPI) or
/// `require.php` on Packagist (Laravel).
pub fn framework_requirement(framework: &str) -> Result<Value> {
    let (language, requirement, version) = match framework {
        "django" | "fastapi" => {
            let data: Value = serde_json::from_slice(&tools::fetch(&format!("https://pypi.org/pypi/{framework}/json"), 8_000_000)?)?;
            ("python", data["info"]["requires_python"].as_str().unwrap_or("").to_string(), data["info"]["version"].clone())
        }
        "laravel" => {
            let data: Value = serde_json::from_slice(&tools::fetch("https://repo.packagist.org/p2/laravel/framework.json", 8_000_000)?)?;
            let newest = data["packages"]["laravel/framework"].as_array().and_then(|list| list.iter().find(|p| {
                p["version_normalized"].as_str().is_some_and(|v| !v.contains("dev") && !v.contains("RC") && !v.contains("beta") && !v.contains("alpha"))
            })).cloned().unwrap_or(Value::Null);
            ("php", newest["require"]["php"].as_str().unwrap_or("").to_string(), newest["version"].clone())
        }
        _ => anyhow::bail!("unknown_framework"),
    };
    ensure!(requirement.len() <= 200, "invalid_requirement");
    Ok(json!({"framework": framework, "language": language, "requirement": requirement, "version": version}))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn requirements_by_line() {
        assert!(satisfies(">=3.12", "3.13") && !satisfies(">=3.12", "3.11"));
        assert!(satisfies(">=3.10,<4", "3.14") && !satisfies(">=3.10,<4", "3.9"));
        assert!(satisfies(">=3.8", "3.13"));
        assert!(satisfies("~=3.11", "3.13") && !satisfies("~=3.11", "3.10"));
        assert!(!satisfies("!=3.12.*", "3.12") && satisfies("!=3.12.*", "3.13"));
        assert!(satisfies("^8.2", "8.4") && !satisfies("^8.2", "8.1") && !satisfies("^8.2", "9.0"));
        assert!(satisfies("^8.2|^9.0", "9.0"));
        assert!(satisfies(">=8.1 <8.4", "8.3") && !satisfies(">=8.1 <8.4", "8.4"));
        assert!(satisfies(">=3.12.1", "3.12"));
        assert!(satisfies("", "3.9"));
    }
    #[test]
    fn validates_lines_and_reads_builds() {
        for ok in ["3.13", "3.13.18", "3.9"] { validate_line(ok).unwrap(); }
        for bad in ["3", "2.7", "3.13.0a2", "../3.13", "3.13.1.1", "3.x"] { assert!(validate_line(bad).is_err(), "{bad}"); }
        let t = triple();
        let release = json!({"tag_name": "20261110", "assets": [
            {"name": format!("cpython-3.13.18+20261110-{t}-install_only.tar.gz")},
            {"name": format!("cpython-3.13.18+20261110-{t}-install_only_stripped.tar.gz")},
            {"name": format!("cpython-3.16.0a2+20261110-{t}-install_only.tar.gz")},
            {"name": "cpython-3.12.16+20261110-x86_64-unknown-linux-gnu-install_only.tar.gz"},
        ]});
        let found = builds(&release);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].0, "3.13.18");
    }
    #[test]
    fn resolves_lines_and_global() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::new(temp.path().join("s")).unwrap();
        for (line, version) in [("3.12", "3.12.16"), ("3.13", "3.13.18")] {
            let dir = temp.path().join("s/runtimes/python").join(line);
            fs::create_dir_all(dir.join("bin")).unwrap();
            fs::write(dir.join("bin/python3"), "").unwrap();
            let m = PythonManifest { line: line.into(), version: version.into(), release: "20261110".into(), url: String::new(), sha256: String::new(), installed_at: 0 };
            fs::write(dir.join("butake-manifest.json"), serde_json::to_vec(&m).unwrap()).unwrap();
        }
        assert_eq!(installed(&store).len(), 2);
        assert!(resolve(&store, "").unwrap().to_string_lossy().contains("/3.13/"));
        assert!(resolve(&store, "3.12").unwrap().to_string_lossy().contains("/3.12/"));
        assert!(resolve(&store, "3.12.4").unwrap().to_string_lossy().contains("/3.12/"));
        assert!(resolve(&store, "3.11").is_none());
        let mut config = store.config().unwrap();
        config.versions.insert("python".into(), "3.12".into());
        store.save_config(&config).unwrap();
        assert!(resolve(&store, "").unwrap().to_string_lossy().contains("/3.12/"));
        remove(&store, "3.12").unwrap();
        assert!(remove(&store, "../x").is_err());
        assert_eq!(installed(&store).len(), 1);
    }
}
