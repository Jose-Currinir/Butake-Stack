#[test]
fn today_is_an_iso_date() {
    let t = super::today();
    assert!(t.as_str() > "2026-01-01" && &t[4..5] == "-" && &t[7..8] == "-");
}
#[test]
fn framework_specs() {
    assert_eq!(
        super::framework_spec("django", "5.2").unwrap(),
        "django>=5.2,<5.3"
    );
    assert_eq!(
        super::framework_spec("fastapi[standard]", "").unwrap(),
        "fastapi[standard]"
    );
    assert!(super::framework_spec("django", "5;x").is_err());
    assert!(
        super::satisfies(">=3.12,<=3.15", "3.15") && !super::satisfies(">=3.12,<=3.15", "3.16")
    );
}
use super::*;
#[test]
fn requirements_by_line() {
    assert!(satisfies(">=3.12", "3.13") && !satisfies(">=3.12", "3.11"));
    assert!(satisfies(">=3.10,<4", "3.14") && !satisfies(">=3.10,<4", "3.9"));
    assert!(satisfies(">=3.8", "3.13"));
    assert!(satisfies("~=3.11", "3.13") && !satisfies("~=3.11", "3.10"));
    assert!(!satisfies("!=3.12.*", "3.12") && satisfies("!=3.12.*", "3.13"));
    assert!(satisfies("^8.2", "8.4") && !satisfies("^8.2", "8.1") && !satisfies("^8.2", "9.0"));
    assert!(satisfies("^8.2|^9.0", "9.0"));
    assert!(satisfies(">=8.1 <8.4", "8.3") && !satisfies(">=8.1 <8.4", "8.4"));
    assert!(satisfies(">=3.12.1", "3.12"));
    assert!(satisfies("", "3.9"));
}
#[test]
fn validates_lines_and_reads_builds() {
    for ok in ["3.13", "3.13.18", "3.9"] {
        validate_line(ok).unwrap();
    }
    for bad in ["3", "2.7", "3.13.0a2", "../3.13", "3.13.1.1", "3.x"] {
        assert!(validate_line(bad).is_err(), "{bad}");
    }
    let t = triple();
    // The names as SHA256SUMS lists them ("<hash>  <name>").
    let names = [
        format!("cpython-3.13.18+20261110-{t}-install_only.tar.gz"),
        format!("cpython-3.13.18+20261110-{t}-install_only_stripped.tar.gz"),
        format!("cpython-3.16.0a2+20261110-{t}-install_only.tar.gz"),
        "cpython-3.12.16+20261110-x86_64-unknown-linux-gnu-install_only.tar.gz".into(),
    ];
    let found = builds("20261110", names.iter().map(String::as_str));
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].0, "3.13.18");
}
#[test]
fn resolves_lines_and_global() {
    let temp = tempfile::tempdir().unwrap();
    let store = Store::new(temp.path().join("s")).unwrap();
    for (line, version) in [("3.12", "3.12.16"), ("3.13", "3.13.18")] {
        let dir = temp.path().join("s/runtimes/python").join(line);
        fs::create_dir_all(dir.join("bin")).unwrap();
        fs::write(dir.join("bin/python3"), "").unwrap();
        let m = PythonManifest {
            line: line.into(),
            version: version.into(),
            release: "20261110".into(),
            url: String::new(),
            sha256: String::new(),
            installed_at: 0,
        };
        fs::write(
            dir.join("butake-manifest.json"),
            serde_json::to_vec(&m).unwrap(),
        )
        .unwrap();
    }
    assert_eq!(installed(&store).len(), 2);
    assert!(
        resolve(&store, "")
            .unwrap()
            .to_string_lossy()
            .contains("/3.13/")
    );
    assert!(
        resolve(&store, "3.12")
            .unwrap()
            .to_string_lossy()
            .contains("/3.12/")
    );
    assert!(
        resolve(&store, "3.12.4")
            .unwrap()
            .to_string_lossy()
            .contains("/3.12/")
    );
    assert!(resolve(&store, "3.11").is_none());
    let mut config = store.config().unwrap();
    config.versions.insert("python".into(), "3.12".into());
    store.save_config(&config).unwrap();
    assert!(
        resolve(&store, "")
            .unwrap()
            .to_string_lossy()
            .contains("/3.12/")
    );
    remove(&store, "3.12").unwrap();
    assert!(remove(&store, "../x").is_err());
    assert_eq!(installed(&store).len(), 1);
}
