use super::*;
use std::os::unix::fs::PermissionsExt;

#[test]
fn hostnames_and_zones() {
    let local = vec!["test".to_string()];
    // The name the app proposes (`<id>-test.<zone>`) is covered by the universal certificate.
    assert!(!validate_hostname("salud-test.example.com", "example.com", &local).unwrap());
    assert!(validate_hostname("salud.test.example.com", "example.com", &local).unwrap());
    for (host, zone, code) in [
        (
            "salud.otra.com",
            "example.com",
            "public_hostname_outside_zone",
        ),
        ("example.com", "example.com", "public_hostname_outside_zone"),
        (
            "xexample.com",
            "example.com",
            "public_hostname_outside_zone",
        ),
        (
            "Salud.example.com",
            "example.com",
            "invalid_public_hostname",
        ),
        (
            "sa lud.example.com",
            "example.com",
            "invalid_public_hostname",
        ),
        ("-a.example.com", "example.com", "invalid_public_hostname"),
        ("a.salud.test", "salud.test", "invalid_zone"),
        ("a.com", "com", "invalid_zone"),
    ] {
        assert_eq!(
            validate_hostname(host, zone, &local)
                .unwrap_err()
                .to_string(),
            code,
            "{host}"
        );
    }
}

#[test]
fn reads_the_created_tunnel_and_classifies_failures() {
    let id = "6f1c2a4e-0b7d-4c55-9a0e-3b2f1d9c8e71";
    assert_eq!(
        created_id(&format!(r#"{{"id":"{id}","name":"stack-salud"}}"#)).as_deref(),
        Some(id)
    );
    assert_eq!(
        created_id(&format!("Created tunnel stack-salud with id {id}")).as_deref(),
        Some(id)
    );
    assert!(created_id("nada").is_none());
    for (text, code) in [
        (
            "failed: tunnel with name already exists",
            "tunnel_name_taken",
        ),
        (
            "An A, AAAA, or CNAME record with that host already exists.",
            "public_hostname_taken",
        ),
        (
            "dial tcp: lookup api.cloudflare.com: no such host",
            "tunnel_offline",
        ),
        ("Failed to add route: zone not found", "zone_not_authorized"),
        ("Tunnel 6f1c… not found", "tunnel_not_found"),
        (
            "Cannot determine default origin certificate path",
            "cloudflare_not_connected",
        ),
        ("something else", "tunnel_failed"),
    ] {
        assert_eq!(classify(text), code, "{text}");
    }
}

#[test]
fn ingress_enters_like_the_temporary_address() {
    let address = Address {
        hostname: "salud-test.example.com".into(),
        tunnel: "6f1c2a4e-0b7d-4c55-9a0e-3b2f1d9c8e71".into(),
        zone: "example.com".into(),
    };
    let text = ingress(
        &address,
        Path::new("/Users/x/Library/Application Support/Stack/tunnels/salud.json"),
        80,
        "salud.test",
    );
    assert!(text.contains("service: http://127.0.0.1:80\n"));
    assert!(text.contains("httpHostHeader: \"salud.test\""));
    assert!(text.contains("hostname: \"salud-test.example.com\""));
    assert!(text.contains(
        "credentials-file: \"/Users/x/Library/Application Support/Stack/tunnels/salud.json\""
    ));
    assert!(text.ends_with("  - service: http_status:404\n"));
    assert_eq!(
        run_arguments(Path::new("/c.yml"), &address.tunnel),
        [
            "tunnel",
            "--no-autoupdate",
            "--config",
            "/c.yml",
            "run",
            "6f1c2a4e-0b7d-4c55-9a0e-3b2f1d9c8e71"
        ]
    );
}

/// A fake `cloudflared`: it records each call, writes credentials on `create` and fails the
/// way the real one words it for the names the test chooses.
fn fake(dir: &Path) -> Cloudflared {
    let home = dir.join("home");
    std::fs::create_dir_all(home.join(".cloudflared")).unwrap();
    let executable = dir.join("cloudflared");
    std::fs::write(
            &executable,
            r#"#!/bin/sh
echo "$*" >> "$HOME/calls.log"
case "$*" in
  *" create "*)
    for last; do :; done
    if [ "$last" = "stack-usado" ]; then echo "tunnel with name already exists" >&2; exit 1; fi
    while [ "$1" != "--credentials-file" ]; do shift; done
    echo '{"AccountTag":"x","TunnelSecret":"CENTINELA-SECRETO"}' > "$2"; chmod 400 "$2"
    echo '{"id":"6f1c2a4e-0b7d-4c55-9a0e-3b2f1d9c8e71","name":"x"}' ;;
  *" route dns "*)
    case "$*" in
      *usado*) echo "An A, AAAA, or CNAME record with that host already exists. CENTINELA-SECRETO" >&2; exit 1 ;;
      *sinred*) echo "dial tcp: lookup api.cloudflare.com: no such host" >&2; exit 1 ;;
    esac
    echo "Added CNAME" ;;
  *" delete "*) echo "Deleted" ;;
  *) echo "unknown" >&2; exit 1 ;;
esac
"#,
        )
        .unwrap();
    std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o700)).unwrap();
    Cloudflared { executable, home }
}

fn store_with(dir: &Path, ids: &[&str]) -> Store {
    let store = Store::new(dir.join("store")).unwrap();
    for id in ids {
        let path = dir.join(id);
        std::fs::create_dir_all(&path).unwrap();
        store
            .save(
                serde_json::from_value(json!({
                        "id": id, "name": id, "path": path, "domains": [format!("{id}.test")],
                        "https": false, "kind": "static", "runtime": {}, "docroot": ".",
                        "services": [], "databases": [], "processes": []}))
                .unwrap(),
            )
            .unwrap();
    }
    store
}

#[test]
fn configure_change_and_remove_with_a_fake_cloudflared() {
    // Other tests raise SIGTERM in this process to cancel their runs: take turns with them.
    let _turn = crate::core::progress::TEST_TURN
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    crate::core::watch::clear_stop();
    let temp = tempfile::tempdir().unwrap();
    let tool = fake(temp.path());
    let store = store_with(temp.path(), &["salud", "otro"]);
    // Without the connection nothing is tried.
    assert_eq!(
        configure(
            &store,
            &tool,
            "salud",
            "salud-test.example.com",
            "example.com"
        )
        .unwrap_err()
        .to_string(),
        "cloudflare_not_connected"
    );
    std::fs::write(cert_path(&tool.home), "certificado ficticio").unwrap();
    let done = configure(
        &store,
        &tool,
        "salud",
        "salud-test.example.com",
        "example.com",
    )
    .unwrap();
    assert_eq!(done["advancedCertificate"], false);
    let creds = credentials(&store, "salud").unwrap();
    assert_eq!(
        std::fs::metadata(&creds).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert_eq!(
        addresses(&store)["salud"],
        "salud-test.example.com".to_string()
    );
    // The address survives a new engine (it is in the store), the credentials never leave it.
    let status = status(&store).unwrap().to_string();
    assert!(status.contains("salud-test.example.com"));
    assert!(!status.contains("CENTINELA"));
    // Failures carry a code, never what cloudflared printed; a failed route leaves nothing.
    for (host, code) in [
        ("usado.example.com", "public_hostname_taken"),
        ("sinred.example.com", "tunnel_offline"),
    ] {
        let error = configure(&store, &tool, "otro", host, "example.com").unwrap_err();
        assert_eq!(error.to_string(), code);
        assert!(!credentials(&store, "otro").unwrap().exists());
        assert!(address(&store, "otro").is_none());
    }
    let calls = std::fs::read_to_string(tool.home.join("calls.log")).unwrap();
    assert!(calls.contains("delete -f 6f1c2a4e-0b7d-4c55-9a0e-3b2f1d9c8e71"));
    // A second address on the same name is refused before calling Cloudflare.
    assert_eq!(
        configure(
            &store,
            &tool,
            "otro",
            "salud-test.example.com",
            "example.com"
        )
        .unwrap_err()
        .to_string(),
        "public_hostname_taken"
    );
    let changed = change(&store, &tool, "salud", "salud.test.example.com").unwrap();
    assert_eq!(changed["previous"], "salud-test.example.com");
    assert_eq!(changed["advancedCertificate"], true);
    let removed = remove(&store, &tool, "salud").unwrap();
    assert_eq!(removed["hostname"], "salud.test.example.com");
    assert!(!creds.exists());
    assert!(addresses(&store).is_empty());
    // The certificate is only checked, never touched.
    assert_eq!(
        std::fs::read_to_string(cert_path(&tool.home)).unwrap(),
        "certificado ficticio"
    );
}
