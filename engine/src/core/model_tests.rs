use super::*;

#[test]
fn project_port_markers() {
    let project = |id: &str, upstream: Option<u16>| -> Project {
        serde_json::from_value(serde_json::json!({
                "id": id, "name": id, "path": "/tmp", "domains": [format!("{id}.test")],
                "https": false, "kind": "kmp", "runtime": {}, "docroot": ".", "services": [],
                "databases": [], "processes": [], "upstream": upstream}))
        .unwrap()
    };
    let all = [project("api", Some(18100)), project("web", None)];
    assert_eq!(
        port_references("a {port:api} b {port:web} {port}"),
        ["api", "web"]
    );
    assert_eq!(
        fill_project_ports("http://127.0.0.1:{port:api}/{port}", &all).unwrap(),
        "http://127.0.0.1:18100/{port}"
    );
    for (text, code) in [
        ("{port:otro}", "unknown_port_project"),
        ("{port:../x}", "unknown_port_project"),
        ("{port:web}", "project_without_port"),
    ] {
        assert_eq!(
            fill_project_ports(text, &all).unwrap_err().to_string(),
            code
        );
    }
    assert_eq!(
        fill_project_ports("sin marcas", &all).unwrap(),
        "sin marcas"
    );
}

#[test]
fn project_public_markers() {
    let project = |id: &str| -> Project {
        serde_json::from_value(serde_json::json!({
                "id": id, "name": id, "path": "/tmp", "domains": [format!("{id}.test")],
                "https": false, "kind": "kmp", "runtime": {}, "docroot": ".", "services": [],
                "databases": [], "processes": []}))
        .unwrap()
    };
    let all = [project("salud"), project("web")];
    let addresses: BTreeMap<String, String> =
        [("salud".to_string(), "salud-test.example.com".to_string())].into();
    assert_eq!(
        public_references("{public:salud}/x {port:web} {public:web}"),
        ["salud", "web"]
    );
    assert_eq!(
        project_references("{port:web} {public:salud}"),
        ["web", "salud"]
    );
    assert_eq!(
        fill_public_addresses("{public:salud}/auth/callback", &all, &addresses).unwrap(),
        "https://salud-test.example.com/auth/callback"
    );
    for (text, code) in [
        ("{public:nadie}", "unknown_public_project"),
        ("{public:../x}", "unknown_public_project"),
        ("{public:web}", "project_without_public_address"),
    ] {
        assert_eq!(
            fill_public_addresses(text, &all, &addresses)
                .unwrap_err()
                .to_string(),
            code
        );
    }
}
pub fn project(path: &std::path::Path) -> Project {
    Project {
        id: "demo".into(),
        name: "Demostración".into(),
        path: path.into(),
        domains: vec!["demo.test".into()],
        https: true,
        kind: ProjectKind::Laravel,
        runtime: [("php".into(), "8.2".into())].into(),
        docroot: ".".into(),
        services: vec!["mysql".into()],
        databases: vec!["demo_db".into()],
        processes: vec![ProjectProcess {
            name: "queue".into(),
            program: "php".into(),
            args: vec!["artisan".into()],
            autostart: false,
        }],
        enabled: false,
        upstream: None,
        env: BTreeMap::new(),
        gcp: None,
    }
}

/// Validating never touches `env` for the link: a variable written by hand stays with or
/// without a link, and wins over the link's; the record keeps only `gcp`.
#[test]
fn google_cloud_link_never_rewrites_env() {
    let folder = tempfile::tempdir().unwrap();
    let config = StackConfig::default();
    let mut demo = project(folder.path());
    demo.env.insert("APP_ENV".into(), "local".into());
    demo.env
        .insert("GOOGLE_CLOUD_PROJECT".into(), "escrito-a-mano".into());
    let written = demo.env.clone();
    demo.validate(&config).unwrap();
    assert_eq!(demo.env, written);
    assert_eq!(
        demo.gcp_environment_with(None),
        BTreeMap::from([("GOOGLE_CLOUD_PROJECT".into(), "escrito-a-mano".into())])
    );
    demo.gcp = Some(GcpLink {
        account: "qa@ejemplo.test".into(),
        project: "tienda-ficticia".into(),
    });
    demo.validate(&config).unwrap();
    assert_eq!(demo.env, written);
    let linked = demo.gcp_environment_with(None);
    assert_eq!(linked["CLOUDSDK_CORE_ACCOUNT"], "qa@ejemplo.test");
    assert_eq!(linked["CLOUDSDK_CORE_PROJECT"], "tienda-ficticia");
    assert_eq!(linked["GOOGLE_CLOUD_PROJECT"], "escrito-a-mano");
    let saved = serde_json::to_value(&demo).unwrap();
    assert_eq!(
        saved["gcp"],
        serde_json::json!({"account": "qa@ejemplo.test", "project": "tienda-ficticia"})
    );
    assert_eq!(
        saved["env"],
        serde_json::json!({"APP_ENV": "local", "GOOGLE_CLOUD_PROJECT": "escrito-a-mano"})
    );
    demo.gcp = None;
    assert!(serde_json::to_value(&demo).unwrap().get("gcp").is_none());
    for (account, project, code) in [
        ("-x@ejemplo.test", "tienda-ficticia", "gcp_invalid_account"),
        ("qa@ejemplo.test", "--quiet", "gcp_invalid_project"),
    ] {
        demo.gcp = Some(GcpLink {
            account: account.into(),
            project: project.into(),
        });
        assert_eq!(demo.validate(&config).unwrap_err().to_string(), code);
    }
}

#[test]
fn validates_ids_domains_and_ports() {
    for id in ["demo", "a-1", "-"] {
        assert!(validate_id(id).is_ok());
    }
    for id in ["", "../x", "A", "a/b", &"x".repeat(41)] {
        assert!(validate_id(id).is_err());
    }
    let mut config = StackConfig::default();
    assert!(config.validate().is_ok());
    for domain in ["demo.test", "sub.demo.test"] {
        assert!(config.validate_domain(domain).is_ok());
    }
    for domain in [
        "demo.com",
        "test",
        "-a.test",
        "a..test",
        "x.test;id",
        "X.test",
        "a.test/",
        "a.local",
    ] {
        assert!(config.validate_domain(domain).is_err());
    }
    config.ports.http = 0;
    assert!(config.validate().is_err());
    config.ports.http = 443;
    assert!(config.validate().is_err());
    config.ports.http = 65535;
    assert!(config.validate().is_ok());
}
#[test]
fn validates_paths_programs_and_docroot_escape() {
    let temp = tempfile::tempdir().unwrap();
    let mut p = project(temp.path());
    p.path = temp.path().join(".");
    p.validate(&StackConfig::default()).unwrap();
    assert_eq!(p.path, temp.path().canonicalize().unwrap());
    p.processes[0].program = "sh".into();
    assert!(p.validate(&StackConfig::default()).is_err());
    p.processes[0].program = "php".into();
    p.docroot = "..".into();
    assert!(p.validate(&StackConfig::default()).is_err());
    let outside = tempfile::tempdir().unwrap();
    std::os::unix::fs::symlink(outside.path(), temp.path().join("escape")).unwrap();
    p.docroot = "escape".into();
    assert!(p.validate(&StackConfig::default()).is_err());
    p.path = temp.path().join("missing");
    assert!(p.validate(&StackConfig::default()).is_err());
}
