use super::*;

/// What the wizard made of a Swift package or a React Native app is registered as a project
/// without a server (P-42): listed, off, with no domain to serve and its own checks.
#[test]
fn swift_and_react_native_are_registered_without_a_server() {
    let temp = tempfile::tempdir().unwrap();
    let store = Store::new(temp.path().join("store")).unwrap();
    let swift = temp.path().join("paquete");
    fs::create_dir_all(swift.join("Sources/Paquete")).unwrap();
    fs::write(swift.join("Package.swift"), "// swift-tools-version:6.0\n").unwrap();
    let mobile = temp.path().join("movil");
    fs::create_dir_all(&mobile).unwrap();
    fs::write(
            mobile.join("package.json"),
            "{\"dependencies\":{\"expo\":\"54\",\"react-native\":\"0.81\"},\"scripts\":{\"test\":\"jest\"}}",
        )
        .unwrap();
    for folder in [&swift, &mobile] {
        let project = register_unserved(&store, folder).unwrap();
        assert_eq!(project.kind, crate::core::model::ProjectKind::Unserved);
        assert!(!project.enabled && project.upstream.is_none());
        assert!(store.list().unwrap().iter().any(|p| p.id == project.id));
    }
    let package = store.get("paquete").unwrap();
    assert!(
        package
            .processes
            .iter()
            .any(|p| p.program == "swift" && p.args == ["test"])
    );
}

#[test]
fn validates_inputs_and_rewrites_env() {
    validate_name("mi-app_2").unwrap();
    for bad in ["", "../x", "a b", "-x", &"x".repeat(41)] {
        assert!(validate_name(bad).is_err());
    }
    assert!(package("angular").is_err());
    let temp = tempfile::tempdir().unwrap();
    let env = temp.path().join(".env");
    fs::write(
        &env,
        "DB_CONNECTION=sqlite\n# DB_HOST=127.0.0.1\nAPP_NAME=x\n",
    )
    .unwrap();
    set_env(
        &env,
        &[
            ("DB_CONNECTION", "mysql".into()),
            ("DB_HOST", "127.0.0.1".into()),
            ("DB_DATABASE", "demo".into()),
        ],
    )
    .unwrap();
    let text = fs::read_to_string(&env).unwrap();
    assert!(text.contains("DB_CONNECTION=mysql\nDB_HOST=127.0.0.1\nAPP_NAME=x\nDB_DATABASE=demo"));
}

/// The `.env` that receives a database password is owner-only from the moment it is written,
/// even when it was created readable (`.env.example` copied with the default mode).
#[test]
fn set_env_leaves_the_file_owner_only() {
    use std::os::unix::fs::PermissionsExt;
    let temp = tempfile::tempdir().unwrap();
    let env = temp.path().join(".env");
    fs::write(&env, "APP_NAME=x\n").unwrap();
    fs::set_permissions(&env, fs::Permissions::from_mode(0o644)).unwrap();
    set_env(&env, &[("DB_PASSWORD", "secreto-de-prueba".into())]).unwrap();
    assert_eq!(
        fs::metadata(&env).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert!(
        fs::read_to_string(&env)
            .unwrap()
            .contains("DB_PASSWORD=secreto-de-prueba")
    );
}
