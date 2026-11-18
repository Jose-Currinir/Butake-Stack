//! The Google Cloud tool: the accounts gcloud already has on this Mac, the projects each one
//! reaches, and the Google Cloud account and project of each Stack project (see
//! docs/architecture.md, «Herramienta Google Cloud»).
//!
//! What it never does (privacy requirement R17): read or copy gcloud's credential files, run a command
//! that prints a token, create or download service account keys, change IAM, enable APIs, create
//! or delete resources, or change gcloud's active configuration. Signing in happens in a console
//! of the Terminal (the app's), where the browser and the password are the user's own.

mod accounts;
mod cli;

use crate::core::{model::GcpLink, store::Store, watch as core_watch};
use anyhow::{Result, ensure};
use cli::Cli;
use serde_json::{Value, json};
use std::path::Path;

/// Requests of the Google Cloud tool (`gcp*`); the caller checked that the tool is on.
pub fn dispatch(store: &Store, method: &str, request: &Value) -> Result<Value> {
    let records = store.directory("gcp-runs")?;
    // A run of gcloud whose engine died without ending it (see core/watch.rs) ends now.
    core_watch::reap(&records);
    let account = request["account"].as_str().unwrap_or("");
    let id = request["id"].as_str().unwrap_or("");
    let found = Cli::find();
    match method {
        "gcpAccounts" => state(store, found.as_ref(), &records),
        "gcpProjects" => {
            let cli = found.ok_or_else(|| anyhow::anyhow!("gcp_cli_missing"))?;
            Ok(json!(accounts::projects(&cli, &records, account)?))
        }
        "gcpRevoke" => {
            ensure!(request["confirmed"] == true, "confirmation_required");
            let cli = found.ok_or_else(|| anyhow::anyhow!("gcp_cli_missing"))?;
            accounts::revoke(&cli, &records, account)?;
            state(store, Some(&cli), &records)
        }
        "gcpLink" => link(
            store,
            id,
            Some(GcpLink {
                account: account.to_string(),
                project: request["project"].as_str().unwrap_or("").to_string(),
            }),
        ),
        "gcpUnlink" => link(store, id, None),
        // The link of a project of several parts, inherited by its parts without one of their own.
        "gcpLinkGroup" => link_group(
            store,
            id,
            Some(GcpLink {
                account: account.to_string(),
                project: request["project"].as_str().unwrap_or("").to_string(),
            }),
        ),
        "gcpUnlinkGroup" => link_group(store, id, None),
        _ => anyhow::bail!("unknown_method"),
    }
}

/// gcloud on this Mac (or its absence), its accounts, and which Stack projects use which.
fn state(store: &Store, cli: Option<&Cli>, records: &Path) -> Result<Value> {
    let accounts = match cli {
        Some(cli) => accounts::list(cli, records)?,
        None => vec![],
    };
    Ok(json!({
        "cli": {"installed": cli.is_some(), "path": cli.map(|c| c.program.clone())},
        "accounts": accounts,
        "links": links(store)?,
    }))
}

/// The Stack projects linked to a Google Cloud account and project.
fn links(store: &Store) -> Result<Vec<Value>> {
    Ok(store
        .list()?
        .into_iter()
        .filter_map(|project| {
            let link = project.gcp?;
            Some(json!({"id": project.id, "name": project.name,
                        "account": link.account, "project": link.project}))
        })
        .collect())
}

/// Sets (or removes) a project's link and reloads the daemon: the project's processes start
/// again with the new variables. gcloud's configuration is not touched.
fn link(store: &Store, id: &str, link: Option<GcpLink>) -> Result<Value> {
    if let Some(link) = &link {
        link.validate()?;
    }
    let mut project = store.get(id)?;
    project.gcp = link;
    let project = store.save(project)?;
    let _ = crate::daemon::request_sync(store, "reload", json!({}), false);
    Ok(serde_json::to_value(project)?)
}

/// Like `link`, for a project of several parts: its parts' processes start again with it.
fn link_group(store: &Store, id: &str, link: Option<GcpLink>) -> Result<Value> {
    let group = store.set_group_gcp(id, link)?;
    let _ = crate::daemon::request_sync(store, "reload", json!({}), false);
    Ok(serde_json::to_value(group)?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{collections::BTreeMap, fs, os::unix::fs::PermissionsExt, path::PathBuf};

    /// A temporary home with the fake gcloud and its own configuration folder: two made-up
    /// accounts, the first one active, with a project set.
    struct Fake {
        _temp: tempfile::TempDir,
        home: PathBuf,
        config: PathBuf,
        cli: Cli,
    }

    fn fake() -> Fake {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path().join("home");
        let bin = home.join(".local/bin");
        let config = home.join("gcloud-config");
        fs::create_dir_all(&bin).unwrap();
        fs::create_dir_all(config.join("configurations")).unwrap();
        let program = bin.join("gcloud");
        fs::write(&program, include_str!("testdata/gcloud")).unwrap();
        fs::set_permissions(&program, fs::Permissions::from_mode(0o755)).unwrap();
        fs::write(
            config.join("accounts"),
            "qa@ejemplo.test\notra@ejemplo.test\ndespliegue@tienda-ficticia.iam.gserviceaccount.com\n",
        )
        .unwrap();
        fs::write(config.join("active_config"), "default").unwrap();
        fs::write(
            config.join("configurations/config_default"),
            "[core]\naccount = qa@ejemplo.test\nproject = agenda-de-prueba\n",
        )
        .unwrap();
        let cli = Cli {
            program,
            home: home.clone(),
            config: Some(config.clone()),
            watched: false,
        };
        Fake {
            _temp: temp,
            home,
            config,
            cli,
        }
    }

    /// gcloud's active configuration: which one is active and what it says.
    fn active_configuration(config: &Path) -> BTreeMap<String, String> {
        let mut files = BTreeMap::new();
        files.insert(
            "active_config".into(),
            fs::read_to_string(config.join("active_config")).unwrap(),
        );
        for entry in fs::read_dir(config.join("configurations")).unwrap() {
            let path = entry.unwrap().path();
            files.insert(
                path.file_name().unwrap().to_string_lossy().into_owned(),
                fs::read_to_string(&path).unwrap(),
            );
        }
        files
    }

    fn calls(config: &Path) -> Vec<String> {
        fs::read_to_string(config.join("calls.log"))
            .unwrap_or_default()
            .lines()
            .map(String::from)
            .collect()
    }

    /// Listing accounts and projects and closing a session leave gcloud's active configuration as
    /// it was; the active account cannot be closed; and only reading commands (or the confirmed
    /// revoke) reach gcloud, with the account as `--account`, never a token or a `config` change.
    #[test]
    fn flows_never_change_the_active_configuration() {
        let fake = fake();
        let records = fake.home.join("runs");
        fs::create_dir_all(&records).unwrap();
        let before = active_configuration(&fake.config);

        let listed = accounts::list(&fake.cli, &records).unwrap();
        assert_eq!(
            listed
                .iter()
                .map(|a| (a.account.as_str(), a.kind, a.active))
                .collect::<Vec<_>>(),
            [
                (
                    "despliegue@tienda-ficticia.iam.gserviceaccount.com",
                    "service",
                    false
                ),
                ("otra@ejemplo.test", "user", false),
                ("qa@ejemplo.test", "user", true),
            ]
        );
        let projects = accounts::projects(&fake.cli, &records, "otra@ejemplo.test").unwrap();
        assert_eq!(
            projects.iter().map(|p| p.id.as_str()).collect::<Vec<_>>(),
            ["agenda-de-prueba", "tienda-ficticia"]
        );
        assert_eq!(
            accounts::revoke(&fake.cli, &records, "qa@ejemplo.test")
                .unwrap_err()
                .to_string(),
            "gcp_account_active"
        );
        assert_eq!(
            accounts::revoke(&fake.cli, &records, "nadie@ejemplo.test")
                .unwrap_err()
                .to_string(),
            "gcp_unknown_account"
        );
        accounts::revoke(&fake.cli, &records, "otra@ejemplo.test").unwrap();
        assert!(
            !accounts::list(&fake.cli, &records)
                .unwrap()
                .iter()
                .any(|a| a.account == "otra@ejemplo.test")
        );
        assert_eq!(active_configuration(&fake.config), before);

        let calls = calls(&fake.config);
        assert!(calls.contains(&"projects list --account=otra@ejemplo.test --filter=lifecycleState:ACTIVE --format=json(projectId,name,projectNumber) --limit=2000 --quiet".to_string()));
        assert!(calls.contains(&"auth revoke otra@ejemplo.test --quiet".to_string()));
        for call in &calls {
            assert!(
                call.starts_with("auth list ")
                    || call.starts_with("projects list ")
                    || call.starts_with("auth revoke "),
                "{call}"
            );
            assert!(
                !call.contains("token") && !call.contains("config "),
                "{call}"
            );
        }
    }

    /// The fake behaves like gcloud: logging in without `--no-activate` changes the active
    /// account. This is the change Stack's own sign-in (in the Terminal) avoids.
    #[test]
    fn the_fake_changes_the_configuration_like_gcloud() {
        let fake = fake();
        let records = fake.home.join("runs");
        fs::create_dir_all(&records).unwrap();
        let before = active_configuration(&fake.config);
        fake.cli
            .run(
                &records,
                &["auth", "login", "--no-activate"],
                cli::SHORT_LIMIT,
            )
            .unwrap();
        assert_eq!(active_configuration(&fake.config), before);
        fake.cli
            .run(
                &records,
                &["auth", "login", "x@ejemplo.test"],
                cli::SHORT_LIMIT,
            )
            .unwrap();
        assert_ne!(active_configuration(&fake.config), before);
    }

    /// An expired session and an unknown account become fixed codes; nothing of gcloud's text.
    #[test]
    fn failures_are_codes() {
        let fake = fake();
        let records = fake.home.join("runs");
        fs::create_dir_all(&records).unwrap();
        fs::write(fake.config.join("expired"), "otra@ejemplo.test\n").unwrap();
        for (account, code) in [
            ("otra@ejemplo.test", "gcp_session_expired"),
            ("nadie@ejemplo.test", "gcp_session_expired"),
            ("--impersonate-service-account=x@y.z", "gcp_invalid_account"),
        ] {
            assert_eq!(
                accounts::projects(&fake.cli, &records, account)
                    .unwrap_err()
                    .to_string(),
                code
            );
        }
    }

    /// A linked project's processes and consoles get the account and project; a variable the
    /// project sets by hand is kept without a link and wins with one; the stored record never
    /// holds derived variables; unlinking takes them away again.
    #[test]
    fn linked_projects_pass_the_account_to_their_processes() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::new(temp.path().join("store")).unwrap();
        let make = |id: &str, env: Value| -> crate::core::model::Project {
            let folder = temp.path().join(id);
            fs::create_dir_all(&folder).unwrap();
            serde_json::from_value(json!({
                "id": id, "name": id, "path": folder, "domains": [format!("{id}.test")],
                "https": false, "kind": "kmp", "runtime": {}, "docroot": ".", "services": [],
                "databases": [], "enabled": true, "env": env,
                "processes": [{"name": "dev", "program": "npm", "args": ["run", "dev"], "autostart": true}]}))
            .unwrap()
        };
        store.save(make("tienda", json!({}))).unwrap();
        store
            .save(make(
                "agenda",
                json!({"GOOGLE_CLOUD_PROJECT": "escrito-a-mano"}),
            ))
            .unwrap();
        let spec = |store: &Store, id: &str| {
            crate::daemon::specs(store, crate::daemon::WebFds::default())
                .unwrap()
                .into_iter()
                .find(|s| s.id == format!("{id}.dev"))
                .unwrap()
                .environment
        };
        let record = |id: &str| -> Value {
            serde_json::from_str(
                &fs::read_to_string(store.root().join(format!("projects/{id}.json"))).unwrap(),
            )
            .unwrap()
        };
        let link_to = |id: &str| GcpLink {
            account: "qa@ejemplo.test".into(),
            project: format!("{id}-ficticia"),
        };

        // Without a link: the variable written by hand stays, alone.
        let environment = spec(&store, "agenda");
        assert_eq!(environment["GOOGLE_CLOUD_PROJECT"], "escrito-a-mano");
        assert!(!environment.contains_key("CLOUDSDK_CORE_ACCOUNT"));

        let saved = link(&store, "tienda", Some(link_to("tienda"))).unwrap();
        assert_eq!(
            saved["gcp"],
            json!({"account": "qa@ejemplo.test", "project": "tienda-ficticia"})
        );
        link(&store, "agenda", Some(link_to("agenda"))).unwrap();
        assert_eq!(links(&store).unwrap().len(), 2);

        // With a link: the three variables.
        let environment = spec(&store, "tienda");
        assert_eq!(environment["CLOUDSDK_CORE_ACCOUNT"], "qa@ejemplo.test");
        assert_eq!(environment["CLOUDSDK_CORE_PROJECT"], "tienda-ficticia");
        assert_eq!(environment["GOOGLE_CLOUD_PROJECT"], "tienda-ficticia");
        let console = crate::daemon::site_shell_environment(&store, "tienda").unwrap();
        assert_eq!(console["CLOUDSDK_CORE_ACCOUNT"], "qa@ejemplo.test");
        assert_eq!(console["GOOGLE_CLOUD_PROJECT"], "tienda-ficticia");
        // With a link and a variable by hand: the project's wins, in processes and consoles.
        let environment = spec(&store, "agenda");
        assert_eq!(environment["CLOUDSDK_CORE_PROJECT"], "agenda-ficticia");
        assert_eq!(environment["GOOGLE_CLOUD_PROJECT"], "escrito-a-mano");
        let console = crate::daemon::site_shell_environment(&store, "agenda").unwrap();
        assert_eq!(console["GOOGLE_CLOUD_PROJECT"], "escrito-a-mano");
        // The stored records keep the link and the user's env, never derived variables.
        assert!(record("tienda").get("env").is_none());
        assert_eq!(
            record("agenda")["env"],
            json!({"GOOGLE_CLOUD_PROJECT": "escrito-a-mano"})
        );
        assert_eq!(record("agenda")["gcp"]["project"], "agenda-ficticia");

        assert_eq!(
            link(
                &store,
                "tienda",
                Some(GcpLink {
                    account: "qa@ejemplo.test".into(),
                    project: "--quiet".into()
                })
            )
            .unwrap_err()
            .to_string(),
            "gcp_invalid_project"
        );
        link(&store, "tienda", None).unwrap();
        link(&store, "agenda", None).unwrap();
        let environment = spec(&store, "tienda");
        assert!(
            GcpLink::VARIABLES
                .iter()
                .all(|name| !environment.contains_key(*name))
        );
        assert_eq!(
            spec(&store, "agenda")["GOOGLE_CLOUD_PROJECT"],
            "escrito-a-mano"
        );
        assert!(links(&store).unwrap().is_empty());
    }
}
