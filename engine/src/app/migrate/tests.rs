//! The migration against temporary homes: plan without effects, a full run, a failure halfway with
//! an exact reversal, the checks before moving, and repeated or resumed runs. A fake `Control`
//! stands in for the daemon and launchd; nothing here touches the real folders.

use super::*;
use std::{
    cell::RefCell,
    collections::BTreeMap,
    os::unix::fs::{symlink, PermissionsExt},
};

#[derive(Default)]
struct Fake {
    running: Vec<String>,
    agent: bool,
    open: Vec<String>,
    fail_start_in: Option<PathBuf>,
    calls: RefCell<Vec<String>>,
}

fn name(root: &Path) -> String {
    root.file_name().unwrap().to_string_lossy().into_owned()
}

impl Control for Fake {
    fn running(&self, _root: &Path) -> Vec<String> {
        self.running.clone()
    }
    fn agent_loaded(&self) -> bool {
        self.agent
    }
    fn stop(&self, root: &Path, _agent: bool) -> Result<()> {
        self.calls.borrow_mut().push(format!("stop {}", name(root)));
        Ok(())
    }
    fn open_files(&self, _root: &Path) -> Result<Vec<String>> {
        Ok(self.open.clone())
    }
    fn start(
        &self,
        root: &Path,
        agent: bool,
        plist: &Path,
        running: &[String],
    ) -> Result<Vec<Value>> {
        self.calls
            .borrow_mut()
            .push(format!("start {}", name(root)));
        // The agent always comes back on the folder its plist names.
        if agent {
            assert!(fs::read_to_string(plist)
                .unwrap()
                .contains(&format!("{}<", root.display())));
        }
        if self.fail_start_in.as_deref() == Some(root) {
            bail!("migration_start_failed:[{{\"id\":\"stack.mysql\",\"running\":false}}]");
        }
        Ok(running
            .iter()
            .map(|id| json!({"id": id, "running": true, "answers": true}))
            .collect())
    }
}

struct Home {
    _temp: tempfile::TempDir,
    layout: Layout,
}

fn home() -> Home {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().canonicalize().unwrap();
    let layout = Layout::for_home(&home);
    let old = &layout.old;
    let o = old.display().to_string();
    let w = |path: &Path, text: &str| {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, text).unwrap();
    };
    w(&old.join("stack.json"), "{}");
    w(
        &old.join("projects/app.json"),
        &format!(
            "{{\"id\":\"app\",\"path\":\"{}\"}}",
            home.join("Projects/app").display()
        ),
    );
    w(
        &old.join("config/mysql/my.cnf"),
        &format!("[mysqld]\ndatadir={o}/data/mysql\nsocket={o}/run/mysql.sock\n"),
    );
    fs::set_permissions(
        old.join("config/mysql/my.cnf"),
        fs::Permissions::from_mode(0o600),
    )
    .unwrap();
    w(&old.join("config/php/8.4/php.ini"), "memory_limit=512M\n");
    symlink(old.join("config/php/8.4"), old.join("config/php/current")).unwrap();
    w(&old.join("runtimes/node/22/bin/node"), "binario");
    w(&old.join("runtimes/python/3.13/bin/python3"), "binario");
    w(
        &old.join("data/mysql/ibdata1"),
        &format!("bytes {o} de la base"),
    );
    w(
        &old.join("logs/stack.mysql.log"),
        &format!("arranca en {o}\n"),
    );
    w(
        &layout.launch_agent(),
        &format!("<plist><key>BUTAKE_STACK_HOME</key><string>{o}</string></plist>\n"),
    );
    w(&home.join(".zprofile"), &format!("export A=1\n# >>> Butake Stack >>>\nexport PHPRC=\"{o}/config/php/current\"\n# <<< Butake Stack <<<\n"));
    w(&home.join(".aws/config"), &format!("[profile dentro]\ncredential_process = \"{o}/bin/ayuda\" aws-credential dentro\n# {o}\n[profile fuera]\ncredential_process = \"/Applications/Stack.app/Contents/Resources/butake-stack\" aws-credential fuera\n"));
    fs::create_dir_all(home.join(".local/bin")).unwrap();
    symlink(
        old.join("runtimes/node/22/bin/node"),
        home.join(".local/bin/node"),
    )
    .unwrap();
    symlink("/usr/bin/true", home.join(".local/bin/ajeno")).unwrap();
    w(
        &home.join("Projects/app/.venv/pyvenv.cfg"),
        &format!("home = {o}/runtimes/python/3.13/bin\n"),
    );
    fs::create_dir_all(home.join("Projects/app/.venv/bin")).unwrap();
    symlink(
        old.join("runtimes/python/3.13/bin/python3"),
        home.join("Projects/app/.venv/bin/python"),
    )
    .unwrap();
    Home {
        _temp: temp,
        layout,
    }
}

/// Every entry of the home: kind, bytes or link target, permissions.
fn snapshot(
    root: &Path,
    skip: &dyn Fn(&Path) -> bool,
) -> BTreeMap<PathBuf, (String, Vec<u8>, u32)> {
    let mut found = BTreeMap::new();
    let mut pending = vec![root.to_path_buf()];
    while let Some(folder) = pending.pop() {
        for entry in fs::read_dir(&folder).unwrap().flatten() {
            let path = entry.path();
            if skip(&path) {
                continue;
            }
            let meta = fs::symlink_metadata(&path).unwrap();
            let relative = path.strip_prefix(root).unwrap().to_path_buf();
            let mode = meta.permissions().mode() & 0o7777;
            if meta.file_type().is_symlink() {
                found.insert(
                    relative,
                    (
                        "link".into(),
                        fs::read_link(&path).unwrap().into_os_string().into_vec(),
                        0,
                    ),
                );
            } else if meta.is_dir() {
                found.insert(relative, ("dir".into(), vec![], mode));
                pending.push(path);
            } else {
                found.insert(relative, ("file".into(), fs::read(&path).unwrap(), mode));
            }
        }
    }
    found
}
use std::os::unix::ffi::OsStringExt;

fn everything(_: &Path) -> bool {
    false
}
/// What a failed run may leave on purpose: the backup next to the folder and the journal.
fn kept_on_failure(path: &Path) -> bool {
    let text = path.to_string_lossy();
    text.contains("(copia ") || text.ends_with(JOURNAL)
}

#[test]
fn the_plan_changes_nothing_and_lists_every_path() {
    let h = home();
    let fake = Fake {
        running: vec!["stack.mysql".into()],
        agent: true,
        ..Fake::default()
    };
    let before = snapshot(&h.layout.home, &everything);
    let plan = plan(&h.layout, &fake).unwrap();
    assert_eq!(before, snapshot(&h.layout.home, &everything));
    assert_eq!(plan["state"], "ready");
    assert_eq!(plan["running"], json!(["stack.mysql"]));
    assert_eq!(plan["agent"], true);
    assert_eq!(plan["sameVolume"], true);
    let places: Vec<String> = plan["rewrites"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| {
            format!(
                "{} {}",
                r["place"].as_str().unwrap(),
                Path::new(r["path"].as_str().unwrap())
                    .file_name()
                    .unwrap()
                    .to_string_lossy()
            )
        })
        .collect();
    for expected in [
        "data my.cnf",
        "data current",
        "launchAgent cl.butake.stack.daemon.plist",
        "terminal .zprofile",
        "aws config",
        "links node",
        "project pyvenv.cfg",
        "project python",
    ] {
        assert!(
            places.contains(&expected.to_string()),
            "{expected} in {places:?}"
        );
    }
    assert_eq!(
        places.len(),
        8,
        "{places:?}: never data/, logs/ or foreign links"
    );
    assert!(plan["backup"]
        .as_str()
        .unwrap()
        .contains("Butake Stack (copia "));
}

#[test]
fn a_migration_moves_the_folder_and_rewrites_every_path() {
    let h = home();
    let (old, new) = (h.layout.old.clone(), h.layout.new.clone());
    let fake = Fake {
        running: vec!["stack.mysql".into()],
        agent: true,
        ..Fake::default()
    };
    let result = run(&h.layout, &fake, Cut::None).unwrap();
    assert_eq!(result["ok"], true, "{result}");
    assert!(!old.exists() && new.join("stack.json").is_file());
    let (o, n) = (old.display().to_string(), new.display().to_string());
    let read = |p: PathBuf| fs::read_to_string(p).unwrap();
    assert_eq!(
        read(new.join("config/mysql/my.cnf")),
        format!("[mysqld]\ndatadir={n}/data/mysql\nsocket={n}/run/mysql.sock\n")
    );
    assert_eq!(
        fs::metadata(new.join("config/mysql/my.cnf"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
    assert_eq!(
        fs::read_link(new.join("config/php/current")).unwrap(),
        new.join("config/php/8.4")
    );
    assert_eq!(
        read(new.join("data/mysql/ibdata1")),
        format!("bytes {o} de la base"),
        "databases are never edited"
    );
    assert_eq!(
        read(new.join("logs/stack.mysql.log")),
        format!("arranca en {o}\n")
    );
    assert!(read(h.layout.launch_agent()).contains(&format!("<string>{n}</string>")));
    assert!(read(h.layout.home.join(".zprofile"))
        .contains(&format!("PHPRC=\"{n}/config/php/current\"")));
    let aws = read(h.layout.home.join(".aws/config"));
    assert!(
        aws.contains(&format!("credential_process = \"{n}/bin/ayuda\""))
            && aws.contains(&format!("# {o}\n"))
    );
    assert!(aws.contains(
        "\"/Applications/Stack.app/Contents/Resources/butake-stack\" aws-credential fuera"
    ));
    assert_eq!(
        fs::read_link(h.layout.home.join(".local/bin/node")).unwrap(),
        new.join("runtimes/node/22/bin/node")
    );
    assert_eq!(
        fs::read_link(h.layout.home.join(".local/bin/ajeno")).unwrap(),
        Path::new("/usr/bin/true")
    );
    assert_eq!(
        read(h.layout.home.join("Projects/app/.venv/pyvenv.cfg")),
        format!("home = {n}/runtimes/python/3.13/bin\n")
    );
    // The backup is the folder as it was, next to it.
    let backup = PathBuf::from(result["backup"].as_str().unwrap());
    assert_eq!(backup.parent(), old.parent());
    assert!(read(backup.join("config/mysql/my.cnf")).contains(&o));
    assert_eq!(journal(&new).unwrap().phase, "done");
    assert!(!new.join(".migration").exists());
    assert_eq!(
        *fake.calls.borrow(),
        ["stop Butake Stack", "stop Stack", "start Stack"]
    );
    assert_eq!(crate::core::store::Store::resolve(&h.layout.home), new);
}

#[test]
fn a_failure_after_the_move_puts_everything_back_exactly() {
    let h = home();
    let before = snapshot(&h.layout.home, &kept_on_failure);
    let fake = Fake {
        running: vec!["stack.mysql".into()],
        agent: true,
        fail_start_in: Some(h.layout.new.clone()),
        ..Fake::default()
    };
    let result = run(&h.layout, &fake, Cut::None).unwrap();
    assert_eq!(result["ok"], false);
    assert_eq!(result["step"], "start");
    assert_eq!(result["error"], "migration_start_failed");
    assert_eq!(result["reverted"], true);
    assert_eq!(result["report"][0]["id"], "stack.mysql");
    assert_eq!(
        before,
        snapshot(&h.layout.home, &kept_on_failure),
        "every byte, link and permission as before"
    );
    assert!(!h.layout.new.exists());
    assert_eq!(journal(&h.layout.old).unwrap().phase, "reverted");
    assert!(!blocks_daemon(&h.layout.old));
    // What ran runs again, on the old folder.
    assert_eq!(fake.calls.borrow().last().unwrap(), "start Butake Stack");
    assert_eq!(
        crate::core::store::Store::resolve(&h.layout.home),
        h.layout.old
    );
    // And the next run goes through.
    let fake = Fake {
        agent: true,
        ..Fake::default()
    };
    assert_eq!(run(&h.layout, &fake, Cut::None).unwrap()["ok"], true);
}

#[test]
fn nothing_moves_after_an_unclean_shutdown_or_with_files_open() {
    let h = home();
    fs::create_dir_all(h.layout.old.join("run")).unwrap();
    fs::write(h.layout.old.join("run/mysql.pid"), "123").unwrap();
    let before = snapshot(&h.layout.home, &kept_on_failure);
    let result = run(&h.layout, &Fake::default(), Cut::None).unwrap();
    assert_eq!(
        (result["ok"].clone(), result["error"].clone()),
        (json!(false), json!("migration_unclean_shutdown"))
    );
    assert_eq!(before, snapshot(&h.layout.home, &kept_on_failure));
    assert!(!h.layout.new.exists());
    fs::remove_file(h.layout.old.join("run/mysql.pid")).unwrap();
    let busy = Fake {
        open: vec!["mysqld (123)".into()],
        ..Fake::default()
    };
    let result = run(&h.layout, &busy, Cut::None).unwrap();
    assert_eq!(result["error"], "migration_files_open");
    assert_eq!(result["detail"], "mysqld (123)");
    assert!(!h.layout.new.exists());
    assert!(
        fs::read_dir(h.layout.old.parent().unwrap())
            .unwrap()
            .count()
            == 1,
        "no backup left behind"
    );
}

#[test]
fn a_run_cut_short_resumes_and_a_finished_one_does_nothing() {
    let h = home();
    let fake = Fake {
        running: vec!["stack.redis".into()],
        agent: true,
        ..Fake::default()
    };
    assert_eq!(run(&h.layout, &fake, Cut::AfterMove).unwrap()["cut"], true);
    assert!(
        blocks_daemon(&h.layout.new),
        "no daemon on a half-moved folder"
    );
    assert_eq!(plan(&h.layout, &fake).unwrap()["state"], "resume");
    let resumed = run(&h.layout, &fake, Cut::None).unwrap();
    assert_eq!(resumed["ok"], true, "{resumed}");
    assert!(fs::read_to_string(h.layout.launch_agent())
        .unwrap()
        .contains(&format!("{}<", h.layout.new.display())));
    let after = snapshot(&h.layout.home, &everything);
    let again = run(&h.layout, &fake, Cut::None).unwrap();
    assert_eq!(
        (again["ok"].clone(), again["already"].clone()),
        (json!(true), json!(true))
    );
    assert_eq!(after, snapshot(&h.layout.home, &everything));
    assert_eq!(plan(&h.layout, &fake).unwrap()["state"], "done");
}

#[test]
fn both_folders_with_data_are_a_conflict() {
    let h = home();
    fs::create_dir_all(h.layout.new.join("projects")).unwrap();
    assert_eq!(
        plan(&h.layout, &Fake::default()).unwrap()["state"],
        "conflict"
    );
    assert!(run(&h.layout, &Fake::default(), Cut::None).is_err());
}

#[test]
fn open_files_are_found_by_lsof() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().canonicalize().unwrap();
    let _held = fs::File::create(path.join("abierto")).unwrap();
    let found = Live { launchd: false }.open_files(&path).unwrap();
    assert!(
        found
            .iter()
            .any(|p| p.ends_with(&format!("({})", std::process::id()))),
        "{found:?}"
    );
}
