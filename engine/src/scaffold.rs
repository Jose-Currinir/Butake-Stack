//! New projects of every kind the stack serves, each with its official generator (Laravel's
//! installer choices, create-astro, create-emdash, create-next-app, create-vite) run with the stack's
//! own PHP, Composer and Node: nothing global is installed. The result goes through the same
//! detection as an opened folder, so a created project and an opened one are configured alike.
use crate::{detect, model::Project, store::Store, tools};
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
            && name.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
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
        let mut log = fs::OpenOptions::new().create(true).append(true).open(&self.log)?;
        writeln!(log, "$ {} {}", program.file_name().unwrap_or_default().to_string_lossy(), args.join(" "))?;
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
    pub fn new(store: &Store, php_series: Option<&str>, node_line: Option<&str>, log_name: &str) -> Result<Self> {
        let config = store.config()?;
        let series = php_series
            .map(str::to_string)
            .or_else(|| config.versions.get("php").cloned())
            .unwrap_or_else(|| "8.2".into());
        crate::runtimes::manifest(store, &series)?;
        let php_root = store.root().join("runtimes/php").join(&series);
        let wanted = node_line.or(config.versions.get("node").map(String::as_str)).unwrap_or("");
        // The wanted Node line, or else the newest one installed.
        let node_bin = tools::resolve(store, "node", wanted)
            .or_else(|| tools::resolve(store, "node", ""))
            .map(|d| d.join("bin"));
        // Commands that project scripts call by name (Laravel's `install:features` runs `composer`
        // and `npm`; lockfiles may ask for pnpm or yarn): links to the real programs, no wrappers.
        let bin = store.directory("run")?.join("toolchain").join(&series);
        fs::create_dir_all(&bin)?;
        let phar = php_root.join("composer.phar");
        // composer.phar runs as a program (#!/usr/bin/env php, the PHP first on this PATH).
        fs::set_permissions(&phar, std::os::unix::fs::PermissionsExt::from_mode(0o755))?;
        crate::toolchains::replace_link(&phar, &bin.join("composer"))?;
        let corepack = node_bin.as_deref().and_then(|node| crate::toolchains::corepack_dir(store, node));
        let mut path = vec![bin.to_string_lossy().into_owned(), php_root.join("bin").to_string_lossy().into_owned()];
        if let Some(node) = &node_bin {
            path.push(node.to_string_lossy().into_owned());
        }
        if let Some(dir) = corepack {
            path.push(dir.to_string_lossy().into_owned());
        }
        path.push("/usr/bin:/bin:/usr/sbin:/sbin".into());
        let log = store.directory("logs")?.join(format!("{log_name}.log"));
        let _ = fs::remove_file(&log);
        let phprc = store.root().join("config/php").join(&series).to_string_lossy().into_owned();
        Ok(Self {
            php: php_root.join("bin/php"),
            composer: php_root.join("composer.phar").to_string_lossy().into_owned(),
            series,
            node_bin,
            runner: Runner {
                extra: vec![],
                phprc,
                path: path.join(":"),
                home: dirs::home_dir().map(|h| h.to_string_lossy().into_owned()).unwrap_or_default(),
                log,
            },
        })
    }
}

/// Last lines of a step log (`create-<name>` or `task-<id>`), for live progress in the app.
pub fn log_tail(store: &Store, log_name: &str) -> Result<Vec<String>> {
    ensure!(
        !log_name.is_empty() && log_name.len() <= 60 && log_name.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_'),
        "invalid_name"
    );
    let path = store.directory("logs")?.join(format!("{log_name}.log"));
    let text = fs::read_to_string(path).unwrap_or_default();
    // Tools draw spinners and colors: keep only the text, last frame of each line.
    let lines: Vec<String> = text.lines().map(|l| strip_ansi(l.rsplit('\r').next().unwrap_or(l))).collect();
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
                    if ('@'..='~').contains(&c) { break; }
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
        "vite" => &["react-ts", "vue-ts", "svelte-ts", "solid-ts", "preact-ts", "lit-ts", "vanilla-ts", "react", "vue", "svelte", "vanilla"],
        _ => &[""],
    };
    if wanted.is_empty() {
        return Ok(list[0]);
    }
    list.iter().copied().find(|t| *t == wanted).ok_or_else(|| anyhow::anyhow!("unknown_template"))
}

/// Runner with only the stack's Node on the PATH (JavaScript generators need no PHP).
fn node_runner(store: &Store, log_name: &str) -> Result<(PathBuf, Runner)> {
    let config = store.config()?;
    let wanted = config.versions.get("node").map(String::as_str).unwrap_or("");
    let node_bin = tools::resolve(store, "node", wanted)
        .or_else(|| tools::resolve(store, "node", ""))
        .map(|d| d.join("bin"))
        .ok_or_else(|| anyhow::anyhow!("node_not_installed"))?;
    let log = store.directory("logs")?.join(format!("{log_name}.log"));
    let _ = fs::remove_file(&log);
    let runner = Runner {
        extra: vec![],
        path: format!("{}:/usr/bin:/bin:/usr/sbin:/sbin", node_bin.to_string_lossy()),
        home: dirs::home_dir().map(|h| h.to_string_lossy().into_owned()).unwrap_or_default(),
        phprc: String::new(),
        log,
    };
    Ok((node_bin, runner))
}

/// Node major of a bin folder (…/node/24.13.0/bin -> 24), written to .nvmrc so the site keeps it.
fn node_major(node_bin: &Path) -> Option<String> {
    node_bin.parent()?.file_name()?.to_str()?.split('.').next().map(str::to_string)
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
    if runner.run(target, git, &["init", "-q", "-b", "main"]).is_err() || runner.run(target, git, &["add", "-A"]).is_err() {
        notes.push("git_failed".into());
        return;
    }
    if runner.run(target, git, &["commit", "-q", "-m", "Proyecto inicial"]).is_err() {
        notes.push("git_no_commit".into());
    }
}

/// What a new project needs before anything is downloaded, checked up front so a failure never
/// leaves half a project behind: a free name (folder and site), and the runtime of its kind.
fn preflight(store: &Store, options: &Options) -> Result<()> {
    ensure!(
        ["laravel", "php", "static", "node", "astro", "emdash", "next", "vite", "kmp", "django", "fastapi", "rust", "swift", "react-native"].contains(&options.kind.as_str()),
        "unknown_kind"
    );
    ensure!(options.kind != "kmp", "kmp_use_wizard");
    let (_, target) = target_of(options)?;
    let _ = target;
    // The site id comes from the folder name; an existing site (even one whose folder is missing)
    // must never be overwritten by a new project.
    let id = detect::sanitize_id(&options.name);
    ensure!(!store.list()?.iter().any(|p| p.id == id) && !store.missing()?.iter().any(|(m, _)| *m == id), "site_exists");
    let config = store.config()?;
    let needs_php = matches!(options.kind.as_str(), "laravel");
    let needs_node = matches!(options.kind.as_str(), "astro" | "emdash" | "next" | "vite" | "node")
        || (options.kind == "laravel" && options.kit != "none");
    if needs_php {
        let series = if options.php.is_empty() { config.versions.get("php").cloned().unwrap_or_else(|| "8.2".into()) } else { options.php.clone() };
        ensure!(crate::runtimes::manifest(store, &series).is_ok(), "php_not_installed");
    }
    if needs_node || options.kind == "react-native" {
        ensure!(tools::resolve(store, "node", "").is_some(), "node_not_installed");
    }
    match options.kind.as_str() {
        "django" | "fastapi" => {
            ensure!(options.python.is_empty() || crate::python::validate_line(&options.python).is_ok(), "invalid_version");
            ensure!(crate::python::resolve(store, &options.python).is_some(), "python_not_installed");
            ensure!(["pip", "uv", ""].contains(&options.manager.as_str()), "invalid_manager");
            ensure!(options.manager != "uv" || tools::user_tool("uv").is_some(), "uv_not_installed");
        }
        "rust" => ensure!(tools::user_tool("cargo").is_some(), "cargo_not_installed"),
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

/// What was created: the site (none for apps, libraries and tools Stack doesn't serve), its folder and
/// the notes for the next steps.
pub struct Created {
    pub project: Option<Project>,
    pub path: PathBuf,
    pub notes: Vec<String>,
}

/// Creates the project and, when it's a site, registers it (off). If any step fails, the half-made
/// folder is removed: it did not exist before this call.
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
        "swift" => create_swift(store, options, &mut notes).map(|_| None),
        "react-native" => create_react_native(store, options, &mut notes).map(|_| None),
        _ => create_javascript(store, options, &mut notes).map(Some),
    };
    match result {
        Ok(project) => Ok(Created { project, path: target, notes }),
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
    let home = dirs::home_dir().unwrap_or_default();
    let mut path: Vec<String> = [home.join(".local/bin"), home.join(".cargo/bin")].iter().map(|p| p.to_string_lossy().into_owned()).collect();
    if let Some(node) = node_bin { path.insert(0, node.to_string_lossy().into_owned()); }
    path.push("/usr/bin:/bin:/usr/sbin:/sbin".into());
    let log = store.directory("logs")?.join(format!("create-{}.log", options.name));
    let _ = fs::remove_file(&log);
    Ok(Runner { path: path.join(":"), home: home.to_string_lossy().into_owned(), phprc: String::new(), log, extra: vec![] })
}

fn pascal(name: &str) -> String {
    name.split(|c: char| !c.is_ascii_alphanumeric())
        .filter(|p| !p.is_empty())
        .map(|p| p[..1].to_ascii_uppercase() + &p[1..])
        .collect::<String>()
        .trim_start_matches(|c: char| c.is_ascii_digit())
        .to_string()
}

/// Django or FastAPI with the Python chosen (Stack's own CPython): `.venv` made with venv and pip,
/// or with uv when chosen (then a uv project: pyproject and lock). `.python-version` keeps the line.
fn create_python(store: &Store, options: &Options, notes: &mut Vec<String>) -> Result<Project> {
    let (parent, target) = target_of(options)?;
    let python = crate::python::resolve(store, &options.python).ok_or_else(|| anyhow::anyhow!("python_not_installed"))?;
    let line = python.parent().and_then(Path::parent).and_then(Path::file_name).map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let mut runner = user_runner(store, options, None)?;
    let venv_bin = target.join(".venv/bin");
    runner.path = format!("{}:{}:{}", venv_bin.display(), python.parent().unwrap().display(), runner.path);
    let package = if options.kind == "django" { "django" } else { "fastapi[standard]" };
    if options.manager == "uv" {
        let uv = tools::user_tool("uv").ok_or_else(|| anyhow::anyhow!("uv_not_installed"))?;
        let python_arg = python.to_string_lossy().into_owned();
        // uv uses this interpreter and never downloads one of its own.
        runner.extra = vec![("UV_PYTHON".into(), python_arg.clone()), ("UV_PYTHON_DOWNLOADS".into(), "never".into())];
        runner.run(&parent, &uv, &["init", options.name.as_str(), "--app", "--vcs", "none", "--no-workspace", "--python", &python_arg])?;
        let _ = fs::remove_file(target.join("main.py"));
        runner.run(&target, &uv, &["add", package])?;
    } else {
        fs::create_dir_all(&target)?;
        runner.run(&target, &python, &["-m", "venv", ".venv"])?;
        fs::write(target.join("requirements.txt"), format!("{package}\n"))?;
        runner.run(&target, &venv_bin.join("python"), &["-m", "pip", "install", "--disable-pip-version-check", "-r", "requirements.txt"])?;
        // Pin what was installed, so the project installs the same versions elsewhere.
        let freeze = Command::new(venv_bin.join("python")).args(["-m", "pip", "freeze", "--disable-pip-version-check"]).current_dir(&target).env_clear().output()?;
        if freeze.status.success() && !freeze.stdout.is_empty() { fs::write(target.join("requirements.txt"), &freeze.stdout)?; }
    }
    fs::write(target.join(".python-version"), format!("{line}\n"))?;
    let python_bin = venv_bin.join("python");
    if options.kind == "django" {
        runner.run(&target, &venv_bin.join("django-admin"), &["startproject", "config", "."])?;
        runner.run(&target, &python_bin, &["manage.py", "migrate", "--noinput"])?;
    } else {
        let title = options.name.replace('"', "");
        fs::write(target.join("main.py"), format!("from fastapi import FastAPI\n\napp = FastAPI(title=\"{title}\")\n\n\n@app.get(\"/\")\ndef inicio():\n    return {{\"mensaje\": \"Hola desde FastAPI y Butake Stack\"}}\n\n\n@app.get(\"/salud\")\ndef salud():\n    return {{\"estado\": \"ok\"}}\n"))?;
    }
    if !target.join(".gitignore").exists() {
        fs::write(target.join(".gitignore"), ".venv/\n__pycache__/\n*.pyc\ndb.sqlite3\n.env\n")?;
    }
    if options.git { git_init(&runner, &target, notes); }
    let mut project = register(store, &target)?;
    project.runtime.insert("python".into(), line);
    store.save(project)
}

/// Rust with cargo: a web server (axum, reading PORT and HOST from Stack) or a command-line tool.
fn create_rust(store: &Store, options: &Options, notes: &mut Vec<String>) -> Result<Option<Project>> {
    let (parent, target) = target_of(options)?;
    let cargo = tools::user_tool("cargo").ok_or_else(|| anyhow::anyhow!("cargo_not_installed"))?;
    let runner = user_runner(store, options, None)?;
    let web = options.template != "cli";
    runner.run(&parent, &cargo, &["new", options.name.as_str(), "--vcs", "none"])?;
    if web {
        runner.run(&target, &cargo, &["add", "axum", "tokio", "--features", "tokio/full"])?;
        fs::write(target.join("src/main.rs"), "use axum::{routing::get, Router};\n\n#[tokio::main]\nasync fn main() {\n    // Butake Stack assigns PORT and HOST; the .test address points here.\n    let port = std::env::var(\"PORT\").unwrap_or_else(|_| \"3000\".into());\n    let host = std::env::var(\"HOST\").unwrap_or_else(|_| \"127.0.0.1\".into());\n    let app = Router::new()\n        .route(\"/\", get(|| async { \"Hola desde Rust y Butake Stack\" }))\n        .route(\"/salud\", get(|| async { \"ok\" }));\n    let listener = tokio::net::TcpListener::bind(format!(\"{host}:{port}\")).await.unwrap();\n    println!(\"http://{host}:{port}\");\n    axum::serve(listener, app).await.unwrap();\n}\n")?;
        // Compiled once now, so the first start of the site is quick.
        runner.run(&target, &cargo, &["build"])?;
    }
    if !target.join(".gitignore").exists() { fs::write(target.join(".gitignore"), "/target\n")?; }
    if options.git { git_init(&runner, &target, notes); }
    if web { register(store, &target).map(Some) } else { Ok(None) }
}

/// A Swift package (SwiftPM): executable, library or command-line tool. Apps with a window are
/// created in Xcode; the note says so.
fn create_swift(store: &Store, options: &Options, notes: &mut Vec<String>) -> Result<()> {
    let (_, target) = target_of(options)?;
    let kind = match options.template.as_str() { "library" => "library", "tool" => "tool", _ => "executable" };
    let runner = user_runner(store, options, None)?;
    fs::create_dir_all(&target)?;
    let name = pascal(&options.name);
    ensure!(!name.is_empty(), "invalid_name");
    runner.run(&target, Path::new("/usr/bin/swift"), &["package", "init", "--type", kind, "--name", &name])?;
    if options.git { git_init(&runner, &target, notes); }
    notes.push("swift_xcode_apps".into());
    Ok(())
}

/// React Native: Expo (the framework React Native recommends) or the bare React Native CLI.
fn create_react_native(store: &Store, options: &Options, notes: &mut Vec<String>) -> Result<()> {
    let (parent, target) = target_of(options)?;
    let node = tools::resolve(store, "node", "").map(|d| d.join("bin")).ok_or_else(|| anyhow::anyhow!("node_not_installed"))?;
    let runner = user_runner(store, options, Some(&node))?;
    let npx = node.join("npx");
    if options.template == "cli" {
        let name = pascal(&options.name);
        ensure!(!name.is_empty(), "invalid_name");
        runner.run(&parent, &npx, &["--yes", "@react-native-community/cli@latest", "init", &name, "--directory", &options.name, "--skip-git-init", "--install-pods", "false", "--pm", "npm"])?;
        notes.push("rn_pods".into());
    } else {
        let template = match options.template.as_str() { "blank" => "blank-typescript", "tabs" => "tabs", _ => "default" };
        runner.run(&parent, &npx, &["--yes", "create-expo-app@latest", &options.name, "--template", template, "--yes"])?;
    }
    if !target.join(".nvmrc").exists() {
        if let Some(major) = node_major(&node) { fs::write(target.join(".nvmrc"), format!("{major}\n"))?; }
    }
    if options.git { git_init(&runner, &target, notes); }
    Ok(())
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

fn create_javascript(store: &Store, options: &Options, notes: &mut Vec<String>) -> Result<Project> {
    let template = template(&options.kind, &options.template)?;
    let (parent, target) = target_of(options)?;
    let (node_bin, runner) = node_runner(store, &format!("create-{}", options.name))?;
    let npx = node_bin.join("npx");
    let name = options.name.as_str();
    match options.kind.as_str() {
        "astro" => runner.run(&parent, &npx, &["--yes", "create-astro@latest", name, "--template", template, "--install", "--no-git", "--skip-houston", "--yes"])?,
        "emdash" => {
            let platform = if options.platform == "node" { "node" } else { "cloudflare" };
            runner.run(&parent, &npx, &["--yes", "create-emdash@latest", name, "--template", template, "--platform", platform, "--pm", "npm", "--install", "--yes"])?
        }
        "next" => {
            let mut args = vec!["--yes", "create-next-app@latest", name, "--ts", "--tailwind", "--eslint", "--app", "--use-npm", "--disable-git", "--no-agent-feedback", "--yes"];
            match template {
                "api" => args.push("--api"),
                "empty" => args.push("--empty"),
                _ => {}
            }
            runner.run(&parent, &npx, &args)?
        }
        _ => {
            runner.run(&parent, &npx, &["--yes", "create-vite@latest", name, "--template", template, "--no-interactive", "--no-immediate"])?;
            runner.run(&target, &node_bin.join("npm"), &["install", "--no-audit", "--no-fund"])?;
        }
    }
    ensure!(target.is_dir(), "scaffold_step_failed");
    if !target.join(".nvmrc").exists() {
        if let Some(major) = node_major(&node_bin) {
            fs::write(target.join(".nvmrc"), format!("{major}\n"))?;
        }
    }
    if options.git {
        git_init(&runner, &target, notes);
    }
    register(store, &target)
}

/// PHP, Node (node:http, no dependencies) and static sites: a small, working starting point.
fn create_basic(store: &Store, options: &Options, notes: &mut Vec<String>) -> Result<Project> {
    let (_, target) = target_of(options)?;
    let title = escape_html(&options.name);
    fs::create_dir_all(&target)?;
    let style = "body{font:16px/1.5 -apple-system,system-ui,sans-serif;max-width:40rem;margin:4rem auto;padding:0 1rem;color:#111;background:#fff}@media(prefers-color-scheme:dark){body{color:#eee;background:#111}}";
    match options.kind.as_str() {
        "php" => {
            fs::write(target.join("index.php"), format!("<?php\n$title = '{title}';\n?><!doctype html>\n<html lang=\"es\">\n<head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title><?= htmlspecialchars($title) ?></title><style>{style}</style></head>\n<body><h1><?= htmlspecialchars($title) ?></h1><p>PHP <?= PHP_VERSION ?> desde Butake Stack.</p></body>\n</html>\n"))?;
            fs::write(target.join(".gitignore"), "/vendor/\n.env\n")?;
        }
        "node" => {
            let package = serde_json::json!({
                "name": options.name.to_ascii_lowercase(), "private": true, "type": "module",
                "scripts": {"dev": "node --watch server.js", "start": "node server.js"},
            });
            fs::write(target.join("package.json"), serde_json::to_string_pretty(&package)? + "\n")?;
            fs::write(target.join("server.js"), format!("import {{ createServer }} from 'node:http'\n\n// Butake Stack assigns PORT and HOST; the .test address points here.\nconst port = Number(process.env.PORT ?? 3000)\nconst host = process.env.HOST ?? '127.0.0.1'\n\ncreateServer((request, response) => {{\n  response.writeHead(200, {{ 'content-type': 'text/html; charset=utf-8' }})\n  response.end(`<!doctype html><title>{title}</title><style>{style}</style><h1>{title}</h1><p>Node ${{process.version}} desde Butake Stack.</p>`)\n}}).listen(port, host, () => console.log(`http://${{host}}:${{port}}`))\n"))?;
            fs::write(target.join(".gitignore"), "node_modules/\n.env\n")?;
            let (node_bin, _) = node_runner(store, &format!("create-{}", options.name))?;
            if let Some(major) = node_major(&node_bin) {
                fs::write(target.join(".nvmrc"), format!("{major}\n"))?;
            }
        }
        _ => {
            fs::write(target.join("index.html"), format!("<!doctype html>\n<html lang=\"es\">\n<head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>{title}</title><style>{style}</style></head>\n<body><h1>{title}</h1><p>Sitio estático servido por Butake Stack.</p></body>\n</html>\n"))?;
        }
    }
    if options.git {
        let runner = Runner {
            extra: vec![],
            path: "/usr/bin:/bin".into(),
            home: dirs::home_dir().map(|h| h.to_string_lossy().into_owned()).unwrap_or_default(),
            phprc: String::new(),
            log: store.directory("logs")?.join(format!("create-{}.log", options.name)),
        };
        git_init(&runner, &target, notes);
    }
    register(store, &target)
}

fn escape_html(text: &str) -> String {
    text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;").replace('\'', "&#39;")
}

fn create_laravel(store: &Store, options: &Options, notes: &mut Vec<String>) -> Result<Project> {
    let package = package(&options.kit)?;
    ensure!(["pest", "phpunit"].contains(&options.testing.as_str()), "invalid_testing");
    ensure!(["sqlite", "mysql", "pgsql"].contains(&options.database.as_str()), "invalid_database");
    let (parent, target) = target_of(options)?;

    let config = store.config()?;
    let chain = Toolchain::new(store, (!options.php.is_empty()).then_some(options.php.as_str()), None, &format!("create-{}", options.name))?;
    let (php, runner, node_bin, series) = (&chain.php, &chain.runner, &chain.node_bin, chain.series.clone());
    let composer_arg = chain.composer.clone();

    // 1. Skeleton (Composer runs its post-create scripts: .env, key, SQLite file).
    // Starter kits come from their main branch, like the official installer (`--stability=dev`):
    // some have no stable tag, and the tagged ones lag behind.
    let mut args = vec![composer_arg.as_str(), "create-project", package, &options.name, "--prefer-dist", "--no-interaction"];
    if options.kit != "none" {
        args.push("--stability=dev");
    }
    runner.run(&parent, php, &args)?;
    let artisan = |args: &[&str]| -> Result<()> {
        let mut all = vec!["artisan"];
        all.extend_from_slice(args);
        runner.run(&target, php, &all)
    };
    let env = target.join(".env");
    set_env(&env, &[("APP_URL", format!("http://{}.test", options.name.to_ascii_lowercase()))])?;
    // 2. Tests: Pest replaces PHPUnit as the runner, like the official installer. Starter kits
    //    already ship with Pest; there it stays (the installer can't turn a kit into PHPUnit).
    let composer: serde_json::Value = fs::read_to_string(target.join("composer.json")).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default();
    let has_pest = composer["require-dev"].get("pestphp/pest").is_some();
    if options.testing == "pest" && !has_pest {
        runner.run(&target, php, &[&composer_arg, "remove", "phpunit/phpunit", "--dev", "--no-update"])?;
        runner.run(&target, php, &[&composer_arg, "require", "pestphp/pest", "pestphp/pest-plugin-laravel", "--dev", "--with-all-dependencies", "--no-interaction"])?;
        runner.run(&target, php, &["vendor/bin/pest", "--init"])?;
    } else if options.testing == "phpunit" && has_pest {
        notes.push("kit_uses_pest".into());
    }
    // 3. Front-end assets (Vite).
    if target.join("package.json").exists() {
        if let Some(node) = node_bin {
            runner.run(&target, &node.join("npm"), &["install", "--no-audit", "--no-fund"])?;
            runner.run(&target, &node.join("npm"), &["run", "build"])?;
            if let Some(major) = node_major(node) {
                if !target.join(".nvmrc").exists() {
                    fs::write(target.join(".nvmrc"), format!("{major}\n"))?;
                }
            }
        } else {
            notes.push("frontend_needs_node".into());
        }
    }
    // 4. Database: SQLite migrates right away. MySQL and PostgreSQL get their own database (and,
    //    on PostgreSQL, their own role) when the engine is running, then migrate; otherwise the
    //    .env is ready and the note says what's left.
    let database = database_name(&options.name);
    match options.database.as_str() {
        "sqlite" => artisan(&["migrate", "--force", "--no-interaction"])?,
        engine => {
            let engine = if engine == "pgsql" { "postgres" } else { "mysql" };
            let port = crate::engines::port(&config, engine);
            let mut values = vec![
                ("DB_CONNECTION", options.database.clone()),
                ("DB_HOST", "127.0.0.1".into()),
                ("DB_PORT", port.to_string()),
                ("DB_DATABASE", database.clone()),
            ];
            let running = std::net::TcpStream::connect_timeout(&([127, 0, 0, 1], port).into(), std::time::Duration::from_millis(500)).is_ok();
            let ready = running && match engine {
                "postgres" => match crate::engines::create_postgres_database(store, &config, &database) {
                    Ok(created) => {
                        values.push(("DB_USERNAME", created["migrationUser"].as_str().unwrap_or("").to_string()));
                        values.push(("DB_PASSWORD", created["migrationPassword"].as_str().unwrap_or("").to_string()));
                        true
                    }
                    Err(_) => false,
                },
                _ => {
                    values.push(("DB_USERNAME", "root".into()));
                    values.push(("DB_PASSWORD", String::new()));
                    crate::engines::create_mysql_database(store, &config, &database).is_ok()
                }
            };
            if !ready {
                if engine == "postgres" {
                    values.push(("DB_USERNAME", "postgres".into()));
                    values.push(("DB_PASSWORD", String::new()));
                }
                notes.push(format!("database_pending_{engine}"));
            }
            set_env(&env, &values)?;
            // The .env now may hold a password: owner-only, like the environments manager writes it.
            let _ = fs::set_permissions(&env, std::os::unix::fs::PermissionsExt::from_mode(0o600));
            if ready {
                artisan(&["migrate", "--force", "--no-interaction"])?;
            }
        }
    }
    // 5. Git.
    if options.git {
        git_init(runner, &target, notes);
    }
    // 6. Register the site (off, like every site, until the user turns it on).
    let mut project = detect::detect(&target)?.project;
    project.runtime.insert("php".into(), series);
    let service = match options.database.as_str() { "pgsql" => Some("postgres"), "mysql" => Some("mysql"), _ => None };
    if let Some(service) = service {
        if !project.services.iter().any(|s| s == service) {
            project.services.push(service.into());
        }
    }
    store.save(project)
}

/// Database name for a project: lowercase letters, digits and underscores, starting with a letter.
fn database_name(name: &str) -> String {
    let base: String = name.to_ascii_lowercase().chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '_' }).collect();
    if base.starts_with(|c: char| c.is_ascii_digit()) { format!("db_{base}") } else { base }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn validates_inputs_and_rewrites_env() {
        validate_name("mi-app_2").unwrap();
        for bad in ["", "../x", "a b", "-x", &"x".repeat(41)] {
            assert!(validate_name(bad).is_err());
        }
        assert!(package("angular").is_err());
        let temp = tempfile::tempdir().unwrap();
        let env = temp.path().join(".env");
        fs::write(&env, "DB_CONNECTION=sqlite\n# DB_HOST=127.0.0.1\nAPP_NAME=x\n").unwrap();
        set_env(&env, &[("DB_CONNECTION", "mysql".into()), ("DB_HOST", "127.0.0.1".into()), ("DB_DATABASE", "demo".into())]).unwrap();
        let text = fs::read_to_string(&env).unwrap();
        assert!(text.contains("DB_CONNECTION=mysql\nDB_HOST=127.0.0.1\nAPP_NAME=x\nDB_DATABASE=demo"));
    }
}

/// Current versions of each kind's framework and generator, for the assistant to show what it will
/// install: npm's `latest` tags and Packagist's newest stable release. Requests run in parallel.
pub fn versions() -> Result<serde_json::Value> {
    let npm = ["astro", "create-astro", "emdash", "create-emdash", "next", "create-next-app", "vite", "create-vite", "react", "vue", "svelte"];
    let packagist = ["laravel/framework", "laravel/laravel", "pestphp/pest", "livewire/livewire"];
    let handles: Vec<_> = npm
        .iter()
        .map(|name| (name.to_string(), format!("https://registry.npmjs.org/{name}/latest"), false))
        .chain(packagist.iter().map(|name| (name.to_string(), format!("https://repo.packagist.org/p2/{name}.json"), true)))
        .map(|(name, url, composer)| {
            std::thread::spawn(move || -> Option<(String, String)> {
                let body: serde_json::Value = serde_json::from_slice(&tools::fetch(&url, 8_000_000).ok()?).ok()?;
                let version = if composer {
                    body["packages"][&name].as_array()?.iter().filter_map(|v| v["version"].as_str())
                        .find(|v| !v.contains("dev") && !v.contains("RC") && !v.contains("beta") && !v.contains("alpha"))?
                        .trim_start_matches('v').to_string()
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
