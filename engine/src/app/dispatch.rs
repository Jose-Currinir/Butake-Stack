//! Requests about the app itself: its optional tools, configuration and backup of the environment.

use crate::{app, core::store::Store, daemon};
use anyhow::Result;
use serde_json::{json, Value};

/// Requests of this domain; `None` when `method` is not one of them.
pub fn dispatch(store: &Store, method: &str, request: &Value) -> Result<Option<Value>> {
    let id = request["id"].as_str().unwrap_or("");
    let result: Result<Value> = match method {
        "pluginCatalog" => Ok(serde_json::to_value(app::plugins::catalog(store)?)?),
        "pluginSetEnabled" => Ok(serde_json::to_value(app::plugins::set_enabled(
            store,
            id,
            request["enabled"] == true,
        )?)?),
        "pluginRemove" => Ok(serde_json::to_value(app::plugins::remove(
            store,
            id,
            request["deleteData"] == true,
            request["confirmed"] == true,
        )?)?),
        "stackConfig" => {
            if let Some(value) = request.get("config") {
                store.save_config(&serde_json::from_value(value.clone())?)?;
            }
            Ok(serde_json::to_value(store.config()?)?)
        }
        "exportEnvironment" => app::backup::export(
            store,
            serde_json::from_value(request["profiles"].clone()).unwrap_or_default(),
        ),
        "planRestore" => app::backup::plan(store, &request["data"]),
        "restoreEnvironment" => {
            anyhow::ensure!(request["confirmed"] == true, "confirmation_required");
            let result = app::backup::restore(store, &request["data"], &request["parts"])?;
            let _ = daemon::request_sync(store, "reload", json!({}), false);
            Ok(result)
        }
        "cloneSite" => {
            anyhow::ensure!(request["confirmed"] == true, "confirmation_required");
            app::backup::clone(
                std::path::Path::new(request["path"].as_str().unwrap_or("")),
                request["remote"].as_str().unwrap_or(""),
                request["branch"].as_str(),
            )?;
            Ok(json!(true))
        }
        // ---- Local mail catcher ----
        "setMail" => {
            let config = app::plugins::update_receiver_config(store, |config| {
                let mail = config.mail.get_or_insert_with(Default::default);
                if let Some(enabled) = request["enabled"].as_bool() {
                    mail.enabled = enabled;
                }
                if let Some(port) = request["port"].as_u64() {
                    mail.port = u16::try_from(port)?;
                }
                if let Some(days) = request["retentionDays"].as_u64() {
                    mail.retention_days = u16::try_from(days)?;
                }
                if let Some(max) = request["maxMessages"].as_u64() {
                    mail.max_messages = u32::try_from(max)?;
                }
                Ok(())
            })?;
            Ok(serde_json::to_value(config)?)
        }
        // ---- dump() receiver ----
        "setDumps" => {
            let config = app::plugins::update_receiver_config(store, |config| {
                let dumps = config.dumps.get_or_insert_with(Default::default);
                if let Some(enabled) = request["enabled"].as_bool() {
                    dumps.enabled = enabled;
                }
                if let Some(port) = request["port"].as_u64() {
                    dumps.port = u16::try_from(port)?;
                }
                Ok(())
            })?;
            Ok(serde_json::to_value(config)?)
        }
        _ => return Ok(None),
    };
    result.map(Some)
}
