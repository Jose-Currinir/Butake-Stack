//! New projects of every kind the stack serves, each with its official generator (Laravel's
//! installer choices, create-astro, create-emdash, create-next-app, create-vite) run with the stack's
//! own PHP, Composer and Node: nothing global is installed. The result goes through the same
//! detection as an opened folder, so a created project and an opened one are configured alike.
mod apps;
mod laravel;
mod web;

use apps::*;
use laravel::*;
use web::*;

use crate::core::process;
use crate::{
    core::download, core::model::Project, core::store::Store, runtimes::utilities::catalog,
    web::projects::detect,
};
use anyhow::{ensure, Result};
use std::{
    fs,
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

pub struct Options {
    /// laravel, php, astro, emdash, next, vite, node or static.
    pub kind: String,
    /// Generator template (Astro, EmDash, Next.js and Vite); empty means the generator's default.
    pub template: String,
    /// EmDash only: cloudflare or node.
    pub platform: String,
    pub name: String,
    pub parent: PathBuf,
    pub kit: String,
    pub testing: String,
    pub database: String,
    pub git: bool,
    /// Python line for Django and FastAPI (empty: the global one, else the newest installed).
    pub python: String,
    /// Package manager for Django and FastAPI: `pip` (venv + pip, with CPython) or `uv`.
    pub manager: String,
    /// PHP line for Laravel (empty: the global one).
    pub php: String,
    /// The stack's MySQL root password, from the Keychain (none while root has no password).
    pub mysql_password: Option<String>,
    /// Framework line ("5.2" Django, "12" Laravel, "0.162" FastAPI); empty: the newest.
    pub framework_version: String,
}

fn package(kit: &str) -> Result<&'static str> {
    Ok(match kit {
        "none" => "laravel/laravel",
        "react" => "laravel/react-starter-kit",
        "vue" => "laravel/vue-starter-kit",
        "svelte" => "laravel/svelte-starter-kit",
        "livewire" => "laravel/livewire-starter-kit",
        _ => anyhow::bail!("unknown_starter_kit"),
    })
}

pub fn validate_name(name: &str) -> Result<()> {
    ensure!(
        !name.is_empty()
            && name.len() <= 40
            && name
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
            && !name.starts_with('-'),
        "invalid_name"
    );
    Ok(())
}

pub struct Runner {
    pub path: String,
    /// More environment for every step (uv's interpreter, for instance).
    pub extra: Vec<(String, String)>,
    home: String,
    /// Folder of the stack's php.ini for this PHP line (the binary's built-in path is the build machine's).
    phprc: String,
    pub log: PathBuf,
}

impl Runner {
    pub fn run(&self, cwd: &Path, program: &Path, args: &[&str]) -> Result<()> {
        use std::io::Write;
        let mut log = process::append_log(&self.log)?;
        writeln!(
            log,
            "$ {} {}",
            program.file_name().unwrap_or_default().to_string_lossy(),
            args.join(" ")
        )?;
        let status = Command::new(program)
            .args(args)
            .current_dir(cwd)
            .env_clear()
            .env("PATH", &self.path)
            .env("HOME", &self.home)
            .env("PHPRC", &self.phprc)
            .env("LANG", "en_US.UTF-8")
            .env("COMPOSER_NO_INTERACTION", "1")
            .env("COREPACK_ENABLE_DOWNLOAD_PROMPT", "0")
            .env("CI", "1")
            .envs(self.extra.iter().map(|(k, v)| (k.as_str(), v.as_str())))
            .stdin(Stdio::null())
            .stdout(log.try_clone()?)
            .stderr(log)
            .status()?;
        ensure!(status.success(), "scaffold_step_failed");
        Ok(())
    }
}

/// The stack's own PHP (with Composer) and Node, and a runner whose PATH only has them.
pub struct Toolchain {
    pub series: String,
    pub php: PathBuf,
    pub composer: String,
    pub node_bin: Option<PathBuf>,
    pub runner: Runner,
}

impl Toolchain {
    pub fn new(
        store: &Store,
        php_series: Option<&str>,
        node_line: Option<&str>,
        log_name: &str,
    ) -> Result<Self> {
        let config = store.config()?;
        let series = php_series
            .map(str::to_string)
            .or_else(|| config.versions.get("php").cloned())
            .unwrap_or_else(|| "8.2".into());
        crate::runtimes::languages::php::manifest(store, &series)?;
        let php_root = store.root().join("runtimes/php").join(&series);
        let wanted = node_line
            .or(config.versions.get("node").map(String::as_str))
            .unwrap_or("");
        // The wanted Node line, or else the newest one installed.
        let node_bin = catalog::resolve(store, "node", wanted)
            .or_else(|| catalog::resolve(store, "node", ""))
            .map(|d| d.join("bin"));
        // Commands that project scripts call by name (Laravel's `install:features` runs `composer`
        // and `npm`; lockfiles may ask for pnpm or yarn): links to the real programs, no wrappers.
        let bin = store.directory("run")?.join("toolchain").join(&series);
        fs::create_dir_all(&bin)?;
        let phar = php_root.join("composer.phar");
        // composer.phar runs as a program (#!/usr/bin/env php, the PHP first on this PATH).
        fs::set_permissions(&phar, std::os::unix::fs::PermissionsExt::from_mode(0o755))?;
        crate::runtimes::languages::toolchains::replace_link(&phar, &bin.join("composer"))?;
        let corepack = node_bin
            .as_deref()
            .and_then(|node| crate::runtimes::languages::toolchains::corepack_dir(store, node));
        let mut path = vec![
            bin.to_string_lossy().into_owned(),
            php_root.join("bin").to_string_lossy().into_owned(),
        ];
        if let Some(node) = &node_bin {
            path.push(node.to_string_lossy().into_owned());
        }
        if let Some(dir) = corepack {
            path.push(dir.to_string_lossy().into_owned());
        }
        path.push("/usr/bin:/bin:/usr/sbin:/sbin".into());
        let log = store.directory("logs")?.join(format!("{log_name}.log"));
        let _ = fs::remove_file(&log);
        let phprc = store
            .root()
            .join("config/php")
            .join(&series)
            .to_string_lossy()
            .into_owned();
        Ok(Self {
            php: php_root.join("bin/php"),
            composer: php_root
                .join("composer.phar")
                .to_string_lossy()
                .into_owned(),
            series,
            node_bin,
            runner: Runner {
                extra: vec![],
                phprc,
                path: path.join(":"),
                home: Store::home()
                    .map(|h| h.to_string_lossy().into_owned())
                    .unwrap_or_default(),
                log,
            },
        })
    }
}

/// Last lines of a step log (`create-<name>` or `task-<id>`), for live progress in the app.
pub fn log_tail(store: &Store, log_name: &str) -> Result<Vec<String>> {
    ensure!(
        !log_name.is_empty()
            && log_name.len() <= 60
            && log_name
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_'),
        "invalid_name"
    );
    let path = store.directory("logs")?.join(format!("{log_name}.log"));
    let text = fs::read_to_string(path).unwrap_or_default();
    // Tools draw spinners and colors: keep only the text, last frame of each line.
    let lines: Vec<String> = text
        .lines()
        .map(|l| strip_ansi(l.rsplit('\r').next().unwrap_or(l)))
        .collect();
    Ok(lines[lines.len().saturating_sub(200)..].to_vec())
}

fn strip_ansi(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut chars = line.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\u{1b}' {
            if chars.peek() == Some(&'[') {
                chars.next();
                // CSI: parameters until a final byte in @..~
                for c in chars.by_ref() {
                    if ('@'..='~').contains(&c) {
                        break;
                    }
                }
            } else {
                chars.next();
            }
        } else if !c.is_control() || c == '\t' {
            out.push(c);
        }
    }
    out
}

fn set_env(file: &Path, values: &[(&str, String)]) -> Result<()> {
    let text = fs::read_to_string(file).unwrap_or_default();
    let mut lines: Vec<String> = text.lines().map(str::to_string).collect();
    for (key, value) in values {
        let entry = format!("{key}={value}");
        // Commented defaults (`# DB_HOST=…`) are activated in place.
        if let Some(line) = lines.iter_mut().find(|l| {
            let l = l.trim_start_matches('#').trim_start();
            l.starts_with(&format!("{key}="))
        }) {
            *line = entry;
        } else {
            lines.push(entry);
        }
    }
    fs::write(file, lines.join("\n") + "\n")?;
    Ok(())
}

/// Allowed templates per generator: only these strings ever reach a command line.
fn template(kind: &str, wanted: &str) -> Result<&'static str> {
    let list: &[&'static str] = match kind {
        "astro" => &["minimal", "basics", "blog", "portfolio", "starlight"],
        "emdash" => &["blog", "starter", "marketing", "portfolio"],
        "next" => &["app", "api", "empty"],
        "vite" => &[
            "react-ts",
            "vue-ts",
            "svelte-ts",
            "solid-ts",
            "preact-ts",
            "lit-ts",
            "vanilla-ts",
            "react",
            "vue",
            "svelte",
            "vanilla",
        ],
        _ => &[""],
    };
    if wanted.is_empty() {
        return Ok(list[0]);
    }
    list.iter()
        .copied()
        .find(|t| *t == wanted)
        .ok_or_else(|| anyhow::anyhow!("unknown_template"))
}

/// Runner with only the stack's Node on the PATH (JavaScript generators need no PHP).
fn node_runner(store: &Store, log_name: &str) -> Result<(PathBuf, Runner)> {
    let config = store.config()?;
    let wanted = config
        .versions
        .get("node")
        .map(String::as_str)
        .unwrap_or("");
    let node_bin = catalog::resolve(store, "node", wanted)
        .or_else(|| catalog::resolve(store, "node", ""))
        .map(|d| d.join("bin"))
        .ok_or_else(|| anyhow::anyhow!("node_not_installed"))?;
    let log = store.directory("logs")?.join(format!("{log_name}.log"));
    let _ = fs::remove_file(&log);
    let runner = Runner {
        extra: vec![],
        path: format!(
            "{}:/usr/bin:/bin:/usr/sbin:/sbin",
            node_bin.to_string_lossy()
        ),
        home: Store::home()
            .map(|h| h.to_string_lossy().into_owned())
            .unwrap_or_default(),
        phprc: String::new(),
        log,
    };
    Ok((node_bin, runner))
}

/// Node major of a bin folder (…/node/24.13.0/bin -> 24), written to .nvmrc so the site keeps it.
fn node_major(node_bin: &Path) -> Option<String> {
    node_bin
        .parent()?
        .file_name()?
        .to_str()?
        .split('.')
        .next()
        .map(str::to_string)
}

/// A repository with the first commit (signed if the user signs commits). Never fatal: without
/// the Command Line Tools, or if the commit can't be made, the project is still created.
fn git_init(runner: &Runner, target: &Path, notes: &mut Vec<String>) {
    if target.join(".git").exists() {
        return;
    }
    if !git_available() {
        notes.push("git_unavailable".into());
        return;
    }
    let git = Path::new("/usr/bin/git");
    if runner
        .run(target, git, &["init", "-q", "-b", "main"])
        .is_err()
        || runner.run(target, git, &["add", "-A"]).is_err()
    {
        notes.push("git_failed".into());
        return;
    }
    if runner
        .run(target, git, &["commit", "-q", "-m", "Proyecto inicial"])
        .is_err()
    {
        notes.push("git_no_commit".into());
    }
}

/// What a new project needs before anything is downloaded, checked up front so a failure never
/// leaves half a project behind: a free name (folder and site), and the runtime of its kind.
fn preflight(store: &Store, options: &Options) -> Result<()> {
    ensure!(
        [
            "laravel",
            "php",
            "static",
            "node",
            "astro",
            "emdash",
            "next",
            "vite",
            "kmp",
            "django",
            "fastapi",
            "rust",
            "swift",
            "react-native"
        ]
        .contains(&options.kind.as_str()),
        "unknown_kind"
    );
    ensure!(options.kind != "kmp", "kmp_use_wizard");
    let (_, target) = target_of(options)?;
    let _ = target;
    // The site id comes from the folder name; an existing site (even one whose folder is missing)
    // must never be overwritten by a new project.
    let id = detect::sanitize_id(&options.name);
    ensure!(
        !store.list()?.iter().any(|p| p.id == id) && !store.missing()?.iter().any(|m| m.id == id),
        "site_exists"
    );
    let config = store.config()?;
    let needs_php = matches!(options.kind.as_str(), "laravel");
    let needs_node = matches!(
        options.kind.as_str(),
        "astro" | "emdash" | "next" | "vite" | "node"
    ) || (options.kind == "laravel" && options.kit != "none");
    if needs_php {
        let series = if options.php.is_empty() {
            config
                .versions
                .get("php")
                .cloned()
                .unwrap_or_else(|| "8.2".into())
        } else {
            options.php.clone()
        };
        ensure!(
            crate::runtimes::languages::php::manifest(store, &series).is_ok(),
            "php_not_installed"
        );
    }
    if needs_node || options.kind == "react-native" {
        ensure!(
            catalog::resolve(store, "node", "").is_some(),
            "node_not_installed"
        );
    }
    match options.kind.as_str() {
        "django" | "fastapi" => {
            ensure!(
                options.python.is_empty()
                    || crate::runtimes::languages::python::validate_line(&options.python).is_ok(),
                "invalid_version"
            );
            ensure!(
                crate::runtimes::languages::python::resolve(store, &options.python).is_some(),
                "python_not_installed"
            );
            ensure!(
                ["pip", "uv", ""].contains(&options.manager.as_str()),
                "invalid_manager"
            );
            ensure!(
                options.manager != "uv" || catalog::user_tool("uv").is_some(),
                "uv_not_installed"
            );
        }
        "rust" => ensure!(catalog::user_tool("cargo").is_some(), "cargo_not_installed"),
        "swift" => ensure!(git_available(), "clt_not_installed"),
        _ => {}
    }
    Ok(())
}

/// Git from the Command Line Tools: `/usr/bin/git` is only a shim that offers to install them.
fn git_available() -> bool {
    Command::new("/usr/bin/xcode-select")
        .arg("-p")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

/// What was created: the project (a Rust command-line tool is not registered), its folder and the
/// notes for the next steps.
pub struct Created {
    pub project: Option<Project>,
    pub path: PathBuf,
    pub notes: Vec<String>,
}

/// Creates the project and registers it (a site off; a Swift package or a React Native app as a
/// project without a server). If any step fails, the half-made folder is removed: it did not
/// exist before this call.
pub fn create(store: &Store, options: &Options) -> Result<Created> {
    validate_name(&options.name)?;
    preflight(store, options)?;
    let (_, target) = target_of(options)?;
    let mut notes = vec![];
    let result = match options.kind.as_str() {
        "laravel" => create_laravel(store, options, &mut notes).map(Some),
        "php" | "static" | "node" => create_basic(store, options, &mut notes).map(Some),
        "django" | "fastapi" => create_python(store, options, &mut notes).map(Some),
        "rust" => create_rust(store, options, &mut notes),
        "swift" => create_swift(store, options, &mut notes).map(Some),
        "react-native" => create_react_native(store, options, &mut notes).map(Some),
        _ => create_javascript(store, options, &mut notes).map(Some),
    };
    match result {
        Ok(project) => Ok(Created {
            project,
            path: target,
            notes,
        }),
        Err(error) => {
            if target.is_dir() {
                let _ = fs::remove_dir_all(&target);
            }
            Err(error)
        }
    }
}

/// A runner whose PATH has the user's toolchains (uv, cargo) and, when given, the stack's Node.
fn user_runner(store: &Store, options: &Options, node_bin: Option<&Path>) -> Result<Runner> {
    let home = Store::home().unwrap_or_default();
    let mut path: Vec<String> = [home.join(".local/bin"), home.join(".cargo/bin")]
        .iter()
        .map(|p| p.to_string_lossy().into_owned())
        .collect();
    if let Some(node) = node_bin {
        path.insert(0, node.to_string_lossy().into_owned());
    }
    path.push("/usr/bin:/bin:/usr/sbin:/sbin".into());
    let log = store
        .directory("logs")?
        .join(format!("create-{}.log", options.name));
    let _ = fs::remove_file(&log);
    Ok(Runner {
        path: path.join(":"),
        home: home.to_string_lossy().into_owned(),
        phprc: String::new(),
        log,
        extra: vec![],
    })
}

fn pascal(name: &str) -> String {
    name.split(|c: char| !c.is_ascii_alphanumeric())
        .filter(|p| !p.is_empty())
        .map(|p| p[..1].to_ascii_uppercase() + &p[1..])
        .collect::<String>()
        .trim_start_matches(|c: char| c.is_ascii_digit())
        .to_string()
}

fn target_of(options: &Options) -> Result<(PathBuf, PathBuf)> {
    let parent = options.parent.canonicalize()?;
    ensure!(parent.is_dir(), "invalid_path");
    let target = parent.join(&options.name);
    ensure!(!target.exists(), "folder_exists");
    Ok((parent, target))
}

/// Registers what detection makes of the new folder (off, like every site).
fn register(store: &Store, target: &Path) -> Result<Project> {
    store.save(detect::detect(target)?.project)
}

/// Registers an app or a package Stack builds but does not serve (Swift, React Native): a project
/// without a server, with the checks detection finds («Comprobar», «Compilar»).
fn register_unserved(store: &Store, target: &Path) -> Result<Project> {
    let mut project = detect::detect(target)?.project;
    project.kind = crate::core::model::ProjectKind::Unserved;
    store.save(project)
}

/// Current versions of each kind's framework and generator, for the assistant to show what it will
/// install: npm's `latest` tags and Packagist's newest stable release. Requests run in parallel.
pub fn versions() -> Result<serde_json::Value> {
    let npm = [
        "astro",
        "create-astro",
        "emdash",
        "create-emdash",
        "next",
        "create-next-app",
        "vite",
        "create-vite",
        "react",
        "vue",
        "svelte",
    ];
    let packagist = [
        "laravel/framework",
        "laravel/laravel",
        "pestphp/pest",
        "livewire/livewire",
    ];
    let handles: Vec<_> = npm
        .iter()
        .map(|name| {
            (
                name.to_string(),
                format!("https://registry.npmjs.org/{name}/latest"),
                false,
            )
        })
        .chain(packagist.iter().map(|name| {
            (
                name.to_string(),
                format!("https://repo.packagist.org/p2/{name}.json"),
                true,
            )
        }))
        .map(|(name, url, composer)| {
            std::thread::spawn(move || -> Option<(String, String)> {
                let body: serde_json::Value =
                    serde_json::from_slice(&download::fetch(&url, 8_000_000).ok()?).ok()?;
                let version = if composer {
                    body["packages"][&name]
                        .as_array()?
                        .iter()
                        .filter_map(|v| v["version"].as_str())
                        .find(|v| {
                            !v.contains("dev")
                                && !v.contains("RC")
                                && !v.contains("beta")
                                && !v.contains("alpha")
                        })?
                        .trim_start_matches('v')
                        .to_string()
                } else {
                    body["version"].as_str()?.to_string()
                };
                Some((name, version))
            })
        })
        .collect();
    let mut out = serde_json::Map::new();
    for handle in handles {
        if let Ok(Some((name, version))) = handle.join() {
            out.insert(name, serde_json::Value::String(version));
        }
    }
    ensure!(!out.is_empty(), "offline");
    Ok(serde_json::Value::Object(out))
}

#[cfg(test)]
mod tests;
