//! The list of profiles as the app shows it: names, region, output, the kind of credential and
//! where it comes from, the sign-in session's expiry and the projects that use each profile. No
//! field carries a secret: of an access key only its last four characters.

use super::{Files, helper, ini::Document};
use crate::core::{hash, store::Store, time};
use anyhow::Result;
use serde::Serialize;
use serde_json::{Value, json};
use std::path::Path;

#[derive(Debug, Clone, Copy, Serialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    /// Access keys in `credentials` (or `config`).
    Static,
    /// IAM Identity Center (single sign-on).
    Sso,
    /// A role assumed from another profile or source.
    Role,
    /// An external credential process (Stack's own for keys in the Keychain).
    Process,
    /// Only settings (region, output), no credentials.
    None,
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Session {
    /// When the sign-in session ends (seconds since 1970); none when the cache does not say.
    pub expires_at: Option<u64>,
    pub valid: bool,
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ProjectUse {
    pub project: String,
    pub project_name: String,
    pub environment: String,
    pub environment_name: String,
    pub production: bool,
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Profile {
    pub name: String,
    pub is_default: bool,
    pub kind: Kind,
    pub region: Option<String>,
    pub output: Option<String>,
    /// The AWS account, when the files say it (single sign-on, a role's ARN).
    pub account: Option<String>,
    /// Static keys: the last four characters of the access key id, and the file that keeps them in
    /// plain text (`credentials` or `config`).
    pub key_suffix: Option<String>,
    pub key_file: Option<String>,
    /// Temporary static keys (with a session token).
    pub temporary: bool,
    pub sso_session: Option<String>,
    pub sso_start_url: Option<String>,
    pub sso_region: Option<String>,
    pub role_name: Option<String>,
    pub session: Option<Session>,
    pub role_arn: Option<String>,
    pub source_profile: Option<String>,
    pub credential_source: Option<String>,
    /// Stack's credential process: `ok`, `other` (another copy of Stack) or `missing` (its
    /// program is gone: the app offers to repair it). None for any other process.
    pub helper: Option<String>,
    /// The section is written twice in a file: the CLI refuses it and Stack does not edit it.
    pub duplicated: bool,
    pub projects: Vec<ProjectUse>,
}

/// `default` and `profile x` of the config file (`profile default` is also the default).
pub fn config_name(section: &str) -> Option<String> {
    if section == "default" {
        return Some("default".into());
    }
    section
        .strip_prefix("profile ")
        .map(|n| n.trim().to_string())
        .filter(|n| !n.is_empty())
}

/// The section of `profile` in the config file, as written there (or how a new one is written).
pub fn config_section(doc: &Document, profile: &str) -> Result<String> {
    let names: Vec<String> = doc
        .sections()
        .into_iter()
        .map(|s| s.name)
        .filter(|n| config_name(n).as_deref() == Some(profile))
        .collect();
    anyhow::ensure!(names.len() <= 1, "aws_profile_duplicated");
    Ok(names.into_iter().next().unwrap_or_else(|| {
        if profile == "default" {
            "default".into()
        } else {
            format!("profile {profile}")
        }
    }))
}

/// The words of a `credential_process` line: separated by spaces, double quotes around one word.
pub fn words(line: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut current = String::new();
    let (mut quoted, mut started) = (false, false);
    for c in line.chars() {
        match c {
            '"' => {
                quoted = !quoted;
                started = true;
            }
            c if c.is_whitespace() && !quoted => {
                if started {
                    out.push(std::mem::take(&mut current));
                    started = false;
                }
            }
            c => {
                current.push(c);
                started = true;
            }
        }
    }
    if started {
        out.push(current);
    }
    out
}

/// The account of `arn:aws:iam::111122223333:role/x`.
fn account_of(arn: &str) -> Option<String> {
    let account = arn.split(':').nth(4)?;
    (account.len() == 12 && account.bytes().all(|c| c.is_ascii_digit())).then(|| account.into())
}

/// The sign-in session of a single sign-on profile, read from AWS CLI's cache: the file named by
/// the SHA-1 of the session's name (or of the start URL for the older setup). Only `expiresAt` is
/// taken; the rest of the file (the token) is dropped unread.
fn sso_state(files: &Files, key: &str, now: u64) -> Option<Session> {
    let path = files
        .sso_cache()
        .join(format!("{}.json", hash::sha1_hex(key.as_bytes())));
    let text = super::read(&path).ok().filter(|t| !t.is_empty())?;
    let expires_at = serde_json::from_str::<Value>(&text)
        .ok()?
        .get("expiresAt")
        .and_then(Value::as_str)
        .and_then(time::parse_utc);
    Some(Session {
        valid: expires_at.is_some_and(|e| e > now),
        expires_at,
    })
}

fn last_four(id: &str) -> String {
    let chars: Vec<char> = id.trim().chars().collect();
    chars[chars.len().saturating_sub(4)..].iter().collect()
}

/// Which projects' environments set `AWS_PROFILE` to each profile.
fn uses(store: &Store) -> Vec<(String, ProjectUse)> {
    let mut out = Vec::new();
    for project in store.list().unwrap_or_default() {
        let Ok(site) = crate::web::projects::envs::load(store, &project.id) else {
            continue;
        };
        for env in site.environments {
            for entry in env
                .entries
                .iter()
                .filter(|e| e.key == "AWS_PROFILE" && !e.secret)
            {
                out.push((
                    entry.value.clone(),
                    ProjectUse {
                        project: project.id.clone(),
                        project_name: project.name.clone(),
                        environment: env.id.clone(),
                        environment_name: env.name.clone(),
                        production: env.kind == crate::web::projects::envs::Kind::Production,
                    },
                ));
            }
        }
    }
    out
}

/// Every profile of the two files, in the order of the config file and then the credentials-only
/// ones.
pub fn read_profiles(
    config: &Document,
    credentials: &Document,
    files: &Files,
    helper: Option<&Path>,
    now: u64,
) -> Vec<Profile> {
    let config_sections = config.sections();
    let credential_sections = credentials.sections();
    let mut names: Vec<String> = Vec::new();
    for name in config_sections
        .iter()
        .filter_map(|s| config_name(&s.name))
        .chain(credential_sections.iter().map(|s| s.name.clone()))
    {
        if !names.contains(&name) {
            names.push(name);
        }
    }
    let sessions: Vec<_> = config_sections
        .iter()
        .filter_map(|s| Some((s.name.strip_prefix("sso-session ")?.trim().to_string(), s)))
        .collect();
    names
        .into_iter()
        .map(|name| {
            let mine: Vec<_> = config_sections
                .iter()
                .filter(|s| config_name(&s.name).as_deref() == Some(name.as_str()))
                .collect();
            let creds: Vec<_> = credential_sections
                .iter()
                .filter(|s| s.name == name)
                .collect();
            let get = |key: &str| {
                mine.first()
                    .and_then(|s| config.get(s, key))
                    .filter(|v| !v.is_empty())
            };
            let cred = |key: &str| {
                creds
                    .first()
                    .and_then(|s| credentials.get(s, key))
                    .filter(|v| !v.is_empty())
            };
            let session_name = get("sso_session");
            let session = session_name
                .as_ref()
                .and_then(|n| sessions.iter().find(|(s, _)| s == n).map(|(_, s)| *s));
            let from_session = |key: &str| session.and_then(|s| config.get(s, key));
            let start_url = from_session("sso_start_url").or_else(|| get("sso_start_url"));
            let process = get("credential_process").or_else(|| cred("credential_process"));
            let (key_id, key_file, temporary) = match cred("aws_access_key_id") {
                Some(id) => (
                    Some(id),
                    Some("credentials"),
                    cred("aws_session_token").is_some(),
                ),
                None => match get("aws_access_key_id") {
                    Some(id) => (Some(id), Some("config"), get("aws_session_token").is_some()),
                    None => (None, None, false),
                },
            };
            let role_arn = get("role_arn");
            // The order the CLI looks for credentials in a profile.
            let kind = if role_arn.is_some() {
                Kind::Role
            } else if session_name.is_some() || get("sso_start_url").is_some() {
                Kind::Sso
            } else if key_file == Some("credentials") {
                Kind::Static
            } else if process.is_some() {
                Kind::Process
            } else if key_id.is_some() {
                Kind::Static
            } else {
                Kind::None
            };
            let helper_state = process
                .as_deref()
                .and_then(|line| helper::state(line, helper));
            let sso_key = session_name.clone().or_else(|| start_url.clone());
            Profile {
                is_default: name == "default",
                kind,
                region: get("region"),
                output: get("output"),
                account: get("sso_account_id").or_else(|| role_arn.as_deref().and_then(account_of)),
                key_suffix: key_id.as_deref().map(last_four),
                key_file: key_file.map(String::from),
                temporary,
                sso_session: session_name,
                sso_region: from_session("sso_region").or_else(|| get("sso_region")),
                sso_start_url: start_url,
                role_name: get("sso_role_name"),
                session: (kind == Kind::Sso)
                    .then(|| sso_key.and_then(|k| sso_state(files, &k, now)))
                    .flatten(),
                role_arn,
                source_profile: get("source_profile"),
                credential_source: get("credential_source")
                    .or_else(|| get("web_identity_token_file").map(|_| "WebIdentity".into())),
                helper: helper_state,
                duplicated: mine.len() > 1 || creds.len() > 1,
                projects: Vec::new(),
                name,
            }
        })
        .collect()
}

/// `awsProfiles`: the CLI on this Mac, the files and every profile.
pub fn list(store: &Store, files: &Files, helper: Option<&Path>) -> Result<Value> {
    let config = Document::parse(&super::read(&files.config)?);
    let credentials = Document::parse(&super::read(&files.credentials)?);
    let mut profiles = read_profiles(&config, &credentials, files, helper, time::now_secs());
    for (name, used) in uses(store) {
        if let Some(profile) = profiles.iter_mut().find(|p| p.name == name) {
            profile.projects.push(used);
        }
    }
    let sessions: Vec<Value> = config
        .sections()
        .iter()
        .filter_map(|s| {
            let name = s.name.strip_prefix("sso-session ")?.trim();
            Some(json!({"name": name, "startUrl": config.get(s, "sso_start_url"), "region": config.get(s, "sso_region")}))
        })
        .collect();
    Ok(json!({
        "cli": super::cli_status(),
        "configPath": files.config,
        "credentialsPath": files.credentials,
        "profiles": profiles,
        "ssoSessions": sessions,
        "helperAvailable": helper.is_some(),
    }))
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use std::fs;

    pub const CONFIG: &str = "# Perfiles de ejemplo (cuentas ficticias)\n[default]\nregion = us-east-1\noutput = json\n\n[profile acme-dev]\nsso_session = acme\nsso_account_id = 111122223333\nsso_role_name = Desarrollo\nregion = sa-east-1\n\n[profile acme-prod]\nrole_arn = arn:aws:iam::444455556666:role/Despliegue\nsource_profile = acme-dev\nregion = us-east-1\n\n[profile llavero]\ncredential_process = \"/Applications/Stack P17.app/Contents/Resources/butake-stack\" aws-credential llavero\n\n[profile otro-proceso]\ncredential_process = /opt/bin/credenciales --usuario ana\n\n[profile antiguo]\nsso_start_url = https://antiguo.awsapps.com/start\nsso_region = us-east-1\nsso_account_id = 777788889999\nsso_role_name = Lectura\n\n[sso-session acme]\nsso_start_url = https://acme.awsapps.com/start\nsso_region = us-east-1\nsso_registration_scopes = sso:account:access\n\n[services local]\ndynamodb =\n  endpoint_url = http://localhost:8000\n";
    pub const CREDENTIALS: &str = "[default]\naws_access_key_id = AKIAIOSFODNN7EXAMPLE\naws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY\n\n[temporal]\naws_access_key_id=ASIAI44QH8DHBEXAMPLE\naws_secret_access_key=je7MtGbClwBF/2Zp9Utk/h3yCo8nvbEXAMPLEKEY\naws_session_token = IQoJb3JpZ2luX2IQoJb3JpZVERYLONGSTRINGEXAMPLE\n";

    fn files(home: &Path) -> Files {
        Files {
            config: home.join(".aws/config"),
            credentials: home.join(".aws/credentials"),
            home: home.to_path_buf(),
        }
    }

    #[test]
    fn every_kind_is_read_and_no_secret_is_returned() {
        let temp = tempfile::tempdir().unwrap();
        let files = files(temp.path());
        fs::create_dir_all(files.sso_cache()).unwrap();
        // A session that ends in the future and an expired one (the token is made up and never read).
        fs::write(
            files.sso_cache().join(format!("{}.json", hash::sha1_hex(b"acme"))),
            r#"{"startUrl": "https://acme.awsapps.com/start", "region": "us-east-1", "accessToken": "TOKEN-DE-EJEMPLO", "expiresAt": "2030-01-01T00:00:00Z"}"#,
        )
        .unwrap();
        fs::write(
            files.sso_cache().join(format!(
                "{}.json",
                hash::sha1_hex(b"https://antiguo.awsapps.com/start")
            )),
            r#"{"accessToken": "TOKEN-DE-EJEMPLO", "expiresAt": "2020-01-01T00:00:00UTC"}"#,
        )
        .unwrap();
        let helper = Path::new("/Applications/Stack P17.app/Contents/Resources/butake-stack");
        let list = read_profiles(
            &Document::parse(CONFIG),
            &Document::parse(CREDENTIALS),
            &files,
            Some(helper),
            1_800_000_000,
        );
        let names: Vec<_> = list.iter().map(|p| p.name.as_str()).collect();
        assert_eq!(
            names,
            [
                "default",
                "acme-dev",
                "acme-prod",
                "llavero",
                "otro-proceso",
                "antiguo",
                "temporal"
            ]
        );
        let by = |n: &str| list.iter().find(|p| p.name == n).unwrap();
        let default = by("default");
        assert!(default.is_default && default.kind == Kind::Static);
        assert_eq!(default.key_suffix.as_deref(), Some("MPLE"));
        assert_eq!(default.key_file.as_deref(), Some("credentials"));
        assert_eq!(default.region.as_deref(), Some("us-east-1"));
        let dev = by("acme-dev");
        assert_eq!(dev.kind, Kind::Sso);
        assert_eq!(dev.account.as_deref(), Some("111122223333"));
        assert_eq!(
            dev.sso_start_url.as_deref(),
            Some("https://acme.awsapps.com/start")
        );
        assert_eq!(
            dev.session,
            Some(Session {
                expires_at: Some(1_893_456_000),
                valid: true
            })
        );
        let prod = by("acme-prod");
        assert_eq!(prod.kind, Kind::Role);
        assert_eq!(prod.account.as_deref(), Some("444455556666"));
        assert_eq!(prod.source_profile.as_deref(), Some("acme-dev"));
        assert_eq!(by("llavero").kind, Kind::Process);
        assert_eq!(by("llavero").helper.as_deref(), Some("ok"));
        assert_eq!(by("otro-proceso").helper, None);
        let old = by("antiguo");
        assert_eq!(
            old.session,
            Some(Session {
                expires_at: Some(1_577_836_800),
                valid: false
            })
        );
        let temporary = by("temporal");
        assert!(temporary.temporary && temporary.kind == Kind::Static && !temporary.is_default);
        // Nothing secret reaches the response.
        let text = serde_json::to_string(&list).unwrap();
        for secret in [
            "wJalrXUtnFEMI",
            "je7MtGbClwBF",
            "IQoJb3JpZ2lu",
            "TOKEN-DE-EJEMPLO",
            "AKIAIOSFODNN7EXA",
            "ASIAI44QH8DHBEXA",
        ] {
            assert!(!text.contains(secret), "{secret}");
        }
    }

    #[test]
    fn missing_files_duplicates_and_odd_lines() {
        let temp = tempfile::tempdir().unwrap();
        let files = files(temp.path());
        assert!(
            read_profiles(&Document::parse(""), &Document::parse(""), &files, None, 0).is_empty()
        );
        let config = "basura\n[profile a]\nregion=x\n[profile a]\nregion=y\n[profile default]\noutput: text\n[profile ]\n[otra cosa]\n";
        let list = read_profiles(
            &Document::parse(config),
            &Document::parse(""),
            &files,
            None,
            0,
        );
        let names: Vec<_> = list
            .iter()
            .map(|p| (p.name.as_str(), p.duplicated))
            .collect();
        assert_eq!(names, [("a", true), ("default", false)]);
        assert_eq!(list[0].region.as_deref(), Some("x"));
        assert_eq!(list[1].output.as_deref(), Some("text"));
        assert_eq!(list[1].kind, Kind::None);
        assert_eq!(
            config_section(&Document::parse(config), "default").unwrap(),
            "profile default"
        );
        assert_eq!(
            config_section(&Document::parse(""), "default").unwrap(),
            "default"
        );
        assert_eq!(
            config_section(&Document::parse(""), "x").unwrap(),
            "profile x"
        );
        assert_eq!(
            config_section(&Document::parse(config), "a")
                .unwrap_err()
                .to_string(),
            "aws_profile_duplicated"
        );
    }

    #[test]
    fn words_follow_the_cli_quoting() {
        assert_eq!(
            words("\"/Applications/Stack P17.app/x\" aws-credential  dev"),
            ["/Applications/Stack P17.app/x", "aws-credential", "dev"]
        );
        assert_eq!(
            words("/opt/bin/c --u \"a b\""),
            ["/opt/bin/c", "--u", "a b"]
        );
        assert!(words("   ").is_empty());
    }
}
