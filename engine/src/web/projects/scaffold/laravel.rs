//! Laravel with its official installer: starter kit, testing, database created and migrated.

use super::*;

pub(super) fn create_laravel(
    store: &Store,
    options: &Options,
    notes: &mut Vec<String>,
) -> Result<Project> {
    let package = package(&options.kit)?;
    ensure!(
        ["pest", "phpunit"].contains(&options.testing.as_str()),
        "invalid_testing"
    );
    ensure!(
        ["sqlite", "mysql", "pgsql"].contains(&options.database.as_str()),
        "invalid_database"
    );
    let (parent, target) = target_of(options)?;

    let config = store.config()?;
    let chain = Toolchain::new(
        store,
        (!options.php.is_empty()).then_some(options.php.as_str()),
        None,
        &format!("create-{}", options.name),
    )?;
    let (php, runner, node_bin, series) = (
        &chain.php,
        &chain.runner,
        &chain.node_bin,
        chain.series.clone(),
    );
    let composer_arg = chain.composer.clone();

    // 1. Skeleton (Composer runs its post-create scripts: .env, key, SQLite file).
    // Starter kits come from their main branch, like the official installer (`--stability=dev`):
    // some have no stable tag, and the tagged ones lag behind.
    // A Laravel line ("12") picks its skeleton; starter kits follow their main branch.
    ensure!(
        options.framework_version.is_empty()
            || options
                .framework_version
                .bytes()
                .all(|c| c.is_ascii_digit())
                && options.framework_version.len() <= 3,
        "invalid_version"
    );
    let constraint = format!("^{}.0", options.framework_version);
    let mut args = vec![
        composer_arg.as_str(),
        "create-project",
        package,
        &options.name,
    ];
    if options.kit == "none" && !options.framework_version.is_empty() {
        args.push(&constraint);
    }
    args.extend(["--prefer-dist", "--no-interaction"]);
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
    set_env(
        &env,
        &[(
            "APP_URL",
            format!("http://{}.test", options.name.to_ascii_lowercase()),
        )],
    )?;
    // 2. Tests: Pest replaces PHPUnit as the runner, like the official installer. Starter kits
    //    already ship with Pest; there it stays (the installer can't turn a kit into PHPUnit).
    let composer: serde_json::Value = fs::read_to_string(target.join("composer.json"))
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default();
    let has_pest = composer["require-dev"].get("pestphp/pest").is_some();
    if options.testing == "pest" && !has_pest {
        runner.run(
            &target,
            php,
            &[
                &composer_arg,
                "remove",
                "phpunit/phpunit",
                "--dev",
                "--no-update",
            ],
        )?;
        runner.run(
            &target,
            php,
            &[
                &composer_arg,
                "require",
                "pestphp/pest",
                "pestphp/pest-plugin-laravel",
                "--dev",
                "--with-all-dependencies",
                "--no-interaction",
            ],
        )?;
        runner.run(&target, php, &["vendor/bin/pest", "--init"])?;
    } else if options.testing == "phpunit" && has_pest {
        notes.push("kit_uses_pest".into());
    }
    // 3. Front-end assets (Vite).
    if target.join("package.json").exists() {
        if let Some(node) = node_bin {
            runner.run(
                &target,
                &node.join("npm"),
                &["install", "--no-audit", "--no-fund"],
            )?;
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
            let engine = if engine == "pgsql" {
                "postgres"
            } else {
                "mysql"
            };
            let port = crate::web::services::engines::port(&config, engine);
            let mut values = vec![
                ("DB_CONNECTION", options.database.clone()),
                ("DB_HOST", "127.0.0.1".into()),
                ("DB_PORT", port.to_string()),
                ("DB_DATABASE", database.clone()),
            ];
            let running = std::net::TcpStream::connect_timeout(
                &([127, 0, 0, 1], port).into(),
                std::time::Duration::from_millis(500),
            )
            .is_ok();
            // A new project keeps the accounts it always had: owner + app role in PostgreSQL, its
            // own `<base>_app` account in MySQL. An account that already exists keeps its
            // password, which Stack does not know: the .env waits for it (a note says so).
            let created = if !running {
                None
            } else if engine == "postgres" {
                crate::web::services::databases::create_postgres(
                    store,
                    &config,
                    &database,
                    &crate::web::services::databases::Accounts::Split,
                )
                .ok()
                .map(|c| (c["migrationUser"].clone(), c["migrationPassword"].clone()))
            } else {
                crate::web::services::databases::create_mysql(
                    store,
                    &config,
                    &database,
                    &format!("{database}_app"),
                    options.mysql_password.as_deref(),
                )
                .ok()
                .map(|c| (c["user"].clone(), c["password"].clone()))
            };
            let ready = match created {
                Some((user, password)) => {
                    values.push(("DB_USERNAME", user.as_str().unwrap_or("").to_string()));
                    match password.as_str() {
                        Some(password) => {
                            values.push(("DB_PASSWORD", password.to_string()));
                            true
                        }
                        None => {
                            values.push(("DB_PASSWORD", String::new()));
                            notes.push("database_user_exists".into());
                            false
                        }
                    }
                }
                None => {
                    values.push((
                        "DB_USERNAME",
                        if engine == "postgres" {
                            "postgres"
                        } else {
                            "root"
                        }
                        .into(),
                    ));
                    values.push(("DB_PASSWORD", String::new()));
                    notes.push(format!("database_pending_{engine}"));
                    false
                }
            };
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
    let service = match options.database.as_str() {
        "pgsql" => Some("postgres"),
        "mysql" => Some("mysql"),
        _ => None,
    };
    if let Some(service) = service {
        if !project.services.iter().any(|s| s == service) {
            project.services.push(service.into());
        }
    }
    store.save(project)
}

/// Database name for a project: lowercase letters, digits and underscores, starting with a letter.
pub(super) fn database_name(name: &str) -> String {
    let base: String = name
        .to_ascii_lowercase()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '_' })
        .collect();
    if base.starts_with(|c: char| c.is_ascii_digit()) {
        format!("db_{base}")
    } else {
        base
    }
}
