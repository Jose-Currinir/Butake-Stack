//! Local mail catcher: an SMTP server on 127.0.0.1 that accepts every message the sites send and
//! keeps it in the store (`mail/`, 0600) instead of delivering it. Credentials sent with AUTH are
//! accepted and discarded; nothing leaves the Mac. Messages expire after the configured days and
//! the oldest go first beyond the configured count.
use crate::core::fsutil::private_options;
use crate::core::time::now_millis;
use crate::{core::codec, core::model::MailConfig};
use anyhow::{ensure, Result};
use serde_json::{json, Value};
use std::{
    fs,
    io::Write,
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
    time::Duration,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    net::TcpListener,
};

pub const MAX_MESSAGE: usize = 25 * 1024 * 1024;
const MAX_LINE: u64 = 8192;
const MAX_RECIPIENTS: usize = 100;
static SEQUENCE: AtomicU64 = AtomicU64::new(0);

/// Message ids are `<millis>-<sequence>`: digits and one dash, nothing that can leave the folder.
pub fn validate_id(id: &str) -> Result<()> {
    let mut parts = id.split('-');
    let ok = id.len() <= 40
        && matches!((parts.next(), parts.next(), parts.next()), (Some(a), Some(b), None)
            if !a.is_empty() && !b.is_empty() && a.bytes().chain(b.bytes()).all(|c| c.is_ascii_digit()));
    ensure!(ok, "invalid_message");
    Ok(())
}

fn ids(dir: &Path) -> Vec<String> {
    let mut ids: Vec<String> = fs::read_dir(dir)
        .map(|entries| {
            entries
                .flatten()
                .filter_map(|e| {
                    e.file_name()
                        .to_str()?
                        .strip_suffix(".eml")
                        .map(str::to_string)
                })
                .filter(|id| validate_id(id).is_ok())
                .collect()
        })
        .unwrap_or_default();
    // Newest first: ids start with the arrival time.
    ids.sort_by_key(|id| {
        std::cmp::Reverse(
            id.split('-')
                .map(|p| p.parse::<u128>().unwrap_or(0))
                .collect::<Vec<_>>(),
        )
    });
    ids
}

/// Removes expired messages and the oldest beyond the limit.
pub fn prune(dir: &Path, config: &MailConfig) {
    // A temporary file left by an interrupted save (never one still being written).
    if let Ok(entries) = fs::read_dir(dir) {
        for entry in entries.flatten() {
            let name = entry.file_name();
            let stale = name
                .to_str()
                .is_some_and(|n| n.starts_with('.') && n.ends_with(".tmp"))
                && entry
                    .metadata()
                    .and_then(|m| m.modified())
                    .ok()
                    .and_then(|t| t.elapsed().ok())
                    .is_some_and(|age| age > Duration::from_secs(3600));
            if stale {
                let _ = fs::remove_file(entry.path());
            }
        }
    }
    let cutoff = now_millis().saturating_sub(config.retention_days as u128 * 86_400_000);
    for (index, id) in ids(dir).iter().enumerate() {
        let time: u128 = id
            .split('-')
            .next()
            .and_then(|t| t.parse().ok())
            .unwrap_or(0);
        if index >= config.max_messages as usize || time < cutoff {
            let _ = fs::remove_file(dir.join(format!("{id}.eml")));
        }
    }
}

/// Keeps one message: written to a temporary name and renamed, so readers never see half of it.
pub fn save(
    dir: &Path,
    envelope_from: &str,
    recipients: &[String],
    data: &[u8],
    config: &MailConfig,
) -> Result<String> {
    let id = format!(
        "{}-{}",
        now_millis(),
        SEQUENCE.fetch_add(1, Ordering::Relaxed)
    );
    let temporary = dir.join(format!(".{id}.tmp"));
    let mut file = private_options().create_new(true).open(&temporary)?;
    // The envelope (Bcc recipients only exist there) as headers of our own, before the message.
    let clean = |s: &str| {
        s.chars()
            .filter(|c| !c.is_control())
            .take(320)
            .collect::<String>()
    };
    write!(
        file,
        "X-Butake-Envelope-From: {}\r\nX-Butake-Envelope-To: {}\r\n",
        clean(envelope_from),
        clean(&recipients.join(", "))
    )?;
    file.write_all(data)?;
    file.sync_all()?;
    fs::rename(&temporary, dir.join(format!("{id}.eml")))?;
    prune(dir, config);
    Ok(id)
}

pub fn count(dir: &Path) -> usize {
    ids(dir).len()
}

// ---- SMTP ----

/// Address inside `MAIL FROM:<…>` / `RCPT TO:<…>` (parameters after it ignored).
fn address(argument: &str) -> String {
    let argument = argument.trim();
    match (argument.find('<'), argument.find('>')) {
        (Some(start), Some(end)) if end > start => argument[start + 1..end].to_string(),
        _ => argument.split_whitespace().next().unwrap_or("").to_string(),
    }
}

pub async fn serve(listener: TcpListener, dir: PathBuf, config: MailConfig) {
    // Each session may hold up to `MAX_MESSAGE` bytes: bound how many run at once.
    let sessions = std::sync::Arc::new(tokio::sync::Semaphore::new(16));
    loop {
        let Ok((stream, peer)) = listener.accept().await else {
            tokio::time::sleep(Duration::from_millis(100)).await;
            continue;
        };
        if !peer.ip().is_loopback() {
            continue;
        }
        let Ok(permit) = sessions.clone().try_acquire_owned() else {
            continue;
        };
        let dir = dir.clone();
        let config = config.clone();
        tokio::spawn(async move {
            let _permit = permit;
            let _ =
                tokio::time::timeout(Duration::from_secs(600), session(stream, dir, config)).await;
        });
    }
}

async fn read_line<R: tokio::io::AsyncBufRead + Unpin>(
    reader: &mut R,
    line: &mut Vec<u8>,
) -> Result<bool> {
    line.clear();
    let count = tokio::time::timeout(
        Duration::from_secs(120),
        (&mut *reader).take(MAX_LINE).read_until(b'\n', line),
    )
    .await??;
    Ok(count > 0)
}

pub async fn session<S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin>(
    stream: S,
    dir: PathBuf,
    config: MailConfig,
) -> Result<()> {
    let (read, mut writer) = tokio::io::split(stream);
    let mut reader = BufReader::new(read);
    writer
        .write_all(b"220 butake-stack ESMTP correo local\r\n")
        .await?;
    let mut from: Option<String> = None;
    let mut recipients: Vec<String> = vec![];
    let mut line = Vec::new();
    while read_line(&mut reader, &mut line).await? {
        let text = String::from_utf8_lossy(&line).trim_end().to_string();
        let upper = text.to_ascii_uppercase();
        let verb = upper.split_whitespace().next().unwrap_or("").to_string();
        let reply: String = match verb.as_str() {
            "EHLO" => format!("250-butake-stack\r\n250-SIZE {MAX_MESSAGE}\r\n250-8BITMIME\r\n250-SMTPUTF8\r\n250 AUTH PLAIN LOGIN\r\n"),
            "HELO" => "250 butake-stack\r\n".into(),
            "AUTH" => {
                // Any credentials are accepted and dropped at once: never stored or logged.
                let mut words = upper.split_whitespace().skip(1);
                match (words.next(), words.next()) {
                    (Some("PLAIN"), Some(_)) => {}
                    (Some("PLAIN"), None) => {
                        writer.write_all(b"334 \r\n").await?;
                        read_line(&mut reader, &mut line).await?;
                    }
                    (Some("LOGIN"), initial) => {
                        if initial.is_none() {
                            writer.write_all(b"334 VXNlcm5hbWU6\r\n").await?;
                            read_line(&mut reader, &mut line).await?;
                        }
                        writer.write_all(b"334 UGFzc3dvcmQ6\r\n").await?;
                        read_line(&mut reader, &mut line).await?;
                    }
                    _ => {
                        writer.write_all(b"504 5.5.4 Unrecognized authentication type\r\n").await?;
                        continue;
                    }
                }
                line.iter_mut().for_each(|b| *b = 0);
                "235 2.7.0 Authentication successful\r\n".into()
            }
            "MAIL" if upper.starts_with("MAIL FROM:") => {
                from = Some(address(&text[10..]));
                recipients.clear();
                "250 2.1.0 OK\r\n".into()
            }
            "RCPT" if upper.starts_with("RCPT TO:") => {
                if from.is_none() {
                    "503 5.5.1 MAIL first\r\n".into()
                } else if recipients.len() >= MAX_RECIPIENTS {
                    "452 4.5.3 Too many recipients\r\n".into()
                } else {
                    recipients.push(address(&text[8..]));
                    "250 2.1.5 OK\r\n".into()
                }
            }
            "DATA" => {
                if from.is_none() || recipients.is_empty() {
                    "503 5.5.1 RCPT first\r\n".into()
                } else {
                    writer.write_all(b"354 End data with <CR><LF>.<CR><LF>\r\n").await?;
                    let mut data = Vec::new();
                    let mut too_large = false;
                    // A line longer than the read limit arrives in pieces: only the first one
                    // can be the end marker or carry a dot-stuffing prefix.
                    let mut continued = false;
                    loop {
                        if !read_line(&mut reader, &mut line).await? {
                            return Ok(());
                        }
                        let first_piece = !continued;
                        continued = !line.ends_with(b"\n");
                        if first_piece && (line == b".\r\n" || line == b".\n") {
                            break;
                        }
                        let content = if first_piece && line.starts_with(b"..") { &line[1..] } else { &line[..] };
                        if data.len() + content.len() > MAX_MESSAGE {
                            too_large = true;
                        } else {
                            data.extend_from_slice(content);
                        }
                    }
                    let envelope = from.take().unwrap_or_default();
                    let to = std::mem::take(&mut recipients);
                    if too_large {
                        "552 5.3.4 Message too big\r\n".into()
                    } else {
                        let dir = dir.clone();
                        let config = config.clone();
                        let saved = tokio::task::spawn_blocking(move || save(&dir, &envelope, &to, &data, &config)).await;
                        match saved {
                            Ok(Ok(id)) => format!("250 2.0.0 OK {id}\r\n"),
                            _ => "451 4.3.0 Could not store the message\r\n".into(),
                        }
                    }
                }
            }
            "RSET" => {
                from = None;
                recipients.clear();
                "250 2.0.0 OK\r\n".into()
            }
            "NOOP" => "250 2.0.0 OK\r\n".into(),
            "VRFY" => "252 2.1.5 Cannot verify\r\n".into(),
            "STARTTLS" => "454 4.7.0 TLS not available\r\n".into(),
            "QUIT" => {
                writer.write_all(b"221 2.0.0 Bye\r\n").await?;
                return Ok(());
            }
            _ => "502 5.5.2 Command not recognized\r\n".into(),
        };
        writer.write_all(reply.as_bytes()).await?;
    }
    Ok(())
}

// ---- MIME ----

#[derive(Default)]
struct Part {
    headers: Vec<(String, String)>,
    body: Vec<u8>,
}

fn split_headers(raw: &[u8]) -> (&[u8], &[u8]) {
    for (index, window) in raw.windows(2).enumerate() {
        if window == b"\n\n" {
            return (&raw[..index], &raw[index + 2..]);
        }
        if index + 4 <= raw.len() && &raw[index..index + 4] == b"\r\n\r\n" {
            return (&raw[..index], &raw[index + 4..]);
        }
    }
    (raw, &[])
}

fn parse_headers(block: &[u8]) -> Vec<(String, String)> {
    let text = String::from_utf8_lossy(block);
    let mut headers: Vec<(String, String)> = vec![];
    for line in text.split('\n') {
        let line = line.trim_end_matches('\r');
        if line.starts_with([' ', '\t']) {
            if let Some(last) = headers.last_mut() {
                last.1.push(' ');
                last.1.push_str(line.trim());
            }
        } else if let Some((name, value)) = line.split_once(':') {
            if headers.len() < 500 {
                headers.push((name.trim().to_ascii_lowercase(), value.trim().to_string()));
            }
        }
    }
    headers
}

fn header<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
    headers
        .iter()
        .find(|(n, _)| n == name)
        .map(|(_, v)| v.as_str())
}

/// RFC 2047 encoded words (`=?UTF-8?B?…?=`, `=?ISO-8859-1?Q?…?=`) in headers.
pub fn decode_words(value: &str) -> String {
    let mut out = String::new();
    let mut rest = value;
    let mut last_was_word = false;
    while let Some(start) = rest.find("=?") {
        let decoded = (|| {
            let inner = &rest[start + 2..];
            let (charset, inner) = inner.split_once('?')?;
            let (encoding, inner) = inner.split_once('?')?;
            let end = inner.find("?=")?;
            let bytes = match encoding.to_ascii_uppercase().as_str() {
                "B" => codec::base64_decode(&inner[..end])?,
                "Q" => codec::quoted_printable(&inner.as_bytes()[..end], true),
                _ => return None,
            };
            let consumed = start + 2 + charset.len() + 1 + encoding.len() + 1 + end + 2;
            Some((
                codec::decode_charset(&bytes, charset.split('*').next().unwrap_or("")),
                consumed,
            ))
        })();
        match decoded {
            Some((text, consumed)) => {
                let between = &rest[..start];
                // Whitespace between two encoded words is not part of the text.
                if !(last_was_word && between.trim().is_empty()) {
                    out.push_str(between);
                }
                out.push_str(&text);
                rest = &rest[consumed..];
                last_was_word = true;
            }
            None => {
                out.push_str(&rest[..start + 2]);
                rest = &rest[start + 2..];
                last_was_word = false;
            }
        }
    }
    out.push_str(rest);
    out.chars()
        .filter(|c| !c.is_control() || *c == '\t')
        .collect()
}

/// `type/subtype; name=value; …` → (lowercase type, parameters with lowercase names).
fn parameters(value: &str) -> (String, Vec<(String, String)>) {
    let mut pieces = value.split(';');
    let kind = pieces.next().unwrap_or("").trim().to_ascii_lowercase();
    let params = pieces
        .filter_map(|p| {
            let (name, value) = p.split_once('=')?;
            let mut value = value.trim().trim_matches('"').to_string();
            let name = name.trim().to_ascii_lowercase();
            // RFC 2231: filename*=UTF-8''caf%C3%A9.pdf
            if name.ends_with('*') {
                if let Some((_, encoded)) = value.split_once("''") {
                    let mut bytes = vec![];
                    let raw = encoded.as_bytes();
                    let mut i = 0;
                    while i < raw.len() {
                        if raw[i] == b'%' && i + 2 < raw.len() {
                            if let Ok(b) = u8::from_str_radix(&encoded[i + 1..i + 3], 16) {
                                bytes.push(b);
                                i += 3;
                                continue;
                            }
                        }
                        bytes.push(raw[i]);
                        i += 1;
                    }
                    value = String::from_utf8_lossy(&bytes).into_owned();
                }
                return Some((name.trim_end_matches('*').to_string(), value));
            }
            Some((name, value))
        })
        .collect();
    (kind, params)
}

fn param<'a>(params: &'a [(String, String)], name: &str) -> Option<&'a str> {
    params
        .iter()
        .find(|(n, _)| n == name)
        .map(|(_, v)| v.as_str())
}

fn leaves(raw: &[u8], depth: usize, out: &mut Vec<Part>) {
    let (head, body) = split_headers(raw);
    let headers = parse_headers(head);
    let (kind, params) = parameters(header(&headers, "content-type").unwrap_or("text/plain"));
    if kind.starts_with("multipart/") && depth < 10 {
        if let Some(boundary) = param(&params, "boundary").filter(|b| !b.is_empty()) {
            let marker = format!("--{boundary}");
            let text = body;
            let mut sections: Vec<&[u8]> = vec![];
            let mut start: Option<usize> = None;
            let mut position = 0;
            while position <= text.len() {
                let end = text[position..]
                    .iter()
                    .position(|&b| b == b'\n')
                    .map(|p| position + p + 1)
                    .unwrap_or(text.len());
                let line = &text[position..end];
                let trimmed = line.strip_suffix(b"\n").unwrap_or(line);
                let trimmed = trimmed.strip_suffix(b"\r").unwrap_or(trimmed);
                // The boundary is the whole line (or it closes with `--`), never a longer word.
                if trimmed.starts_with(marker.as_bytes())
                    && trimmed[marker.len()..]
                        .iter()
                        .all(|b| matches!(b, b' ' | b'\t'))
                    || trimmed.starts_with(marker.as_bytes())
                        && trimmed[marker.len()..].starts_with(b"--")
                {
                    if let Some(s) = start {
                        // The line break before the boundary belongs to the boundary.
                        let mut piece = &text[s..position];
                        piece = piece.strip_suffix(b"\n").unwrap_or(piece);
                        piece = piece.strip_suffix(b"\r").unwrap_or(piece);
                        sections.push(piece);
                    }
                    if trimmed[marker.len()..].starts_with(b"--") {
                        break;
                    }
                    start = Some(end);
                }
                if end == text.len() {
                    break;
                }
                position = end;
            }
            for section in sections.into_iter().take(200) {
                leaves(section, depth + 1, out);
            }
            return;
        }
    }
    let encoding = header(&headers, "content-transfer-encoding")
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase();
    let body = match encoding.as_str() {
        "base64" => codec::base64_decode(&String::from_utf8_lossy(body)).unwrap_or_default(),
        "quoted-printable" => codec::quoted_printable(body, false),
        _ => body.to_vec(),
    };
    out.push(Part { headers, body });
}

struct Leaf<'a> {
    kind: String,
    charset: String,
    name: Option<String>,
    inline: bool,
    cid: Option<String>,
    part: &'a Part,
}

fn describe(part: &Part) -> Leaf<'_> {
    let (kind, params) = parameters(header(&part.headers, "content-type").unwrap_or("text/plain"));
    let (disposition, dparams) =
        parameters(header(&part.headers, "content-disposition").unwrap_or(""));
    let name = param(&dparams, "filename")
        .or_else(|| param(&params, "name"))
        .map(decode_words);
    Leaf {
        charset: param(&params, "charset").unwrap_or("utf-8").to_string(),
        inline: disposition != "attachment",
        cid: header(&part.headers, "content-id").map(|c| {
            c.trim()
                .trim_start_matches('<')
                .trim_end_matches('>')
                .to_string()
        }),
        kind,
        name,
        part,
    }
}

fn message_path(dir: &Path, id: &str) -> Result<PathBuf> {
    validate_id(id)?;
    let path = dir.join(format!("{id}.eml"));
    ensure!(
        path.is_file() && !path.symlink_metadata()?.file_type().is_symlink(),
        "message_not_found"
    );
    Ok(path)
}

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
    value["headers"] = json!(headers
        .iter()
        .filter(|(n, _)| !n.starts_with("x-butake-"))
        .take(100)
        .map(|(n, v)| json!([n, decode_words(v)]))
        .collect::<Vec<_>>());
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

pub fn delete(dir: &Path, id: Option<&str>) -> Result<()> {
    match id {
        Some(id) => fs::remove_file(message_path(dir, id)?)?,
        None => {
            for id in ids(dir) {
                let _ = fs::remove_file(dir.join(format!("{id}.eml")));
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const MESSAGE: &str = "From: =?UTF-8?B?Sm9zw6k=?= <app@demo.test>\r\nTo: cliente@example.com\r\nSubject: =?utf-8?Q?Factura_n=C2=BA_1?=\r\nMIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=\"b1\"\r\n\r\n--b1\r\nContent-Type: multipart/related; boundary=b2\r\n\r\n--b2\r\nContent-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n<p>Hola <img src=3D\"cid:logo@x\"> caf=C3=A9</p>\r\n--b2\r\nContent-Type: image/png\r\nContent-ID: <logo@x>\r\nContent-Transfer-Encoding: base64\r\n\r\niVBORw==\r\n--b2--\r\n--b1\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nHola café\r\n--b1\r\nContent-Type: application/pdf; name=\"f.pdf\"\r\nContent-Disposition: attachment; filename*=UTF-8''factura%20%C3%A9.pdf\r\nContent-Transfer-Encoding: base64\r\n\r\nJVBERi0=\r\n--b1--\r\n";

    #[test]
    fn parses_mime_and_inline_images() {
        let temp = tempfile::tempdir().unwrap();
        let config = MailConfig::default();
        let id = save(
            temp.path(),
            "app@demo.test",
            &["oculto@example.com".into()],
            MESSAGE.as_bytes(),
            &config,
        )
        .unwrap();
        let message = get(temp.path(), &id).unwrap();
        assert_eq!(message["from"], "José <app@demo.test>");
        assert_eq!(message["subject"], "Factura nº 1");
        assert_eq!(message["text"], "Hola café");
        let html = message["html"].as_str().unwrap();
        assert!(
            html.contains("caf\u{e9}")
                && html.contains("data:image/png;base64,iVBORw==")
                && !html.contains("cid:")
        );
        assert_eq!(message["attachments"][0]["name"], "factura é.pdf");
        let target = temp.path().join("out.pdf");
        save_attachment(
            temp.path(),
            &id,
            message["attachments"][0]["index"].as_u64().unwrap() as usize,
            &target,
        )
        .unwrap();
        assert_eq!(fs::read(&target).unwrap(), b"%PDF-");
        let initial = changes(temp.path(), &config, &Default::default()).unwrap();
        let listed = initial["messages"].as_array().unwrap();
        let next = changes(
            temp.path(),
            &config,
            &std::collections::HashSet::from([id.as_str()]),
        )
        .unwrap();
        assert_eq!(next, json!({"ids":[id], "messages":[]}));
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0]["to"], "cliente@example.com");
        assert!(get(temp.path(), "../x").is_err() && get(temp.path(), "1-2-3").is_err());
        delete(temp.path(), Some(&id)).unwrap();
        assert_eq!(count(temp.path()), 0);
    }

    #[test]
    fn keeps_the_limit() {
        let temp = tempfile::tempdir().unwrap();
        let config = MailConfig {
            max_messages: 3,
            ..MailConfig::default()
        };
        for _ in 0..5 {
            save(
                temp.path(),
                "a@b",
                &["c@d".into()],
                b"Subject: x\r\n\r\nhola",
                &config,
            )
            .unwrap();
        }
        assert_eq!(count(temp.path()), 3);
        fs::write(temp.path().join("1-0.eml"), "Subject: viejo\r\n\r\n").unwrap();
        prune(temp.path(), &config);
        assert!(
            !temp.path().join("1-0.eml").exists(),
            "expired by retention"
        );
    }

    async fn expect(
        reader: &mut BufReader<tokio::io::ReadHalf<tokio::io::DuplexStream>>,
        code: &str,
    ) {
        let mut line = String::new();
        loop {
            line.clear();
            reader.read_line(&mut line).await.unwrap();
            assert!(line.starts_with(code), "{line}");
            if line.as_bytes().get(3) != Some(&b'-') {
                break;
            }
        }
    }

    #[tokio::test]
    async fn speaks_smtp() {
        let temp = tempfile::tempdir().unwrap();
        let (client, server) = tokio::io::duplex(65_536);
        let dir = temp.path().to_path_buf();
        let task = tokio::spawn(session(server, dir, MailConfig::default()));
        let (read, mut write) = tokio::io::split(client);
        let mut reader = BufReader::new(read);
        expect(&mut reader, "220").await;
        for (command, code) in [
            ("EHLO demo", "250"),
            ("AUTH PLAIN AHVzZXIAc2VjcmV0", "235"),
            ("MAIL FROM:<a@demo.test> SIZE=10", "250"),
            ("RCPT TO:<b@example.com>", "250"),
            ("DATA", "354"),
        ] {
            write
                .write_all(format!("{command}\r\n").as_bytes())
                .await
                .unwrap();
            expect(&mut reader, code).await;
        }
        write
            .write_all(b"Subject: Prueba\r\n\r\n..punto\r\n.\r\n")
            .await
            .unwrap();
        expect(&mut reader, "250").await;
        write.write_all(b"QUIT\r\n").await.unwrap();
        expect(&mut reader, "221").await;
        task.await.unwrap().unwrap();
        let changes = changes(temp.path(), &MailConfig::default(), &Default::default()).unwrap();
        let listed = changes["messages"].as_array().unwrap();
        assert_eq!(listed[0]["subject"], "Prueba");
        let message = get(temp.path(), listed[0]["id"].as_str().unwrap()).unwrap();
        assert_eq!(message["text"], ".punto\r\n");
        assert!(
            !message["source"].as_str().unwrap().contains("c2VjcmV0"),
            "credentials never stored"
        );
    }
}
