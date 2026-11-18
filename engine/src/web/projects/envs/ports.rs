//! The `{port:<id>}` and `{public:<id>}` markers: filled when the `.env` is written, and the projects that name a project whose port or address changed.

use super::*;

/// An environment with its markers filled, as the `.env` must carry it.
pub(super) struct Filled {
    pub(super) env: Environment,
    pub(super) secrets: BTreeMap<String, String>,
}

/// One value with its `{port:<id>}` and `{public:<id>}` filled; `None` when it names a project
/// without a fixed address yet: the variable is left out of the `.env` (the site falls back to
/// its own default) and Entornos says it is pending ([`public_pending`]) until the address exists
/// (P-35).
pub(super) fn fill_markers(
    text: &str,
    projects: &[Project],
    addresses: &BTreeMap<String, String>,
) -> Result<Option<String>> {
    let ported = crate::core::model::fill_project_ports(text, projects)?;
    match crate::core::model::fill_public_addresses(&ported, projects, addresses) {
        Ok(filled) => Ok(Some(filled)),
        Err(error) if error.to_string() == "project_without_public_address" => Ok(None),
        Err(error) => Err(error),
    }
}

/// The environment and its secrets with each `{port:<id>}` replaced by that project's port and
/// each `{public:<id>}` by its fixed address, as the `.env` must carry them (the site reads the
/// file itself).
pub(super) fn with_ports(
    store: &Store,
    env: &Environment,
    secrets: &BTreeMap<String, String>,
) -> Result<Filled> {
    let projects = store.list()?;
    let addresses = crate::web::net::tunnels::addresses(store);
    let mut env = env.clone();
    let mut entries = vec![];
    for mut entry in env.entries {
        if let Some(value) = fill_markers(&entry.value, &projects, &addresses)? {
            entry.value = value;
            entries.push(entry);
        }
    }
    env.entries = entries;
    let mut filled = BTreeMap::new();
    for (key, value) in secrets {
        if let Some(value) = fill_markers(value, &projects, &addresses)? {
            filled.insert(key.clone(), value);
        } else {
            // A secret left out of the `.env` is left out of its entries too.
            env.entries.retain(|e| &e.key != key);
        }
    }
    Ok(Filled {
        env,
        secrets: filled,
    })
}

/// Projects named by `{public:<id>}` in the active environment that have no fixed address yet:
/// its `.env` was written without those variables (P-35).
pub fn public_pending(store: &Store, id: &str) -> Vec<String> {
    let Ok(site) = load(store, id) else {
        return vec![];
    };
    let addresses = crate::web::net::tunnels::addresses(store);
    let mut out: Vec<String> = vec![];
    for env in site
        .environments
        .iter()
        .filter(|e| site.active.as_ref() == Some(&e.id))
    {
        for entry in &env.entries {
            for named in crate::core::model::public_references(&entry.value) {
                if !addresses.contains_key(named) && !out.iter().any(|o| o == named) {
                    out.push(named.to_string());
                }
            }
        }
    }
    out
}

/// Projects that name project `id` with `{port:<id>}` or `{public:<id>}`: in their `env`
/// (resolved by the supervisor at every launch) or in any of their environments (resolved when
/// the `.env` is written).
pub fn port_dependents(store: &Store, id: &str) -> Result<Vec<String>> {
    let names = |text: &str| crate::core::model::project_references(text).contains(&id);
    let mut out = vec![];
    for project in store.list()? {
        if project.id == id {
            continue;
        }
        let in_env = project.env.values().any(|v| names(v));
        let in_environments = load(store, &project.id).is_ok_and(|site| {
            site.environments
                .iter()
                .any(|env| env.entries.iter().any(|e| names(&e.value)))
        });
        if in_env || in_environments {
            out.push(project.id);
        }
    }
    Ok(out)
}

/// What became of a project whose active environment names a project that changed.
#[derive(Debug, Serialize, PartialEq)]
pub struct Refreshed {
    pub id: String,
    /// `rewritten` (the engine wrote the `.env` again), `outdated` (it has secrets: the app writes
    /// it again with the Keychain), `missing` (the project it names is gone or has no port) or
    /// `processes` (only its `env`, which the supervisor fills at every launch).
    pub state: &'static str,
}

/// After project `changed` got a new port, was renamed or removed: the `.env` of every project
/// whose active environment names it with `{port:<id>}` is written again when the engine can (no
/// secrets, the file is Stack's), or marked `outdated` for the app, which holds the secrets. The
/// processes are never restarted here: the app offers it (and the supervisor logs why when a
/// process's own `env` changed).
pub fn refresh_port_dependents(
    store: &Store,
    changed: &str,
    actor: &str,
) -> Result<Vec<Refreshed>> {
    let mut out = vec![];
    for id in port_dependents(store, changed)? {
        let mut site = load(store, &id)?;
        let active = site
            .active
            .as_ref()
            .and_then(|a| site.environments.iter().find(|e| &e.id == a))
            .cloned();
        let Some(env) = active.filter(|env| {
            env.entries
                .iter()
                .any(|e| crate::core::model::project_references(&e.value).contains(&changed))
        }) else {
            out.push(Refreshed {
                id,
                state: "processes",
            });
            continue;
        };
        let project = store.get(&id)?;
        let filled = with_ports(store, &env, &BTreeMap::new());
        let target = project.path.join(".env");
        // Only its header is read: the values are written again from the store, never read.
        let ours = written_by_stack(&target);
        let state = match filled {
            Err(_) => "missing",
            Ok(_) if env.entries.iter().any(|e| e.secret) || !ours => "outdated",
            Ok(Filled { env, .. }) => {
                write_private(&target, &render(&env, &BTreeMap::new())?)?;
                audit(store, &id, &env.id, "actualizar", "", actor)?;
                "rewritten"
            }
        };
        if state == "rewritten" {
            site.outdated.clear();
        } else if !site.outdated.iter().any(|o| o == changed) {
            site.outdated.push(changed.to_string());
        }
        json::write(&path(store, &id)?, &site)?;
        out.push(Refreshed { id, state });
    }
    Ok(out)
}
