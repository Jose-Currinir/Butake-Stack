use super::*;
#[test]
fn finds_the_tunnel_address() {
    let lines = vec![
            "INF Requesting new quick Tunnel on trycloudflare.com...".to_string(),
            "INF |  https://brave-lion-tests-01.trycloudflare.com                                          |".to_string(),
            "ERR failed https://api.trycloudflare.com/tunnel".to_string(),
        ];
    assert_eq!(
        tunnel_url(&lines).as_deref(),
        Some("https://brave-lion-tests-01.trycloudflare.com")
    );
    assert!(tunnel_url(&["https://evil.example.com".to_string()]).is_none());
    assert_eq!(
        share_arguments(80, "demo.test"),
        [
            "tunnel",
            "--no-autoupdate",
            "--url",
            "http://127.0.0.1:80",
            "--http-host-header",
            "demo.test"
        ]
    );
}

/// A project without a server is never served, but its commands are there to be run by hand:
/// never on their own, never again when they end, the Mac's tools from `/usr/bin`.
#[test]
fn commands_of_a_project_without_a_server_run_only_by_hand() {
    let temp = tempfile::tempdir().unwrap();
    let store = Store::new(temp.path().join("store")).unwrap();
    let lib: crate::core::model::Project = serde_json::from_value(json!({
            "id": "lib", "name": "Lib", "path": temp.path(), "domains": [], "https": false,
            "kind": "unserved", "runtime": {}, "docroot": ".", "services": [], "databases": [],
            "processes": [{"name": "check", "program": "swift", "args": ["test"], "autostart": true}]}))
        .unwrap();
    store.save(lib).unwrap();
    let all = specs(
        &store,
        WebFds {
            http: None,
            https: None,
            https_udp: None,
        },
    )
    .unwrap();
    let check = all.iter().find(|s| s.id == "lib.check").unwrap();
    assert!(!check.autostart && !check.restart_on_exit);
    assert_eq!(check.executable, PathBuf::from("/usr/bin/swift"));
    let caddyfile = crate::web::services::web_server::caddyfile(
        &store,
        &store.list().unwrap(),
        &store.config().unwrap(),
        false,
    )
    .unwrap();
    assert!(!caddyfile.contains("root *") && !caddyfile.contains("reverse_proxy"));
}

/// `{port:<id>}` is filled at launch with the other project's port; when that project is gone,
/// the process is blocked with the reason and the rest of the stack still loads.
#[test]
fn project_ports_are_filled_and_a_missing_one_blocks_only_its_process() {
    let temp = tempfile::tempdir().unwrap();
    let store = Store::new(temp.path().join("store")).unwrap();
    let folder = |name: &str| {
        let path = temp.path().join(name);
        std::fs::create_dir_all(&path).unwrap();
        path
    };
    let project = |id: &str, path: PathBuf, env: Value| -> crate::core::model::Project {
        serde_json::from_value(json!({
                "id": id, "name": id, "path": path, "domains": [format!("{id}.test")],
                "https": false, "kind": "kmp", "runtime": {}, "docroot": ".", "services": [],
                "databases": [], "enabled": true, "env": env,
                "processes": [{"name": "dev", "program": "npm", "args": ["run", "{port:api}"], "autostart": true}]}))
            .unwrap()
    };
    let api = store
        .save(project("api", folder("api"), json!({})))
        .unwrap();
    let port = api.upstream.unwrap().to_string();
    store
        .save(project(
            "web",
            folder("web"),
            json!({"API_URL": "http://127.0.0.1:{port:api}"}),
        ))
        .unwrap();
    let fds = || WebFds {
        http: None,
        https: None,
        https_udp: None,
    };
    let web = |specs: Vec<ProcessSpec>| specs.into_iter().find(|s| s.id == "web.dev").unwrap();
    let spec = web(specs(&store, fds()).unwrap());
    assert_eq!(
        spec.environment["API_URL"],
        format!("http://127.0.0.1:{port}")
    );
    assert_eq!(spec.args, ["run", port.as_str()]);
    assert!(spec.blocked.is_none());
    store.delete("api").unwrap();
    let all = specs(&store, fds()).unwrap();
    let spec = web(all);
    assert_eq!(spec.blocked.as_deref(), Some("unknown_port_project"));
    assert!(!spec.autostart);
}

/// `{public:<id>}` in a process's environment: filled with the fixed address, or left out while
/// there is none. The fixed address is only run while shared, with its configuration written
/// for that run; sharing is forgotten when the site is turned off.
#[test]
fn public_addresses_reach_processes_and_run_only_while_shared() {
    let temp = tempfile::tempdir().unwrap();
    let store = Store::new(temp.path().join("store")).unwrap();
    let folder = temp.path().join("pub");
    std::fs::create_dir_all(&folder).unwrap();
    store
        .save(
            serde_json::from_value(json!({
                "id": "pub", "name": "pub", "path": folder, "domains": ["pub.test"],
                "https": false, "kind": "kmp", "runtime": {}, "docroot": ".", "services": [],
                "databases": [], "enabled": true,
                "env": {"APP_URL": "{public:pub}", "OTRA": "x"},
                "processes": [{"name": "dev", "program": "npm", "args": [], "autostart": true}]}))
            .unwrap(),
        )
        .unwrap();
    let fds = WebFds::default();
    let dev = |all: &[ProcessSpec]| all.iter().find(|s| s.id == "pub.dev").unwrap().clone();
    let all = specs(&store, fds).unwrap();
    assert!(!dev(&all).environment.contains_key("APP_URL"));
    assert_eq!(dev(&all).environment["OTRA"], "x");
    crate::core::json::write(
        &store.directory("tunnels").unwrap().join("addresses.json"),
        &json!({"addresses": {"pub": {"hostname": "pub-test.example.com",
                "tunnel": "6f1c2a4e-0b7d-4c55-9a0e-3b2f1d9c8e71", "zone": "example.com"}}}),
    )
    .unwrap();
    let all = specs(&store, fds).unwrap();
    assert_eq!(
        dev(&all).environment["APP_URL"],
        "https://pub-test.example.com"
    );
    assert!(!all.iter().any(|s| s.id == "public.pub"));
    public::set_shared("pub", true);
    let all = specs(&store, fds).unwrap();
    let run = all.iter().find(|s| s.id == "public.pub").unwrap();
    assert!(!run.restart_on_exit);
    assert_eq!(run.args[..3], ["tunnel", "--no-autoupdate", "--config"]);
    let config = std::fs::read_to_string(&run.args[3]).unwrap();
    assert!(config.contains("httpHostHeader: \"pub.test\""));
    public::retain(&Default::default());
    assert!(
        !specs(&store, fds)
            .unwrap()
            .iter()
            .any(|s| s.id == "public.pub")
    );
}
