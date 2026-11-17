//! Requests of the Correo and Dumps tools that read their folders (the receivers live in the daemon).

use crate::{core::store::Store, daemon, web};
use anyhow::Result;
use serde_json::{Value, json};

/// Requests of this domain; `None` when `method` is not one of them.
pub fn dispatch(store: &Store, method: &str, request: &Value) -> Result<Option<Value>> {
    let id = request["id"].as_str().unwrap_or("");
    let result: Result<Value> = match method {
        "mailChanges" => {
            let known = request["known"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .collect();
            let changes = web::tools::mail::changes(
                &store.directory("mail")?,
                &store.config()?.mail.unwrap_or_default(),
                &known,
            )?;
            Ok(changes)
        }
        "mailGet" => web::tools::mail::get(&store.directory("mail")?, id),
        "mailAttachment" => {
            web::tools::mail::save_attachment(
                &store.directory("mail")?,
                id,
                request["index"].as_u64().unwrap_or(u64::MAX) as usize,
                std::path::Path::new(request["path"].as_str().unwrap_or("")),
            )?;
            Ok(json!(true))
        }
        "mailDelete" => {
            let all = request["all"] == true;
            web::tools::mail::delete(&store.directory("mail")?, if all { None } else { Some(id) })?;
            Ok(json!(true))
        }
        "dumpsClear" => daemon::request_sync(store, "clearDumps", json!({}), false),
        _ => return Ok(None),
    };
    result.map(Some)
}
