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
    path: String,
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
        let mut path = vec![php_root.join("bin").to_string_lossy().into_owned()];
        if let Some(node) = &node_bin {
            path.push(node.to_string_lossy().into_owned());
        }
        path.push("/usr/bin:/bin".into());
        let log = store.directory("logs")?.join(format!("{log_name}.log"));
        let _ = fs::remove_file(&log);
        let phprc = store.root().join("config/php").join(&series).to_string_lossy().into_owned();
        Ok(Self {
            php: php_root.join("bin/php"),
            composer: php_root.join("composer.phar").to_string_lossy().into_owned(),
            series,
            node_bin,
            runner: Runner {
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
    let lines: Vec<String> = text.lines().map(str::to_string).collect();
    Ok(lines[lines.len().saturating_sub(200)..].to_vec())
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

fn git_init(runner: &Runner, target: &Path) -> Result<()> {
    if target.join(".git").exists() {
        return Ok(());
    }
    let git = Path::new("/usr/bin/git");
    runner.run(target, git, &["init", "-q"])?;
    runner.run(target, git, &["add", "-A"])?;
    let _ = runner.run(target, git, &["commit", "-q", "-m", "Proyecto inicial"]);
    Ok(())
}

pub fn create(store: &Store, options: &Options) -> Result<Project> {
    validate_name(&options.name)?;
    match options.kind.as_str() {
        "laravel" => create_laravel(store, options),
        "php" | "static" | "node" => create_basic(store, options),
        "astro" | "emdash" | "next" | "vite" => create_javascript(store, options),
        "kmp" => anyhow::bail!("kmp_use_wizard"),
        _ => anyhow::bail!("unknown_kind"),
    }
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

fn create_javascript(store: &Store, options: &Options) -> Result<Project> {
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
        git_init(&runner, &target)?;
    }
    register(store, &target)
}

/// PHP, Node (node:http, no dependencies) and static sites: a small, working starting point.
fn create_basic(store: &Store, options: &Options) -> Result<Project> {
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
            path: "/usr/bin:/bin".into(),
            home: dirs::home_dir().map(|h| h.to_string_lossy().into_owned()).unwrap_or_default(),
            phprc: String::new(),
            log: store.directory("logs")?.join(format!("create-{}.log", options.name)),
        };
        git_init(&runner, &target)?;
    }
    register(store, &target)
}

fn escape_html(text: &str) -> String {
    text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;").replace('\'', "&#39;")
}

fn create_laravel(store: &Store, options: &Options) -> Result<Project> {
    let package = package(&options.kit)?;
    ensure!(["pest", "phpunit"].contains(&options.testing.as_str()), "invalid_testing");
    ensure!(["sqlite", "mysql", "pgsql"].contains(&options.database.as_str()), "invalid_database");
    let (parent, target) = target_of(options)?;

    let config = store.config()?;
    let chain = Toolchain::new(store, None, None, &format!("create-{}", options.name))?;
    let (php, runner, node_bin, series) = (&chain.php, &chain.runner, &chain.node_bin, chain.series.clone());
    let composer_arg = chain.composer.clone();

    // 1. Skeleton (Composer runs its post-create scripts: .env, key, SQLite file).
    runner.run(&parent, php, &[&composer_arg, "create-project", package, &options.name, "--prefer-dist", "--no-interaction"])?;
    let artisan = |args: &[&str]| -> Result<()> {
        let mut all = vec!["artisan"];
        all.extend_from_slice(args);
        runner.run(&target, php, &all)
    };
    // 2. Database.
    let env = target.join(".env");
    match options.database.as_str() {
        "mysql" => set_env(&env, &[("DB_CONNECTION", "mysql".into()), ("DB_HOST", "127.0.0.1".into()), ("DB_PORT", crate::engines::port(&config, "mysql").to_string()), ("DB_DATABASE", options.name.replace('-', "_")), ("DB_USERNAME", "root".into()), ("DB_PASSWORD", String::new())])?,
        "pgsql" => set_env(&env, &[("DB_CONNECTION", "pgsql".into()), ("DB_HOST", "127.0.0.1".into()), ("DB_PORT", crate::engines::port(&config, "postgres").to_string()), ("DB_DATABASE", options.name.replace('-', "_")), ("DB_USERNAME", "postgres".into()), ("DB_PASSWORD", String::new())])?,
        _ => {}
    }
    set_env(&env, &[("APP_URL", format!("http://{}.test", options.name.to_ascii_lowercase()))])?;
    // 3. Tests: Pest replaces PHPUnit as the runner, like the official installer.
    if options.testing == "pest" {
        runner.run(&target, php, &[&composer_arg, "remove", "phpunit/phpunit", "--dev", "--no-update"])?;
        runner.run(&target, php, &[&composer_arg, "require", "pestphp/pest", "pestphp/pest-plugin-laravel", "--dev", "--with-all-dependencies", "--no-interaction"])?;
        runner.run(&target, php, &["vendor/bin/pest", "--init"])?;
    }
    // 4. Front-end assets for starter kits (Vite).
    if target.join("package.json").exists() {
        if let Some(node) = node_bin {
            runner.run(&target, &node.join("npm"), &["install", "--no-audit", "--no-fund"])?;
            runner.run(&target, &node.join("npm"), &["run", "build"])?;
        }
    }
    // 5. SQLite migrates right away; server databases migrate once their engine is on.
    if options.database == "sqlite" {
        let _ = artisan(&["migrate", "--force", "--no-interaction"]);
    }
    // 6. Git.
    if options.git {
        git_init(runner, &target)?;
    }
    // 7. Register the site (off, like every site, until the user turns it on).
    let mut project = detect::detect(&target)?.project;
    project.runtime.insert("php".into(), series);
    if project.services.is_empty() || options.database != "sqlite" {
        let service = if options.database == "pgsql" { "postgres" } else { "mysql" };
        if options.database != "sqlite" && !project.services.contains(&service.to_string()) {
            project.services.push(service.into());
        }
    }
    store.save(project)
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
