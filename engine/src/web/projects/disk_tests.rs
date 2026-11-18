use super::*;
use std::process::Command;

struct Case {
    _temp: tempfile::TempDir,
    store: Store,
    root: PathBuf,
}

/// A store and a projects folder, both temporary and canonical (the real ones are never read).
fn case() -> Case {
    let temp = tempfile::tempdir().unwrap();
    let store = Store::new(temp.path().join("store")).unwrap();
    let root = temp.path().join("Proyectos");
    fs::create_dir_all(&root).unwrap();
    let root = root.canonicalize().unwrap();
    set_root(&store, &root).unwrap();
    Case {
        _temp: temp,
        store,
        root,
    }
}

/// A repository (an empty `.git` is enough for the tree) at `rel` under the projects folder.
fn repo(case: &Case, rel: &str) -> PathBuf {
    let path = case.root.join(rel);
    fs::create_dir_all(path.join(".git")).unwrap();
    path
}

fn add(case: &Case, id: &str, path: &Path) {
    let project: Project = serde_json::from_value(json!({
        "id": id, "name": id, "path": path, "domains": [format!("{id}.test")], "https": false,
        "kind": "static", "runtime": {}, "docroot": ".", "services": [], "databases": [],
        "processes": []
    }))
    .unwrap();
    case.store.save(project).unwrap();
}

fn group<'a>(groups: &'a [SiteGroup], rel: &str) -> &'a SiteGroup {
    groups
        .iter()
        .find(|g| g.path.as_deref() == Some(rel))
        .unwrap_or_else(|| panic!("no folder {rel}: {groups:?}"))
}

#[test]
fn the_tree_comes_from_the_folder() {
    let case = case();
    let a = repo(&case, "Apps/Huellitas");
    let b = repo(&case, "Apps/Salud/Salud");
    let c = repo(&case, "Apps/Salud/Salud-Web");
    fs::create_dir_all(case.root.join("Sitios/Vacia")).unwrap();
    // Hidden and dependency folders are not part of it.
    fs::create_dir_all(case.root.join(".oculta/x")).unwrap();
    fs::create_dir_all(case.root.join("node_modules/x")).unwrap();
    for (id, path) in [("huellitas", &a), ("salud", &b), ("salud-web", &c)] {
        add(&case, id, path);
    }
    set_multipart(&case.store, "Apps/Salud", true).unwrap();
    let groups = groups_view(&case.store).unwrap();
    let rels: Vec<_> = groups.iter().filter_map(|g| g.path.clone()).collect();
    assert_eq!(rels, ["Apps", "Apps/Salud", "Sitios", "Sitios/Vacia"]);
    let apps = group(&groups, "Apps");
    let salud = group(&groups, "Apps/Salud");
    assert_eq!(apps.sites, ["huellitas"]);
    assert!(apps.parent.is_none() && !apps.is_project());
    assert!(salud.is_project());
    assert_eq!(salud.sites, ["salud", "salud-web"]);
    assert_eq!(salud.parent.as_deref(), Some(apps.id.as_str()));
    assert_eq!(
        group(&groups, "Sitios/Vacia").parent,
        Some(group(&groups, "Sitios").id.clone())
    );
    // Ids of plain folders are the same every time and are valid ids.
    assert_eq!(groups, groups_view(&case.store).unwrap());
    assert!(groups.iter().all(|g| crate::core::validate::id(&g.id, 40)));
}

#[test]
fn a_project_moved_in_finder_is_followed_keeping_its_record() {
    let case = case();
    let old = repo(&case, "Apps/Tienda");
    add(&case, "tienda", &old);
    let before = case.store.get("tienda").unwrap();
    assert!(reconcile(&case.store).unwrap().is_empty());
    // The user moves it in Finder.
    fs::create_dir_all(case.root.join("Sitios")).unwrap();
    let new = case.root.join("Sitios/Tienda");
    fs::rename(&old, &new).unwrap();
    assert!(
        case.store
            .folder_missing()
            .unwrap()
            .iter()
            .any(|p| p.id == "tienda")
    );
    let followed = reconcile(&case.store).unwrap();
    assert_eq!(followed.len(), 1);
    assert_eq!(followed[0].to, new);
    let after = case.store.get("tienda").unwrap();
    assert_eq!(after.path, new);
    assert_eq!(after.domains, before.domains);
    assert_eq!(after.processes, before.processes);
    assert_eq!(load(&case.store).unwrap().moves.len(), 1);
    // Nothing else to follow the second time.
    assert!(reconcile(&case.store).unwrap().is_empty());
}

#[test]
fn a_copy_of_the_repository_is_found_by_its_first_commit_and_remote() {
    let case = case();
    let old = repo(&case, "Viejo/api");
    fs::remove_dir_all(old.join(".git")).unwrap();
    let run = |args: &[&str]| {
        assert!(
            Command::new("git")
                .args(["-c", "user.name=QA", "-c", "user.email=qa@ejemplo.test"])
                .args(args)
                .current_dir(&old)
                .env("GIT_CONFIG_GLOBAL", "/dev/null")
                .env("GIT_CONFIG_SYSTEM", "/dev/null")
                .output()
                .unwrap()
                .status
                .success()
        );
    };
    run(&["init", "-q"]);
    run(&["commit", "-q", "--allow-empty", "-m", "primero"]);
    run(&["remote", "add", "origin", "https://ejemplo.test/qa/api.git"]);
    add(&case, "api", &old);
    reconcile(&case.store).unwrap();
    // Copied (another inode) and the original removed: the name changed too.
    let new = case.root.join("Nuevo/servicio");
    fs::create_dir_all(new.parent().unwrap()).unwrap();
    assert!(
        Command::new("cp")
            .arg("-R")
            .arg(&old)
            .arg(&new)
            .status()
            .unwrap()
            .success()
    );
    fs::remove_dir_all(&old).unwrap();
    let followed = reconcile(&case.store).unwrap();
    assert_eq!(followed.len(), 1, "{followed:?}");
    assert_eq!(case.store.get("api").unwrap().path, new);
}

#[test]
fn two_possible_folders_are_left_to_the_user() {
    let case = case();
    let old = repo(&case, "uno/app");
    add(&case, "app", &old);
    reconcile(&case.store).unwrap();
    fs::remove_dir_all(&old).unwrap();
    // Without a recorded identity both are possible by name: nothing is chosen.
    let mut disk = load(&case.store).unwrap();
    disk.identities.clear();
    case.store.save_document("disk", &disk).unwrap();
    repo(&case, "dos/app");
    repo(&case, "tres/app");
    assert!(reconcile(&case.store).unwrap().is_empty());
    assert_eq!(case.store.folder_missing().unwrap().len(), 1);
}

#[test]
fn a_deleted_folder_leaves_the_project_missing_and_nothing_else() {
    let case = case();
    let path = repo(&case, "Apps/Efimero");
    add(&case, "efimero", &path);
    reconcile(&case.store).unwrap();
    fs::remove_dir_all(&path).unwrap();
    assert!(reconcile(&case.store).unwrap().is_empty());
    let missing = case.store.folder_missing().unwrap();
    assert_eq!(missing[0].id, "efimero");
    // The record is as it was and the folder it was in is still a folder.
    assert_eq!(missing[0].path, path);
    assert!(
        groups_view(&case.store)
            .unwrap()
            .iter()
            .any(|g| g.path.as_deref() == Some("Apps"))
    );
    assert!(
        groups_view(&case.store)
            .unwrap()
            .iter()
            .all(|g| g.sites.is_empty())
    );
}

#[test]
fn a_new_repository_is_offered_and_never_added() {
    let case = case();
    let known = repo(&case, "Apps/Conocido");
    add(&case, "conocido", &known);
    repo(&case, "Apps/Nuevo");
    let state = state(&case.store, None).unwrap();
    let fresh = state["newRepos"].as_array().unwrap();
    assert_eq!(fresh.len(), 1);
    assert_eq!(fresh[0]["name"], "Nuevo");
    assert_eq!(fresh[0]["folder"], json!(folder_id("Apps")));
    assert_eq!(case.store.list().unwrap().len(), 1);
}

#[test]
fn folders_with_repositories_of_one_prefix_are_suggested() {
    let case = case();
    repo(&case, "Apps/Salud/Salud");
    repo(&case, "Apps/Salud/Salud-Web");
    repo(&case, "Apps/Mesh");
    repo(&case, "Apps/Huellitas");
    repo(&case, "Otros/uno");
    repo(&case, "Otros/dos");
    let state = state(&case.store, None).unwrap();
    let suggestions = state["suggestions"].as_array().unwrap();
    assert_eq!(suggestions.len(), 1, "{suggestions:?}");
    assert_eq!(suggestions[0]["path"], "Apps/Salud");
    // Marked, it is not suggested again.
    set_multipart(&case.store, "Apps/Salud", true).unwrap();
    assert!(
        self::state(&case.store, None).unwrap()["suggestions"]
            .as_array()
            .unwrap()
            .is_empty()
    );
}

#[test]
fn moving_a_folder_moves_its_projects_and_refuses_to_overwrite() {
    let case = case();
    let a = repo(&case, "Apps/Salud/Salud");
    add(&case, "salud", &a);
    set_multipart(&case.store, "Apps/Salud", true).unwrap();
    fs::create_dir_all(case.root.join("Plataforma")).unwrap();
    let moved = move_into(
        &case.store,
        &case.root.join("Apps/Salud"),
        &case.root.join("Plataforma"),
    )
    .unwrap();
    assert_eq!(moved["projects"], json!(["salud"]));
    assert_eq!(
        case.store.get("salud").unwrap().path,
        case.root.join("Plataforma/Salud/Salud")
    );
    assert!(!case.root.join("Apps/Salud").exists());
    // The folder of several parts is the same one, in its new place.
    let groups = groups_view(&case.store).unwrap();
    assert!(group(&groups, "Plataforma/Salud").is_project());
    // Renaming.
    rename_folder(
        &case.store,
        &case.root.join("Plataforma/Salud"),
        "Bienestar",
    )
    .unwrap();
    assert_eq!(
        case.store.get("salud").unwrap().path,
        case.root.join("Plataforma/Bienestar/Salud")
    );
    // Nothing is overwritten, nothing leaves the projects folder, nothing goes into itself.
    repo(&case, "Apps/Bienestar");
    let err = |r: Result<Value>| r.unwrap_err().to_string();
    assert_eq!(
        err(move_into(
            &case.store,
            &case.root.join("Apps/Bienestar"),
            &case.root.join("Plataforma")
        )),
        "folder_exists"
    );
    assert_eq!(
        err(move_into(
            &case.store,
            &case.root.join("Plataforma"),
            &case.root.join("Plataforma/Bienestar")
        )),
        "move_into_itself"
    );
    assert_eq!(
        err(move_into(
            &case.store,
            &case.root.join("Plataforma"),
            Path::new("/tmp")
        )),
        "invalid_path"
    );
    assert_eq!(
        err(rename_folder(&case.store, &case.root.join("Apps"), "a/b")),
        "invalid_folder"
    );
}

#[test]
fn only_empty_folders_are_removed() {
    let case = case();
    let created = create_folder(&case.store, &case.root, "Nueva").unwrap();
    assert!(Path::new(created["path"].as_str().unwrap()).is_dir());
    assert_eq!(
        create_folder(&case.store, &case.root, "Nueva")
            .unwrap_err()
            .to_string(),
        "folder_exists"
    );
    fs::write(case.root.join("Nueva/.DS_Store"), "").unwrap();
    remove_folder(&case.store, &case.root.join("Nueva")).unwrap();
    assert!(!case.root.join("Nueva").exists());
    repo(&case, "Llena/repo");
    assert_eq!(
        remove_folder(&case.store, &case.root.join("Llena"))
            .unwrap_err()
            .to_string(),
        "folder_not_empty"
    );
    assert_eq!(
        remove_folder(&case.store, &case.root)
            .unwrap_err()
            .to_string(),
        "invalid_path"
    );
}

fn legacy(case: &Case, groups: Vec<SiteGroup>) {
    case.store.save_groups(groups).unwrap();
}

fn old_group(id: &str, name: &str, sites: &[&str], kind: &str) -> SiteGroup {
    SiteGroup {
        id: id.into(),
        name: name.into(),
        sites: sites.iter().map(|s| s.to_string()).collect(),
        kind: kind.into(),
        ..Default::default()
    }
}

#[test]
fn the_groups_file_is_compared_with_the_disk_and_converted() {
    let case = case();
    for (id, rel) in [
        ("uno", "Apps/Uno"),
        ("dos", "Apps/Dos"),
        ("salud", "Apps/Salud/Salud"),
        ("salud-web", "Apps/Salud/Salud-Web"),
        ("suelto-a", "Sueltos/a"),
        ("suelto-b", "Otro/b"),
    ] {
        let path = repo(&case, rel);
        add(&case, id, &path);
    }
    legacy(
        &case,
        vec![
            old_group("apps", "Apps", &["uno", "dos"], ""),
            old_group("salud", "Salud", &["salud", "salud-web"], "project"),
            old_group("mezcla", "Mezcla", &["suelto-a", "suelto-b"], ""),
        ],
    );
    let before = fs::read(case.store.root().join("groups.json")).unwrap();
    // The sidebar stays on the groups until the user decides what to do with what does not match.
    let pending = state(&case.store, None).unwrap();
    assert_eq!(pending["enabled"], false);
    let matches = pending["migration"]["matches"].as_array().unwrap();
    assert_eq!(matches.len(), 2);
    let proposals = pending["migration"]["proposals"].as_array().unwrap();
    assert_eq!(proposals.len(), 1);
    assert_eq!(proposals[0]["name"], "Mezcla");
    assert_eq!(proposals[0]["moves"].as_array().unwrap().len(), 2);
    assert!(
        case.root.join("Sueltos/a").exists(),
        "the preview moves nothing"
    );
    assert_eq!(
        fs::read(case.store.root().join("groups.json")).unwrap(),
        before
    );

    migrate(&case.store, true).unwrap();
    assert!(load(&case.store).unwrap().enabled);
    assert_eq!(
        fs::read(case.store.root().join("groups.pre-disk.json")).unwrap(),
        before
    );
    assert_eq!(
        case.store.get("suelto-a").unwrap().path,
        case.root.join("Mezcla/a")
    );
    assert!(case.root.join("Mezcla/b").is_dir());
    let groups = groups_view(&case.store).unwrap();
    assert_eq!(group(&groups, "Apps").sites, ["dos", "uno"]);
    let salud = group(&groups, "Apps/Salud");
    assert!(salud.is_project() && salud.id == "salud");
    assert!(
        group(&groups, "Mezcla")
            .sites
            .contains(&"suelto-a".to_string())
    );
    // The file is still one the previous version reads.
    assert!(
        case.store
            .groups()
            .unwrap()
            .iter()
            .any(|g| g.id == "mezcla")
    );
    // Going back to the groups is one switch.
    set_enabled(&case.store, false).unwrap();
    assert!(!load(&case.store).unwrap().enabled);
}

#[test]
fn leaving_the_rest_as_it_is_moves_nothing() {
    let case = case();
    let a = repo(&case, "A/a");
    let b = repo(&case, "B/b");
    add(&case, "a", &a);
    add(&case, "b", &b);
    legacy(
        &case,
        vec![old_group("mezcla", "Mezcla", &["a", "b"], "project")],
    );
    migrate(&case.store, false).unwrap();
    assert!(a.exists() && b.exists());
    // A group that got no place is not in the tree, but stays in the file.
    assert!(
        groups_view(&case.store)
            .unwrap()
            .iter()
            .all(|g| !g.is_project())
    );
    assert!(
        case.store
            .groups()
            .unwrap()
            .iter()
            .any(|g| g.id == "mezcla")
    );
}

#[test]
fn a_new_store_follows_the_disk_from_the_start() {
    let case = case();
    assert_eq!(state(&case.store, None).unwrap()["enabled"], true);
}

#[test]
fn the_fingerprint_changes_with_the_folders_only() {
    let case = case();
    repo(&case, "Apps/a");
    let first = fingerprint(&case.store).unwrap();
    assert_eq!(first, fingerprint(&case.store).unwrap());
    fs::write(case.root.join("Apps/a/archivo.txt"), "x").unwrap();
    assert_eq!(first, fingerprint(&case.store).unwrap());
    fs::rename(case.root.join("Apps"), case.root.join("Aplicaciones")).unwrap();
    assert_ne!(first, fingerprint(&case.store).unwrap());
}
