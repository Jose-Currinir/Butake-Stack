//! Without network: a fake PostgreSQL (its `pg_config` a script) and a fake extension served from
//! a local origin go through the same install, record, carry and removal as the real ones.
use super::catalog::{Archive, Build, Recipe};
use super::*;
use crate::core::progress::TEST_TURN;
use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::Command,
};

fn leak(text: String) -> &'static str {
    Box::leak(text.into_boxed_str())
}

/// A PostgreSQL 16.4 tree with two bundled extensions and a `pg_config` that answers from where it
/// is, like the real one.
fn fake_postgres(store_root: &Path) -> PathBuf {
    let root = store_root.join("runtimes/postgres/16.4");
    fs::create_dir_all(root.join("bin")).unwrap();
    fs::create_dir_all(root.join("share/extension")).unwrap();
    for exe in crate::runtimes::utilities::catalog::executables("postgres") {
        fs::write(root.join(exe), "").unwrap();
    }
    fs::write(
        root.join("bin/pg_config"),
        "#!/bin/sh\nd=$(cd \"$(dirname \"$0\")/..\" && pwd)\ncase \"$1\" in --sharedir) echo \"$d/share\";; esac\n",
    )
    .unwrap();
    fs::set_permissions(
        root.join("bin/pg_config"),
        fs::Permissions::from_mode(0o755),
    )
    .unwrap();
    for name in ["plpgsql", "citext"] {
        fs::write(root.join(format!("share/extension/{name}.control")), name).unwrap();
    }
    fs::write(
        root.join("butake-manifest.json"),
        r#"{"tool":"postgres","version":"16.4","url":"","checksum_url":"","sha256":"","installed_at":0}"#,
    )
    .unwrap();
    root
}

/// A source archive whose `make install` copies its control and SQL files where `pg_config`
/// says (or over `citext.control`, to show a conflict).
fn fake_source(dir: &Path, name: &str, version: &str, clobber: bool) -> (PathBuf, String) {
    let tree = dir.join(format!("{name}-{version}"));
    fs::create_dir_all(&tree).unwrap();
    fs::write(
        tree.join(format!("{name}.control")),
        format!("default_version = '{version}'\n"),
    )
    .unwrap();
    fs::write(tree.join(format!("{name}--{version}.sql")), "SELECT 1;\n").unwrap();
    let extra = if clobber {
        "\techo cambiado > \"$$($(PG_CONFIG) --sharedir)/extension/citext.control\"\n"
    } else {
        ""
    };
    fs::write(
        tree.join("Makefile"),
        format!(
            "all:\n\t@echo compilando {name}\ninstall:\n\tmkdir -p \"$$($(PG_CONFIG) --sharedir)/extension\"\n\
             \tcp {name}.control {name}--{version}.sql \"$$($(PG_CONFIG) --sharedir)/extension/\"\n{extra}"
        ),
    )
    .unwrap();
    let archive = dir.join(format!("{name}-{version}.tar.gz"));
    assert!(
        Command::new("/usr/bin/tar")
            .arg("-czf")
            .arg(&archive)
            .arg("-C")
            .arg(dir)
            .arg(format!("{name}-{version}"))
            .status()
            .unwrap()
            .success()
    );
    let sum = crate::core::hash::sha256_file(&archive).unwrap();
    (archive, sum)
}

fn recipe(name: &str, version: &str, archive: &Path, sha256: &str) -> &'static Recipe {
    Box::leak(Box::new(Recipe {
        component: "postgres",
        id: leak(name.into()),
        name: leak(name.into()),
        version: leak(version.into()),
        license: "PostgreSQL",
        homepage: "https://example.invalid",
        archive: Archive {
            file: leak(archive.file_name().unwrap().to_string_lossy().into_owned()),
            url: "https://example.invalid/x.tar.gz",
            sha256: leak(sha256.into()),
            size: 1,
            strip: true,
        },
        dependencies: &[],
        build: Build::Pgxs,
        sql_names: Box::leak(vec![leak(name.into())].into_boxed_slice()),
        engines: (13, 19),
        note: None,
    }))
}

/// The local origin: copies the archive the recipe names from `dir`.
fn local(dir: &Path) -> impl Fn(&Archive, &Path) -> anyhow::Result<()> + '_ {
    move |archive: &Archive, target: &Path| {
        fs::copy(dir.join(archive.file), target)?;
        Ok(())
    }
}

#[test]
fn installs_records_carries_and_removes_without_network() {
    let _turn = TEST_TURN.lock().unwrap_or_else(|e| e.into_inner());
    let temp = tempfile::tempdir().unwrap();
    // Stack's real data folder has spaces: so does this one.
    let store = Store::new(temp.path().join("Application Support/Stack p43")).unwrap();
    let root = fake_postgres(store.root());
    let origin = temp.path().join("origin");
    fs::create_dir_all(&origin).unwrap();
    let (archive, sum) = fake_source(&origin, "demo", "1.0", false);
    let demo = recipe("demo", "1.0", &archive, &sum);
    let engine = install::engine(&store, "postgres", None).unwrap();
    assert_eq!(engine.version, "16.4");

    // A wrong sum stops it before anything is built or placed, and the download is cleaned up.
    let wrong = recipe("demo", "1.0", &archive, &"0".repeat(64));
    let error = install::install(&store, &engine, wrong, &local(&origin)).unwrap_err();
    assert_eq!(error.to_string(), "checksum_mismatch");
    assert!(!root.join("share/extension/demo.control").exists());
    assert_eq!(fs::read_dir(store.root().join("cache")).unwrap().count(), 0);

    let installed = install::install(&store, &engine, demo, &local(&origin)).unwrap();
    assert_eq!(
        installed.files,
        [
            "share/extension/demo--1.0.sql",
            "share/extension/demo.control"
        ]
    );
    assert_eq!(installed.sources[0].sha256, sum);
    assert!(root.join("share/extension/demo.control").is_file());
    let names = install::control_names(&root);
    assert_eq!(names.get("demo"), Some(&Some("demo".to_string())));
    assert_eq!(names.get("citext"), Some(&None));
    // Listed: the catalog's entries and the bundled ones (not the one a catalog entry placed).
    let listed = postgres(&store, &engine).unwrap();
    assert!(
        listed
            .iter()
            .any(|e| e.id == "citext" && e.kind == "bundled" && !e.removable)
    );
    assert!(listed.iter().all(|e| e.id != "demo"));
    let postgis = listed.iter().find(|e| e.id == "postgis").unwrap();
    assert!(postgis.supported && postgis.installed.is_none() && postgis.downloads.len() == 6);

    // An update replaces its files; one the new version no longer has goes away.
    let (archive2, sum2) = fake_source(&origin, "demo", "1.1", false);
    let demo2 = recipe("demo", "1.1", &archive2, &sum2);
    install::install(&store, &engine, demo2, &local(&origin)).unwrap();
    assert!(!root.join("share/extension/demo--1.0.sql").exists());
    assert!(root.join("share/extension/demo--1.1.sql").exists());
    assert_eq!(install::state(&root).extensions["demo"].version, "1.1");

    // An extension that would overwrite a file of the engine is refused, and nothing is placed.
    let (archive3, sum3) = fake_source(&origin, "rogue", "1.0", true);
    let rogue = recipe("rogue", "1.0", &archive3, &sum3);
    let error = install::install(&store, &engine, rogue, &local(&origin)).unwrap_err();
    assert_eq!(error.to_string(), "extension_conflict");
    assert_eq!(
        fs::read_to_string(root.join("share/extension/citext.control")).unwrap(),
        "citext"
    );
    assert!(!root.join("share/extension/rogue.control").exists());

    // A rebuilt engine (same version) keeps what was installed in the old copy.
    let rebuilt = temp.path().join("rebuilt");
    fs::create_dir_all(rebuilt.join("share/extension")).unwrap();
    install::carry(&root, &rebuilt).unwrap();
    assert!(rebuilt.join("share/extension/demo.control").is_file());
    assert_eq!(install::state(&rebuilt).extensions["demo"].version, "1.1");

    // Removing is refused while a database uses it, saying which; then it goes completely.
    let error = install::remove(&engine, "demo", &["geo".into(), "app".into()]).unwrap_err();
    assert_eq!(error.to_string(), "extension_in_use:geo, app");
    assert!(root.join("share/extension/demo.control").exists());
    install::remove(&engine, "demo", &[]).unwrap();
    assert!(!root.join("share/extension/demo.control").exists());
    assert!(install::state(&root).extensions.is_empty());
    assert_eq!(
        install::remove(&engine, "demo", &[])
            .unwrap_err()
            .to_string(),
        "extension_not_installed"
    );
}

#[test]
fn a_project_says_what_its_databases_lack() {
    let temp = tempfile::tempdir().unwrap();
    let store = Store::new(temp.path().join("store")).unwrap();
    let folder = temp.path().join("geo");
    fs::create_dir_all(&folder).unwrap();
    let project: crate::core::model::Project = serde_json::from_value(json!({
        "id": "geo", "name": "Geo", "path": folder, "domains": ["geo.test"], "https": false,
        "kind": "static", "runtime": {}, "docroot": ".", "services": ["postgres"],
        "databases": [{"name": "geo", "extensions": ["citext", "postgis", "nada"]}, "plain"],
        "processes": []}))
    .unwrap();
    store.save(project.clone()).unwrap();
    // Without PostgreSQL: the service is missing for each.
    let issues = project::check(&store, &project).unwrap();
    assert!(issues.iter().all(|i| i.problem == "serviceMissing") && issues.len() == 3);
    fake_postgres(store.root());
    let issues = project::check(&store, &project).unwrap();
    let by: Vec<_> = issues
        .iter()
        .map(|i| (i.extension.as_str(), i.problem, i.catalog))
        .collect();
    assert_eq!(
        by,
        [
            ("postgis", "notInstalled", Some("postgis")),
            ("nada", "unknown", None),
            ("citext", "serverStopped", None)
        ]
    );
    assert_eq!(
        project::plan(&issues),
        [
            "downloadSource",
            "verifySum",
            "buildDependencies",
            "build",
            "install",
            "activate"
        ]
    );
    // The record keeps both forms; the app asks for the plan of resolving it.
    let saved = store.get("geo").unwrap();
    assert_eq!(saved.databases[1], "plain".to_string());
    let steps = dispatch(
        &store,
        "installSteps",
        &json!({"tool": "extension-project-geo"}),
    )
    .unwrap()
    .unwrap();
    assert_eq!(steps[0], "downloadSource");
    let steps = dispatch(
        &store,
        "installSteps",
        &json!({"tool": "extension-pgvector"}),
    )
    .unwrap()
    .unwrap();
    assert_eq!(
        steps,
        json!(["downloadSource", "verifySum", "build", "install"])
    );
    assert!(
        dispatch(&store, "installSteps", &json!({"tool": "node"}))
            .unwrap()
            .is_none()
    );
    assert!(dispatch(&store, "other", &json!({})).unwrap().is_none());
    // Changing anything needs the user's confirmation.
    for method in [
        "installExtension",
        "removeExtension",
        "activateExtension",
        "deactivateExtension",
        "resolveProjectExtensions",
    ] {
        let error = dispatch(
            &store,
            method,
            &json!({"component": "postgres", "id": "pgvector"}),
        )
        .unwrap_err();
        assert_eq!(error.to_string(), "confirmation_required", "{method}");
    }
}

#[test]
fn the_catalog_names_official_origins_and_sums() {
    for recipe in catalog::RECIPES {
        for archive in recipe.archives() {
            assert!(archive.url.starts_with("https://"), "{}", archive.url);
            let host = archive.url.split('/').nth(2).unwrap();
            assert!(
                ["download.osgeo.org", "github.com", "ftp.gnu.org"].contains(&host),
                "{host}"
            );
            assert!(
                archive.sha256.len() == 64
                    && archive
                        .sha256
                        .bytes()
                        .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()),
                "{}",
                archive.file
            );
        }
        assert!(recipe.supports("18.7") && !recipe.supports("12.1"));
    }
    let postgis = catalog::recipe("postgres", "postgis").unwrap();
    assert_eq!(
        catalog::providing("postgres", "vector").unwrap().id,
        "pgvector"
    );
    assert!(postgis.download_size() > 100_000_000);
    assert!(newer("3.7.1", "3.7.0") && !newer("3.7.0", "3.7.0") && newer("0.10.0", "0.9.9"));
}
