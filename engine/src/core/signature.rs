//! Apple signatures of what the engine downloads: code signed by a given Developer ID team,
//! notarized by Apple, and installer packages signed by that team. Only the system's own tools
//! (`codesign`, `spctl`, `pkgutil`) with a cleared environment; nothing downloaded is run.

use anyhow::{ensure, Result};
use std::{
    path::Path,
    process::{Command, Stdio},
};

fn requirement(team: &str) -> String {
    format!("=anchor apple generic and certificate leaf[subject.OU] = \"{team}\"")
}

/// A team identifier is ten uppercase letters or digits (it goes inside the requirement).
fn valid_team(team: &str) -> bool {
    team.len() == 10
        && team
            .bytes()
            .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit())
}

/// `codesign` checks the signature chain up to Apple and that the leaf belongs to `team`. With
/// `deep`, every nested bundle and framework of an app is checked too.
pub fn verify_code(path: &Path, team: &str, deep: bool) -> Result<()> {
    ensure!(valid_team(team), "signature_invalid");
    let mut command = Command::new("/usr/bin/codesign");
    command.args(["--verify", "--strict"]);
    if deep {
        command.arg("--deep");
    }
    let status = command
        .args(["-R", &requirement(team)])
        .arg(path)
        .env_clear()
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()?;
    ensure!(status.success(), "signature_invalid");
    Ok(())
}

/// Gatekeeper accepts `path` as notarized Developer ID software: an app (`app`) or a single
/// program. For a program Apple's notary service is asked over the network.
pub fn verify_notarized(path: &Path, app: bool) -> Result<()> {
    let mut command = Command::new("/usr/sbin/spctl");
    command.args(["--assess", "-vv"]);
    if app {
        command.args(["--type", "execute"]);
    } else {
        command.args(["--type", "open", "--context", "context:primary-signature"]);
    }
    let out = command
        .arg(path)
        .env_clear()
        .stdin(Stdio::null())
        .output()?;
    let text = String::from_utf8_lossy(&out.stderr);
    ensure!(
        out.status.success() && text.contains("source=Notarized Developer ID"),
        "not_notarized"
    );
    Ok(())
}

/// What `pkgutil --check-signature` must say of a package signed by `team` and notarized.
fn package_accepted(report: &str, team: &str) -> bool {
    report.contains("signed by a developer certificate issued by Apple for distribution")
        && report.contains("Notarization: trusted by the Apple notary service")
        && report.lines().any(|line| {
            let line = line.trim();
            line.starts_with("1. Developer ID Installer:") && line.ends_with(&format!("({team})"))
        })
}

/// An installer package signed with a Developer ID Installer certificate of `team` (the first of
/// its chain) and notarized.
pub fn verify_package(pkg: &Path, team: &str) -> Result<()> {
    ensure!(valid_team(team), "signature_invalid");
    let out = Command::new("/usr/sbin/pkgutil")
        .arg("--check-signature")
        .arg(pkg)
        .env_clear()
        .stdin(Stdio::null())
        .output()?;
    ensure!(
        out.status.success() && package_accepted(&String::from_utf8_lossy(&out.stdout), team),
        "signature_invalid"
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn code_of_another_team_or_altered_is_refused() {
        // Apple's own programs have no Developer ID team: refused for any team.
        let error = verify_code(Path::new("/usr/bin/true"), "Q6L2SF6YDW", false).unwrap_err();
        assert_eq!(error.to_string(), "signature_invalid");
        // One byte changed in a signed program breaks its signature.
        let dir = tempfile::tempdir().unwrap();
        let copy = dir.path().join("true");
        let mut bytes = fs::read("/usr/bin/true").unwrap();
        let middle = bytes.len() / 2;
        bytes[middle] ^= 0xFF;
        fs::write(&copy, bytes).unwrap();
        assert!(verify_code(&copy, "Q6L2SF6YDW", false).is_err());
        // Not a program at all, and a team that would break out of the requirement.
        fs::write(dir.path().join("text"), "hola").unwrap();
        assert!(verify_code(&dir.path().join("text"), "Q6L2SF6YDW", false).is_err());
        assert!(verify_code(Path::new("/usr/bin/true"), "X\" or true", false).is_err());
    }

    #[test]
    fn a_file_that_is_not_a_signed_package_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        let pkg = dir.path().join("fake.pkg");
        fs::write(&pkg, "not a package").unwrap();
        assert_eq!(
            verify_package(&pkg, "94KV3E626L").unwrap_err().to_string(),
            "signature_invalid"
        );
        assert!(verify_notarized(&pkg, false).is_err());
    }

    #[test]
    fn package_reports_need_the_team_first_and_notarization() {
        let good = "Package \"a.pkg\":\n   Status: signed by a developer certificate issued by Apple for distribution\n   Notarization: trusted by the Apple notary service\n   Certificate Chain:\n    1. Developer ID Installer: AMZN Mobile LLC (94KV3E626L)\n    2. Developer ID Certification Authority\n";
        assert!(package_accepted(good, "94KV3E626L"));
        assert!(!package_accepted(good, "V9AUD2URP3"));
        assert!(!package_accepted(
            &good.replace("Notarization: trusted by the Apple notary service\n", ""),
            "94KV3E626L"
        ));
        // The team named further down the chain does not count.
        let other = good.replace(
            "1. Developer ID Installer: AMZN Mobile LLC (94KV3E626L)",
            "1. Developer ID Installer: Someone Else (ABCDE12345)\n    2. (94KV3E626L)",
        );
        assert!(!package_accepted(&other, "94KV3E626L"));
    }
}
