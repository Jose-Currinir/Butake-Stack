//! GitHub as a source of releases, spending as little of its API quota as possible.
//!
//! Unauthenticated, the API allows 60 requests an hour per network. So:
//! - The newest tag of a repository comes from the web page's redirect
//!   (`github.com/<repo>/releases/latest` → `…/releases/tag/<tag>`), which is not counted.
//! - Assets download from `github.com/<repo>/releases/download/<tag>/<name>`, not counted either.
//! - What only the API says (the SHA-256 digest of an asset, release lists) is read through
//!   [`api`]: a copy on disk per address, fresh for a while, then asked again with `If-None-Match`
//!   (a 304 answer does not count against the quota).
//! - When GitHub limits this network the error says so, with the minutes until it resets
//!   (`source_rate_limited:<minutes>`), and a copy on disk is used instead when there is one.
//!
//! No token of the user is ever sent: raising the limit with one would be an explicit, opt-in
//! option (not offered today).

use super::{download, fsutil::write_private, hash, store::Store, time::now_secs};
use anyhow::{bail, ensure, Result};
use serde_json::{json, Value};
use std::{
    fs,
    path::PathBuf,
    process::{Command, Stdio},
};

/// How long a copy of an API answer is used without asking again.
pub const FRESH: u64 = 3600;
const MAX_BODY: usize = 30_000_000;

/// One answer of an HTTPS request: status, headers (names in lowercase) and body.
pub struct Reply {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Reply {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(n, _)| n == name)
            .map(|(_, v)| v.as_str())
    }

    /// GitHub's rate limit: 429, or 403 with no requests left or a `retry-after`. The minutes
    /// until it resets, at least one.
    pub fn rate_limit_minutes(&self) -> Option<u64> {
        let limited = self.status == 429
            || (self.status == 403
                && (self.header("x-ratelimit-remaining") == Some("0")
                    || self.header("retry-after").is_some()));
        if !limited {
            return None;
        }
        let seconds = self
            .header("retry-after")
            .and_then(|v| v.trim().parse::<u64>().ok())
            .or_else(|| {
                self.header("x-ratelimit-reset")
                    .and_then(|v| v.trim().parse::<u64>().ok())
                    .map(|reset| reset.saturating_sub(now_secs()))
            })
            .unwrap_or(3600);
        Some(seconds.div_ceil(60).max(1))
    }
}

/// How a request leaves this Mac: the system curl in production, a fake in tests.
pub type Transport = fn(url: &str, etag: Option<&str>) -> Result<Reply>;

/// HTTPS GET through the system curl (TLS 1.2 or newer, no redirects followed, 30 s), with
/// `If-None-Match` when there is an ETag. No connection: `download_offline`.
pub fn curl(url: &str, etag: Option<&str>) -> Result<Reply> {
    ensure!(url.starts_with("https://"), "insecure_url");
    let mut command = Command::new("/usr/bin/curl");
    command
        .args([
            "--proto",
            "=https",
            "--tlsv1.2",
            "-sS",
            "-i",
            "--max-time",
            "30",
        ])
        .args(["-H", "User-Agent: butake-stack"])
        .args(["-H", "Accept: application/vnd.github+json"]);
    if let Some(etag) = etag.filter(|e| e.len() < 200 && !e.contains(['\r', '\n'])) {
        command.args(["-H", &format!("If-None-Match: {etag}")]);
    }
    let out = command
        .arg(url)
        .env_clear()
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()?;
    if !out.status.success() {
        bail!(download::curl_failure(out.status.code()));
    }
    parse(&out.stdout)
}

/// The last header block of a `curl -i` answer (a proxy may add one before it) and the body.
fn parse(raw: &[u8]) -> Result<Reply> {
    let mut rest = raw;
    loop {
        let end = rest
            .windows(4)
            .position(|w| w == b"\r\n\r\n")
            .ok_or_else(|| anyhow::anyhow!("download_failed"))?;
        let head = String::from_utf8_lossy(&rest[..end]).into_owned();
        let body = &rest[end + 4..];
        if body.starts_with(b"HTTP/") {
            rest = body;
            continue;
        }
        let mut lines = head.lines();
        let status = lines
            .next()
            .and_then(|l| l.split_whitespace().nth(1))
            .and_then(|s| s.parse().ok())
            .ok_or_else(|| anyhow::anyhow!("download_failed"))?;
        let headers = lines
            .filter_map(|l| l.split_once(':'))
            .map(|(n, v)| (n.trim().to_ascii_lowercase(), v.trim().to_string()))
            .collect();
        ensure!(body.len() <= MAX_BODY, "download_too_large");
        return Ok(Reply {
            status,
            headers,
            body: body.to_vec(),
        });
    }
}

/// A tag as GitHub writes it in addresses: letters, digits and `.-_+`.
fn valid_tag(tag: &str) -> bool {
    !tag.is_empty()
        && tag.len() <= 100
        && tag
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b".-_+".contains(&c))
}

fn valid_repo(repo: &str) -> bool {
    let parts: Vec<&str> = repo.split('/').collect();
    parts.len() == 2
        && parts.iter().all(|p| {
            !p.is_empty()
                && !p.starts_with('.')
                && p.len() <= 100
                && p.bytes()
                    .all(|c| c.is_ascii_alphanumeric() || b".-_".contains(&c))
        })
}

/// The newest release's tag, from the web page's redirect (no API quota).
pub fn latest_tag(repo: &str) -> Result<String> {
    latest_tag_with(repo, curl)
}

fn latest_tag_with(repo: &str, transport: Transport) -> Result<String> {
    ensure!(valid_repo(repo), "invalid_request");
    let reply = transport(&format!("https://github.com/{repo}/releases/latest"), None)?;
    if let Some(minutes) = reply.rate_limit_minutes() {
        bail!("source_rate_limited:{minutes}");
    }
    let location = reply.header("location").unwrap_or_default();
    let tag = location
        .split_once("/releases/tag/")
        .map(|(_, tag)| tag.split(['?', '#']).next().unwrap_or(""))
        .unwrap_or("");
    let tag = tag.replace("%2B", "+");
    ensure!(
        (300..400).contains(&reply.status) && valid_tag(&tag),
        "download_failed"
    );
    Ok(tag)
}

/// A release of `repo` by its tag, from the API (through [`api`]).
pub fn release(store: &Store, repo: &str, tag: &str) -> Result<Value> {
    ensure!(valid_repo(repo) && valid_tag(tag), "invalid_request");
    api(
        store,
        &format!("https://api.github.com/repos/{repo}/releases/tags/{tag}"),
    )
}

/// The newest release of `repo`: its tag from the web, its details from the API.
pub fn latest_release(store: &Store, repo: &str) -> Result<Value> {
    release(store, repo, &latest_tag(repo)?)
}

/// An API answer: the copy on disk while fresh, then asked again with its ETag.
pub fn api(store: &Store, url: &str) -> Result<Value> {
    api_with(store, url, FRESH, curl)
}

fn copy_path(store: &Store, url: &str) -> Result<PathBuf> {
    let name = &hash::sha1_hex(url.as_bytes())[..24];
    Ok(store
        .directory("cache")?
        .join(format!("github-{name}.json")))
}

fn api_with(store: &Store, url: &str, fresh: u64, transport: Transport) -> Result<Value> {
    ensure!(
        url.starts_with("https://api.github.com/"),
        "invalid_request"
    );
    let path = copy_path(store, url)?;
    let copy: Option<Value> = fs::symlink_metadata(&path)
        .ok()
        .filter(|m| m.is_file() && m.len() <= MAX_BODY as u64 + 4096)
        .and_then(|_| fs::read(&path).ok())
        .and_then(|data| serde_json::from_slice(&data).ok())
        .filter(|c: &Value| c["url"] == url);
    if let Some(copy) = &copy {
        if copy["fetched_at"]
            .as_u64()
            .is_some_and(|t| now_secs().saturating_sub(t) < fresh)
        {
            return Ok(copy["value"].clone());
        }
    }
    let save = |value: &Value, etag: Option<&str>| {
        let _ = write_private(
            &path,
            &json!({"url": url, "etag": etag, "fetched_at": now_secs(), "value": value})
                .to_string(),
        );
    };
    let etag = copy.as_ref().and_then(|c| c["etag"].as_str());
    let reply = match transport(url, etag) {
        Ok(reply) => reply,
        // Offline: the copy beats an error.
        Err(error) => return copy.map(|c| c["value"].clone()).ok_or(error),
    };
    if reply.status == 304 {
        if let Some(copy) = &copy {
            save(&copy["value"], etag);
            return Ok(copy["value"].clone());
        }
    }
    if reply.status == 200 {
        let value: Value =
            serde_json::from_slice(&reply.body).map_err(|_| anyhow::anyhow!("download_failed"))?;
        save(&value, reply.header("etag"));
        return Ok(value);
    }
    // Limited or failing: the copy (however old) beats an error.
    if let Some(copy) = copy {
        return Ok(copy["value"].clone());
    }
    match reply.rate_limit_minutes() {
        Some(minutes) => bail!("source_rate_limited:{minutes}"),
        None => bail!("download_failed"),
    }
}

/// The text of a file attached to a release (`releases/download`, no API quota).
pub fn asset_text(repo: &str, tag: &str, name: &str, limit: u64) -> Result<String> {
    ensure!(
        valid_repo(repo) && valid_tag(tag) && valid_tag(name),
        "invalid_request"
    );
    String::from_utf8(download::fetch(
        &format!(
            "https://github.com/{repo}/releases/download/{tag}/{}",
            name.replace('+', "%2B")
        ),
        limit,
    )?)
    .map_err(|_| anyhow::anyhow!("download_failed"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reply(status: u16, headers: &[(&str, &str)], body: &str) -> Result<Reply> {
        Ok(Reply {
            status,
            headers: headers
                .iter()
                .map(|(n, v)| (n.to_string(), v.to_string()))
                .collect(),
            body: body.as_bytes().to_vec(),
        })
    }

    const URL: &str = "https://api.github.com/repos/openai/codex/releases/tags/rust-v1.2.3";

    #[test]
    fn answers_are_kept_revalidated_with_their_etag_and_survive_a_limit() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::new(temp.path().join("store")).unwrap();
        // Limited and nothing on disk: the code says so, with the minutes until the reset.
        let limited: Transport = |_, _| {
            reply(
                403,
                &[
                    ("x-ratelimit-remaining", "0"),
                    ("x-ratelimit-reset", &(now_secs() + 31 * 60 + 5).to_string()),
                ],
                "{\"message\": \"API rate limit exceeded\"}",
            )
        };
        assert_eq!(
            api_with(&store, URL, FRESH, limited)
                .unwrap_err()
                .to_string(),
            "source_rate_limited:32"
        );
        let retry: Transport = |_, _| reply(429, &[("retry-after", "120")], "");
        assert_eq!(
            api_with(&store, URL, FRESH, retry).unwrap_err().to_string(),
            "source_rate_limited:2"
        );
        // A first answer is kept with its ETag; while fresh nothing is asked.
        let first: Transport = |_, etag| {
            assert!(etag.is_none());
            reply(
                200,
                &[("etag", "W/\"abc\"")],
                "{\"tag_name\": \"rust-v1.2.3\"}",
            )
        };
        assert_eq!(
            api_with(&store, URL, FRESH, first).unwrap()["tag_name"],
            "rust-v1.2.3"
        );
        let never: Transport = |_, _| panic!("a fresh copy must not ask GitHub");
        assert_eq!(
            api_with(&store, URL, FRESH, never).unwrap()["tag_name"],
            "rust-v1.2.3"
        );
        // Old: asked with If-None-Match; 304 (free) keeps the copy.
        let not_modified: Transport = |_, etag| {
            assert_eq!(etag, Some("W/\"abc\""));
            reply(304, &[], "")
        };
        assert_eq!(
            api_with(&store, URL, 0, not_modified).unwrap()["tag_name"],
            "rust-v1.2.3"
        );
        // Limited with a copy on disk: the copy.
        assert_eq!(
            api_with(&store, URL, 0, limited).unwrap()["tag_name"],
            "rust-v1.2.3"
        );
        // Offline with a copy: the copy; without one: the network's own error.
        let offline: Transport = |_, _| bail!("download_offline");
        assert_eq!(
            api_with(&store, URL, 0, offline).unwrap()["tag_name"],
            "rust-v1.2.3"
        );
        let other = "https://api.github.com/repos/cli/cli/releases/tags/v2.0.0";
        assert_eq!(
            api_with(&store, other, 0, offline).unwrap_err().to_string(),
            "download_offline"
        );
        let server: Transport = |_, _| reply(502, &[], "");
        assert_eq!(
            api_with(&store, other, 0, server).unwrap_err().to_string(),
            "download_failed"
        );
        assert!(api_with(&store, "https://example.com/x", 0, first).is_err());
    }

    #[test]
    fn the_newest_tag_comes_from_the_web_redirect() {
        let found: Transport = |url, _| {
            assert_eq!(url, "https://github.com/openai/codex/releases/latest");
            reply(
                302,
                &[(
                    "location",
                    "https://github.com/openai/codex/releases/tag/rust-v0.58.0",
                )],
                "",
            )
        };
        assert_eq!(
            latest_tag_with("openai/codex", found).unwrap(),
            "rust-v0.58.0"
        );
        let odd: Transport = |_, _| {
            reply(
                302,
                &[("location", "https://github.com/a/b/releases/tag/x;rm")],
                "",
            )
        };
        assert!(latest_tag_with("a/b", odd).is_err());
        let limited: Transport = |_, _| reply(429, &[("retry-after", "600")], "");
        assert_eq!(
            latest_tag_with("a/b", limited).unwrap_err().to_string(),
            "source_rate_limited:10"
        );
        assert!(latest_tag_with("../x", found).is_err());
    }

    #[test]
    fn curl_answers_are_parsed_and_no_network_is_its_own_error() {
        let raw = b"HTTP/1.1 200 Connection established\r\n\r\nHTTP/2 403 \r\nx-ratelimit-remaining: 0\r\nETag: \"x\"\r\n\r\n{}";
        let reply = parse(raw).unwrap();
        assert_eq!(reply.status, 403);
        assert_eq!(reply.header("etag"), Some("\"x\""));
        assert_eq!(reply.body, b"{}");
        // Nothing listens on port 1 of this Mac: no connection, not a server error.
        assert_eq!(
            curl("https://127.0.0.1:1/x", None)
                .err()
                .unwrap()
                .to_string(),
            "download_offline"
        );
    }
}
