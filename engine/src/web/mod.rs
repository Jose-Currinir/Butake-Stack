//! Projects and the local web, by responsibility: the projects themselves (`projects`), the
//! services generated from the model and their databases (`services`), the local network
//! (`net`: DNS, ports, tunnels) and the mail and dump receivers (`tools`).

pub mod net;
pub mod projects;
pub mod services;
pub mod tools;

/// Requests of this domain; `None` when `method` is not one of them.
pub fn dispatch(
    store: &crate::core::store::Store,
    method: &str,
    request: &serde_json::Value,
) -> anyhow::Result<Option<serde_json::Value>> {
    for domain in [
        projects::dispatch,
        services::dispatch,
        tools::dispatch,
        net::dispatch,
    ] {
        if let Some(value) = domain(store, method, request)? {
            return Ok(Some(value));
        }
    }
    Ok(None)
}
