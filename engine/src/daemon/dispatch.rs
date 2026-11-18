//! Requests about the supervisor daemon, the launch agent and the trust of the local certificate.

use crate::{core::store::Store, daemon, web};
use anyhow::Result;
use serde_json::{Value, json};

/// Requests of this domain; `None` when `method` is not one of them.
pub fn dispatch(store: &Store, method: &str, request: &Value) -> Result<Option<Value>> {
    let id = request["id"].as_str().unwrap_or("");
    let result: Result<Value> = match method {
        "startDaemon" => daemon::request_sync(store, "stackStatus", json!({}), true),
        "processAction" => {
            let action = request["action"].as_str().unwrap_or("");
            anyhow::ensure!(
                ["start", "stop", "restart"].contains(&action),
                "invalid_action"
            );
            daemon::supervisor::validate_process_id(id)?;
            daemon::request_sync(store, action, json!({"id":id}), false)
        }
        "agentStatus" => Ok(daemon::launch_agent::status()),
        "installAgent" => {
            if request["confirmed"] == true && request["preview"] != true {
                // A daemon started by hand holds the lock; launchd's copy must replace it.
                let _ = daemon::request_sync(store, "shutdown", json!({}), false);
                std::thread::sleep(std::time::Duration::from_millis(1500));
            }
            daemon::launch_agent::configure(request, true)
        }
        "uninstallAgent" => daemon::launch_agent::configure(request, false),
        "stackStatus" => daemon::request_sync(store, "stackStatus", json!({}), false),
        "reloadStack" => daemon::request_sync(store, "reload", json!({}), false),
        // ---- What macOS needs for .test sites (privileged: macOS asks in its own dialog) ----
        "localTrust" => daemon::trust::status(store),
        "installResolver" => daemon::trust::install_resolvers(store, request["confirmed"] == true),
        "trustLocalCa" => daemon::trust::trust_authority(store, request["confirmed"] == true),
        "siteHealth" => daemon::probe_sites(store),
        "siteShellEnvironment" => daemon::site_shell_environment(store, id),
        "portStatus" => Ok(json!({
            "dns": web::net::listeners::port_owner(53, true),
            "http": web::net::listeners::port_owner(80, false),
            "https": web::net::listeners::port_owner(443, false),
        })),
        _ => return Ok(None),
    };
    result.map(Some)
}
