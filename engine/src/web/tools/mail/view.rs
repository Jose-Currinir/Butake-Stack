//! What the interface reads: the list of messages, one message in full and its attachments.
use super::mime::{Leaf, decode_words, describe, header, leaves, parse_headers, split_headers};
use super::store::{ids, message_path, prune};
use crate::core::codec;
use crate::core::model::MailConfig;
use anyhow::{Result, ensure};
use serde_json::{Value, json};
use std::{fs, io::Write, os::unix::fs::OpenOptionsExt, path::Path};

fn summary(id: &str, headers: &[(String, String)], size: u64) -> Value {
    let get = |name: &str| header(headers, name).map(decode_words).unwrap_or_default();
    let to = {
        let listed = get("to");
        if listed.is_empty() {
            get("x-butake-envelope-to")
        } else {
            listed
        }
    };
    json!({
        "id": id,
        "from": get("from"),
        "to": to,
        "subject": get("subject"),
        "date": get("date"),
        "received": id.split('-').next().and_then(|t| t.parse::<u64>().ok()).unwrap_or(0) / 1000,
        "size": size,
    })
}

/// Newest first; only the headers are read.
pub fn changes(
    dir: &Path,
    config: &MailConfig,
    known: &std::collections::HashSet<&str>,
) -> Result<Value> {
    prune(dir, config);
    let mut out = vec![];
    let current = ids(dir);
    for id in current.iter().filter(|id| !known.contains(id.as_str())) {
        let path = dir.join(format!("{id}.eml"));
        let Ok(file) = fs::File::open(&path) else {
            continue;
        };
        let size = file.metadata().map(|m| m.len()).unwrap_or(0);
        let mut head = Vec::new();
        let _ = std::io::Read::read_to_end(&mut std::io::Read::take(file, 65_536), &mut head);
        out.push(summary(id, &parse_headers(split_headers(&head).0), size));
    }
    Ok(json!({"ids":current,"messages":out}))
}

/// One message: text, HTML (inline images as `data:` URLs), attachments and its source.
pub fn get(dir: &Path, id: &str) -> Result<Value> {
    let path = message_path(dir, id)?;
    let raw = fs::read(&path)?;
    let (head, _) = split_headers(&raw);
    let headers = parse_headers(head);
    let mut parts = vec![];
    leaves(&raw, 0, &mut parts);
    let leaves: Vec<Leaf> = parts.iter().map(describe).collect();
    let mut text = None;
    let mut html: Option<String> = None;
    let mut attachments = vec![];
    for (index, leaf) in leaves.iter().enumerate() {
        let body_text = || codec::decode_charset(&leaf.part.body, &leaf.charset);
        match (leaf.kind.as_str(), leaf.inline && leaf.name.is_none()) {
            ("text/plain", true) if text.is_none() => text = Some(body_text()),
            ("text/html", true) if html.is_none() => html = Some(body_text()),
            _ => {
                if !(leaf.cid.is_some() && leaf.inline && leaf.kind.starts_with("image/"))
                    || leaf.name.is_some()
                {
                    attachments.push(json!({
                        "index": index,
                        "name": leaf.name.clone().unwrap_or_else(|| format!("adjunto-{index}")),
                        "type": leaf.kind,
                        "size": leaf.part.body.len(),
                    }));
                }
            }
        }
    }
    // Inline images referenced by `cid:` become data URLs (the viewer loads nothing from outside).
    if let Some(page) = html.as_mut() {
        for leaf in &leaves {
            if let (Some(cid), true) = (
                &leaf.cid,
                leaf.kind.starts_with("image/") && leaf.part.body.len() <= 5 * 1024 * 1024,
            ) {
                let kind: String = leaf
                    .kind
                    .chars()
                    .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '/' | '+' | '.' | '-'))
                    .collect();
                *page = page.replace(
                    &format!("cid:{cid}"),
                    &format!(
                        "data:{kind};base64,{}",
                        codec::base64_encode(&leaf.part.body)
                    ),
                );
            }
        }
    }
    let size = raw.len() as u64;
    let mut value = summary(id, &headers, size);
    value["cc"] = json!(header(&headers, "cc").map(decode_words).unwrap_or_default());
    value["text"] = json!(text);
    value["html"] = json!(html);
    value["attachments"] = json!(attachments);
    value["headers"] = json!(
        headers
            .iter()
            .filter(|(n, _)| !n.starts_with("x-butake-"))
            .take(100)
            .map(|(n, v)| json!([n, decode_words(v)]))
            .collect::<Vec<_>>()
    );
    value["source"] = json!(String::from_utf8_lossy(&raw[..raw.len().min(200_000)]));
    Ok(value)
}

/// Writes one attachment where the user chose (the app's save panel).
pub fn save_attachment(dir: &Path, id: &str, index: usize, target: &Path) -> Result<()> {
    ensure!(
        target.is_absolute() && target.parent().is_some_and(Path::is_dir),
        "invalid_path"
    );
    ensure!(
        !target
            .symlink_metadata()
            .is_ok_and(|m| m.file_type().is_symlink()),
        "invalid_path"
    );
    let raw = fs::read(message_path(dir, id)?)?;
    let mut parts = vec![];
    leaves(&raw, 0, &mut parts);
    let part = parts
        .get(index)
        .ok_or_else(|| anyhow::anyhow!("attachment_not_found"))?;
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o644)
        .custom_flags(libc::O_NOFOLLOW)
        .open(target)?;
    file.write_all(&part.body)?;
    Ok(())
}
