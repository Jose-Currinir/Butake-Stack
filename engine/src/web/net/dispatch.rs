//! Sharing a project through a temporary public tunnel (cloudflared); the fixed address has its own requests in `tunnels.rs`.

use crate::{core::store::Store, daemon, runtimes};
use anyhow::Result;
use serde_json::{json, Value};

/// Requests of this domain; `None` when `method` is not one of them.
pub fn dispatch(store: &Store, method: &str, request: &Value) -> Result<Option<Value>> {
    let id = request["id"].as_str().unwrap_or("");
    let result: Result<Value> = match method {
        // ---- Sharing a site through a public tunnel (cloudflared) ----
        "shareSite" => {
            let on = request["on"] == true;
            if on {
                anyhow::ensure!(request["confirmed"] == true, "confirmation_required");
                anyhow::ensure!(store.get(id)?.enabled, "site_off");
                anyhow::ensure!(
                    runtimes::utilities::catalog::user_tool("cloudflared").is_some(),
                    "cloudflared_missing"
                );
            } else {
                crate::core::model::validate_id(id)?;
            }
            daemon::request_sync(store, "share", json!({"id": id, "on": on}), false)
        }
        _ => return Ok(None),
    };
    result.map(Some)
}
