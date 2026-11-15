//! Requests about the stack's services: their switch, port and version, the databases and accounts of a project, and how PostgreSQL lets people in.

use crate::{core::store::Store, daemon, web};
use anyhow::{bail, Result};
use serde_json::{json, Value};

/// Requests of this domain; `None` when `method` is not one of them.
pub fn dispatch(store: &Store, method: &str, request: &Value) -> Result<Option<Value>> {
    let result: Result<Value> = match method {
        // A database with its own account(s). An account that exists keeps its password.
        "createDatabase" => {
            let config = store.config()?;
            let name = request["name"].as_str().unwrap_or("");
            match request["engine"].as_str().unwrap_or("") {
                "postgres" => web::services::databases::create_postgres(
                    store,
                    &config,
                    name,
                    &web::services::databases::Accounts::from_request(request, name),
                ),
                "mysql" => web::services::databases::create_mysql(
                    store,
                    &config,
                    name,
                    request["user"]
                        .as_str()
                        .filter(|u| !u.is_empty())
                        .unwrap_or(name),
                    request["mysqlPassword"].as_str(),
                ),
                _ => bail!("unsupported_engine"),
            }
        }
        // Rotating a password is its own, confirmed request; the app keeps the new one at once.
        "rotateDatabasePassword" => {
            anyhow::ensure!(request["confirmed"] == true, "confirmation_required");
            let config = store.config()?;
            let user = request["user"].as_str().unwrap_or("");
            let password = match request["engine"].as_str().unwrap_or("") {
                "postgres" => web::services::databases::rotate_postgres(store, &config, user)?,
                "mysql" => web::services::databases::rotate_mysql(
                    store,
                    &config,
                    user,
                    request["mysqlPassword"].as_str(),
                )?,
                _ => bail!("unsupported_engine"),
            };
            Ok(json!({"password": password}))
        }
        // How the stack's PostgreSQL lets people in, and the explicit change (with its undo).
        "postgresAuth" => web::services::postgres_auth::describe(store, &store.config()?),
        "postgresRequirePassword" => {
            anyhow::ensure!(request["confirmed"] == true, "confirmation_required");
            web::services::postgres_auth::require_password(store, &store.config()?)
        }
        "postgresAllowTrust" => {
            anyhow::ensure!(request["confirmed"] == true, "confirmation_required");
            web::services::postgres_auth::allow_trust(store, &store.config()?)
        }
        "databaseAccountUsers" => Ok(json!(web::services::databases::account_users(
            store,
            request["user"].as_str().unwrap_or("")
        )?)),
        "engineRecipes" => {
            let config = store.config()?;
            Ok(json!(web::services::engines::RECIPES
                .iter()
                .map(|r| json!({"id": r.id, "category": r.category, "port": web::services::engines::port(&config, r.id)}))
                .collect::<Vec<_>>()))
        }
        "setEngine" => {
            let name = request["engine"].as_str().unwrap_or("");
            anyhow::ensure!(
                web::services::engines::recipe(name).is_some(),
                "unknown_engine"
            );
            let port = match request["port"].as_u64() {
                Some(port) => {
                    Some(u16::try_from(port).map_err(|_| anyhow::anyhow!("invalid_port"))?)
                }
                None => None,
            };
            // Version and port under the store's lock: a change never undoes another one made
            // at the same time (the app and the command line share `stack.json`).
            let mut config = store.update_config(|config| {
                let entry = config.engines.entry(name.into()).or_default();
                if let Some(version) = request["version"].as_str() {
                    entry.version = version.into();
                }
                if port.is_some() {
                    entry.port = port;
                }
                Ok(())
            })?;
            // The switch: turning off a service that projects that are on use needs
            // `confirmed` (otherwise `service_in_use` with their names), and every change is
            // written down with who asked (`actor`, `cli` when it does not say).
            if let Some(enabled) = request["enabled"].as_bool() {
                config = web::projects::service_use::set_enabled(
                    store,
                    name,
                    enabled,
                    request["confirmed"] == true,
                    request["actor"].as_str().unwrap_or(""),
                )?;
            }
            let _ = daemon::request_sync(store, "reload", json!({}), false);
            Ok(serde_json::to_value(config)?)
        }
        _ => return Ok(None),
    };
    result.map(Some)
}
