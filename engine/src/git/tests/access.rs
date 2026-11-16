//! What a clone over SSH needs: addresses, known hosts and keys in a temporary home. No network:
//! the keys "scanned" are the public host keys the providers publish, given as text.
use crate::git::access::{ssh_access, ssh_endpoint, trust_scanned, SshAccess};
use crate::ssh::common::fingerprints_of;

const BITBUCKET_KEY: &str =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIazEu89wgQZ4bqs3d63QSMzYVa0MuJ2e2gKTKqu+UUO";
const GITHUB_KEY: &str =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";

#[test]
fn ssh_addresses_give_their_server_and_port() {
    for (url, host, port) in [
        ("git@bitbucket.org:equipo/app.git", "bitbucket.org", 22),
        ("git@GitHub.com:a/b.git", "github.com", 22),
        (
            "ssh://git@git.example.invalid/a/b.git",
            "git.example.invalid",
            22,
        ),
        (
            "ssh://git@git.example.invalid:7999/a/b.git",
            "git.example.invalid",
            7999,
        ),
        (
            "ssh://git.example.invalid/a/b.git",
            "git.example.invalid",
            22,
        ),
    ] {
        assert_eq!(ssh_endpoint(url), Some((host.to_string(), port)), "{url}");
    }
    for url in [
        "https://github.com/a/b.git",
        "https://git@bitbucket.org/a/b.git",
        "ssh://git@git.example.invalid:puerto/a/b.git",
        "ssh://git@-oProxyCommand=x/a/b.git",
        "git@[::1]:a/b.git",
    ] {
        assert_eq!(ssh_endpoint(url), None, "{url}");
    }
}

#[test]
fn access_tells_what_is_missing_and_trusting_fills_known_hosts() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let url = "git@git.example.invalid:equipo/app.git";
    assert_eq!(
        ssh_access(home, None, "https://git.example.invalid/equipo/app.git").unwrap(),
        SshAccess::default()
    );
    assert_eq!(
        ssh_access(home, None, "ext::sh").unwrap_err().code,
        "invalid_url"
    );
    let before = ssh_access(home, None, url).unwrap();
    assert!(before.ssh && !before.host_known && !before.identities);
    assert_eq!(
        (before.host.as_str(), before.port),
        ("git.example.invalid", 22)
    );

    let keys = format!("git.example.invalid {BITBUCKET_KEY}\n");
    let prints = fingerprints_of(&keys).unwrap();
    assert_eq!(prints.len(), 1);
    // Not the fingerprints the user saw: nothing is written.
    let other = fingerprints_of(&format!("git.example.invalid {GITHUB_KEY}\n")).unwrap();
    assert_eq!(
        trust_scanned(home, "git.example.invalid", 22, &prints, &keys, &other)
            .unwrap_err()
            .code,
        "ssh_host_changed"
    );
    // A line of another host, or one that is not a plain key, is never written.
    for bad in [
        format!("otro.example.invalid {BITBUCKET_KEY}\n"),
        format!("@cert-authority git.example.invalid {BITBUCKET_KEY}\n"),
        format!("git.example.invalid {BITBUCKET_KEY} extra\n"),
    ] {
        assert_eq!(
            trust_scanned(home, "git.example.invalid", 22, &prints, &bad, &prints)
                .unwrap_err()
                .code,
            "ssh_host_changed",
            "{bad}"
        );
    }
    assert!(!home.join(".ssh").exists());

    trust_scanned(home, "git.example.invalid", 22, &prints, &keys, &prints).unwrap();
    trust_scanned(home, "git.example.invalid", 22, &prints, &keys, &prints).unwrap();
    let file = home.join(".ssh/known_hosts");
    assert_eq!(std::fs::read_to_string(&file).unwrap(), keys);
    use std::os::unix::fs::PermissionsExt;
    assert_eq!(file.metadata().unwrap().permissions().mode() & 0o777, 0o600);
    assert_eq!(
        home.join(".ssh").metadata().unwrap().permissions().mode() & 0o777,
        0o700
    );
    assert!(ssh_access(home, None, url).unwrap().host_known);
    // Another port of the same server is another entry.
    assert!(
        !ssh_access(home, None, "ssh://git@git.example.invalid:7999/a/b.git")
            .unwrap()
            .host_known
    );

    // A default key in ~/.ssh counts as a key to offer (its content is never read).
    std::fs::write(home.join(".ssh/id_ed25519"), "inventada").unwrap();
    assert!(ssh_access(home, None, url).unwrap().identities);
}

#[test]
fn a_provider_is_trusted_only_with_the_keys_it_publishes() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    // Someone answering for bitbucket.org with another key (here, GitHub's): refused even when
    // the user accepted the fingerprint shown.
    let fake = format!("bitbucket.org {GITHUB_KEY}\n");
    let prints = fingerprints_of(&fake).unwrap();
    let refused = trust_scanned(home, "bitbucket.org", 22, &prints, &fake, &prints).unwrap_err();
    assert_eq!(refused.code, "ssh_host_changed");
    assert!(!home.join(".ssh/known_hosts").exists());

    for (host, key) in [("bitbucket.org", BITBUCKET_KEY), ("github.com", GITHUB_KEY)] {
        let keys = format!("{host} {key}\n");
        let prints = fingerprints_of(&keys).unwrap();
        trust_scanned(home, host, 22, &prints, &keys, &prints).unwrap();
        assert!(
            ssh_access(home, None, &format!("git@{host}:a/b.git"))
                .unwrap()
                .host_known
        );
    }
}
