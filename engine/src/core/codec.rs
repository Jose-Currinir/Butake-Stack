//! Small decoders shared by the mail catcher, the dump receiver and the certificate check.

fn sextet(c: u8) -> Option<u8> {
    match c {
        b'A'..=b'Z' => Some(c - b'A'),
        b'a'..=b'z' => Some(c - b'a' + 26),
        b'0'..=b'9' => Some(c - b'0' + 52),
        b'+' | b'-' => Some(62),
        b'/' | b'_' => Some(63),
        _ => None,
    }
}

/// Standard or URL-safe base64; whitespace is skipped, padding optional. None on any other byte.
pub fn base64_decode(text: &str) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(text.len() * 3 / 4);
    let mut buffer = 0u32;
    let mut bits = 0;
    for &c in text.as_bytes() {
        if c.is_ascii_whitespace() {
            continue;
        }
        if c == b'=' {
            break;
        }
        buffer = (buffer << 6) | sextet(c)? as u32;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((buffer >> bits) as u8);
            buffer &= (1 << bits) - 1;
        }
    }
    Some(out)
}

pub fn base64_encode(data: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let n = (chunk[0] as u32) << 16
            | (*chunk.get(1).unwrap_or(&0) as u32) << 8
            | *chunk.get(2).unwrap_or(&0) as u32;
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(TABLE[(n >> (18 - 6 * i)) as usize & 63] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

fn hex(c: u8) -> Option<u8> {
    (c as char).to_digit(16).map(|d| d as u8)
}

/// Quoted-printable (`=XX`, soft line breaks); `underscore` turns `_` into spaces (RFC 2047 "Q").
pub fn quoted_printable(data: &[u8], underscore: bool) -> Vec<u8> {
    let mut out = Vec::with_capacity(data.len());
    let mut i = 0;
    while i < data.len() {
        match data[i] {
            b'=' => {
                if data.get(i + 1) == Some(&b'\r') && data.get(i + 2) == Some(&b'\n') {
                    i += 3;
                } else if data.get(i + 1) == Some(&b'\n') {
                    i += 2;
                } else if let (Some(a), Some(b)) = (
                    data.get(i + 1).and_then(|c| hex(*c)),
                    data.get(i + 2).and_then(|c| hex(*c)),
                ) {
                    out.push(a << 4 | b);
                    i += 3;
                } else {
                    out.push(b'=');
                    i += 1;
                }
            }
            b'_' if underscore => {
                out.push(b' ');
                i += 1;
            }
            c => {
                out.push(c);
                i += 1;
            }
        }
    }
    out
}

/// Text in a charset mail commonly uses; anything unknown is read as UTF-8 (lossy).
pub fn decode_charset(data: &[u8], charset: &str) -> String {
    match charset.trim().to_ascii_lowercase().as_str() {
        "iso-8859-1" | "latin1" | "iso8859-1" | "windows-1252" | "cp1252" | "iso-8859-15" => {
            data.iter().map(|&b| b as char).collect()
        }
        _ => String::from_utf8_lossy(data).into_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn round_trips() {
        for sample in [&b""[..], b"a", b"ab", b"abc", b"hola mundo\x00\xff"] {
            assert_eq!(base64_decode(&base64_encode(sample)).unwrap(), sample);
        }
        assert_eq!(base64_decode("aG9s\r\nYQ==").unwrap(), b"hola");
        assert!(base64_decode("a*b").is_none());
        assert_eq!(
            quoted_printable(b"caf=C3=A9 =\r\nok", false),
            "café ok".as_bytes()
        );
        assert_eq!(quoted_printable(b"a_b", true), b"a b");
        assert_eq!(decode_charset(&[0xE9], "ISO-8859-1"), "é");
    }
}
