use super::smtp::session;
use super::store::{prune, save};
use super::*;
use crate::core::model::MailConfig;
use serde_json::json;
use std::fs;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

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

async fn expect(reader: &mut BufReader<tokio::io::ReadHalf<tokio::io::DuplexStream>>, code: &str) {
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

#[test]
fn rfc2231_values_survive_percent_before_multibyte_text() {
    use super::mime::parameters;
    let name = |value: &str| {
        let (_, params) = parameters(value);
        params.into_iter().find(|(n, _)| n == "filename").unwrap().1
    };
    // Used to panic: the slice after `%` cut through a multibyte character.
    assert_eq!(name("attachment; filename*=UTF-8''%€x"), "%€x");
    assert_eq!(name("attachment; filename*=UTF-8''a%1éz"), "a%1éz");
    // A escape that ends the value is decoded too.
    assert_eq!(name("attachment; filename*=UTF-8''a%41"), "aA");
    assert_eq!(name("attachment; filename*=UTF-8''%"), "%");
}
