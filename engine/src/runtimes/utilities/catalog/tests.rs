use super::*;
#[test]
fn plans_say_what_is_built_from_source() {
    assert_eq!(plan("node"), ["download", "verifySum", "install"]);
    assert_eq!(
        plan("postgres"),
        ["downloadSource", "verifySum", "build", "install"]
    );
    assert_eq!(plan("redis")[2], "build");
}

#[test]
fn validates_and_resolves_versions() {
    for v in ["22.23.5", "2.11.9"] {
        validate_version(v).unwrap();
    }
    validate_version("17.11").unwrap();
    for v in ["22", "1.2.3.4.5", "1.2.x", "../1.2.3", "1.2.3; rm", "17."] {
        assert!(validate_version(v).is_err(), "{v}");
    }
    assert!(validate_tool("php").is_err());
    let temp = tempfile::tempdir().unwrap();
    let store = Store::new(temp.path().join("s")).unwrap();
    for v in ["22.1.0", "22.23.5", "24.2.0"] {
        let dir = temp.path().join("s/runtimes/node").join(v);
        fs::create_dir_all(dir.join("bin")).unwrap();
        for e in executables("node") {
            fs::write(dir.join(e), "").unwrap();
        }
        let m = ToolManifest {
            tool: "node".into(),
            version: v.into(),
            url: String::new(),
            checksum_url: String::new(),
            sha256: String::new(),
            installed_at: 0,
            openssl: None,
            extensions: None,
        };
        fs::write(
            dir.join("butake-manifest.json"),
            serde_json::to_vec(&m).unwrap(),
        )
        .unwrap();
    }
    assert!(resolve(&store, "node", "22").unwrap().ends_with("22.23.5"));
    assert!(resolve(&store, "node", "").unwrap().ends_with("24.2.0"));
    assert!(resolve(&store, "node", "20").is_none());
    // A link pointing outside the tool tree is rejected.
    let dir = temp.path().join("s/runtimes/node/24.2.0");
    std::os::unix::fs::symlink("/etc", dir.join("bin/escape")).unwrap();
    assert!(archive::check_tree(&dir, Links::Inside).is_err());
    remove(&store, "node", "22.1.0").unwrap();
    assert_eq!(installed(&store, "node").unwrap().len(), 2);
    assert!(remove(&store, "node", "../x").is_err());
}

/// A PostgreSQL built before P-29 (core only) is told apart from one with `contrib`, and an
/// old manifest without the new fields still reads.
#[test]
fn postgres_without_contrib_is_detected() {
    let temp = tempfile::tempdir().unwrap();
    let store = Store::new(temp.path().join("s")).unwrap();
    for (version, full) in [("16.15", false), ("16.16", true)] {
        let dir = temp.path().join("s/runtimes/postgres").join(version);
        fs::create_dir_all(dir.join("bin")).unwrap();
        fs::create_dir_all(dir.join("share/extension")).unwrap();
        for e in executables("postgres") {
            fs::write(dir.join(e), "").unwrap();
        }
        fs::write(dir.join("share/extension/plpgsql.control"), "").unwrap();
        if full {
            for name in POSTGRES_EXTENSIONS {
                fs::write(dir.join(format!("share/extension/{name}.control")), "").unwrap();
            }
        }
        fs::write(
            dir.join("butake-manifest.json"),
            format!(r#"{{"tool":"postgres","version":"{version}","url":"","checksum_url":"","sha256":"","installed_at":0}}"#),
        )
        .unwrap();
    }
    let listed = installed(&store, "postgres").unwrap();
    let flags: Vec<_> = listed
        .iter()
        .map(|m| (m.version.as_str(), m.extensions))
        .collect();
    assert_eq!(flags, [("16.16", Some(true)), ("16.15", Some(false))]);
    // Listing never writes the flag into the manifest.
    let text = fs::read_to_string(
        temp.path()
            .join("s/runtimes/postgres/16.15/butake-manifest.json"),
    )
    .unwrap();
    assert!(!text.contains("extensions"));
    assert!(installed(&store, "node")
        .unwrap()
        .iter()
        .all(|m| m.extensions.is_none()));
    // A reinstall without `replace` is refused; the plan says it builds from source.
    assert_eq!(
        install(&store, "postgres", "16.16", false)
            .unwrap_err()
            .to_string(),
        "runtime_exists"
    );
    assert_eq!(
        plan("postgres"),
        ["downloadSource", "verifySum", "build", "install"]
    );
    assert!(openssl_url().starts_with("https://github.com/openssl/openssl/releases/download/"));
    // Stack's data folder has spaces (`Application Support`): the build happens elsewhere and
    // no configure option gets a path it would split.
    let spaced = temp.path().join("Application Support/Stack p29");
    fs::create_dir_all(&spaced).unwrap();
    assert_eq!(
        build_base(Some(spaced.clone())),
        PathBuf::from("/private/tmp")
    );
    assert_eq!(build_base(None), PathBuf::from("/private/tmp"));
    let plain = build_base(Some(temp.path().to_path_buf()));
    assert!(no_whitespace(&plain) && plain.is_dir());
    assert_eq!(
        postgres_flags(&spaced.join(".openssl"))
            .unwrap_err()
            .to_string(),
        "unsafe_runtime_path"
    );
    let flags = postgres_flags(Path::new("/private/tmp/b/.openssl")).unwrap();
    assert!(flags.iter().all(|f| !f.contains(' ')));
    assert!(flags.contains(&"--with-includes=/private/tmp/b/.openssl/include".to_string()));
    let work = build_workspace("postgres", "16.16").unwrap();
    assert!(no_whitespace(&work) && work.is_dir());
    fs::remove_dir(&work).unwrap();
    assert_eq!(OPENSSL_SHA256.len(), 64);
}

/// A JDK version with two numbers passes `validate_version` but is not a release: it is refused
/// with `invalid_version` instead of failing on an index while naming the download.
#[test]
fn a_jdk_version_without_a_patch_number_is_refused() {
    let temp = tempfile::tempdir().unwrap();
    let store = Store::new(temp.path().join("s")).unwrap();
    let error = install(&store, "jdk", "21.0", false).unwrap_err();
    assert_eq!(error.to_string(), "invalid_version");
}
