//! AWS CLI runs: «Comprobar» (`sts get-caller-identity`), «Iniciar sesión…» (`sso login`) and
//! «Cerrar sesión» (`sso logout`). The program is the one found in the user's places (the same
//! copy Utilidades shows), started without a shell, with separate arguments, a small environment
//! that names the two files Stack shows, a time limit, and a way for the app to stop it. Its own messages are never returned:
//! they become one of a few fixed codes.

use super::{Files, helper};
use crate::core::cli_tool::{CliTool, Codes};
use anyhow::{Result, ensure};
use serde_json::{Value, json};
use std::{
    path::{Path, PathBuf},
    time::Duration,
};

/// AWS CLI as found on this Mac (with a temporary home in tests and QA, only there).
pub fn program() -> Option<PathBuf> {
    crate::runtimes::utilities::catalog::user_tool("aws")
}

/// AWS CLI with the two files Stack shows and no pager or prompts.
fn tool(files: &Files, program: PathBuf) -> CliTool {
    let mut environment = vec![
        (
            "AWS_CONFIG_FILE".to_string(),
            files.config.clone().into_os_string(),
        ),
        (
            "AWS_SHARED_CREDENTIALS_FILE".to_string(),
            files.credentials.clone().into_os_string(),
        ),
        ("AWS_PAGER".to_string(), "".into()),
        ("AWS_CLI_AUTO_PROMPT".to_string(), "off".into()),
    ];
    // A QA store keeps its Keychain items apart; Stack's credential process must look there too.
    if let Some(store) = std::env::var_os("BUTAKE_STACK_HOME") {
        environment.push(("BUTAKE_STACK_HOME".to_string(), store));
    }
    CliTool {
        program,
        home: files.home.clone(),
        environment,
        codes: Codes {
            missing: "aws_cli_missing",
            cancelled: "aws_cancelled",
        },
    }
}

/// What went wrong, from the CLI's message: one of the tool's error codes.
pub fn translate(stderr: &str) -> &'static str {
    let text = stderr.to_ascii_lowercase();
    let has = |words: &[&str]| words.iter().any(|w| text.contains(w));
    if has(&["could not be found", "profilenotfound"]) {
        "aws_profile_not_found"
    } else if has(&[
        "token has expired",
        "expiredtoken",
        "sso session associated with this profile has expired",
        "error loading sso token",
        "refresh failed",
        "sso token",
    ]) {
        "aws_session_expired"
    } else if has(&[
        "could not connect to the endpoint",
        "endpointconnectionerror",
        "connect timeout",
        "name resolution",
        "nodename nor servname",
        "network is unreachable",
    ]) {
        "aws_offline"
    } else if has(&["custom-process", "credential_process", "credential process"]) {
        "aws_process_failed"
    } else if has(&[
        "unable to locate credentials",
        "partial credentials",
        "missing required configuration",
        "must specify a region",
        "incomplete",
    ]) {
        "aws_profile_incomplete"
    } else if has(&[
        "invalidclienttokenid",
        "signaturedoesnotmatch",
        "security token included in the request is invalid",
        "unrecognizedclient",
    ]) {
        "aws_invalid_credentials"
    } else if has(&["accessdenied", "access denied", "not authorized"]) {
        "aws_access_denied"
    } else {
        "aws_check_failed"
    }
}

/// Longest wait for «Comprobar» and «Cerrar sesión».
pub const SHORT_LIMIT: Duration = Duration::from_secs(30);
/// Longest wait for the user to finish signing in in the browser.
const SIGN_IN_LIMIT: Duration = Duration::from_secs(300);

/// [`SIGN_IN_LIMIT`]; debug builds (tests and QA) may shorten it with
/// `BUTAKE_QA_AWS_SIGN_IN_LIMIT` (seconds) to see the end of the wait.
pub fn sign_in_limit() -> Duration {
    #[cfg(debug_assertions)]
    if let Some(seconds) = std::env::var("BUTAKE_QA_AWS_SIGN_IN_LIMIT")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
    {
        return Duration::from_secs(seconds.clamp(1, 300));
    }
    SIGN_IN_LIMIT
}

/// Runs the CLI until it ends, its limit passes (`timed_out`) or the app stops the request
/// (`aws_cancelled`); either way nothing it started keeps running (see core/watch.rs). `records`
/// is the store's folder where a run notes its process group while it waits.
fn run(
    files: &Files,
    records: &Path,
    arguments: &[&str],
    limit: Duration,
    timed_out: &'static str,
) -> Result<String> {
    let program = program().ok_or_else(|| anyhow::anyhow!("aws_cli_missing"))?;
    tool(files, program).run(
        Some(records),
        arguments,
        256 * 1024,
        limit,
        timed_out,
        translate,
    )
}

/// «Comprobar»: who the profile is (account, ARN and id). Nothing is kept.
pub fn check(files: &Files, records: &Path, name: &str) -> Result<Value> {
    ensure!(helper::valid_name(name), "aws_invalid_profile");
    let out = run(
        files,
        records,
        &[
            "sts",
            "get-caller-identity",
            "--profile",
            name,
            "--output",
            "json",
        ],
        SHORT_LIMIT,
        "aws_timeout",
    )?;
    let value: Value =
        serde_json::from_str(&out).map_err(|_| anyhow::anyhow!("aws_check_failed"))?;
    let text = |key: &str| {
        value[key]
            .as_str()
            .filter(|v| v.len() <= 2048)
            .map(String::from)
    };
    let account = text("Account").ok_or_else(|| anyhow::anyhow!("aws_check_failed"))?;
    Ok(json!({"account": account, "arn": text("Arn"), "userId": text("UserId")}))
}

/// «Iniciar sesión…»: the CLI opens the system's browser and waits for the user, at most
/// [`sign_in_limit`]; past it, `aws_login_timeout`.
pub fn sso_login(files: &Files, records: &Path, name: &str) -> Result<()> {
    ensure!(helper::valid_name(name), "aws_invalid_profile");
    run(
        files,
        records,
        &["sso", "login", "--profile", name],
        sign_in_limit(),
        "aws_login_timeout",
    )
    .map(|_| ())
}

/// «Cerrar sesión»: the CLI signs out of every single sign-on session of this Mac.
pub fn sso_logout(files: &Files, records: &Path) -> Result<()> {
    run(
        files,
        records,
        &["sso", "logout"],
        SHORT_LIMIT,
        "aws_timeout",
    )
    .map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn messages_become_codes() {
        for (message, code) in [
            (
                "The config profile (nadie) could not be found",
                "aws_profile_not_found",
            ),
            (
                "Error when retrieving token from sso: Token has expired and refresh failed",
                "aws_session_expired",
            ),
            (
                "Could not connect to the endpoint URL: \"https://sts.amazonaws.com/\"",
                "aws_offline",
            ),
            (
                "Unable to locate credentials. You can configure credentials by running \"aws configure\".",
                "aws_profile_incomplete",
            ),
            (
                "An error occurred (InvalidClientTokenId) when calling the GetCallerIdentity operation",
                "aws_invalid_credentials",
            ),
            (
                "An error occurred (AccessDenied) when calling the AssumeRole operation",
                "aws_access_denied",
            ),
            (
                "Error when retrieving credentials from custom-process: Stack: x",
                "aws_process_failed",
            ),
            ("algo raro", "aws_check_failed"),
        ] {
            assert_eq!(translate(message), code, "{message}");
        }
    }
}
