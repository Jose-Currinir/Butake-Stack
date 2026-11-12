//! New Laravel projects, with the same choices as the official installer (starter kit, tests,
//! database, Git), run with the stack's own PHP, Composer and Node: nothing global is installed.
use crate::{detect, model::Project, store::Store, tools};
use anyhow::{ensure, Result};
use std::{
    fs,
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

pub struct Options {
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
        Ok(Self {
            php: php_root.join("bin/php"),
            composer: php_root.join("composer.phar").to_string_lossy().into_owned(),
            series,
            node_bin,
            runner: Runner {
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

pub fn create(store: &Store, options: &Options) -> Result<Project> {
    validate_name(&options.name)?;
    let package = package(&options.kit)?;
    ensure!(["pest", "phpunit"].contains(&options.testing.as_str()), "invalid_testing");
    ensure!(["sqlite", "mysql", "pgsql"].contains(&options.database.as_str()), "invalid_database");
    let parent = options.parent.canonicalize()?;
    ensure!(parent.is_dir(), "invalid_path");
    let target = parent.join(&options.name);
    ensure!(!target.exists(), "folder_exists");

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
    if options.git && !target.join(".git").exists() {
        runner.run(&target, Path::new("/usr/bin/git"), &["init", "-q"])?;
        runner.run(&target, Path::new("/usr/bin/git"), &["add", "-A"])?;
        let _ = runner.run(&target, Path::new("/usr/bin/git"), &["commit", "-q", "-m", "Proyecto inicial"]);
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
