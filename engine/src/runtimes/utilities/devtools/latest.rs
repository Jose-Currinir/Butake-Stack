//! The newest version of each tool at its source, and what can be updated.

use super::*;

/// Newest version of each tool at its source: GitHub releases (uv, gh, cloudflared: the tag from
/// the web page, no API quota), npm (Wrangler), Rust's stable channel, Python's supported lines and
/// the utilities' own sources. A source that doesn't answer goes to `unavailable` with its error
/// code. Cached by the caller.
pub fn latest() -> Result<Value> {
    type Found = std::result::Result<String, String>;
    fn code<T>(result: Result<T>) -> std::result::Result<T, String> {
        result.map_err(|e| e.to_string())
    }
    let tag = |repo: &'static str| {
        std::thread::spawn(move || -> Found {
            code(github::latest_tag(repo)).map(|t| t.trim_start_matches('v').to_string())
        })
    };
    let (uv, gh, cloudflared) = (
        tag("astral-sh/uv"),
        tag("cli/cli"),
        tag("cloudflare/cloudflared"),
    );
    let wrangler = std::thread::spawn(|| -> Found {
        let body = code(download::fetch(
            "https://registry.npmjs.org/wrangler/latest",
            2_000_000,
        ))?;
        serde_json::from_slice::<Value>(&body)
            .ok()
            .and_then(|v| v["version"].as_str().map(str::to_string))
            .ok_or_else(|| "download_failed".into())
    });
    let rust = std::thread::spawn(|| -> Found {
        let body = code(download::fetch(
            "https://static.rust-lang.org/dist/channel-rust-stable.toml",
            30_000_000,
        ))?;
        String::from_utf8(body)
            .ok()
            .and_then(|text| {
                let section = text.split("[pkg.rust]").nth(1)?;
                section
                    .lines()
                    .find(|l| l.starts_with("version"))?
                    .split('"')
                    .nth(1)?
                    .split_whitespace()
                    .next()
                    .map(str::to_string)
            })
            .ok_or_else(|| "download_failed".into())
    });
    let python = std::thread::spawn(|| code(crate::runtimes::languages::python::versions()));
    let utilities = std::thread::spawn(utilities::latest);
    let mut out = serde_json::Map::new();
    let mut unavailable = serde_json::Map::new();
    let mut found = |id: &str, result: Found| match result {
        Ok(version) => {
            out.insert(id.into(), json!(version));
        }
        Err(error) => {
            unavailable.insert(id.into(), json!(error));
        }
    };
    for (id, handle) in [
        ("uv", uv),
        ("gh", gh),
        ("cloudflared", cloudflared),
        ("wrangler", wrangler),
        ("rustup", rust),
    ] {
        found(
            id,
            handle
                .join()
                .unwrap_or_else(|_| Err("download_failed".into())),
        );
    }
    for (id, result) in utilities.join().unwrap_or_default() {
        found(id, result);
    }
    match python
        .join()
        .unwrap_or_else(|_| Err("download_failed".into()))
    {
        Ok(lines) => {
            let map: serde_json::Map<String, Value> = lines
                .as_array()
                .cloned()
                .unwrap_or_default()
                .into_iter()
                .filter_map(|l| Some((l["version"].as_str()?.to_string(), l["latest"].clone())))
                .collect();
            out.insert("python".into(), Value::Object(map));
        }
        Err(error) => {
            unavailable.insert("python".into(), json!(error));
        }
    }
    ensure!(!out.is_empty(), "download_offline");
    out.insert("unavailable".into(), Value::Object(unavailable));
    Ok(Value::Object(out))
}

/// A newer answer keeps what the previous one knew of the sources that did not answer now, with
/// when it was asked (`known`: id → seconds since 1970); `unavailable` stays as it is now.
pub fn keep_known(mut latest: Value, previous: Option<(Value, u64)>) -> Value {
    let Some((previous, fetched_at)) = previous else {
        return latest;
    };
    let missing: Vec<String> = latest["unavailable"]
        .as_object()
        .map(|m| m.keys().cloned().collect())
        .unwrap_or_default();
    for id in missing {
        if latest.get(&id).is_none() {
            if let Some(known) = previous.get(&id).filter(|v| !v.is_null()).cloned() {
                let when = previous["known"][&id].as_u64().unwrap_or(fetched_at);
                latest[&id] = known;
                latest["known"][&id] = json!(when);
            }
        }
    }
    latest
}

pub(in crate::runtimes) fn newer(latest: &str, installed: &str) -> bool {
    let parse = |v: &str| {
        v.split(['.', '-'])
            .map(|p| p.parse::<u64>().unwrap_or(0))
            .collect::<Vec<_>>()
    };
    parse(latest) > parse(installed)
}

/// What can be updated: installed version against the newest at its source, and for what is not
/// installed, the version an install would bring.
pub fn updates(store: &Store, latest: &Value) -> Result<Value> {
    let local = catalog::dev_tools(store)?;
    let mut out = serde_json::Map::new();
    for id in ["uv", "gh", "cloudflared", "wrangler", "rustup"]
        .into_iter()
        .chain(utilities::IDS)
    {
        // Not installed yet: the version an install would bring ("installed" empty, no update).
        if let Some(newest) = latest[id].as_str() {
            let installed = local[id]["version"].as_str().unwrap_or("");
            let update = !installed.is_empty() && newer(newest, installed);
            out.insert(
                id.into(),
                json!({"installed": installed, "latest": newest, "update": update}),
            );
        }
    }
    // Python: each line Stack has, against that line's newest patch.
    let mut lines = serde_json::Map::new();
    for manifest in crate::runtimes::languages::python::installed(store) {
        if let Some(newest) = latest["python"][&manifest.line].as_str() {
            lines.insert(manifest.line.clone(), json!({"installed": manifest.version, "latest": newest, "update": newer(newest, &manifest.version)}));
        }
    }
    out.insert("python".into(), Value::Object(lines));
    // Sources that did not answer (their error code) and versions known from an earlier answer.
    out.insert("unavailable".into(), latest["unavailable"].clone());
    out.insert("known".into(), latest["known"].clone());
    Ok(Value::Object(out))
}
