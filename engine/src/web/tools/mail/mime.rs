//! The MIME reader: headers, RFC 2047 words, RFC 2231 parameters and the multipart tree.
use crate::core::codec;

#[derive(Default)]
pub(super) struct Part {
    pub(super) headers: Vec<(String, String)>,
    pub(super) body: Vec<u8>,
}

pub(super) fn split_headers(raw: &[u8]) -> (&[u8], &[u8]) {
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

pub(super) fn parse_headers(block: &[u8]) -> Vec<(String, String)> {
    let text = String::from_utf8_lossy(block);
    let mut headers: Vec<(String, String)> = vec![];
    for line in text.split('\n') {
        let line = line.trim_end_matches('\r');
        if line.starts_with([' ', '\t']) {
            if let Some(last) = headers.last_mut() {
                last.1.push(' ');
                last.1.push_str(line.trim());
            }
        } else if let Some((name, value)) = line.split_once(':')
            && headers.len() < 500
        {
            headers.push((name.trim().to_ascii_lowercase(), value.trim().to_string()));
        }
    }
    headers
}

pub(super) fn header<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
    headers
        .iter()
        .find(|(n, _)| n == name)
        .map(|(_, v)| v.as_str())
}

/// RFC 2047 encoded words (`=?UTF-8?B?…?=`, `=?ISO-8859-1?Q?…?=`) in headers.
pub(super) fn decode_words(value: &str) -> String {
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
pub(super) fn parameters(value: &str) -> (String, Vec<(String, String)>) {
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
                        if raw[i] == b'%' {
                            // Decode on bytes: a multibyte character after `%` is not a boundary.
                            let hex = raw
                                .get(i + 1..i + 3)
                                .and_then(|h| std::str::from_utf8(h).ok())
                                .and_then(|h| u8::from_str_radix(h, 16).ok());
                            if let Some(b) = hex {
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

pub(super) fn param<'a>(params: &'a [(String, String)], name: &str) -> Option<&'a str> {
    params
        .iter()
        .find(|(n, _)| n == name)
        .map(|(_, v)| v.as_str())
}

pub(super) fn leaves(raw: &[u8], depth: usize, out: &mut Vec<Part>) {
    let (head, body) = split_headers(raw);
    let headers = parse_headers(head);
    let (kind, params) = parameters(header(&headers, "content-type").unwrap_or("text/plain"));
    if kind.starts_with("multipart/")
        && depth < 10
        && let Some(boundary) = param(&params, "boundary").filter(|b| !b.is_empty())
    {
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

pub(super) struct Leaf<'a> {
    pub(super) kind: String,
    pub(super) charset: String,
    pub(super) name: Option<String>,
    pub(super) inline: bool,
    pub(super) cid: Option<String>,
    pub(super) part: &'a Part,
}

pub(super) fn describe(part: &Part) -> Leaf<'_> {
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
