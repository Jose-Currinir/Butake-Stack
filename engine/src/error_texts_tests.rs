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

/// Every `.swift` file under `dir`, read.
fn swift_sources(dir: &std::path::Path, out: &mut String) {
    for entry in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        let path = entry.path();
        if path.is_dir() {
            swift_sources(&path, out);
        } else if path.extension().is_some_and(|ext| ext == "swift") {
            out.push_str(&std::fs::read_to_string(&path).unwrap_or_default());
        }
    }
}

/// The other direction: an `error.<code>` text that no engine code reaches and that the app does
/// not name itself is a leftover (the code was renamed or removed and its text stayed).
#[test]
fn no_error_text_is_left_without_a_code() {
    let keys = text_keys();
    let mut codes: BTreeSet<&str> = PUBLIC_ERRORS.iter().copied().collect();
    codes.extend(DETAILED_ERRORS);
    codes.extend(["database_error", "ssh_key_in_use", "source_rate_limited"]);
    let mut app = String::new();
    swift_sources(
        &std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../native/Sources"),
        &mut app,
    );
    assert!(app.len() > 100_000, "the app's sources were read");
    let orphans: Vec<&String> = keys
        .iter()
        .filter(|key| {
            key.strip_prefix("error.")
                .is_some_and(|code| !code.is_empty() && !codes.contains(code))
        })
        // The app writes `error.<code>` itself (its own codes) or builds the key from a prefix.
        .filter(|key| !app.contains(&format!("\"{key}\"")))
        // The skills import answers these in its own result (`reason`), not as an error code.
        .filter(|key| !key.starts_with("error.skills_import_"))
        // An unknown method answers `engine.requestFailed` on purpose (`tests/cli.rs`): the text is
        // kept for a version of the app that is newer than its engine.
        .filter(|key| *key != "error.unknown_method")
        .collect();
    assert!(
        orphans.is_empty(),
        "error.* texts without a code: {orphans:?}"
    );
}
