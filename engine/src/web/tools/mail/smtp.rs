//! The SMTP server: accepts every message from the local sites and hands it to the store.
use super::store::save;
use crate::core::model::MailConfig;
use anyhow::Result;
use std::{path::PathBuf, time::Duration};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    net::TcpListener,
};

const MAX_MESSAGE: usize = 25 * 1024 * 1024;
const MAX_LINE: u64 = 8192;
const MAX_RECIPIENTS: usize = 100;

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

pub(super) async fn session<S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin>(
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
            "EHLO" => format!(
                "250-butake-stack\r\n250-SIZE {MAX_MESSAGE}\r\n250-8BITMIME\r\n250-SMTPUTF8\r\n250 AUTH PLAIN LOGIN\r\n"
            ),
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
                        writer
                            .write_all(b"504 5.5.4 Unrecognized authentication type\r\n")
                            .await?;
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
                    writer
                        .write_all(b"354 End data with <CR><LF>.<CR><LF>\r\n")
                        .await?;
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
                        let content = if first_piece && line.starts_with(b"..") {
                            &line[1..]
                        } else {
                            &line[..]
                        };
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
                        let saved = tokio::task::spawn_blocking(move || {
                            save(&dir, &envelope, &to, &data, &config)
                        })
                        .await;
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
