/// New folder with data wins; the old one is used (untouched) until it is moved; a new Mac
/// gets the new one; an empty new folder does not hide the old data.
#[test]
fn resolves_the_data_folder() {
    let home = tempfile::tempdir().unwrap();
    let (new, old) = (
        Store::data_folder(home.path()),
        Store::old_data_folder(home.path()),
    );
    assert_eq!(Store::resolve(home.path()), new);
    std::fs::create_dir_all(old.join("projects")).unwrap();
    assert_eq!(Store::resolve(home.path()), old);
    std::fs::create_dir_all(&new).unwrap();
    assert_eq!(
        Store::resolve(home.path()),
        old,
        "an empty new folder is not the data"
    );
    std::fs::create_dir_all(new.join("projects")).unwrap();
    assert_eq!(Store::resolve(home.path()), new);
    assert!(
        old.join("projects").is_dir(),
        "the old folder is never touched"
    );
    assert!(new.ends_with("Library/Application Support/Stack"));
}
use super::*;
#[test]
fn a_retired_service_in_stack_json_is_dropped_on_read() {
    let temp = tempfile::tempdir().unwrap();
    let store = Store::new(temp.path().join("store")).unwrap();
    let mut written = serde_json::to_value(StackConfig::default()).unwrap();
    written["engines"] = serde_json::json!({
        "aws-emulator": {"enabled": true, "version": "1.0", "telemetry": true},
        "redis": {"enabled": false, "version": "", "telemetry": false}
    });
    fs::write(temp.path().join("store/stack.json"), written.to_string()).unwrap();
    let config = store.config().unwrap();
    assert!(!config.engines.contains_key("aws-emulator"));
    assert!(config.engines.contains_key("redis"));
    assert!(
        !serde_json::to_string(&config)
            .unwrap()
            .contains("telemetry")
    );
}
#[test]
fn groups_are_validated_and_each_site_is_in_one() {
    let temp = tempfile::tempdir().unwrap();
    let store = Store::new(temp.path().join("store")).unwrap();
    assert!(store.groups().unwrap().is_empty());
    let saved = store
        .save_groups(vec![
            SiteGroup {
                id: "clientes".into(),
                name: "  Clientes ".into(),
                sites: vec!["one".into(), "crew".into()],
                ..Default::default()
            },
            SiteGroup {
                id: "internos".into(),
                name: "Internos".into(),
                sites: vec!["crew".into(), "gestion".into()],
                ..Default::default()
            },
        ])
        .unwrap();
    assert_eq!(saved[0].name, "Clientes");
    assert_eq!(saved[1].sites, vec!["gestion".to_string()]);
    assert_eq!(store.groups().unwrap(), saved);
    assert!(
        store
            .save_groups(vec![SiteGroup {
                id: "x".into(),
                name: "".into(),
                sites: vec![],
                ..Default::default()
            }])
            .is_err()
    );
    assert!(
        store
            .save_groups(vec![SiteGroup {
                id: "../x".into(),
                name: "X".into(),
                sites: vec![],
                ..Default::default()
            }])
            .is_err()
    );
    assert!(
        store
            .save_groups(vec![SiteGroup {
                id: "x".into(),
                name: "X".into(),
                sites: vec!["a b".into()],
                ..Default::default()
            }])
            .is_err()
    );
}
/// A `groups.json` written before projects of several parts reads and saves the same: no
/// field is added to a folder.
#[test]
fn an_older_groups_file_reads_and_saves_unchanged() {
    let temp = tempfile::tempdir().unwrap();
    let store = Store::new(temp.path().join("store")).unwrap();
    let older = serde_json::json!([
        {"id": "apps", "name": "Apps", "sites": ["one", "two"]},
        {"id": "web", "name": "Web", "sites": []}
    ]);
    fs::write(temp.path().join("store/groups.json"), older.to_string()).unwrap();
    let read = store.groups().unwrap();
    assert!(read.iter().all(|group| !group.is_project()));
    store.save_groups(read).unwrap();
    let written: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(temp.path().join("store/groups.json")).unwrap())
            .unwrap();
    assert_eq!(written, older);
}
/// A folder becomes a project and back without losing its parts, repositories or link; an
/// unknown kind or a relative repository is refused.
#[test]
fn a_project_of_several_parts_round_trips() {
    let temp = tempfile::tempdir().unwrap();
    let store = Store::new(temp.path().join("store")).unwrap();
    let link = crate::core::model::GcpLink {
        account: "qa@ejemplo.test".into(),
        project: "salud-ficticia".into(),
    };
    let mut salud = SiteGroup {
        id: "salud".into(),
        name: "Salud".into(),
        sites: vec!["salud-app".into(), "salud-web".into()],
        kind: SiteGroup::PROJECT.into(),
        repositories: vec!["/tmp/qa/infra/".into(), "/tmp/qa/infra".into()],
        ordered: true,
        gcp: Some(link.clone()),
        path: None,
        parent: None,
    };
    let saved = store.save_groups(vec![salud.clone()]).unwrap();
    assert_eq!(saved[0].repositories, vec!["/tmp/qa/infra".to_string()]);
    let written: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(temp.path().join("store/groups.json")).unwrap())
            .unwrap();
    assert_eq!(written[0]["kind"], "project");
    assert_eq!(written[0]["ordered"], true);
    salud.kind = "folder".into();
    let folder = store.save_groups(vec![salud.clone()]).unwrap();
    assert!(!folder[0].is_project());
    assert_eq!(folder[0].sites.len(), 2);
    assert_eq!(folder[0].repositories.len(), 1);
    assert_eq!(folder[0].gcp, Some(link));
    let written: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(temp.path().join("store/groups.json")).unwrap())
            .unwrap();
    assert!(written[0].get("kind").is_none());
    salud.kind = "otro".into();
    assert!(store.save_groups(vec![salud.clone()]).is_err());
    salud.kind = SiteGroup::PROJECT.into();
    salud.repositories = vec!["relativa".into()];
    assert!(store.save_groups(vec![salud.clone()]).is_err());
    salud.repositories = vec!["/tmp/../etc".into()];
    assert!(store.save_groups(vec![salud]).is_err());
}
/// A part without a link of its own gets its project's; its own link and `env` win; a plain
/// folder gives nothing.
#[test]
fn parts_inherit_the_google_cloud_link_of_their_project() {
    let temp = tempfile::tempdir().unwrap();
    let store = Store::new(temp.path().join("store")).unwrap();
    let folder = temp.path().join("web");
    fs::create_dir_all(&folder).unwrap();
    let mut web: Project = serde_json::from_value(serde_json::json!({"id":"web","name":"Web","path":folder,"domains":["web.test"],"https":false,"kind":"static","runtime":{},"docroot":".","services":[],"databases":[],"processes":[]})).unwrap();
    let group = SiteGroup {
        id: "salud".into(),
        name: "Salud".into(),
        sites: vec!["web".into()],
        ..Default::default()
    };
    store.save_groups(vec![group]).unwrap();
    assert!(store.set_group_gcp("otra", None).is_err());
    store
        .set_group_gcp(
            "salud",
            Some(crate::core::model::GcpLink {
                account: "qa@ejemplo.test".into(),
                project: "salud-ficticia".into(),
            }),
        )
        .unwrap();
    assert!(
        store.gcp_environment(&web).is_empty(),
        "a folder gives nothing"
    );
    let mut groups = store.groups().unwrap();
    groups[0].kind = SiteGroup::PROJECT.into();
    store.save_groups(groups).unwrap();
    assert_eq!(
        store.gcp_environment(&web)["CLOUDSDK_CORE_PROJECT"],
        "salud-ficticia"
    );
    web.gcp = Some(crate::core::model::GcpLink {
        account: "otra@ejemplo.test".into(),
        project: "web-propia".into(),
    });
    assert_eq!(
        store.gcp_environment(&web)["CLOUDSDK_CORE_PROJECT"],
        "web-propia"
    );
    web.gcp = None;
    web.env
        .insert("GOOGLE_CLOUD_PROJECT".into(), "a-mano".into());
    let environment = store.gcp_environment(&web);
    assert_eq!(environment["GOOGLE_CLOUD_PROJECT"], "a-mano");
    assert_eq!(environment["CLOUDSDK_CORE_ACCOUNT"], "qa@ejemplo.test");
    assert!(
        store
            .set_group_gcp(
                "salud",
                Some(crate::core::model::GcpLink {
                    account: "qa@ejemplo.test".into(),
                    project: "--quiet".into(),
                })
            )
            .is_err()
    );
}
#[test]
fn a_missing_folder_never_breaks_the_list() {
    let temp = tempfile::tempdir().unwrap();
    let store = Store::new(temp.path().join("store")).unwrap();
    let folder = temp.path().join("gone");
    fs::create_dir_all(&folder).unwrap();
    let p: Project = serde_json::from_value(serde_json::json!({"id":"gone","name":"Gone","path":folder,"domains":["gone.test"],"https":false,"kind":"static","runtime":{},"docroot":".","services":[],"databases":[],"processes":[]})).unwrap();
    store.save(p).unwrap();
    fs::remove_dir(&folder).unwrap();
    assert!(store.list().unwrap().is_empty());
    assert_eq!(store.missing().unwrap().len(), 1);
    assert_eq!(store.folder_missing().unwrap()[0].id, "gone");
    fs::create_dir_all(&folder).unwrap();
    assert_eq!(store.list().unwrap().len(), 1);
    assert!(store.missing().unwrap().is_empty());
    assert!(store.folder_missing().unwrap().is_empty());
}
#[test]
fn a_moved_folder_is_found_again_keeping_the_record() {
    let temp = tempfile::tempdir().unwrap();
    let store = Store::new(temp.path().join("store")).unwrap();
    let folder = temp.path().join("before");
    let other = temp.path().join("other");
    fs::create_dir_all(&folder).unwrap();
    fs::create_dir_all(&other).unwrap();
    let p: Project = serde_json::from_value(serde_json::json!({"id":"moved","name":"Moved","path":folder,"domains":["moved.test"],"https":false,"kind":"static","runtime":{},"docroot":".","services":[],"databases":[],"processes":[],"enabled":true})).unwrap();
    store.save(p).unwrap();
    let q: Project = serde_json::from_value(serde_json::json!({"id":"other","name":"Other","path":other,"domains":["other.test"],"https":false,"kind":"static","runtime":{},"docroot":".","services":[],"databases":[],"processes":[]})).unwrap();
    store.save(q).unwrap();
    // Only a site whose folder is gone is relocated.
    assert!(store.relocate("moved", &other).is_err());
    let after = temp.path().join("after");
    fs::rename(&folder, &after).unwrap();
    // Never onto another site's folder.
    assert_eq!(
        store.relocate("moved", &other).unwrap_err().to_string(),
        "folder_in_use"
    );
    let found = store.relocate("moved", &after).unwrap();
    assert_eq!(found.path, after.canonicalize().unwrap());
    assert!(found.enabled);
    assert_eq!(found.domains, vec!["moved.test".to_string()]);
    assert!(store.folder_missing().unwrap().is_empty());
}
#[test]
fn round_trip_and_reject_symlinks() {
    let temp = tempfile::tempdir().unwrap();
    let store = Store::new(temp.path().join("store")).unwrap();
    let p: Project = serde_json::from_value(serde_json::json!({"id":"demo","name":"Demo","path":temp.path(),"domains":["demo.test"],"https":true,"kind":"static","runtime":{},"docroot":".","services":[],"databases":[],"processes":[]})).unwrap();
    let p = store.save(p).unwrap();
    assert_eq!(store.get("demo").unwrap(), p);
    assert_eq!(store.list().unwrap(), vec![p]);
    let mut config = StackConfig::default();
    config.ports.http = 8080;
    store.save_config(&config).unwrap();
    assert_eq!(store.config().unwrap(), config);
    assert!(store.delete("../demo").is_err());
    store.delete("demo").unwrap();
    assert!(store.list().unwrap().is_empty());
    std::os::unix::fs::symlink(
        temp.path().join("outside"),
        store.project_path("demo").unwrap(),
    )
    .unwrap();
    assert!(store.get("demo").is_err());
    assert!(!temp.path().join("outside").exists());
    assert_eq!(
        fs::metadata(&store.root).unwrap().permissions().mode() & 0o777,
        0o700
    );
}
/// A fixed port two projects would share is refused naming the other one, whether it is the
/// server's port or one written in a variable or an argument; a record saved before the
/// check keeps turning on and off. Ports of other services (`DB_PORT`) never count.
#[test]
fn a_fixed_port_of_another_project_is_refused_with_its_name() {
    let temp = tempfile::tempdir().unwrap();
    let store = Store::new(temp.path().join("store")).unwrap();
    let mk = |id: &str, extra: serde_json::Value| -> Project {
        let folder = temp.path().join(id);
        fs::create_dir_all(&folder).unwrap();
        let mut value = serde_json::json!({"id":id,"name":format!("Sitio {id}"),"path":folder,"domains":[format!("{id}.test")],"https":false,"kind":"astro","runtime":{},"docroot":".","services":[],"databases":[],"processes":[]});
        for (key, field) in extra.as_object().unwrap() {
            value[key] = field.clone();
        }
        serde_json::from_value(value).unwrap()
    };
    store
        .save(mk("template", serde_json::json!({"upstream": 4176})))
        .unwrap();
    for extra in [
        serde_json::json!({"upstream": 4176}),
        serde_json::json!({"env": {"PORT": "4176"}}),
        serde_json::json!({"processes": [{"name":"dev","program":"npm","args":["run","dev","--","--port","4176"],"autostart":true}]}),
        serde_json::json!({"processes": [{"name":"dev","program":"npm","args":["run","dev","--port=4176"],"autostart":true}]}),
    ] {
        assert_eq!(
            store.save(mk("kit", extra)).unwrap_err().to_string(),
            "port_in_use:4176 · Sitio template"
        );
    }
    // Someone else's port is not one the project listens on.
    let kit = store
        .save(mk("kit", serde_json::json!({"env": {"DB_PORT": "4176"}})))
        .unwrap();
    assert_ne!(kit.upstream, Some(4176));
    // A record written before the check (two projects with 5000 in PORT) still saves.
    let mut old = mk("viejo", serde_json::json!({"env": {"PORT": "5000"}}));
    old.upstream = Some(4900);
    fs::write(
        store.project_path("viejo").unwrap(),
        serde_json::to_vec(&old).unwrap(),
    )
    .unwrap();
    let mut copy = mk("copia", serde_json::json!({"env": {"PORT": "5000"}}));
    copy.upstream = Some(4901);
    fs::write(
        store.project_path("copia").unwrap(),
        serde_json::to_vec(&copy).unwrap(),
    )
    .unwrap();
    let mut viejo = store.get("viejo").unwrap();
    viejo.enabled = true;
    assert!(store.save(viejo).unwrap().enabled);
}

/// A project without a server reads with no domain, is never on and has no port; a record
/// written before this kind existed reads the same; `versions.mysql` is dropped on read and
/// gone from the next save.
#[test]
fn unserved_projects_and_retired_versions() {
    let temp = tempfile::tempdir().unwrap();
    let store = Store::new(temp.path().join("store")).unwrap();
    let p: Project = serde_json::from_value(serde_json::json!({"id":"lib","name":"Lib","path":temp.path(),"domains":[],"https":false,"kind":"unserved","runtime":{},"docroot":".","services":[],"databases":[],"processes":[{"name":"check","program":"swift","args":["test"],"autostart":true}],"enabled":true,"upstream":4500})).unwrap();
    let saved = store.save(p).unwrap();
    assert!(!saved.enabled && saved.upstream.is_none() && saved.domains.is_empty());
    let written: serde_json::Value =
        serde_json::from_slice(&fs::read(store.project_path("lib").unwrap()).unwrap()).unwrap();
    assert_eq!(written["kind"], "unserved");
    assert!(written.get("upstream").is_none());
    // A served kind still needs its domain.
    let mut served = saved.clone();
    served.kind = crate::core::model::ProjectKind::Static;
    assert_eq!(
        store.save(served).unwrap_err().to_string(),
        "invalid_domain"
    );
    let mut written = serde_json::to_value(StackConfig::default()).unwrap();
    written["versions"] = serde_json::json!({"php": "8.2", "node": "24", "mysql": "8.0"});
    fs::write(temp.path().join("store/stack.json"), written.to_string()).unwrap();
    let config = store.config().unwrap();
    assert!(!config.versions.contains_key("mysql"));
    store.save_config(&config).unwrap();
    let saved: serde_json::Value =
        serde_json::from_slice(&fs::read(temp.path().join("store/stack.json")).unwrap()).unwrap();
    assert_eq!(
        saved["versions"],
        serde_json::json!({"php": "8.2", "node": "24"})
    );
    assert!(!StackConfig::default().versions.contains_key("mysql"));
}

#[test]
fn proxied_sites_get_distinct_free_ports() {
    let temp = tempfile::tempdir().unwrap();
    let store = Store::new(temp.path().join("store")).unwrap();
    let mk = |id: &str| -> Project {
        serde_json::from_value(serde_json::json!({"id":id,"name":id,"path":temp.path(),"domains":[format!("{id}.test")],"https":true,"kind":"astro","runtime":{},"docroot":".","services":[],"databases":[],"processes":[]})).unwrap()
    };
    let a = store.save(mk("uno")).unwrap();
    let b = store.save(mk("dos")).unwrap();
    let (pa, pb) = (a.upstream.unwrap(), b.upstream.unwrap());
    assert!(pa != pb && (4400..5000).contains(&pa) && (4400..5000).contains(&pb));
    assert_eq!(
        store.save(a.clone()).unwrap().upstream,
        Some(pa),
        "an assigned port is kept"
    );
}
