//! HTTPS downloads through the system curl: never plain HTTP, never below TLS 1.2, a clock
//! limit and a size limit, and an empty environment.

use super::{hash, progress};
use anyhow::{ensure, Result};
use std::{
    io::Read,
    path::Path,
    process::{Command, Stdio},
};

/// What a failed curl means: no connection (could not resolve, connect, finish TLS or in time:
/// `download_offline`) or an answer that was an error (`download_failed`).
pub fn curl_failure(code: Option<i32>) -> &'static str {
    match code {
        Some(5 | 6 | 7 | 28 | 35 | 52 | 55 | 56) => "download_offline",
        _ => "download_failed",
    }
}

/// Fetches `url` into memory, refusing more than `limit` bytes.
pub fn fetch(url: &str, limit: u64) -> Result<Vec<u8>> {
    ensure!(url.starts_with("https://"), "insecure_url");
    let mut child = Command::new("/usr/bin/curl")
        .args([
            "--proto",
            "=https",
            "--tlsv1.2",
            "-fsSL",
            "--max-time",
            "60",
        ])
        .args(["-H", "User-Agent: butake-stack"])
        .arg(url)
        .env_clear()
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    let mut data = Vec::new();
    let read = match child.stdout.take() {
        Some(stdout) => stdout.take(limit.saturating_add(1)).read_to_end(&mut data),
        None => Err(std::io::Error::other("no_stdout")),
    };
    // Over the limit curl is cut off (SIGPIPE) and its status says nothing about the network.
    if read.is_err() || data.len() as u64 > limit {
        let _ = child.kill();
        let _ = child.wait();
        ensure!(read.is_ok(), "download_failed");
        anyhow::bail!("download_too_large");
    }
    let status = child.wait()?;
    ensure!(status.success(), curl_failure(status.code()));
    Ok(data)
}

/// Downloads `url` into `target` (at most 500 MB, 15 minutes).
pub fn download(url: &str, target: &Path) -> Result<()> {
    download_up_to(url, target, 500_000_000)
}

/// Downloads `url` into `target`, refusing more than `max_bytes`; the time limit grows with the
/// size (a second per MB, never under 15 minutes).
///
/// While the app follows the operation (see `progress`), the bytes so far go to its log (the size
/// from a first HEAD request, when the server says it) and a stop ends curl and removes the part.
pub fn download_up_to(url: &str, target: &Path, max_bytes: u64) -> Result<()> {
    ensure!(url.starts_with("https://"), "insecure_url");
    let seconds = (max_bytes / 1_000_000).max(900).to_string();
    let total = progress::followed().then(|| size_of(url)).flatten();
    let mut curl = Command::new("/usr/bin/curl");
    curl.args(["--proto", "=https", "--tlsv1.2", "-fsSL", "--max-time"])
        .arg(&seconds)
        .arg("--max-filesize")
        .arg(max_bytes.to_string())
        .arg("-o")
        .arg(target)
        .arg(url)
        .env_clear()
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    let mut reported = 0;
    let status = progress::run(&mut curl, || {
        let done = std::fs::metadata(target).map(|m| m.len()).unwrap_or(0);
        if done != reported && progress::followed() {
            progress::bytes(done, total);
            reported = done;
        }
    });
    let status = match status {
        Ok(status) => status,
        Err(error) => {
            let _ = std::fs::remove_file(target);
            return Err(error);
        }
    };
    if !status.success() {
        // A partial file must not pass for a complete one.
        let _ = std::fs::remove_file(target);
    }
    ensure!(status.success(), curl_failure(status.code()));
    if progress::followed() {
        let done = std::fs::metadata(target).map(|m| m.len()).unwrap_or(0);
        progress::bytes(done, total.or(Some(done)));
    }
    Ok(())
}

/// The size the server announces for `url` (following redirects), when it does.
fn size_of(url: &str) -> Option<u64> {
    let out = Command::new("/usr/bin/curl")
        .args([
            "--proto",
            "=https",
            "--tlsv1.2",
            "-fsSIL",
            "--max-time",
            "20",
        ])
        .arg(url)
        .env_clear()
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|l| l.split_once(':'))
        .filter(|(name, _)| name.trim().eq_ignore_ascii_case("content-length"))
        .filter_map(|(_, value)| value.trim().parse::<u64>().ok())
        .next_back()
        .filter(|size| *size > 0)
}

/// Downloads `url` into `target` and checks its SHA-256 (hex, any case) against `sha256`;
/// returns the digest that was computed.
pub fn download_verified(url: &str, target: &Path, sha256: &str) -> Result<String> {
    download(url, target)?;
    let actual = hash::sha256_file(target)?;
    ensure!(actual.eq_ignore_ascii_case(sha256), "checksum_mismatch");
    Ok(actual)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_https_is_accepted() {
        let dir = tempfile::tempdir().unwrap();
        for url in ["http://example.com/a", "file:///etc/passwd", "ftp://x/y"] {
            assert_eq!(
                fetch(url, 10).unwrap_err().to_string(),
                "insecure_url",
                "{url}"
            );
            assert_eq!(
                download(url, &dir.path().join("a"))
                    .unwrap_err()
                    .to_string(),
                "insecure_url"
            );
            assert!(download_verified(url, &dir.path().join("a"), "00").is_err());
        }
        // Nothing listens on port 1: no connection, said as such.
        assert_eq!(
            fetch("https://127.0.0.1:1/x", 10).unwrap_err().to_string(),
            "download_offline"
        );
        assert_eq!(curl_failure(Some(22)), "download_failed");
    }
}
