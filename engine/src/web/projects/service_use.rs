//! Services (MySQL, PostgreSQL, Redis…) and the projects that use them (P-42): a service a project
//! that is on needs is never turned off without saying which ones, a project that is turned on
//! gets its services on, and every change of a service's switch is written down with who asked.

use crate::core::{
    fsutil::private_options,
    model::{Project, StackConfig},
    store::Store,
    time::now_secs,
};
use anyhow::Result;
use std::{fs, io::Write};

/// Projects that are on and declare `service` among their services, by name.
pub fn users(projects: &[Project], service: &str) -> Vec<Project> {
    projects
        .iter()
        .filter(|p| p.enabled && p.services.iter().any(|s| s == service))
        .cloned()
        .collect()
}

/// `service_in_use:<names>`: the projects that are on and use the service, for the app to say.
pub fn in_use(users: &[Project]) -> String {
    let names: Vec<String> = users
        .iter()
        .map(|p| {
            p.name
                .chars()
                .filter(|c| !c.is_control())
                .take(200)
                .collect()
        })
        .collect();
    format!("service_in_use:{}", names.join(", "))
}

/// Services of `project` that are installed but off in `config`, in its order.
pub fn off_services(store: &Store, config: &StackConfig, project: &Project) -> Vec<String> {
    project
        .services
        .iter()
        .filter(|service| {
            !config
                .engines
                .get(service.as_str())
                .is_some_and(|e| e.enabled)
                && crate::runtimes::utilities::catalog::resolve(
                    store,
                    service,
                    config
                        .engines
                        .get(service.as_str())
                        .map(|e| e.version.as_str())
                        .unwrap_or(""),
                )
                .is_some()
        })
        .cloned()
        .collect()
}

/// Turns a service on or off in `stack.json` under the store's lock (two callers never undo each
/// other's change) and writes it down. Turning one off that projects that are on use needs
/// `confirmed`; without it the answer is `service_in_use` with their names.
pub fn set_enabled(
    store: &Store,
    service: &str,
    enabled: bool,
    confirmed: bool,
    actor: &str,
) -> Result<StackConfig> {
    if !enabled && !confirmed {
        let using = users(&store.list()?, service);
        anyhow::ensure!(using.is_empty(), in_use(&using));
    }
    let config = store.update_config(|config| {
        config.engines.entry(service.into()).or_default().enabled = enabled;
        Ok(())
    })?;
    let _ = record(store, service, enabled, actor);
    Ok(config)
}

/// Turns on, together, the services of `project` that are installed and off. Their names, for
/// the app to say what Stack did.
pub fn start_for(store: &Store, project: &Project, actor: &str) -> Result<Vec<String>> {
    let wanted = off_services(store, &store.config()?, project);
    if wanted.is_empty() {
        return Ok(wanted);
    }
    store.update_config(|config| {
        for service in &wanted {
            config.engines.entry(service.clone()).or_default().enabled = true;
        }
        Ok(())
    })?;
    for service in &wanted {
        let _ = record(store, service, true, actor);
    }
    Ok(wanted)
}

/// One line per change of a service's switch in `logs/services.log` (0600): when, which, on or
/// off and who asked (`app`, `project:<id>` or `cli` when the caller does not say). The newest
/// 500 lines stay.
pub fn record(store: &Store, service: &str, enabled: bool, actor: &str) -> Result<()> {
    let actor: String = if actor.is_empty() { "cli" } else { actor }
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-' | ':'))
        .take(64)
        .collect();
    let file = store.directory("logs")?.join("services.log");
    let entry = serde_json::json!({"ts": now_secs(), "service": service, "enabled": enabled, "actor": actor});
    let mut lines: Vec<String> = fs::read_to_string(&file)
        .unwrap_or_default()
        .lines()
        .map(str::to_string)
        .collect();
    lines.push(entry.to_string());
    let skip = lines.len().saturating_sub(500);
    let mut out = private_options().create(true).truncate(true).open(&file)?;
    out.write_all((lines[skip..].join("\n") + "\n").as_bytes())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn project(store: &Store, root: &std::path::Path, id: &str, services: &[&str], on: bool) {
        let folder = root.join(id);
        fs::create_dir_all(&folder).unwrap();
        let p: Project = serde_json::from_value(serde_json::json!({
            "id": id, "name": format!("Proyecto {id}"), "path": folder, "domains": [format!("{id}.test")],
            "https": false, "kind": "static", "runtime": {}, "docroot": ".", "services": services,
            "databases": [], "processes": [], "enabled": on}))
        .unwrap();
        store.save(p).unwrap();
    }

    /// Turning off a service that a project that is on uses is refused with its name unless the
    /// caller confirms; every change is written down with who asked.
    #[test]
    fn a_service_in_use_is_not_turned_off_silently() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::new(temp.path().join("store")).unwrap();
        project(&store, temp.path(), "api", &["postgres"], true);
        project(&store, temp.path(), "apagado", &["postgres"], false);
        set_enabled(&store, "postgres", true, false, "app").unwrap();
        let error = set_enabled(&store, "postgres", false, false, "")
            .unwrap_err()
            .to_string();
        assert_eq!(error, "service_in_use:Proyecto api");
        assert!(store.config().unwrap().engines["postgres"].enabled);
        // Redis: nobody uses it.
        set_enabled(&store, "redis", false, false, "app").unwrap();
        let config = set_enabled(&store, "postgres", false, true, "app").unwrap();
        assert!(!config.engines["postgres"].enabled);
        let log = fs::read_to_string(store.root().join("logs/services.log")).unwrap();
        let lines: Vec<serde_json::Value> = log
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect();
        assert_eq!(lines.len(), 3);
        assert_eq!(lines[2]["service"], "postgres");
        assert_eq!(lines[2]["enabled"], false);
        assert_eq!(lines[2]["actor"], "app");
        assert_eq!(lines[1]["actor"], "app");
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            fs::metadata(store.root().join("logs/services.log"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }
}
