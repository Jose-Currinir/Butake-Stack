//! Minimal authoritative DNS for the local TLDs: A 127.0.0.1 for any name under them (AAAA
//! gets an empty answer: the stack listens on IPv4 only, so browsers must not try ::1 first),
//! NXDOMAIN otherwise. Only macOS's resolver sends queries here (/etc/resolver/<tld>).
use std::sync::Arc;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, UdpSocket},
};

const TTL: u32 = 60;

/// Builds the answer for one query packet, or None when the packet is not a plain query.
pub fn answer(query: &[u8], tlds: &[String]) -> Option<Vec<u8>> {
    if query.len() < 12 || query.len() > 512 {
        return None;
    }
    let flags = u16::from_be_bytes([query[2], query[3]]);
    let qdcount = u16::from_be_bytes([query[4], query[5]]);
    if flags & 0x8000 != 0 || (flags >> 11) & 0xF != 0 || qdcount != 1 {
        return None;
    }
    let mut pos = 12;
    let mut labels = vec![];
    loop {
        let len = *query.get(pos)? as usize;
        pos += 1;
        if len == 0 {
            break;
        }
        if len > 63 {
            return None;
        }
        labels.push(String::from_utf8(query.get(pos..pos + len)?.to_vec()).ok()?.to_ascii_lowercase());
        pos += len;
    }
    let qtype = u16::from_be_bytes([*query.get(pos)?, *query.get(pos + 1)?]);
    let qclass = u16::from_be_bytes([*query.get(pos + 2)?, *query.get(pos + 3)?]);
    let question_end = pos + 4;
    let local = labels
        .last()
        .is_some_and(|tld| tlds.iter().any(|t| t == tld));
    let mut out = query[..question_end].to_vec();
    // QR, AA, RD copied, RA; rcode 0 or 3.
    let rd = flags & 0x0100;
    let rcode = if local { 0 } else { 3 };
    out[2..4].copy_from_slice(&(0x8400 | rd | 0x0080 | rcode).to_be_bytes());
    out[6..12].copy_from_slice(&[0, 0, 0, 0, 0, 0]);
    let data: Option<Vec<u8>> = match (local, qclass, qtype) {
        (true, 1, 1) => Some(vec![127, 0, 0, 1]),
        _ => None,
    };
    if let Some(data) = data {
        out[6..8].copy_from_slice(&1u16.to_be_bytes());
        out.extend_from_slice(&[0xC0, 0x0C]); // pointer to the question name
        out.extend_from_slice(&qtype.to_be_bytes());
        out.extend_from_slice(&1u16.to_be_bytes());
        out.extend_from_slice(&TTL.to_be_bytes());
        out.extend_from_slice(&(data.len() as u16).to_be_bytes());
        out.extend_from_slice(&data);
    }
    Some(out)
}

pub async fn serve_udp(socket: UdpSocket, tlds: Arc<Vec<String>>) {
    let mut buffer = [0u8; 512];
    loop {
        let Ok((count, peer)) = socket.recv_from(&mut buffer).await else {
            continue;
        };
        if let Some(reply) = answer(&buffer[..count], &tlds) {
            let _ = socket.send_to(&reply, peer).await;
        }
    }
}

pub async fn serve_tcp(listener: TcpListener, tlds: Arc<Vec<String>>) {
    loop {
        let Ok((mut stream, _)) = listener.accept().await else {
            continue;
        };
        let tlds = tlds.clone();
        tokio::spawn(async move {
            let job = async {
                let length = stream.read_u16().await? as usize;
                let mut buffer = vec![0; length.min(512)];
                stream.read_exact(&mut buffer).await?;
                if let Some(reply) = answer(&buffer, &tlds) {
                    stream.write_u16(reply.len() as u16).await?;
                    stream.write_all(&reply).await?;
                }
                anyhow::Ok(())
            };
            let _ = tokio::time::timeout(std::time::Duration::from_secs(5), job).await;
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn query(name: &str, qtype: u16) -> Vec<u8> {
        let mut q = vec![0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0];
        for label in name.split('.') {
            q.push(label.len() as u8);
            q.extend_from_slice(label.as_bytes());
        }
        q.push(0);
        q.extend_from_slice(&qtype.to_be_bytes());
        q.extend_from_slice(&1u16.to_be_bytes());
        q
    }
    #[test]
    fn answers_local_names_only() {
        let tlds = vec!["test".to_string()];
        let a = answer(&query("Gestion.TEST", 1), &tlds).unwrap();
        assert_eq!(&a[0..2], &[0x12, 0x34]);
        assert_eq!(a[3] & 0x0F, 0);
        assert_eq!(u16::from_be_bytes([a[6], a[7]]), 1);
        assert_eq!(&a[a.len() - 4..], &[127, 0, 0, 1]);
        let aaaa = answer(&query("x.y.test", 28), &tlds).unwrap();
        assert_eq!(u16::from_be_bytes([aaaa[6], aaaa[7]]), 0);
        assert_eq!(aaaa[3] & 0x0F, 0);
        let mx = answer(&query("a.test", 15), &tlds).unwrap();
        assert_eq!(u16::from_be_bytes([mx[6], mx[7]]), 0);
        let other = answer(&query("google.com", 1), &tlds).unwrap();
        assert_eq!(other[3] & 0x0F, 3);
        assert!(answer(&[0; 5], &tlds).is_none());
        let mut response = query("a.test", 1);
        response[2] |= 0x80;
        assert!(answer(&response, &tlds).is_none());
        let mut bad = query("a.test", 1);
        bad[12] = 200;
        assert!(answer(&bad, &tlds).is_none());
    }
}
