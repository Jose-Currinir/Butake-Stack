//! Google Cloud's CLI (`gcloud`) as the tool runs it: the copy found in the user's places, started
//! without a shell, with separate arguments, a small environment, a time limit and a way for the
//! app to stop it. Only commands that read (`auth list`, `projects list`) or that the user
//! confirmed (`auth revoke` of an account that is not the active one) are run: never one that
//! changes gcloud's configuration, prints a token or touches a resource. Its own messages are
//! never returned: they become one of a few fixed codes.

use crate::core::cli_tool::{CliTool, Codes};
use anyhow::Result;
use std::{
    path::{Path, PathBuf},
    time::Duration,
};

/// Longest wait for the list of accounts and for «Cerrar sesión…».
pub const SHORT_LIMIT: Duration = Duration::from_secs(30);
/// Longest wait for the projects of an account (a network call to Google).
pub const PROJECTS_LIMIT: Duration = Duration::from_secs(60);

/// gcloud on this Mac: where it is, the home it runs with and, when the environment names one
/// (QA), its configuration folder.
pub struct Cli {
    pub program: PathBuf,
    pub home: PathBuf,
    pub config: Option<PathBuf>,
    /// Runs end with the request that started them (see core/watch.rs); tests run them plainly.
    pub watched: bool,
}

/// gcloud as found on this Mac: the usual places of its installers and the official archive
/// unpacked in the home folder. A temporary home (tests and QA) sees only itself.
pub fn program() -> Option<PathBuf> {
    crate::runtimes::utilities::catalog::user_tool("gcloud").or_else(|| {
        let home = crate::runtimes::utilities::devtools::home().ok()?;
        Some(home.join("google-cloud-sdk/bin/gcloud")).filter(|path| path.is_file())
    })
}

impl Cli {
    pub fn find() -> Option<Self> {
        let home = crate::runtimes::utilities::devtools::home().ok()?;
        let config = std::env::var_os("CLOUDSDK_CONFIG")
            .map(PathBuf::from)
            .filter(|path| path.is_absolute());
        Some(Self {
            program: program()?,
            home,
            config,
            watched: true,
        })
    }

    /// gcloud with prompts, update checks and usage reports off. The environment is cleared:
    /// none of the caller's CLOUDSDK_* (an account or project of a console) reaches these runs;
    /// they always see gcloud's own configuration.
    fn tool(&self) -> CliTool {
        let mut environment = vec![
            ("CLOUDSDK_CORE_DISABLE_PROMPTS".to_string(), "1".into()),
            (
                "CLOUDSDK_COMPONENT_MANAGER_DISABLE_UPDATE_CHECK".to_string(),
                "1".into(),
            ),
            (
                "CLOUDSDK_CORE_DISABLE_USAGE_REPORTING".to_string(),
                "1".into(),
            ),
        ];
        if let Some(config) = &self.config {
            environment.push((
                "CLOUDSDK_CONFIG".to_string(),
                config.clone().into_os_string(),
            ));
        }
        CliTool {
            program: self.program.clone(),
            home: self.home.clone(),
            environment,
            codes: Codes {
                missing: "gcp_cli_missing",
                cancelled: "gcp_cancelled",
            },
        }
    }

    /// Runs gcloud until it ends, its limit passes (`gcp_timeout`) or the app stops the request
    /// (`gcp_cancelled`). `records` is the store's folder where a run notes its process group;
    /// tests run it plainly.
    pub fn run(&self, records: &Path, arguments: &[&str], limit: Duration) -> Result<String> {
        self.tool().run(
            self.watched.then_some(records),
            arguments,
            4 * 1024 * 1024,
            limit,
            "gcp_timeout",
            translate,
        )
    }
}

/// What went wrong, from gcloud's message: one of the tool's error codes.
pub fn translate(stderr: &str) -> &'static str {
    let text = stderr.to_ascii_lowercase();
    let has = |words: &[&str]| words.iter().any(|w| text.contains(w));
    if has(&[
        "reauthentication",
        "problem refreshing",
        "invalid_grant",
        "does not have any valid credentials",
        "no credentialed accounts",
        "gcloud auth login",
        "token has been expired or revoked",
    ]) {
        "gcp_session_expired"
    } else if has(&[
        "unable to find the server",
        "failed to establish",
        "name resolution",
        "nodename nor servname",
        "network is unreachable",
        "connection refused",
        "connection reset",
        "timed out",
    ]) {
        "gcp_offline"
    } else if has(&[
        "has not been used in project",
        "service_disabled",
        "it is disabled",
    ]) {
        "gcp_api_disabled"
    } else if has(&[
        "permission_denied",
        "permission denied",
        "does not have permission",
        "forbidden",
    ]) {
        "gcp_access_denied"
    } else {
        "gcp_failed"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn messages_become_codes() {
        for (message, code) in [
            ("ERROR: (gcloud.projects.list) There was a problem refreshing your current auth tokens: Reauthentication failed.", "gcp_session_expired"),
            ("ERROR: (gcloud.projects.list) Your current active account [qa@ejemplo.test] does not have any valid credentials", "gcp_session_expired"),
            ("ERROR: gcloud crashed (TransportError): HTTPSConnectionPool: Failed to establish a new connection: nodename nor servname provided", "gcp_offline"),
            ("ERROR: (gcloud.projects.list) PERMISSION_DENIED: Cloud Resource Manager API has not been used in project 123 before or it is disabled.", "gcp_api_disabled"),
            ("ERROR: (gcloud.projects.list) PERMISSION_DENIED: The caller does not have permission", "gcp_access_denied"),
            ("algo raro", "gcp_failed"),
        ] {
            assert_eq!(translate(message), code, "{message}");
        }
    }
}
