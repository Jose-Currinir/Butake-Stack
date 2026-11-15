//! What the supervisor runs: each site's runtime and environment, and the process specs of the stack's services and the projects.

use super::*;

pub(super) fn real_home() -> String {
    Store::home()
        .map(|h| h.to_string_lossy().into_owned())
        .unwrap_or_else(|| "/tmp".into())
}

/// What a site's own programs run with: its PHP line, Node, JDK and virtual environment, and the
/// `PATH` that puts them first. The supervisor's processes and the Terminal's consoles share it.
pub struct SiteRuntime {
    pub php_series: String,
    pub php_bin: PathBuf,
    pub node_bin: Option<PathBuf>,
    pub java_home: Option<PathBuf>,
    pub venv: PathBuf,
    pub python_site: bool,
    pub path: Vec<String>,
}

pub fn site_runtime(
    store: &Store,
    config: &crate::core::model::StackConfig,
    project: &crate::core::model::Project,
) -> SiteRuntime {
    let php_series = project
        .runtime
        .get("php")
        .or_else(|| config.versions.get("php"))
        .cloned()
        .unwrap_or_else(|| "8.2".into());
    let php_bin = store
        .root()
        .join("runtimes/php")
        .join(&php_series)
        .join("bin");
    let node_wanted = project
        .runtime
        .get("node")
        .or_else(|| config.versions.get("node"))
        .cloned()
        .unwrap_or_default();
    // The wanted Node line, or else the newest one installed (a site never stays down for that).
    let node_bin = crate::runtimes::utilities::catalog::resolve(store, "node", &node_wanted)
        .or_else(|| crate::runtimes::utilities::catalog::resolve(store, "node", ""))
        .map(|d| d.join("bin"));
    // JDK for Kotlin projects: JAVA_HOME and its bin first on PATH.
    let java_home = (project.kind == crate::core::model::ProjectKind::Kmp
        || project.runtime.contains_key("jdk"))
    .then(|| {
        crate::runtimes::utilities::catalog::resolve(
            store,
            "jdk",
            project.runtime.get("jdk").map(String::as_str).unwrap_or(""),
        )
        .or_else(|| crate::runtimes::utilities::catalog::resolve(store, "jdk", ""))
    })
    .flatten()
    .map(|root| root.join("Contents/Home"));
    // Python sites: the project's virtual environment first (its scripts, its interpreter).
    let venv = project.path.join(".venv");
    let python_site = matches!(
        project.kind,
        crate::core::model::ProjectKind::Django | crate::core::model::ProjectKind::Fastapi
    );
    let mut path = vec![php_bin.to_string_lossy().into_owned()];
    if python_site {
        path.insert(0, venv.join("bin").to_string_lossy().into_owned());
    }
    if let Some(java) = &java_home {
        path.insert(0, java.join("bin").to_string_lossy().into_owned());
    }
    if let Some(node) = &node_bin {
        path.push(node.to_string_lossy().into_owned());
        // `pnpm` and `yarn` as commands (project scripts call them directly): corepack's own
        // links for this Node (`corepack enable --install-directory`), made once per version.
        if let Some(dir) = crate::runtimes::languages::toolchains::corepack_dir(store, node) {
            path.push(dir.to_string_lossy().into_owned());
        }
    }
    // rustup's and uv's own folders, for Rust and Python projects (and the scripts they run).
    if let Some(home) = Store::home() {
        for dir in [home.join(".cargo/bin"), home.join(".local/bin")] {
            if dir.is_dir() {
                path.push(dir.to_string_lossy().into_owned());
            }
        }
    }
    path.push("/usr/bin:/bin:/usr/sbin:/sbin".into());
    SiteRuntime {
        php_series,
        php_bin,
        node_bin,
        java_home,
        venv,
        python_site,
        path,
    }
}

/// The environment of a console opened in a site's folder (the Terminal): its versions first on
/// `PATH`, its JDK and its virtual environment, and its Google Cloud account and project. Nothing
/// of the site's `.env`.
pub fn site_shell_environment(store: &Store, id: &str) -> Result<Value> {
    let project = store.get(id)?;
    let runtime = site_runtime(store, &store.config()?, &project);
    let mut out = serde_json::Map::new();
    out.insert("PATH".into(), json!(runtime.path.join(":")));
    if let Some(java) = &runtime.java_home {
        out.insert("JAVA_HOME".into(), json!(java.to_string_lossy()));
    }
    if runtime.python_site && runtime.venv.is_dir() {
        out.insert("VIRTUAL_ENV".into(), json!(runtime.venv.to_string_lossy()));
    }
    // Its Google Cloud account and project (the project's own values win over the link's).
    for (name, value) in store.gcp_environment(&project) {
        out.insert(name, json!(value));
    }
    Ok(Value::Object(out))
}

pub fn specs(store: &Store, fds: WebFds) -> Result<Vec<ProcessSpec>> {
    let config = store.config()?;
    // Only sites the user turned on are served and run their processes.
    let projects: Vec<_> = store.list()?.into_iter().filter(|p| p.enabled).collect();
    let mut specs = vec![];
    let home = real_home();
    // Stack services first so sites have php-fpm and Caddy before their own processes.
    for series in crate::web::services::web_server::series_in_use(&projects, &config) {
        if crate::runtimes::languages::php::manifest(store, &series).is_err() {
            continue;
        }
        let (conf, ini) = crate::web::services::web_server::fpm_config(store, &series)?;
        // php-fpm reads php.ini only at start: a fingerprint of it (Xdebug on/off…) makes the
        // supervisor restart this line's php-fpm, and only it, when the file changes.
        let ini_print = fingerprint(&std::fs::read_to_string(&ini).unwrap_or_default());
        let php = store.root().join("runtimes/php").join(&series);
        specs.push(ProcessSpec {
            id: format!("stack.php-{}", series.replace('.', "-")),
            executable: php.join("bin/php-fpm"),
            args: vec![
                "-F".into(),
                "-y".into(),
                conf.to_string_lossy().into_owned(),
                "-c".into(),
                ini.to_string_lossy().into_owned(),
            ],
            cwd: store.root().into(),
            autostart: true,
            restart_on_exit: true,
            environment: [
                ("HOME".into(), home.clone()),
                ("BUTAKE_CONFIG".into(), ini_print),
            ]
            .into(),
            inherit: vec![],
            stop_timeout: 10,
            env_file: None,
            blocked: None,
        });
    }
    // Engines first (databases, cache, search, storage), in catalog order.
    for recipe in crate::web::services::engines::RECIPES {
        let Some(base) = crate::web::services::engines::engine_dir(store, &config, recipe.id)
        else {
            continue;
        };
        let launch = crate::web::services::engines::launch(store, &config, recipe.id, &base)?;
        let mut environment = launch.environment;
        environment.insert("HOME".into(), home.clone());
        specs.push(ProcessSpec {
            id: format!("stack.{}", recipe.id),
            executable: launch.executable,
            args: launch.args,
            cwd: store.root().into(),
            autostart: true,
            restart_on_exit: true,
            environment,
            inherit: vec![],
            stop_timeout: recipe.stop_timeout,
            env_file: None,
            blocked: None,
        });
    }
    if let (Some(caddy), Some(http)) = (
        crate::web::services::web_server::caddy_executable(store, &config),
        fds.http,
    ) {
        let file = store.directory("config")?.join("Caddyfile");
        let content = crate::web::services::web_server::caddyfile(
            store,
            &store.list()?,
            &config,
            fds.https_udp.is_some(),
        )?;
        write_private(&file, &content)?;
        // Caddy runs without its admin API, so it never rereads the file: a fingerprint of the
        // content in its environment makes the supervisor restart it whenever sites change.
        let fingerprint = fingerprint(&content);
        let mut inherit = vec![http];
        // Caddy only needs the HTTPS socket when a site asks for HTTPS.
        if store.list()?.iter().any(|p| p.https) {
            if let Some(https) = fds.https {
                inherit.push(https);
                // HTTP/3 (QUIC) needs the UDP side of 443 as a third descriptor.
                if let Some(quic) = fds.https_udp {
                    inherit.push(quic);
                }
            }
        }
        specs.push(ProcessSpec {
            id: "stack.caddy".into(),
            executable: caddy,
            args: vec![
                "run".into(),
                "--config".into(),
                file.to_string_lossy().into_owned(),
                "--adapter".into(),
                "caddyfile".into(),
            ],
            cwd: store.root().into(),
            autostart: true,
            restart_on_exit: true,
            environment: [
                ("HOME".into(), home.clone()),
                ("BUTAKE_CONFIG".into(), fingerprint),
            ]
            .into(),
            inherit,
            stop_timeout: 10,
            env_file: None,
            blocked: None,
        });
    }
    // Shared sites: a cloudflared quick tunnel to the site's HTTP address, with its Host header.
    let shared = SHARES.lock().map(|s| s.clone()).unwrap_or_default();
    for project in projects.iter().filter(|p| shared.contains(&p.id)) {
        let Some(domain) = project.domains.first() else {
            continue;
        };
        let executable = crate::runtimes::utilities::catalog::user_tool("cloudflared");
        specs.push(ProcessSpec {
            id: format!("share.{}", project.id),
            autostart: executable.is_some(),
            executable: executable.unwrap_or_else(|| PathBuf::from("/nonexistent")),
            args: share_arguments(config.ports.http, domain),
            cwd: store.root().into(),
            // A new run means a new public address: it never restarts on its own.
            restart_on_exit: false,
            environment: [("HOME".into(), home.clone())].into(),
            inherit: vec![],
            stop_timeout: 5,
            env_file: None,
            blocked: None,
        });
    }
    specs.extend(public::specs(store, &config, &projects, &home)?);
    // Every project, on or off, for `{port:<id>}`: a stopped backend still has its port.
    let all = store.list()?;
    let addresses = crate::web::net::tunnels::addresses(store);
    // A project without a server is never on, but its commands («Comprobar», «Compilar») are
    // there to be run by hand: each one once, never on its own nor again when it ends.
    let unserved: Vec<_> = all.iter().filter(|p| !p.kind.served()).cloned().collect();
    for project in projects.into_iter().chain(unserved) {
        let manual = !project.kind.served();
        // With Production active, nothing of the site starts on its own (queues, scheduler…).
        let held = crate::web::projects::envs::production_active(store, &project.id);
        let env_file = crate::web::projects::envs::process_env_file(store, &project);
        let SiteRuntime {
            php_series,
            php_bin,
            node_bin,
            java_home,
            venv,
            python_site,
            path,
        } = site_runtime(store, &config, &project);
        // `{port}`, `{domain}` and `{port:<id>}` in arguments and environment. A marker naming a
        // project that is gone leaves the process blocked with that reason, never the rest.
        let port = project.upstream.map(|p| p.to_string()).unwrap_or_default();
        let domain = project.domains.first().cloned().unwrap_or_default();
        let blocked = std::cell::RefCell::new(None::<String>);
        // `{public:<id>}` of a project without a fixed address is pending (`None`): the variable
        // is left out, while an argument blocks its process.
        let fill = |text: &str| -> Option<String> {
            let own = text.replace("{port}", &port).replace("{domain}", &domain);
            let filled = crate::core::model::fill_project_ports(&own, &all).and_then(|text| {
                crate::core::model::fill_public_addresses(&text, &all, &addresses)
            });
            match filled {
                Ok(text) => Some(text),
                Err(error) if error.to_string() == "project_without_public_address" => None,
                Err(error) => {
                    blocked.borrow_mut().get_or_insert(error.to_string());
                    Some(own)
                }
            }
        };
        // Its Google Cloud link (see below), read before the processes are taken.
        let gcp_environment = store.gcp_environment(&project);
        for process in project.processes {
            blocked.borrow_mut().take();
            let (executable, mut args) = match process.program.as_str() {
                "php" => (Some(php_bin.join("php")), vec![]),
                "composer" => (
                    Some(php_bin.join("php")),
                    vec![store
                        .root()
                        .join("runtimes/php")
                        .join(&php_series)
                        .join("composer.phar")
                        .to_string_lossy()
                        .into_owned()],
                ),
                "gradlew" => (Some(project.path.join("gradlew")), vec![]),
                "uv" | "cargo" => (
                    crate::runtimes::utilities::catalog::user_tool(&process.program),
                    vec![],
                ),
                // Stack makes `.venv` with the Python the site asks for; without it the site stays stopped.
                "python" => (Some(venv.join("bin/python")), vec![]),
                program if crate::core::model::SYSTEM_PROGRAMS.contains(&program) => {
                    (Some(PathBuf::from("/usr/bin").join(program)), vec![])
                }
                program => (node_bin.as_ref().map(|b| b.join(program)), vec![]),
            };
            let available = executable.as_ref().is_some_and(|e| e.exists());
            args.extend(process.args.iter().map(|a| {
                fill(a).unwrap_or_else(|| {
                    blocked
                        .borrow_mut()
                        .get_or_insert("project_without_public_address".into());
                    a.clone()
                })
            }));
            let environment = {
                // The project's `env` (with its markers), then Stack's own variables over it.
                // The active environment goes under both, read by the supervisor at each start.
                let mut environment = std::collections::BTreeMap::new();
                // Its Google Cloud link first: a variable the project sets by hand wins over it.
                environment.extend(gcp_environment.clone());
                environment.extend(
                    project
                        .env
                        .iter()
                        .filter_map(|(k, v)| fill(v).map(|v| (k.clone(), v))),
                );
                environment.insert("HOME".into(), home.clone());
                environment.insert("PATH".into(), path.join(":"));
                // corepack downloads the pinned pnpm/yarn without asking (it would wait forever).
                environment.insert("COREPACK_ENABLE_DOWNLOAD_PROMPT".into(), "0".into());
                // The binary's built-in php.ini path is the build machine's; point it at ours.
                environment.insert(
                    "PHPRC".into(),
                    store
                        .root()
                        .join("config/php")
                        .join(&php_series)
                        .to_string_lossy()
                        .into_owned(),
                );
                if let Some(java) = &java_home {
                    environment.insert("JAVA_HOME".into(), java.to_string_lossy().into_owned());
                }
                if python_site {
                    environment.insert("VIRTUAL_ENV".into(), venv.to_string_lossy().into_owned());
                    environment.insert("PYTHONUNBUFFERED".into(), "1".into());
                }
                environment
            };
            let blocked = blocked.borrow_mut().take();
            specs.push(ProcessSpec {
                id: format!("{}.{}", project.id, process.name),
                executable: executable.unwrap_or_else(|| PathBuf::from("/nonexistent")),
                args,
                cwd: project.path.clone(),
                // A missing runtime never blocks the rest of the stack; the UI shows it stopped.
                autostart: !manual && process.autostart && available && !held && blocked.is_none(),
                restart_on_exit: !manual,
                environment,
                inherit: vec![],
                stop_timeout: 10,
                env_file: env_file.clone(),
                blocked,
            });
        }
    }
    Ok(specs)
}
