//! A cloud tool's command line (AWS CLI, gcloud) as the engine runs it: the copy found on this
//! Mac, started without a shell, with separate arguments, a minimal environment whose PATH starts
//! at the program's own folder, a time limit, and a way for the app to stop it (its process group
//! is noted in the tool's runs folder; see core/watch.rs). Its own messages are never returned:
//! the tool turns them into one of its fixed codes.
use crate::core::process::{self, Captured};
use anyhow::{ensure, Result};
use std::{
    ffi::OsString,
    path::{Path, PathBuf},
    process::Command,
    time::Duration,
};

/// The fixed codes of one tool for the ways a run can end without an answer.
pub struct Codes {
    /// The program could not be started.
    pub missing: &'static str,
    /// The app stopped the request.
    pub cancelled: &'static str,
}

/// One external command line and the environment every run of it gets.
pub struct CliTool {
    pub program: PathBuf,
    pub home: PathBuf,
    /// Variables added to the minimal environment (configuration files, prompts off…).
    pub environment: Vec<(String, OsString)>,
    pub codes: Codes,
}

impl CliTool {
    /// The command for `arguments`: the program's folder first in PATH, then the system's.
    pub fn command(&self, arguments: &[&str]) -> Command {
        let folder = self
            .program
            .parent()
            .map(|p| p.display().to_string())
            .unwrap_or_default();
        let mut command = Command::new(&self.program);
        process::minimal_environment(
            &mut command,
            &self.home,
            format!("{folder}:/usr/bin:/bin:/usr/sbin:/sbin"),
        );
        command.args(arguments);
        for (key, value) in &self.environment {
            command.env(key, value);
        }
        command
    }

    /// Runs it until it ends, `limit` passes (`timed_out`) or the app stops the request; either way
    /// nothing it started keeps running. `records` is the store's folder where the run notes its
    /// process group; without one (tests) it runs plainly. A failed run becomes `translate(stderr)`.
    pub fn run(
        &self,
        records: Option<&Path>,
        arguments: &[&str],
        max_output: u64,
        limit: Duration,
        timed_out: &'static str,
        translate: fn(&str) -> &'static str,
    ) -> Result<String> {
        let command = self.command(arguments);
        let done: Captured = match records {
            Some(records) => process::capture_watched(
                command,
                max_output,
                limit,
                self.codes.missing,
                Some(records),
            )?,
            None => process::capture(command, b"", max_output, self.codes.missing)?,
        };
        ensure!(!done.cancelled, self.codes.cancelled);
        ensure!(!done.timed_out, timed_out);
        ensure!(done.success, translate(&done.stderr));
        Ok(done.stdout)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tool(script: &str, folder: &Path) -> CliTool {
        use std::os::unix::fs::PermissionsExt;
        let program = folder.join("nube");
        std::fs::write(&program, script).unwrap();
        std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o755)).unwrap();
        CliTool {
            program,
            home: folder.to_path_buf(),
            environment: vec![("NUBE_MODO".into(), "prueba".into())],
            codes: Codes {
                missing: "nube_missing",
                cancelled: "nube_cancelled",
            },
        }
    }

    fn code(stderr: &str) -> &'static str {
        if stderr.contains("expired") {
            "nube_expired"
        } else {
            "nube_failed"
        }
    }

    /// Only the minimal environment and the tool's own variables reach the program (never the
    /// caller's); its own messages become one of the tool's codes.
    #[test]
    fn runs_with_a_minimal_environment_and_fixed_codes() {
        let temp = tempfile::tempdir().unwrap();
        let limit = Duration::from_secs(10);
        let ok = tool(
            "#!/bin/sh\necho \"$NUBE_MODO|$HOME|${USER:-}|$1\"\n",
            temp.path(),
        );
        let out = ok
            .run(None, &["hola"], 1024, limit, "nube_timeout", code)
            .unwrap();
        assert_eq!(
            out.trim(),
            format!("prueba|{}||hola", temp.path().display())
        );
        let failing = tool("#!/bin/sh\necho 'token expired' >&2\nexit 3\n", temp.path());
        let error = failing
            .run(None, &[], 1024, limit, "nube_timeout", code)
            .unwrap_err();
        assert_eq!(error.to_string(), "nube_expired");
        let missing = CliTool {
            program: temp.path().join("no-existe"),
            ..tool("#!/bin/sh\n", temp.path())
        };
        let error = missing
            .run(None, &[], 1024, limit, "nube_timeout", code)
            .unwrap_err();
        assert_eq!(error.to_string(), "nube_missing");
    }
}
