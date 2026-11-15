//! Fixed public addresses in the daemon (P-35): the connection with Cloudflare
//! (`cloudflared tunnel login`) and each shared address's `cloudflared tunnel run`, supervised like
//! the temporary address: in their own process group, stopped on request, never orphaned.
use super::supervisor::{ProcessSpec, SupervisorReader};
use crate::core::{model::Project, store::Store};
use anyhow::Result;
use serde_json::{json, Value};
use std::{
    collections::BTreeSet,
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Mutex,
    },
};

/// Sites shared on their fixed address. Memory only: the address stays configured, but a
/// restarted daemon or a stopped site shares nothing.
static SHARES: Mutex<BTreeSet<String>> = Mutex::new(BTreeSet::new());
/// The user asked to connect with Cloudflare: the login runs until the certificate appears or the
/// user cancels.
static LOGIN: AtomicBool = AtomicBool::new(false);

const LOGIN_ID: &str = "cloudflare.login";
/// What `cloudflared tunnel run` logs once Cloudflare accepted a connection of the tunnel.
const READY: &str = "Registered tunnel connection";

fn shared() -> BTreeSet<String> {
    SHARES.lock().map(|s| s.clone()).unwrap_or_default()
}

pub fn set_shared(id: &str, on: bool) {
    if let Ok(mut shares) = SHARES.lock() {
        if on {
            shares.insert(id.to_string());
        } else {
            shares.remove(id);
        }
    }
}

/// A site turned off or removed stops being shared.
pub fn retain(enabled: &BTreeSet<String>) {
    if let Ok(mut shares) = SHARES.lock() {
        shares.retain(|id| enabled.contains(id));
    }
}

pub fn set_login(on: bool) {
    LOGIN.store(on, Ordering::SeqCst);
}

/// The login while it is wanted and there is no connection yet, then one `tunnel run` per shared
/// site with a fixed address (its configuration written for this run).
pub fn specs(
    store: &Store,
    config: &crate::core::model::StackConfig,
    projects: &[Project],
    home: &str,
) -> Result<Vec<ProcessSpec>> {
    let mut specs = vec![];
    let executable = crate::runtimes::utilities::catalog::user_tool("cloudflared");
    let spec = |id: String, args: Vec<String>, environment: Vec<(&str, String)>| ProcessSpec {
        id,
        autostart: executable.is_some(),
        executable: executable
            .clone()
            .unwrap_or_else(|| PathBuf::from("/nonexistent")),
        args,
        cwd: store.root().into(),
        // A failed run is the user's to retry: it never restarts on its own.
        restart_on_exit: false,
        environment: environment
            .into_iter()
            .map(|(k, v)| (k.to_string(), v))
            .collect(),
        inherit: vec![],
        stop_timeout: 5,
        env_file: None,
        blocked: None,
    };
    if crate::web::net::tunnels::connected() {
        set_login(false);
    }
    if LOGIN.load(Ordering::SeqCst) {
        specs.push(spec(
            LOGIN_ID.into(),
            vec!["tunnel".into(), "login".into()],
            // `PATH` so that it can open the browser.
            vec![
                ("HOME", home.to_string()),
                ("PATH", "/usr/bin:/bin:/usr/sbin:/sbin".into()),
            ],
        ));
    }
    let shares = shared();
    for project in projects.iter().filter(|p| shares.contains(&p.id)) {
        let Some((address, file, content)) =
            crate::web::net::tunnels::prepare_run(store, project, config.ports.http)?
        else {
            continue;
        };
        specs.push(spec(
            format!("public.{}", project.id),
            crate::web::net::tunnels::run_arguments(&file, &address.tunnel),
            // A new configuration (another name, port or local domain) restarts the run.
            vec![
                ("HOME", home.to_string()),
                ("BUTAKE_CONFIG", super::fingerprint(&content)),
            ],
        ));
    }
    Ok(specs)
}

/// For `stackStatus`: whether the login is wanted, and each shared address with whether
/// Cloudflare already accepted the tunnel.
pub fn status(store: &Store, supervisor: &SupervisorReader) -> Value {
    // Once the certificate is there the login has ended by itself: nothing is being connected.
    if crate::web::net::tunnels::connected() {
        set_login(false);
    }
    let shares: Vec<Value> = shared()
        .into_iter()
        .map(|id| {
            let ready = supervisor
                .logs(&format!("public.{id}"), 400)
                .is_ok_and(|lines| lines.iter().any(|l| l.contains(READY)));
            let hostname = crate::web::net::tunnels::address(store, &id).map(|a| a.hostname);
            json!({"id": id, "hostname": hostname, "ready": ready})
        })
        .collect();
    json!({"login": LOGIN.load(Ordering::SeqCst), "shares": shares})
}
