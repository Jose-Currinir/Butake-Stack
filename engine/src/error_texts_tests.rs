//! Every error code the engine hands the app with its own message has that message in Spanish:
//! `error.<code>` in the app's `Localizable.strings` (the app shows the key the engine names).
use super::{DETAILED_ERRORS, PUBLIC_ERRORS};
use std::collections::BTreeSet;

/// The keys of the app's texts.
fn text_keys() -> BTreeSet<String> {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../native/Sources/ButakeStack/Resources/es.lproj/Localizable.strings");
    let text = std::fs::read_to_string(&path).expect("Localizable.strings");
    text.lines()
        .filter_map(|line| line.trim_start().strip_prefix('"'))
        .filter_map(|rest| rest.split_once("\" = ").map(|(key, _)| key.to_string()))
        .collect()
}

#[test]
fn every_public_error_code_has_its_text() {
    let keys = text_keys();
    assert!(keys.len() > 3000, "{} keys read", keys.len());
    // The codes answered with a fixed key in `main` (database, SSH key in use, rate limit) too.
    let fixed = ["database_error", "ssh_key_in_use", "source_rate_limited"];
    let mut codes: BTreeSet<&str> = PUBLIC_ERRORS.iter().copied().collect();
    codes.extend(DETAILED_ERRORS);
    codes.extend(fixed);
    let missing: Vec<_> = codes
        .iter()
        .filter(|code| !keys.contains(&format!("error.{code}")))
        .collect();
    assert!(missing.is_empty(), "error.<code> missing: {missing:?}");
    // No code is listed twice (a copy would hide that one of them was meant to be another).
    assert_eq!(
        PUBLIC_ERRORS.len(),
        PUBLIC_ERRORS.iter().collect::<BTreeSet<_>>().len()
    );
}
