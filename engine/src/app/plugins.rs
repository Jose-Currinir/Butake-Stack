//! Tools: what the user chooses on top of Stack's base (see docs/herramientas.md). In this
//! phase every plugin is a module compiled into the signed app that is only registered and
//! enabled; what a plugin downloads (if anything) is a resource from the official catalog, with
//! its SHA-256 and the user's confirmation, like the engines.
use crate::core::json;
use crate::core::store::Store;
use crate::core::time::now_secs;
use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};
use std::{collections::BTreeMap, path::PathBuf};

/// One entry of the catalog, as the app shows it.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Plugin {
    pub id: &'static str,
    pub version: &'static str,
    /// Bytes to download; 0 = it ships inside the app.
    pub size: u64,
    /// "builtin" or an https URL of the official release.
    pub source: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sha256: Option<&'static str>,
    /// Pieces of the base or of macOS it relies on.
    pub requires: &'static [&'static str],
    pub installed: bool,
    pub enabled: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub installed_version: Option<String>,
    pub installed_at: u64,
    /// Whether it keeps data of its own (offered for removal on uninstall).
    pub has_data: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct State {
    pub version: String,
    pub enabled: bool,
    #[serde(default)]
    pub installed_at: u64,
}

struct Spec {
    id: &'static str,
    version: &'static str,
    requires: &'static [&'static str],
}

const CATALOG: &[Spec] = &[
    Spec {
        id: "vault",
        version: "1.0.0",
        requires: &["keychain"],
    },
    Spec {
        id: "database-client",
        version: "1.0.0",
        requires: &["engine-clients", "ssh-keys"],
    },
    Spec {
        id: "ssh-terminal",
        version: "1.0.0",
        requires: &["/usr/bin/ssh", "ssh-keys"],
    },
    Spec {
        id: "mail",
        version: "1.0.0",
        requires: &["daemon"],
    },
    Spec {
        id: "dumps",
        version: "1.0.0",
        requires: &["daemon"],
    },
    Spec {
        id: "aws",
        version: "1.0.0",
        requires: &["aws-cli", "keychain"],
    },
    Spec {
        id: "gcp",
        version: "1.0.0",
        requires: &["gcloud"],
    },
    Spec {
        id: "git",
        version: "1.0.0",
        requires: &["git"],
    },
    Spec {
        id: "skills",
        version: "1.0.0",
        requires: &[],
    },
];

fn is_receiver(id: &str) -> bool {
    matches!(id, "mail" | "dumps")
}

fn default_state() -> State {
    State {
        version: "1.0.0".into(),
        enabled: true,
        installed_at: 0,
    }
}

fn file(store: &Store) -> Result<PathBuf> {
    Ok(store.directory("config")?.join("plugins.json"))
}

/// What the user installed. Without a file (Stack 1.3.3 and earlier), the database client is
/// installed and enabled: it was part of the app.
pub fn states(store: &Store) -> Result<BTreeMap<String, State>> {
    let path = file(store)?;
    let mut states: BTreeMap<String, State> = if path.exists() {
        json::read_regular(&path, None)?
    } else {
        BTreeMap::from([("database-client".into(), default_state())])
    };
    states.retain(|id, _| CATALOG.iter().any(|s| s.id == id));
    states.entry("vault".into()).or_insert_with(default_state);

    // Receiver configuration wins over older catalog entries: it is what the daemon loads.
    let config = store.config()?;
    for (id, enabled) in [
        ("mail", config.mail.map(|m| m.enabled)),
        ("dumps", config.dumps.map(|d| d.enabled)),
    ] {
        states.remove(id);
        if let Some(enabled) = enabled {
            states.insert(
                id.into(),
                State {
                    enabled,
                    ..default_state()
                },
            );
        }
    }
    Ok(states)
}

fn save(store: &Store, states: &BTreeMap<String, State>) -> Result<()> {
    let local: BTreeMap<_, _> = states.iter().filter(|(id, _)| !is_receiver(id)).collect();
    json::write(&file(store)?, &local)
}

/// Reads, changes and writes `plugins.json` under the store's lock: two processes that turn on two
/// different tools at the same time (the app and the command line) both keep their change.
fn change_states(store: &Store, change: impl FnOnce(&mut BTreeMap<String, State>)) -> Result<()> {
    let _lock = store.mutation_lock()?;
    let mut states = states(store)?;
    change(&mut states);
    save(store, &states)
}

fn has_data(store: &Store, id: &str) -> bool {
    match id {
        "database-client" => crate::db::client::saved(store)
            .map(|l| !l.is_empty())
            .unwrap_or(false),
        "ssh-terminal" => crate::ssh::hosts::list(store)
            .map(|l| !l.is_empty())
            .unwrap_or(false),
        "vault" => store.root().join("vault").exists(),
        "git" => crate::git::repositories::has_data(store),
        "skills" => crate::skills::has_data(store),
        "mail" => store
            .directory("mail")
            .ok()
            .and_then(|d| std::fs::read_dir(d).ok())
            .is_some_and(|mut d| d.next().is_some()),
        _ => false,
    }
}

pub fn catalog(store: &Store) -> Result<Vec<Plugin>> {
    let states = states(store)?;
    Ok(CATALOG
        .iter()
        .map(|spec| {
            let state = states.get(spec.id);
            Plugin {
                id: spec.id,
                version: spec.version,
                size: 0,
                source: "builtin",
                sha256: None,
                requires: spec.requires,
                installed: state.is_some(),
                enabled: state.is_some_and(|s| s.enabled),
                installed_version: state.map(|s| s.version.clone()),
                installed_at: state.map(|s| s.installed_at).unwrap_or(0),
                has_data: has_data(store, spec.id),
            }
        })
        .collect())
}

pub fn enabled(store: &Store, id: &str) -> bool {
    states(store)
        .map(|s| s.get(id).is_some_and(|s| s.enabled))
        .unwrap_or(false)
}

/// The tool a method belongs to; `None` for the base. The engine's dispatch asks this before any
/// other step, so every method of a tool answers `plugin_disabled` while it is off. The SSH keys
/// (`sshKey*`) are the base's: database tunnels and the Terminal share them. `gitStatus` too (the
/// branch and changes of every project); the Git tool's names are the ones in `git::METHODS`.
pub fn tool_of(method: &str) -> Option<&'static str> {
    if method.starts_with("sshKey") {
        None
    } else if method.starts_with("db") {
        Some("database-client")
    } else if method.starts_with("ssh") {
        Some("ssh-terminal")
    } else if method.starts_with("aws") {
        Some("aws")
    } else if method.starts_with("gcp") {
        Some("gcp")
    } else if method.starts_with("skills") {
        Some("skills")
    } else if crate::git::is_method(method) {
        Some("git")
    } else if method.starts_with("mail") || method == "setMail" {
        Some("mail")
    } else if method.starts_with("dumps") || method == "setDumps" {
        Some("dumps")
    } else {
        None
    }
}

/// Fails with `plugin_disabled` when a plugin's methods are called while it is off: the UI is not
/// the only gate.
pub fn require(store: &Store, id: &str) -> Result<()> {
    ensure!(enabled(store, id), "plugin_disabled");
    Ok(())
}

fn spec(id: &str) -> Result<&'static Spec> {
    CATALOG
        .iter()
        .find(|s| s.id == id)
        .ok_or_else(|| anyhow::anyhow!("unknown_plugin"))
}

/// Turns a tool on or off. Every tool ships inside the app, so turning on one that was never
/// registered registers it (nothing is downloaded).
pub fn set_enabled(store: &Store, id: &str, on: bool) -> Result<Vec<Plugin>> {
    let spec = spec(id)?;
    if is_receiver(id) {
        update_receiver_config(store, |config| {
            match id {
                "mail" => config.mail.get_or_insert_with(Default::default).enabled = on,
                "dumps" => config.dumps.get_or_insert_with(Default::default).enabled = on,
                _ => unreachable!(),
            }
            Ok(())
        })?;
        return catalog(store);
    }
    change_states(store, |states| {
        states
            .entry(id.into())
            .or_insert(State {
                version: spec.version.into(),
                enabled: on,
                installed_at: now_secs(),
            })
            .enabled = on;
    })?;
    if !on {
        stop(store, id);
    }
    catalog(store)
}

/// A stopped supervisor reads the saved intent at startup. A running supervisor must
/// acknowledge reload, or the caller can show the failure and re-read the saved state.
pub fn update_receiver_config(
    store: &Store,
    change: impl FnOnce(&mut crate::core::model::StackConfig) -> Result<()>,
) -> Result<crate::core::model::StackConfig> {
    let config = store.update_config(change)?;
    if let Err(error) = crate::daemon::request_sync(store, "reload", serde_json::json!({}), false) {
        let stopped = error.downcast_ref::<std::io::Error>().is_some_and(|io| {
            matches!(
                io.kind(),
                std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused
            )
        });
        if !stopped {
            return Err(error);
        }
    }
    Ok(config)
}

/// What a plugin leaves running is stopped when it is turned off or removed.
fn stop(store: &Store, id: &str) {
    match id {
        "database-client" => {
            if let Ok(list) = crate::db::client::saved(store) {
                for connection in list {
                    crate::db::client::close_tunnel(store, &connection.id);
                }
            }
        }
        "ssh-terminal" => crate::ssh::hosts::stop_all(store),
        _ => {}
    }
}

/// Unregisters a plugin; its data stays unless `delete_data` (saved hosts or connections; the SSH
/// keys belong to the base and are never removed here).
pub fn remove(store: &Store, id: &str, delete_data: bool, confirmed: bool) -> Result<Vec<Plugin>> {
    spec(id)?;
    ensure!(confirmed, "confirmation_required");
    // The vault's keys and files are only removed from inside the vault, never from here.
    ensure!(!(delete_data && id == "vault"), "vault_data_kept");
    ensure!(states(store)?.contains_key(id), "plugin_not_installed");
    if is_receiver(id) {
        set_enabled(store, id, false)?;
        if delete_data && id == "mail" {
            crate::web::tools::mail::delete(&store.directory("mail")?, None)?;
        }
        return catalog(store);
    }
    stop(store, id);
    if delete_data {
        match id {
            "database-client" => {
                for connection in crate::db::client::saved(store)? {
                    crate::db::client::delete(store, &connection.id)?;
                }
                // Also what Stack's own connections kept (they are not saved ones).
                crate::db::history::forget_all(store)?;
            }
            "ssh-terminal" => crate::ssh::hosts::delete_all(store)?,
            "git" => crate::git::repositories::delete_all(store)?,
            "skills" => crate::skills::delete_all(store)?,
            _ => {}
        }
    }
    // A tool that is on by default stays registered, turned off, so it doesn't come back on by itself.
    change_states(store, |states| {
        if id == "vault" {
            if let Some(state) = states.get_mut(id) {
                state.enabled = false;
            }
        } else {
            states.remove(id);
        }
    })?;
    catalog(store)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn database_client_stays_on_for_existing_users_and_plugins_toggle() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::new(temp.path().join("store")).unwrap();
        let list = catalog(&store).unwrap();
        assert!(
            list.iter()
                .any(|p| p.id == "database-client" && p.installed && p.enabled)
        );
        assert!(list.iter().any(|p| p.id == "ssh-terminal" && !p.installed));
        assert!(require(&store, "ssh-terminal").is_err());
        set_enabled(&store, "ssh-terminal", true).unwrap();
        require(&store, "ssh-terminal").unwrap();
        set_enabled(&store, "ssh-terminal", false).unwrap();
        assert_eq!(
            require(&store, "ssh-terminal").unwrap_err().to_string(),
            "plugin_disabled"
        );
        // The database client keeps its state once the file exists.
        assert!(enabled(&store, "database-client"));
        remove(&store, "database-client", false, true).unwrap();
        assert!(!enabled(&store, "database-client"));
        assert!(set_enabled(&store, "nope", true).is_err());
        // Every tool ships in the app: turning one on registers it.
        set_enabled(&store, "database-client", true).unwrap();
        assert!(enabled(&store, "database-client"));
    }

    /// Turning on two tools at once from two processes (here, threads with their own lock) keeps
    /// both: before the store's lock, one write undid the other (the intermittent Swift test).
    #[test]
    fn tools_turned_on_at_the_same_time_all_stay_on() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("store");
        Store::new(root.clone()).unwrap();
        let tools = ["ssh-terminal", "git", "aws", "gcp"];
        let threads: Vec<_> = tools
            .into_iter()
            .map(|id| {
                let root = root.clone();
                std::thread::spawn(move || {
                    let store = Store::new(root).unwrap();
                    set_enabled(&store, id, true).unwrap();
                })
            })
            .collect();
        for thread in threads {
            thread.join().unwrap();
        }
        let store = Store::new(root).unwrap();
        for id in tools {
            assert!(enabled(&store, id), "{id} lost its change");
        }
    }

    #[test]
    fn receiver_activation_and_conflicts_share_one_source_of_truth() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::new(temp.path().join("store")).unwrap();
        for (id, port) in [("mail", 2525), ("dumps", 9912)] {
            let mut config = store.config().unwrap();
            config.ports.http = port;
            store.save_config(&config).unwrap();
            assert_eq!(
                set_enabled(&store, id, true).unwrap_err().to_string(),
                "duplicate_port"
            );
            assert!(!enabled(&store, id));
            config.ports.http = 80;
            store.save_config(&config).unwrap();
            assert!(
                set_enabled(&store, id, true)
                    .unwrap()
                    .iter()
                    .any(|p| p.id == id && p.enabled)
            );
            update_receiver_config(&store, |config| {
                match id {
                    "mail" => config.mail.as_mut().unwrap().enabled = false,
                    "dumps" => config.dumps.as_mut().unwrap().enabled = false,
                    _ => unreachable!(),
                }
                Ok(())
            })
            .unwrap();
            assert!(!enabled(&store, id));
        }
    }

    #[test]
    fn git_starts_off_and_its_data_goes_only_when_asked() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::new(temp.path().join("store")).unwrap();
        // Off for existing installations and new ones alike.
        assert!(
            catalog(&store)
                .unwrap()
                .iter()
                .any(|p| p.id == "git" && !p.installed && !p.enabled && !p.has_data)
        );
        assert_eq!(
            require(&store, "git").unwrap_err().to_string(),
            "plugin_disabled"
        );
        set_enabled(&store, "git", true).unwrap();
        require(&store, "git").unwrap();
        let repository = temp.path().join("repo");
        std::fs::create_dir_all(repository.join(".git")).unwrap();
        crate::git::repositories::opened(&store, &repository).unwrap();
        assert!(
            catalog(&store)
                .unwrap()
                .iter()
                .any(|p| p.id == "git" && p.has_data)
        );
        // Removing it keeps its data unless asked; asked, only Stack's list goes.
        remove(&store, "git", false, true).unwrap();
        assert!(crate::git::repositories::has_data(&store));
        set_enabled(&store, "git", true).unwrap();
        remove(&store, "git", true, true).unwrap();
        assert!(!crate::git::repositories::has_data(&store));
        assert!(!store.root().join("config/git").exists());
        assert!(repository.join(".git").exists());
    }

    /// Every name the engine's sources answer to (`"name" =>` arms of a `match`), read from the
    /// sources themselves so a method added later is covered without touching this test.
    fn every_method_name() -> std::collections::BTreeSet<String> {
        fn walk(dir: &std::path::Path, out: &mut std::collections::BTreeSet<String>) {
            for entry in std::fs::read_dir(dir).unwrap().flatten() {
                let path = entry.path();
                if path.is_dir() {
                    walk(&path, out);
                } else if path.extension().is_some_and(|e| e == "rs") {
                    let text = std::fs::read_to_string(&path).unwrap();
                    for line in text.lines() {
                        let line = line.trim_start();
                        let Some(arms) = line.split("=>").next().filter(|_| line.contains("=>"))
                        else {
                            continue;
                        };
                        for name in arms.split('|').map(str::trim) {
                            let name = name.split(" if ").next().unwrap_or("").trim();
                            if let Some(name) =
                                name.strip_prefix('"').and_then(|n| n.strip_suffix('"'))
                                && name.chars().all(|c| c.is_ascii_alphanumeric())
                                && !name.is_empty()
                            {
                                out.insert(name.to_string());
                            }
                        }
                    }
                }
            }
        }
        let mut names = std::collections::BTreeSet::new();
        walk(
            &std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src"),
            &mut names,
        );
        names.extend(crate::git::METHODS.iter().map(|m| m.to_string()));
        names
    }

    /// Off, every method of every tool of the catalog answers `plugin_disabled`, whatever it asks,
    /// and the tool writes nothing (Correo and Dumps included, which once answered while off).
    #[test]
    fn every_tool_method_answers_plugin_disabled_while_off() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::new(temp.path().join("store")).unwrap();
        // The database client is the only tool on for an installation without plugins.json.
        set_enabled(&store, "database-client", false).unwrap();
        let names = every_method_name();
        let mut covered = BTreeMap::<&str, usize>::new();
        for name in &names {
            let Some(tool) = tool_of(name) else { continue };
            assert!(CATALOG.iter().any(|s| s.id == tool), "{name}: {tool}");
            assert!(!enabled(&store, tool), "{tool} starts off");
            let request = serde_json::json!({
                "method": name, "id": "x", "path": temp.path(), "all": true, "confirmed": true,
            });
            let error = crate::dispatch_with(&store, name, &request).unwrap_err();
            let code = match error.downcast_ref::<crate::git::GitError>() {
                Some(failure) => failure.code.clone(),
                None => error.to_string(),
            };
            assert_eq!(code, "plugin_disabled", "{name}");
            *covered.entry(tool).or_default() += 1;
        }
        // Every tool but the vault (which lives in the app) has methods, and all were reached.
        for spec in CATALOG.iter().filter(|s| s.id != "vault") {
            assert!(covered.get(spec.id).is_some_and(|n| *n > 0), "{}", spec.id);
        }
        for method in [
            "mailChanges",
            "mailGet",
            "mailAttachment",
            "mailDelete",
            "dumpsClear",
            "setMail",
            "setDumps",
        ] {
            assert!(names.contains(method), "{method}");
        }
        // Nothing of the receivers was written while they were off.
        assert!(store.config().unwrap().mail.is_none());
        assert!(store.config().unwrap().dumps.is_none());
        // The base keeps answering: SSH keys and the projects' Git state.
        assert_eq!(tool_of("sshKeys"), None);
        assert_eq!(tool_of("gitStatus"), None);
        crate::dispatch_with(&store, "sshKeys", &serde_json::json!({})).unwrap();
    }

    #[test]
    fn vault_starts_on_and_mail_follows_its_server() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::new(temp.path().join("store")).unwrap();
        assert!(enabled(&store, "vault"));
        assert!(!enabled(&store, "mail"));
        assert!(!enabled(&store, "dumps"));
        set_enabled(&store, "mail", true).unwrap();
        assert!(store.config().unwrap().mail.unwrap().enabled);
        set_enabled(&store, "mail", false).unwrap();
        assert!(!store.config().unwrap().mail.unwrap().enabled);
        // Turned off, the vault stays off (and its data is never deleted from here).
        assert_eq!(
            remove(&store, "vault", true, true).unwrap_err().to_string(),
            "vault_data_kept"
        );
        remove(&store, "vault", false, true).unwrap();
        assert!(!enabled(&store, "vault"));
        assert!(
            catalog(&store)
                .unwrap()
                .iter()
                .any(|p| p.id == "vault" && p.installed && !p.enabled)
        );
    }
}
