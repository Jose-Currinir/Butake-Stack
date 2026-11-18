//! ECDSA P-256 / SHA-256 signature check with Security.framework, no extra dependencies. Used for
//! files Stack downloads that carry Stack's own signature (the PHP catalog). The public key is the
//! uncompressed X9.63 point (65 bytes); the signature is DER, as `openssl dgst -sha256 -sign` writes.

use anyhow::{Result, ensure};

#[cfg(target_os = "macos")]
#[allow(non_upper_case_globals, non_snake_case)]
mod ffi {
    use std::ffi::c_void;
    pub type CFTypeRef = *const c_void;
    pub type CFIndex = isize;
    #[repr(C)]
    pub struct CallBacks {
        _private: [u8; 0],
    }

    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        pub static kCFTypeDictionaryKeyCallBacks: CallBacks;
        pub static kCFTypeDictionaryValueCallBacks: CallBacks;
        pub fn CFDataCreate(allocator: CFTypeRef, bytes: *const u8, length: CFIndex) -> CFTypeRef;
        pub fn CFDictionaryCreate(
            allocator: CFTypeRef,
            keys: *const CFTypeRef,
            values: *const CFTypeRef,
            count: CFIndex,
            key_callbacks: *const CallBacks,
            value_callbacks: *const CallBacks,
        ) -> CFTypeRef;
        pub fn CFRelease(value: CFTypeRef);
    }

    #[link(name = "Security", kind = "framework")]
    unsafe extern "C" {
        pub static kSecAttrKeyType: CFTypeRef;
        pub static kSecAttrKeyTypeECSECPrimeRandom: CFTypeRef;
        pub static kSecAttrKeyClass: CFTypeRef;
        pub static kSecAttrKeyClassPublic: CFTypeRef;
        pub static kSecKeyAlgorithmECDSASignatureMessageX962SHA256: CFTypeRef;
        pub fn SecKeyCreateWithData(
            key_data: CFTypeRef,
            attributes: CFTypeRef,
            error: *mut CFTypeRef,
        ) -> CFTypeRef;
        pub fn SecKeyVerifySignature(
            key: CFTypeRef,
            algorithm: CFTypeRef,
            signed_data: CFTypeRef,
            signature: CFTypeRef,
            error: *mut CFTypeRef,
        ) -> u8;
    }
}

/// A Core Foundation object this code created and releases when dropped.
#[cfg(target_os = "macos")]
struct Owned(ffi::CFTypeRef);

#[cfg(target_os = "macos")]
impl Drop for Owned {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: `self.0` is non-null and a reference this wrapper owns (from a `Create`
            // function or an out-parameter error); it is released once, here, because `Owned` is
            // neither `Clone` nor `Copy`.
            unsafe { ffi::CFRelease(self.0) }
        }
    }
}

#[cfg(target_os = "macos")]
fn data(bytes: &[u8]) -> Owned {
    // SAFETY: the pointer and length come from one live slice and CoreFoundation copies the bytes
    // during the call; a null allocator is the default one.
    Owned(unsafe {
        ffi::CFDataCreate(
            std::ptr::null(),
            bytes.as_ptr(),
            bytes.len() as ffi::CFIndex,
        )
    })
}

/// Checks that `signature` (DER) is a valid ECDSA P-256 signature of SHA-256(`message`) made by the
/// holder of `public_key` (X9.63, 65 bytes). Any malformed input is an error, never a pass.
#[cfg(target_os = "macos")]
pub fn verify(public_key: &[u8], message: &[u8], signature: &[u8]) -> Result<()> {
    use ffi::*;
    ensure!(
        public_key.len() == 65 && public_key[0] == 4,
        "invalid_public_key"
    );
    ensure!(
        !signature.is_empty() && signature.len() <= 80,
        "signature_invalid"
    );
    let (key_data, message, signature) = (data(public_key), data(message), data(signature));
    // SAFETY: reads extern statics that Security.framework initializes before any code runs and
    // never changes.
    let (keys, values) = unsafe {
        (
            [kSecAttrKeyType, kSecAttrKeyClass],
            [kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClassPublic],
        )
    };
    // SAFETY: `keys` and `values` are live arrays of two CF constants that outlive the call (the
    // dictionary retains them with the standard CFType callbacks, whose statics are valid for the
    // whole process).
    let attributes = Owned(unsafe {
        CFDictionaryCreate(
            std::ptr::null(),
            keys.as_ptr(),
            values.as_ptr(),
            2,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks,
        )
    });
    ensure!(!attributes.0.is_null(), "signature_invalid");
    let mut error: CFTypeRef = std::ptr::null();
    // SAFETY: `key_data` and `attributes` are live CF objects owned here; `error` is a valid
    // out-pointer that is wrapped (and released) right after the call.
    let key = Owned(unsafe { SecKeyCreateWithData(key_data.0, attributes.0, &mut error) });
    drop(Owned(error));
    ensure!(!key.0.is_null(), "invalid_public_key");
    let mut error: CFTypeRef = std::ptr::null();
    // SAFETY: reads an extern static that Security.framework initializes and never changes.
    let algorithm = unsafe { kSecKeyAlgorithmECDSASignatureMessageX962SHA256 };
    // SAFETY: `key`, `message` and `signature` are live CF objects owned here, `algorithm` is a
    // constant string, and `error` is a valid out-pointer that is wrapped (and released) after.
    let valid =
        unsafe { SecKeyVerifySignature(key.0, algorithm, message.0, signature.0, &mut error) };
    drop(Owned(error));
    ensure!(valid != 0, "signature_invalid");
    Ok(())
}

#[cfg(not(target_os = "macos"))]
pub fn verify(_public_key: &[u8], _message: &[u8], _signature: &[u8]) -> Result<()> {
    anyhow::bail!("signature_invalid")
}
