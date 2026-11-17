//! Stack's credential process for AWS CLI: `butake-stack aws-credential <profile>`.
//!
//! A profile whose keys the user chose to keep in the Keychain says, in the config file,
//! `credential_process = "<engine>" aws-credential <profile>`. The CLI runs that command when it
//! needs the profile's credentials and reads the JSON it prints. That output is the subcommand's
//! purpose, so it carries the secret, but only to the CLI's pipe: it is never logged, never written
//! to stderr, and it answers only for the profile asked, only when the config file really points
//! that profile at this subcommand.

use super::{
    ini::Document,
    keychain::{Keychain, Secrets},
    profiles, Files,
};
use anyhow::{ensure, Result};
use serde_json::json;
use std::{
    ffi::OsString,
    path::{Path, PathBuf},
};

pub const SUBCOMMAND: &str = "aws-credential";

/// The engine that is running, by its real path: what a new profile points at.
pub fn program() -> Option<PathBuf> {
    std::env::current_exe()
        .ok()
        .and_then(|p| p.canonicalize().ok())
}

/// A profile name Stack writes: letters, digits, dot, dash and underscore (also what the
/// credential process line accepts without quotes).
pub fn valid_name(name: &str) -> bool {
    (1..=64).contains(&name.len())
        && name.as_bytes()[0].is_ascii_alphanumeric()
        && name
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'.' | b'-' | b'_'))
}

/// The `credential_process` line for `profile`. The CLI accepts in a program's path only letters,
/// digits, `-`, `_`, `.` and spaces (and `/`): any other path is refused.
pub fn line(program: &Path, profile: &str) -> Result<String> {
    let text = program.to_str().unwrap_or("");
    ensure!(
        program.is_absolute()
            && text
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'-' | b'_' | b'.' | b' ' | b'/')),
        "aws_helper_path_unsupported"
    );
    ensure!(valid_name(profile), "aws_invalid_profile");
    Ok(format!("\"{text}\" {SUBCOMMAND} {profile}"))
}

/// Whether a `credential_process` line is Stack's and where its program is: `ok` (this engine),
/// `other` (another copy of Stack, still there) or `missing`. None for any other process.
pub fn state(line: &str, current: Option<&Path>) -> Option<String> {
    let words = profiles::words(line);
    if words.get(1).map(String::as_str) != Some(SUBCOMMAND) {
        return None;
    }
    let program = Path::new(&words[0]);
    Some(
        if Some(program) == current {
            "ok"
        } else if program.is_file() {
            "other"
        } else {
            "missing"
        }
        .into(),
    )
}

/// The profile asked is Stack's in the config file: its credential process is this subcommand
/// for this same profile.
fn points_here(config: &Document, profile: &str) -> bool {
    let Ok(section) = profiles::config_section(config, profile) else {
        return false;
    };
    let Ok(Some(section)) = config.find(&section) else {
        return false;
    };
    let words = config
        .get(&section, "credential_process")
        .map(|l| profiles::words(&l))
        .unwrap_or_default();
    words.len() == 3 && words[1] == SUBCOMMAND && words[2] == profile
}

/// The JSON the CLI expects (Version 1, long-term keys: no Expiration).
fn answer(secrets: &dyn Secrets, config: &Document, profile: &str) -> Result<String> {
    ensure!(
        valid_name(profile) && points_here(config, profile),
        "aws_profile_not_found"
    );
    let stored = secrets
        .get(profile)?
        .ok_or_else(|| anyhow::anyhow!("aws_keychain_missing"))?;
    let keys: serde_json::Value = serde_json::from_slice(&stored)?;
    let id = keys["AccessKeyId"].as_str().unwrap_or("");
    let secret = keys["SecretAccessKey"].as_str().unwrap_or("");
    ensure!(!id.is_empty() && !secret.is_empty(), "aws_keychain_missing");
    Ok(json!({"Version": 1, "AccessKeyId": id, "SecretAccessKey": secret}).to_string())
}

/// Runs the subcommand; the exit code for the CLI. Errors say only which step failed.
pub fn run(arguments: &[OsString]) -> i32 {
    let profile = arguments.first().and_then(|a| a.to_str()).unwrap_or("");
    let result = Files::from_environment()
        .and_then(|files| super::read(&files.config))
        .and_then(|text| answer(&Keychain, &Document::parse(&text), profile));
    match result {
        Ok(json) => {
            // A CLI that closed the pipe must not make this panic.
            use std::io::Write;
            match writeln!(std::io::stdout(), "{json}") {
                Ok(()) => 0,
                Err(_) => 1,
            }
        }
        Err(error) => {
            let message = match error.to_string().as_str() {
                "aws_keychain_missing" => "las claves de este perfil no están en el Llavero",
                "aws_keychain_failed" => "no se pudo leer el Llavero",
                "aws_profile_not_found" => "este perfil no usa las claves del Llavero de Stack",
                _ => "no se pudieron leer las credenciales",
            };
            eprintln!("Stack: {message}");
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::aws::keychain::Memory;

    #[test]
    fn answers_only_for_a_profile_pointed_here_and_with_its_own_keys() {
        let program = Path::new("/Applications/Stack P17.app/Contents/Resources/butake-stack");
        let config = Document::parse(&format!(
            "[profile llavero]\ncredential_process = {}\n[profile ajeno]\ncredential_process = /opt/x aws-credential llavero\n[profile cambiado]\ncredential_process = {}\n",
            line(program, "llavero").unwrap(),
            line(program, "llavero").unwrap()
        ));
        let secrets = Memory::default();
        assert_eq!(
            answer(&secrets, &config, "llavero")
                .unwrap_err()
                .to_string(),
            "aws_keychain_missing"
        );
        secrets
            .set(
                "llavero",
                br#"{"AccessKeyId":"AKIAEJEMPLO0001","SecretAccessKey":"secreto/de+ejemplo"}"#,
            )
            .unwrap();
        secrets
            .set(
                "ajeno",
                br#"{"AccessKeyId":"AKIAEJEMPLO0002","SecretAccessKey":"otro"}"#,
            )
            .unwrap();
        let out: serde_json::Value =
            serde_json::from_str(&answer(&secrets, &config, "llavero").unwrap()).unwrap();
        assert_eq!(out["Version"], 1);
        assert_eq!(out["AccessKeyId"], "AKIAEJEMPLO0001");
        assert_eq!(out["SecretAccessKey"], "secreto/de+ejemplo");
        assert!(out.get("Expiration").is_none());
        // A profile whose line is not exactly this subcommand for itself gets nothing.
        for other in ["ajeno", "cambiado", "nadie", "../x", ""] {
            assert!(answer(&secrets, &config, other).is_err(), "{other}");
        }
    }

    #[test]
    fn lines_quote_the_path_and_refuse_what_the_cli_cannot_read() {
        let program = Path::new("/nonexistent/Stack QA 9.app/Contents/Resources/butake-stack");
        let written = line(program, "acme-dev").unwrap();
        assert_eq!(
            written,
            "\"/nonexistent/Stack QA 9.app/Contents/Resources/butake-stack\" aws-credential acme-dev"
        );
        assert_eq!(state(&written, Some(program)).as_deref(), Some("ok"));
        assert_eq!(state(&written, None).as_deref(), Some("missing"));
        assert_eq!(state("/opt/x --profile y", Some(program)), None);
        assert!(line(Path::new("/Users/josé/butake-stack"), "a").is_err());
        assert!(line(Path::new("relativo/butake-stack"), "a").is_err());
        assert!(line(program, "con espacio").is_err());
        assert!(valid_name("acme-prod_2.x") && !valid_name("") && !valid_name(&"a".repeat(65)));
        assert!(!valid_name("--debug") && !valid_name(".x"));
    }
}
