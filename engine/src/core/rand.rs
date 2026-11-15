//! Randomness from the system source. Failing to read it is an error: a secret is never
//! built from zeros.

use anyhow::Result;
use std::{fs::File, io::Read};

/// `count` random bytes from `/dev/urandom`.
pub fn random_bytes(count: usize) -> Result<Vec<u8>> {
    let mut buffer = vec![0u8; count];
    File::open("/dev/urandom")?.read_exact(&mut buffer)?;
    Ok(buffer)
}

/// `bytes` random bytes as lowercase hex (so `2 * bytes` characters).
pub fn random_hex(bytes: usize) -> Result<String> {
    Ok(random_bytes(bytes)?
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect())
}

/// A random 64-bit number.
pub fn random_u64() -> Result<u64> {
    let bytes = random_bytes(8)?;
    Ok(u64::from_le_bytes(bytes.try_into().expect("8 bytes")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_has_two_characters_per_byte_and_differs() {
        let a = random_hex(24).unwrap();
        assert_eq!(a.len(), 48);
        assert!(a.bytes().all(|c| c.is_ascii_hexdigit()));
        assert_ne!(a, random_hex(24).unwrap());
        assert_ne!(random_u64().unwrap(), random_u64().unwrap());
    }
}
