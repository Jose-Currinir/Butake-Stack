//! Access keys kept in the macOS Keychain for profiles that read them through Stack's credential
//! process (see `helper.rs`). The engine writes them itself, so the item's access list trusts the
//! engine (the program that later answers the CLI) and no other program; the app never reads them
//! back. One generic password per profile, this device only, never synchronized. A QA store
//! (`BUTAKE_STACK_HOME`) uses its own service, like the app's other Keychain items.

use anyhow::Result;

/// Where the secrets of profiles live. The engine uses the Keychain; tests use memory.
pub trait Secrets {
    fn set(&self, account: &str, value: &[u8]) -> Result<()>;
    fn get(&self, account: &str) -> Result<Option<Vec<u8>>>;
    fn delete(&self, account: &str) -> Result<()>;

    /// Moves a secret to another account; nothing leaves the engine. A renamed profile does not
    /// use it (`Changes::save` copies first and deletes after the files are written).
    #[cfg(test)]
    fn rename(&self, from: &str, to: &str) -> Result<()> {
        if let Some(value) = self.get(from)? {
            self.set(to, &value)?;
            self.delete(from)?;
        }
        Ok(())
    }
}

pub fn service() -> &'static str {
    if std::env::var_os("BUTAKE_STACK_HOME").is_some() {
        "cl.butake.stack.aws.qa"
    } else {
        "cl.butake.stack.aws"
    }
}

/// The login Keychain, through Security.framework.
pub struct Keychain;

#[cfg(target_os = "macos")]
#[allow(non_upper_case_globals, non_snake_case)]
mod ffi {
    use std::ffi::c_void;
    pub type CFTypeRef = *const c_void;
    pub type OSStatus = i32;
    pub type CFIndex = isize;
    #[repr(C)]
    pub struct CallBacks {
        _private: [u8; 0],
    }
    pub const UTF8: u32 = 0x0800_0100;
    pub const SUCCESS: OSStatus = 0;
    pub const NOT_FOUND: OSStatus = -25300;

    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        pub static kCFTypeDictionaryKeyCallBacks: CallBacks;
        pub static kCFTypeDictionaryValueCallBacks: CallBacks;
        pub static kCFBooleanTrue: CFTypeRef;
        pub static kCFBooleanFalse: CFTypeRef;
        pub fn CFStringCreateWithBytes(
            allocator: CFTypeRef,
            bytes: *const u8,
            length: CFIndex,
            encoding: u32,
            external: u8,
        ) -> CFTypeRef;
        pub fn CFDataCreate(allocator: CFTypeRef, bytes: *const u8, length: CFIndex) -> CFTypeRef;
        pub fn CFDataGetLength(data: CFTypeRef) -> CFIndex;
        pub fn CFDataGetBytePtr(data: CFTypeRef) -> *const u8;
        pub fn CFDataGetTypeID() -> usize;
        pub fn CFGetTypeID(value: CFTypeRef) -> usize;
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
        pub static kSecClass: CFTypeRef;
        pub static kSecClassGenericPassword: CFTypeRef;
        pub static kSecAttrService: CFTypeRef;
        pub static kSecAttrAccount: CFTypeRef;
        pub static kSecAttrLabel: CFTypeRef;
        pub static kSecAttrSynchronizable: CFTypeRef;
        pub static kSecAttrAccessible: CFTypeRef;
        pub static kSecAttrAccessibleWhenUnlockedThisDeviceOnly: CFTypeRef;
        pub static kSecValueData: CFTypeRef;
        pub static kSecReturnData: CFTypeRef;
        pub static kSecMatchLimit: CFTypeRef;
        pub static kSecMatchLimitOne: CFTypeRef;
        pub fn SecItemAdd(attributes: CFTypeRef, result: *mut CFTypeRef) -> OSStatus;
        pub fn SecItemCopyMatching(query: CFTypeRef, result: *mut CFTypeRef) -> OSStatus;
        pub fn SecItemUpdate(query: CFTypeRef, changes: CFTypeRef) -> OSStatus;
        pub fn SecItemDelete(query: CFTypeRef) -> OSStatus;
    }
}

#[cfg(target_os = "macos")]
mod cf {
    use super::ffi::*;

    /// A Core Foundation object this code created and releases when dropped.
    pub struct Owned(pub CFTypeRef);
    impl Drop for Owned {
        fn drop(&mut self) {
            if !self.0.is_null() {
                // SAFETY: `self.0` is non-null and an object this wrapper owns (one reference
                // from a `Create` function or from `SecItemCopyMatching`); it is released once,
                // here, because `Owned` is neither `Clone` nor `Copy`.
                unsafe { CFRelease(self.0) }
            }
        }
    }

    pub fn string(text: &str) -> Owned {
        // SAFETY: the pointer and length come from one live `&str` and CoreFoundation copies the
        // bytes during the call; a null allocator is the default one.
        Owned(unsafe {
            CFStringCreateWithBytes(
                std::ptr::null(),
                text.as_ptr(),
                text.len() as CFIndex,
                UTF8,
                0,
            )
        })
    }

    pub fn data(bytes: &[u8]) -> Owned {
        // SAFETY: the pointer and length come from one live slice and CoreFoundation copies the
        // bytes during the call; a null allocator is the default one.
        Owned(unsafe { CFDataCreate(std::ptr::null(), bytes.as_ptr(), bytes.len() as CFIndex) })
    }

    pub fn dictionary(pairs: &[(CFTypeRef, CFTypeRef)]) -> Owned {
        let keys: Vec<CFTypeRef> = pairs.iter().map(|p| p.0).collect();
        let values: Vec<CFTypeRef> = pairs.iter().map(|p| p.1).collect();
        // SAFETY: `keys` and `values` are live arrays of `pairs.len()` CF objects that the callers
        // keep alive for the call (the dictionary retains them with the standard CFType
        // callbacks, whose statics are valid for the whole process).
        Owned(unsafe {
            CFDictionaryCreate(
                std::ptr::null(),
                keys.as_ptr(),
                values.as_ptr(),
                pairs.len() as CFIndex,
                &kCFTypeDictionaryKeyCallBacks,
                &kCFTypeDictionaryValueCallBacks,
            )
        })
    }
}

#[cfg(target_os = "macos")]
impl Keychain {
    fn query(
        account: &cf::Owned,
        service: &cf::Owned,
        extra: &[(ffi::CFTypeRef, ffi::CFTypeRef)],
    ) -> cf::Owned {
        use ffi::*;
        // SAFETY: reads extern statics that Security.framework and CoreFoundation initialize before
        // any code runs and never change.
        let mut pairs = unsafe {
            vec![
                (kSecClass, kSecClassGenericPassword),
                (kSecAttrService, service.0),
                (kSecAttrAccount, account.0),
                (kSecAttrSynchronizable, kCFBooleanFalse),
            ]
        };
        pairs.extend_from_slice(extra);
        cf::dictionary(&pairs)
    }
}

#[cfg(target_os = "macos")]
impl Secrets for Keychain {
    fn set(&self, account: &str, value: &[u8]) -> Result<()> {
        use ffi::*;
        let (name, service, data) = (cf::string(account), cf::string(service()), cf::data(value));
        let query = Self::query(&name, &service, &[]);
        // SAFETY: reads an extern static that Security.framework initializes and never changes.
        let change = cf::dictionary(&[(unsafe { kSecValueData }, data.0)]);
        // SAFETY: `query` and `change` are live CF dictionaries owned here; the call keeps neither.
        let updated = unsafe { SecItemUpdate(query.0, change.0) };
        if updated == SUCCESS {
            return Ok(());
        }
        anyhow::ensure!(updated == NOT_FOUND, "aws_keychain_failed");
        let label = cf::string(&format!("Stack · AWS · {account}"));
        // SAFETY: reads extern statics that Security.framework initializes and never changes.
        let attributes = Self::query(&name, &service, &unsafe {
            [
                (kSecValueData, data.0),
                (kSecAttrLabel, label.0),
                (
                    kSecAttrAccessible,
                    kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                ),
            ]
        });
        // SAFETY: `attributes` is a live CF dictionary owned here, and a null result pointer asks
        // for no result.
        let added = unsafe { SecItemAdd(attributes.0, std::ptr::null_mut()) };
        anyhow::ensure!(added == SUCCESS, "aws_keychain_failed");
        Ok(())
    }

    fn get(&self, account: &str) -> Result<Option<Vec<u8>>> {
        use ffi::*;
        let (name, service) = (cf::string(account), cf::string(service()));
        // SAFETY: reads extern statics that Security.framework initializes and never changes.
        let query = Self::query(&name, &service, &unsafe {
            [
                (kSecReturnData, kCFBooleanTrue),
                (kSecMatchLimit, kSecMatchLimitOne),
            ]
        });
        let mut result: CFTypeRef = std::ptr::null();
        // SAFETY: `query` is a live CF dictionary and `result` a live local pointer that the call
        // sets (to a retained object when it succeeds).
        let status = unsafe { SecItemCopyMatching(query.0, &mut result) };
        if status == NOT_FOUND {
            return Ok(None);
        }
        anyhow::ensure!(
            status == SUCCESS && !result.is_null(),
            "aws_keychain_failed"
        );
        let result = cf::Owned(result);
        anyhow::ensure!(
            // SAFETY: `result` is a non-null CF object owned here; both calls only read it.
            unsafe { CFGetTypeID(result.0) == CFDataGetTypeID() },
            "aws_keychain_failed"
        );
        // SAFETY: `result` is a CFData (checked above); the call only reads it.
        let length = unsafe { CFDataGetLength(result.0) } as usize;
        // `CFDataGetBytePtr` can return null for an empty item: answer it without building a slice.
        if length == 0 {
            return Ok(Some(Vec::new()));
        }
        // SAFETY: `result` is a CFData of `length` bytes that stays alive until the end of this
        // function, and the slice is copied before then.
        let bytes = unsafe { std::slice::from_raw_parts(CFDataGetBytePtr(result.0), length) };
        Ok(Some(bytes.to_vec()))
    }

    fn delete(&self, account: &str) -> Result<()> {
        use ffi::*;
        let (name, service) = (cf::string(account), cf::string(service()));
        let query = Self::query(&name, &service, &[]);
        // SAFETY: `query` is a live CF dictionary owned here; the call does not keep it.
        let status = unsafe { SecItemDelete(query.0) };
        anyhow::ensure!(
            status == SUCCESS || status == NOT_FOUND,
            "aws_keychain_failed"
        );
        Ok(())
    }
}

#[cfg(not(target_os = "macos"))]
impl Secrets for Keychain {
    fn set(&self, _: &str, _: &[u8]) -> Result<()> {
        anyhow::bail!("aws_keychain_failed")
    }
    fn get(&self, _: &str) -> Result<Option<Vec<u8>>> {
        anyhow::bail!("aws_keychain_failed")
    }
    fn delete(&self, _: &str) -> Result<()> {
        anyhow::bail!("aws_keychain_failed")
    }
}

/// Secrets in memory, for tests (never the real Keychain).
#[cfg(test)]
#[derive(Default)]
pub struct Memory(pub std::cell::RefCell<std::collections::BTreeMap<String, Vec<u8>>>);

#[cfg(test)]
impl Secrets for Memory {
    fn set(&self, account: &str, value: &[u8]) -> Result<()> {
        self.0.borrow_mut().insert(account.into(), value.to_vec());
        Ok(())
    }
    fn get(&self, account: &str) -> Result<Option<Vec<u8>>> {
        Ok(self.0.borrow().get(account).cloned())
    }
    fn delete(&self, account: &str) -> Result<()> {
        self.0.borrow_mut().remove(account);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Writes, reads, renames and deletes an item of the QA service with made-up bytes. It touches
    /// the login Keychain, so it only runs when asked: `cargo test -- --ignored keychain`.
    #[test]
    #[ignore]
    fn keychain_round_trip_on_the_qa_service() {
        // SAFETY: this test is `#[ignore]` and runs alone (`--ignored`, one test): no other thread
        // reads the environment while it changes.
        unsafe { std::env::set_var("BUTAKE_STACK_HOME", "/nonexistent-qa") };
        assert_eq!(service(), "cl.butake.stack.aws.qa");
        let keychain = Keychain;
        keychain.delete("prueba-qa").unwrap();
        keychain.delete("prueba-qa-2").unwrap();
        assert_eq!(keychain.get("prueba-qa").unwrap(), None);
        keychain.set("prueba-qa", b"no-es-real").unwrap();
        keychain.set("prueba-qa", b"no-es-real-2").unwrap();
        assert_eq!(
            keychain.get("prueba-qa").unwrap().as_deref(),
            Some(&b"no-es-real-2"[..])
        );
        keychain.rename("prueba-qa", "prueba-qa-2").unwrap();
        assert_eq!(keychain.get("prueba-qa").unwrap(), None);
        assert!(keychain.get("prueba-qa-2").unwrap().is_some());
        keychain.delete("prueba-qa-2").unwrap();
        assert_eq!(keychain.get("prueba-qa-2").unwrap(), None);
    }
}
