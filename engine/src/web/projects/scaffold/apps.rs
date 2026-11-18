//! Python, Rust, Swift and React Native projects with their own tools.

use super::*;

/// Django or FastAPI with the Python chosen (Stack's own CPython): `.venv` made with venv and pip,
/// or with uv when chosen (then a uv project: pyproject and lock). `.python-version` keeps the line.
pub(super) fn create_python(
    store: &Store,
    options: &Options,
    notes: &mut Vec<String>,
) -> Result<Project> {
    let (parent, target) = target_of(options)?;
    let python = crate::runtimes::languages::python::resolve(store, &options.python)
        .ok_or_else(|| anyhow::anyhow!("python_not_installed"))?;
    let line = python
        .parent()
        .and_then(Path::parent)
        .and_then(Path::file_name)
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let mut runner = user_runner(store, options, None)?;
    let venv_bin = target.join(".venv/bin");
    runner.path = format!(
        "{}:{}:{}",
        venv_bin.display(),
        python.parent().unwrap().display(),
        runner.path
    );
    let package = crate::runtimes::languages::python::framework_spec(
        if options.kind == "django" {
            "django"
        } else {
            "fastapi[standard]"
        },
        &options.framework_version,
    )?;
    let package = package.as_str();
    if options.manager == "uv" {
        let uv = catalog::user_tool("uv").ok_or_else(|| anyhow::anyhow!("uv_not_installed"))?;
        let python_arg = python.to_string_lossy().into_owned();
        // uv uses this interpreter and never downloads one of its own.
        runner.extra = vec![
            ("UV_PYTHON".into(), python_arg.clone()),
            ("UV_PYTHON_DOWNLOADS".into(), "never".into()),
        ];
        runner.run(
            &parent,
            &uv,
            &[
                "init",
                options.name.as_str(),
                "--app",
                "--vcs",
                "none",
                "--no-workspace",
                "--python",
                &python_arg,
            ],
        )?;
        let _ = fs::remove_file(target.join("main.py"));
        runner.run(&target, &uv, &["add", package])?;
    } else {
        fs::create_dir_all(&target)?;
        runner.run(&target, &python, &["-m", "venv", ".venv"])?;
        fs::write(target.join("requirements.txt"), format!("{package}\n"))?;
        runner.run(
            &target,
            &venv_bin.join("python"),
            &[
                "-m",
                "pip",
                "install",
                "--disable-pip-version-check",
                "-r",
                "requirements.txt",
            ],
        )?;
        // Pin what was installed, so the project installs the same versions elsewhere.
        let freeze = Command::new(venv_bin.join("python"))
            .args(["-m", "pip", "freeze", "--disable-pip-version-check"])
            .current_dir(&target)
            .env_clear()
            .output()?;
        if freeze.status.success() && !freeze.stdout.is_empty() {
            fs::write(target.join("requirements.txt"), &freeze.stdout)?;
        }
    }
    fs::write(target.join(".python-version"), format!("{line}\n"))?;
    let python_bin = venv_bin.join("python");
    if options.kind == "django" {
        runner.run(
            &target,
            &venv_bin.join("django-admin"),
            &["startproject", "config", "."],
        )?;
        runner.run(&target, &python_bin, &["manage.py", "migrate", "--noinput"])?;
    } else {
        let title = options.name.replace('"', "");
        fs::write(
            target.join("main.py"),
            format!(
                "from fastapi import FastAPI\n\napp = FastAPI(title=\"{title}\")\n\n\n@app.get(\"/\")\ndef inicio():\n    return {{\"mensaje\": \"Hola desde FastAPI y Stack\"}}\n\n\n@app.get(\"/salud\")\ndef salud():\n    return {{\"estado\": \"ok\"}}\n"
            ),
        )?;
    }
    if !target.join(".gitignore").exists() {
        fs::write(
            target.join(".gitignore"),
            ".venv/\n__pycache__/\n*.pyc\ndb.sqlite3\n.env\n",
        )?;
    }
    if options.git {
        git_init(&runner, &target, notes);
    }
    let mut project = register(store, &target)?;
    project.runtime.insert("python".into(), line);
    store.save(project)
}

/// Rust with cargo: a web server (axum, reading PORT and HOST from Stack) or a command-line tool.
pub(super) fn create_rust(
    store: &Store,
    options: &Options,
    notes: &mut Vec<String>,
) -> Result<Option<Project>> {
    let (parent, target) = target_of(options)?;
    let cargo =
        catalog::user_tool("cargo").ok_or_else(|| anyhow::anyhow!("cargo_not_installed"))?;
    let runner = user_runner(store, options, None)?;
    let web = options.template != "cli";
    runner.run(
        &parent,
        &cargo,
        &["new", options.name.as_str(), "--vcs", "none"],
    )?;
    if web {
        runner.run(
            &target,
            &cargo,
            &["add", "axum", "tokio", "--features", "tokio/full"],
        )?;
        fs::write(
            target.join("src/main.rs"),
            "use axum::{routing::get, Router};\n\n#[tokio::main]\nasync fn main() {\n    // Stack assigns PORT and HOST; the .test address points here.\n    let port = std::env::var(\"PORT\").unwrap_or_else(|_| \"3000\".into());\n    let host = std::env::var(\"HOST\").unwrap_or_else(|_| \"127.0.0.1\".into());\n    let app = Router::new()\n        .route(\"/\", get(|| async { \"Hola desde Rust y Stack\" }))\n        .route(\"/salud\", get(|| async { \"ok\" }));\n    let listener = tokio::net::TcpListener::bind(format!(\"{host}:{port}\")).await.unwrap();\n    println!(\"http://{host}:{port}\");\n    axum::serve(listener, app).await.unwrap();\n}\n",
        )?;
        // Compiled once now, so the first start of the site is quick.
        runner.run(&target, &cargo, &["build"])?;
    }
    if !target.join(".gitignore").exists() {
        fs::write(target.join(".gitignore"), "/target\n")?;
    }
    if options.git {
        git_init(&runner, &target, notes);
    }
    if web {
        register(store, &target).map(Some)
    } else {
        Ok(None)
    }
}

/// A Swift package (SwiftPM): executable, library or command-line tool. Apps with a window are
/// created in Xcode; the note says so.
pub(super) fn create_swift(
    store: &Store,
    options: &Options,
    notes: &mut Vec<String>,
) -> Result<Project> {
    let (_, target) = target_of(options)?;
    let kind = match options.template.as_str() {
        "library" => "library",
        "tool" => "tool",
        _ => "executable",
    };
    let runner = user_runner(store, options, None)?;
    fs::create_dir_all(&target)?;
    let name = pascal(&options.name);
    ensure!(!name.is_empty(), "invalid_name");
    runner.run(
        &target,
        Path::new("/usr/bin/swift"),
        &["package", "init", "--type", kind, "--name", &name],
    )?;
    if options.git {
        git_init(&runner, &target, notes);
    }
    notes.push("swift_xcode_apps".into());
    register_unserved(store, &target)
}

/// React Native: Expo (the framework React Native recommends) or the bare React Native CLI.
pub(super) fn create_react_native(
    store: &Store,
    options: &Options,
    notes: &mut Vec<String>,
) -> Result<Project> {
    let (parent, target) = target_of(options)?;
    let node = catalog::resolve(store, "node", "")
        .map(|d| d.join("bin"))
        .ok_or_else(|| anyhow::anyhow!("node_not_installed"))?;
    let runner = user_runner(store, options, Some(&node))?;
    let npx = node.join("npx");
    if options.template == "cli" {
        let name = pascal(&options.name);
        ensure!(!name.is_empty(), "invalid_name");
        runner.run(
            &parent,
            &npx,
            &[
                "--yes",
                "@react-native-community/cli@latest",
                "init",
                &name,
                "--directory",
                &options.name,
                "--skip-git-init",
                "--install-pods",
                "false",
                "--pm",
                "npm",
            ],
        )?;
        notes.push("rn_pods".into());
    } else {
        let template = match options.template.as_str() {
            "blank" => "blank-typescript",
            "tabs" => "tabs",
            _ => "default",
        };
        runner.run(
            &parent,
            &npx,
            &[
                "--yes",
                "create-expo-app@latest",
                &options.name,
                "--template",
                template,
                "--yes",
            ],
        )?;
    }
    if !target.join(".nvmrc").exists()
        && let Some(major) = node_major(&node)
    {
        fs::write(target.join(".nvmrc"), format!("{major}\n"))?;
    }
    if options.git {
        git_init(&runner, &target, notes);
    }
    register_unserved(store, &target)
}
