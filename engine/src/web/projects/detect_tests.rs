use super::*;
#[test]
fn detects_laravel_without_leaking_secrets() {
    let temp = tempfile::tempdir().unwrap();
    let app = temp.path().join("Mi App");
    fs::create_dir_all(app.join("public")).unwrap();
    fs::create_dir_all(app.join("config/supervisor")).unwrap();
    fs::write(app.join("artisan"), "").unwrap();
    fs::write(
        app.join("composer.json"),
        r#"{"require":{"php":"^8.2","laravel/framework":"^12.0","laravel/reverb":"^1.0"}}"#,
    )
    .unwrap();
    fs::write(app.join("package.json"), r#"{"scripts":{"dev":"vite"}}"#).unwrap();
    fs::write(app.join(".env"), "APP_URL=http://mi-app.test\nDB_CONNECTION=mysql\nDB_PASSWORD=supersecreto123\nREDIS_PASSWORD=otrosecreto456\nAPP_KEY=base64:clavesecreta789\nQUEUE_CONNECTION=redis\nREVERB_SERVER_PORT=8082\nREVERB_APP_SECRET=reverbsecreto\n").unwrap();
    fs::write(app.join("config/supervisor/app-queue.conf"), "[program:q]\ncommand=@PHP_BIN@ artisan queue:work redis --queue=realtime,default --tries=3\n").unwrap();
    fs::write(
        app.join("config/supervisor/app-exports.conf"),
        "[program:e]\ncommand=/usr/bin/php /var/www/artisan queue:work redis-exports --tries=1\n",
    )
    .unwrap();
    let d = detect(&app).unwrap();
    let json = serde_json::to_string(&d).unwrap();
    for secret in [
        "supersecreto123",
        "otrosecreto456",
        "clavesecreta789",
        "reverbsecreto",
    ] {
        assert!(!json.contains(secret), "{secret}");
    }
    assert!(d.env_keys.contains(&"DB_PASSWORD".to_string()));
    let p = &d.project;
    assert_eq!(p.id, "mi-app");
    assert_eq!(p.kind, ProjectKind::Laravel);
    assert_eq!(p.docroot, PathBuf::from("public"));
    assert_eq!(p.runtime.get("php").unwrap(), "8.2");
    assert!(p.services.is_empty());
    let on: Vec<_> = p
        .processes
        .iter()
        .filter(|x| x.autostart)
        .map(|x| x.name.as_str())
        .collect();
    assert_eq!(on, vec!["reverb", "vite"]);
    assert!(
        p.processes
            .iter()
            .any(|x| x.name == "app-queue" && !x.autostart)
    );
    assert!(
        p.processes
            .iter()
            .any(|x| x.name == "scheduler" && !x.autostart)
    );
    assert!(
        p.processes
            .iter()
            .any(|x| x.name == "app-exports" && !x.autostart && x.args[0] == "artisan")
    );
    assert!(
        p.processes
            .iter()
            .find(|x| x.name == "reverb")
            .unwrap()
            .args
            .contains(&"--port=8082".to_string())
    );
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
        for (file, text) in files {
            fs::write(dir.join(file), text).unwrap();
        }
        detect(&dir).unwrap().project
    };
    let astro = make(
        "web",
        &[(
            "package.json",
            r#"{"scripts":{"dev":"astro dev"},"dependencies":{"astro":"7.4.1"}}"#,
        )],
    );
    assert_eq!(astro.kind, ProjectKind::Astro);
    assert_eq!(
        astro.processes[0].args,
        [
            "run",
            "dev",
            "--",
            "--host",
            "127.0.0.1",
            "--port",
            "{port}"
        ]
    );
    let emdash = make(
        "cms",
        &[(
            "package.json",
            r#"{"packageManager":"pnpm@10.34.9","scripts":{"dev":"node x","dev:setup":"y","dev:reset":"z"},"dependencies":{"emdash":"1.3.1","astro":"7"}}"#,
        )],
    );
    assert_eq!(emdash.kind, ProjectKind::Emdash);
    assert_eq!(
        (emdash.processes[0].program.as_str(), emdash.processes.len()),
        ("corepack", 3)
    );
    assert_eq!(
        emdash.env.get("PUBLIC_SITE_URL").unwrap(),
        "https://{domain}"
    );
    let kmp = make(
        "app",
        &[
            (
                "settings.gradle.kts",
                r#"include(":core")
include(":server")"#,
            ),
            ("gradlew", "#!/bin/sh"),
        ],
    );
    assert_eq!(kmp.kind, ProjectKind::Kmp);
    assert_eq!(
        (
            kmp.processes[0].program.as_str(),
            kmp.processes[0].args[0].as_str()
        ),
        ("gradlew", ":server:run")
    );
    assert_eq!(kmp.runtime.get("jdk").unwrap(), "21");
    let next = make(
        "next",
        &[("package.json", r#"{"dependencies":{"next":"15"}}"#)],
    );
    assert_eq!(next.kind, ProjectKind::Next);
}

#[test]
fn node_projects_get_a_server_process_and_port() {
    let temp = tempfile::tempdir().unwrap();
    let vite = temp.path().join("spa");
    fs::create_dir_all(&vite).unwrap();
    fs::write(
        vite.join("package.json"),
        r#"{"scripts":{"dev":"vite","build":"vite build"}}"#,
    )
    .unwrap();
    let d = detect(&vite).unwrap();
    assert_eq!(d.project.kind, ProjectKind::Node);
    let p = &d.project.processes[0];
    assert_eq!((p.name.as_str(), p.program.as_str()), ("dev", "npm"));
    assert!(p.args.ends_with(&[
        "--".into(),
        "--host".into(),
        "127.0.0.1".into(),
        "--port".into(),
        "{port}".into(),
        "--strictPort".into()
    ]));
    let api = temp.path().join("api");
    fs::create_dir_all(&api).unwrap();
    fs::write(
        api.join("package.json"),
        r#"{"scripts":{"start":"node server.js"}}"#,
    )
    .unwrap();
    let d = detect(&api).unwrap();
    assert_eq!(
        d.project.processes[0].args,
        vec!["run".to_string(), "start".into()]
    );
    assert_eq!(
        d.project.env.get("PORT").map(String::as_str),
        Some("{port}")
    );
    let bare = temp.path().join("bare");
    fs::create_dir_all(&bare).unwrap();
    fs::write(bare.join("package.json"), "{}").unwrap();
    assert!(
        detect(&bare)
            .unwrap()
            .notes
            .contains(&"node_no_script".to_string())
    );
}

#[test]
fn scans_a_folder_of_projects_with_organizing_subfolders() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("Proyectos");
    for (dir, file) in [
        ("blog", "index.html"),
        ("Apps/api", "package.json"),
        ("Apps/web", "composer.json"),
        ("Apps/node_modules/x", "package.json"),
        (".oculto/x", "index.html"),
        ("vacia", ""),
    ] {
        fs::create_dir_all(root.join(dir)).unwrap();
        if !file.is_empty() {
            fs::write(root.join(dir).join(file), "{}").unwrap();
        }
    }
    let result = scan(&root).unwrap();
    let found: Vec<(String, String)> = result["projects"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| {
            (
                p["group"].as_str().unwrap().to_string(),
                p["detection"]["project"]["id"]
                    .as_str()
                    .unwrap()
                    .to_string(),
            )
        })
        .collect();
    assert_eq!(
        found,
        vec![
            ("Apps".into(), "api".into()),
            ("Apps".into(), "web".into()),
            ("".into(), "blog".into())
        ]
    );
    assert_eq!(result["rootIsProject"], false);
}

#[test]
fn detects_python_and_rust_servers_and_other_technologies() {
    let temp = tempfile::tempdir().unwrap();
    let make = |dir: &str, files: &[(&str, &str)]| {
        let root = temp.path().join(dir);
        for (file, body) in files {
            let path = root.join(file);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, body).unwrap();
        }
        root
    };
    let django = make(
        "tienda",
        &[
            ("manage.py", ""),
            ("requirements.txt", "Django==5.2\n"),
            (".python-version", "3.12\n"),
        ],
    );
    let d = detect(&django).unwrap().project;
    assert_eq!(d.kind, ProjectKind::Django);
    assert_eq!(d.processes[0].program, "python");
    assert_eq!(
        d.processes[0].args.join(" "),
        "manage.py runserver 127.0.0.1:{port}"
    );
    assert_eq!(d.runtime.get("python").map(String::as_str), Some("3.12"));
    let api = make(
        "api",
        &[
            (
                "pyproject.toml",
                "[project]\ndependencies = [\"fastapi>=0.115\"]\n",
            ),
            ("app/main.py", "app = FastAPI()\n"),
        ],
    );
    let a = detect(&api).unwrap().project;
    assert_eq!(a.kind, ProjectKind::Fastapi);
    assert!(
        a.processes[0]
            .args
            .join(" ")
            .contains("uvicorn app.main:app --host 127.0.0.1 --port {port}")
    );
    let server = make(
        "servidor",
        &[(
            "Cargo.toml",
            "[package]\nname = \"s\"\n\n[dependencies]\naxum = \"0.8\"\n",
        )],
    );
    assert_eq!(detect(&server).unwrap().project.kind, ProjectKind::Rust);
    let cli = make(
        "cli",
        &[(
            "Cargo.toml",
            "[package]\nname = \"c\"\n\n[dependencies]\nclap = \"4\"\n",
        )],
    );
    assert_eq!(detect(&cli).unwrap().project.kind, ProjectKind::Unserved);
    assert_eq!(technology(&cli), Some("rust"));
    let mobile = make(
        "movil",
        &[(
            "package.json",
            "{\"dependencies\":{\"react-native\":\"0.80\"}}",
        )],
    );
    assert_eq!(detect(&mobile).unwrap().project.kind, ProjectKind::Unserved);
    assert_eq!(technology(&mobile), Some("react-native"));
    let swift = make("app", &[("Package.swift", "// swift-tools-version:6.0")]);
    assert_eq!(technology(&swift), Some("swift"));
}

/// A repository with nothing to serve (no `public/`, no `index.*`, no server Stack knows) is
/// proposed without a server: no domain, nothing that starts, its checks as commands. A
/// folder with a page stays a static site, and `public/` is what gets served.
#[test]
fn a_repository_without_a_server_is_proposed_as_such() {
    let temp = tempfile::tempdir().unwrap();
    let make = |dir: &str, files: &[&str]| {
        let root = temp.path().join(dir);
        for file in files {
            let path = root.join(file);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, "").unwrap();
        }
        fs::create_dir_all(root.join(".git")).unwrap();
        root
    };
    let library = detect(&make("biblioteca", &["Package.swift", "Sources/a.swift"]))
        .unwrap()
        .project;
    assert_eq!(library.kind, ProjectKind::Unserved);
    assert!(library.domains.is_empty() && !library.https && !library.enabled);
    let commands: Vec<(String, String, bool)> = library
        .processes
        .iter()
        .map(|p| {
            (
                p.name.clone(),
                format!("{} {}", p.program, p.args.join(" ")),
                p.autostart,
            )
        })
        .collect();
    assert_eq!(
        commands,
        [
            ("check".into(), "swift test".into(), false),
            ("build".into(), "swift build".into(), false)
        ]
    );
    let android = detect(&make("app-movil", &["gradlew", "settings.gradle.kts"]))
        .unwrap()
        .project;
    assert_eq!(android.kind, ProjectKind::Unserved);
    assert_eq!(android.processes[0].program, "gradlew");
    assert_eq!(android.runtime.get("jdk").map(String::as_str), Some("21"));
    let page = detect(&make("pagina", &["index.html"])).unwrap().project;
    assert_eq!(
        (page.kind.clone(), page.docroot.clone()),
        (ProjectKind::Static, PathBuf::from("."))
    );
    let public = detect(&make("sitio", &["public/logo.svg", "README.md"]))
        .unwrap()
        .project;
    assert_eq!(
        (public.kind.clone(), public.docroot.clone()),
        (ProjectKind::Static, PathBuf::from("public"))
    );
    assert!(!serves_repository(&public));
    assert!(serves_repository(&page));
    let empty = detect(&make("notas", &["README.md"])).unwrap().project;
    assert_eq!(empty.kind, ProjectKind::Unserved);
    assert!(empty.processes.is_empty());
    // Scanning a folder: a project without a server is not offered as a site.
    let found = scan(temp.path()).unwrap();
    let web: Vec<(String, bool)> = found["projects"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| {
            (
                p["detection"]["project"]["id"]
                    .as_str()
                    .unwrap()
                    .to_string(),
                p["web"].as_bool().unwrap(),
            )
        })
        .collect();
    assert!(web.contains(&("biblioteca".into(), false)));
    assert!(web.contains(&("pagina".into(), true)));
}
