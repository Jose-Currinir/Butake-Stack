//! The Redis browser: keys, values and deletion.

use super::*;

/// Keys matching a pattern (SCAN, never KEYS), with their type and TTL.
pub fn redis_keys(target: &Target, request: &Value) -> Result<Value> {
    let database = text(request, "database");
    let pattern = if text(request, "pattern").is_empty() {
        "*"
    } else {
        text(request, "pattern")
    };
    let mut cursor = text(request, "cursor").to_string();
    if cursor.is_empty() {
        cursor = "0".into();
    }
    ensure!(
        cursor.bytes().all(|c| c.is_ascii_digit()),
        "invalid_request"
    );
    let mut keys = vec![];
    let started = Instant::now();
    loop {
        let reply = client::redis(
            target,
            database,
            &[
                "SCAN".into(),
                cursor.clone(),
                "MATCH".into(),
                pattern.into(),
                "COUNT".into(),
                "500".into(),
            ],
        )?;
        cursor = reply[0].as_str().unwrap_or("0").to_string();
        keys.extend(
            reply[1]
                .as_array()
                .cloned()
                .unwrap_or_default()
                .into_iter()
                .filter_map(|k| k.as_str().map(str::to_string)),
        );
        if cursor == "0" || keys.len() >= 500 || started.elapsed() > Duration::from_secs(3) {
            break;
        }
    }
    let info = client::redis(target, "", &["INFO".into(), "keyspace".into()])?;
    let databases: Vec<Value> = info
        .as_str()
        .unwrap_or("")
        .lines()
        .filter_map(|l| {
            let (db, rest) = l.split_once(':')?;
            let index = db.strip_prefix("db")?.parse::<u32>().ok()?;
            let count = rest
                .split(',')
                .find_map(|p| p.strip_prefix("keys="))?
                .parse::<i64>()
                .ok()?;
            Some(json!({"index": index, "keys": count}))
        })
        .collect();
    Ok(json!({"keys": keys, "cursor": cursor, "databases": databases}))
}

/// One key's value by type, its TTL and size.
pub fn redis_value(target: &Target, request: &Value) -> Result<Value> {
    let (database, key) = (text(request, "database"), text(request, "key").to_string());
    let kind = client::redis(target, database, &["TYPE".into(), key.clone()])?;
    let kind = kind.as_str().unwrap_or("none").to_string();
    let read: Vec<String> = match kind.as_str() {
        "string" => vec!["GET".into(), key.clone()],
        "hash" => vec!["HGETALL".into(), key.clone()],
        "list" => vec!["LRANGE".into(), key.clone(), "0".into(), "499".into()],
        "set" => vec![
            "SSCAN".into(),
            key.clone(),
            "0".into(),
            "COUNT".into(),
            "500".into(),
        ],
        "zset" => vec![
            "ZRANGE".into(),
            key.clone(),
            "0".into(),
            "499".into(),
            "WITHSCORES".into(),
        ],
        "stream" => vec![
            "XRANGE".into(),
            key.clone(),
            "-".into(),
            "+".into(),
            "COUNT".into(),
            "100".into(),
        ],
        _ => vec![],
    };
    let value = if read.is_empty() {
        Value::Null
    } else {
        client::redis(target, database, &read)?
    };
    let ttl = client::redis(target, database, &["TTL".into(), key.clone()])?;
    Ok(json!({"key": key, "type": kind, "value": value, "ttl": ttl}))
}

pub fn redis_delete(target: &Target, request: &Value) -> Result<Value> {
    let keys: Vec<String> = request["keys"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|k| k.as_str().map(str::to_string))
        .collect();
    ensure!(!keys.is_empty() && keys.len() <= 500, "invalid_request");
    if !confirmed(target, request) {
        return Ok(
            json!({"needsConfirmation": true, "statements": keys.iter().map(|k| format!("DEL {k}")).collect::<Vec<_>>()}),
        );
    }
    let mut args = vec!["DEL".to_string()];
    args.extend(keys);
    client::redis(target, text(request, "database"), &args)
}
