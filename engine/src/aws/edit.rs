//! Changes to the profiles: create, edit (and rename), duplicate, delete, make one the default and
//! repair Stack's credential process. Each change reads both files, edits only its own lines
//! (`ini.rs`) and saves what changed with a backup first (`super::save`).

use super::{
    Files, helper,
    ini::Document,
    keychain::Secrets,
    profiles::{self, Kind},
};
use crate::core::store::Store;
use anyhow::{Result, ensure};
use serde::Deserialize;
use serde_json::Value;
use std::path::Path;

/// A profile as the app's sheet sends it: never a secret (keys come apart, in [`Keys`]).
#[derive(Debug, Deserialize, Default)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Draft {
    pub name: String,
    /// `static`, `sso` or `role` (a new profile); an edit keeps the profile's own kind.
    #[serde(default)]
    pub kind: String,
    #[serde(default)]
    pub region: String,
    #[serde(default)]
    pub output: String,
    #[serde(default)]
    pub sso_session: String,
    /// A new sign-in session: its start URL and region.
    #[serde(default)]
    pub sso_start_url: String,
    #[serde(default)]
    pub sso_region: String,
    #[serde(default)]
    pub account_id: String,
    #[serde(default)]
    pub role_name: String,
    #[serde(default)]
    pub role_arn: String,
    #[serde(default)]
    pub source_profile: String,
}

/// Access keys typed by the user for a new profile. No `Debug`: it is never printed.
pub struct Keys {
    id: String,
    secret: String,
}

impl Keys {
    pub fn from_request(value: &Value) -> Option<Self> {
        Some(Self {
            id: value["accessKeyId"].as_str()?.trim().to_string(),
            secret: value["secretAccessKey"].as_str()?.trim().to_string(),
        })
    }
    fn valid(&self) -> bool {
        (16..=128).contains(&self.id.len())
            && self
                .id
                .bytes()
                .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit())
            && (16..=256).contains(&self.secret.len())
            && self.secret.bytes().all(|c| c.is_ascii_graphic())
    }
}

const OUTPUTS: [&str; 5] = ["json", "yaml", "yaml-stream", "text", "table"];

fn valid_region(region: &str) -> bool {
    region.len() <= 32
        && region
            .bytes()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-')
}

/// One line of printable text without spaces (URLs, ARNs, role names).
fn token(value: &str, max: usize) -> bool {
    !value.is_empty() && value.len() <= max && value.bytes().all(|c| c.is_ascii_graphic())
}

impl Draft {
    fn validate(&self) -> Result<()> {
        let ok = helper::valid_name(&self.name)
            && valid_region(&self.region)
            && (self.output.is_empty() || OUTPUTS.contains(&self.output.as_str()))
            && (self.sso_session.is_empty() || helper::valid_name(&self.sso_session))
            && (self.sso_start_url.is_empty()
                || (self.sso_start_url.starts_with("https://") && token(&self.sso_start_url, 512)))
            && valid_region(&self.sso_region)
            && (self.account_id.is_empty()
                || (self.account_id.len() == 12
                    && self.account_id.bytes().all(|c| c.is_ascii_digit())))
            && (self.role_name.is_empty() || token(&self.role_name, 64))
            && (self.role_arn.is_empty()
                || (self.role_arn.starts_with("arn:aws") && token(&self.role_arn, 2048)))
            && (self.source_profile.is_empty() || helper::valid_name(&self.source_profile));
        ensure!(ok, "aws_invalid_profile");
        Ok(())
    }
}

fn some(value: &str) -> Option<&str> {
    (!value.is_empty()).then_some(value)
}

/// The two files as read, and as edited.
struct Edit {
    config_before: String,
    credentials_before: String,
    config: Document,
    credentials: Document,
    /// Keychain items to move when the files are saved, in order (`from`, `to`).
    moves: Vec<(String, String)>,
}

pub struct Changes<'a> {
    pub store: &'a Store,
    pub files: &'a Files,
    pub secrets: &'a dyn Secrets,
    pub helper: Option<&'a Path>,
}

impl Changes<'_> {
    fn open(&self) -> Result<Edit> {
        let config_before = super::read(&self.files.config)?;
        let credentials_before = super::read(&self.files.credentials)?;
        Ok(Edit {
            config: Document::parse(&config_before),
            credentials: Document::parse(&credentials_before),
            config_before,
            credentials_before,
            moves: vec![],
        })
    }

    /// Writes both files and moves the Keychain items the edit renamed. The items are copied to
    /// their new names first and the old ones removed only once both files are written, so a
    /// failed save leaves every item where the files still say it is.
    fn save(&self, edit: Edit) -> Result<()> {
        let undo = self.copy_secrets(&edit.moves)?;
        let saved = super::save(
            self.store,
            &self.files.credentials,
            &edit.credentials_before,
            &edit.credentials.text(),
            "credentials",
        )
        .and_then(|()| {
            super::save(
                self.store,
                &self.files.config,
                &edit.config_before,
                &edit.config.text(),
                "config",
            )
        });
        if let Err(error) = saved {
            self.restore_secrets(undo);
            return Err(error);
        }
        // An item that is the destination of a later move is the new one: it stays.
        for (from, _) in &edit.moves {
            if !edit.moves.iter().any(|(_, to)| to == from) {
                let _ = self.secrets.delete(from);
            }
        }
        Ok(())
    }

    /// Copies each moved item to its new name; returns what was there before, to put back.
    fn copy_secrets(&self, moves: &[(String, String)]) -> Result<Vec<(String, Option<Vec<u8>>)>> {
        let mut undo = vec![];
        for (from, to) in moves {
            let step = (|| -> Result<()> {
                let Some(value) = self.secrets.get(from)? else {
                    return Ok(());
                };
                let before = self.secrets.get(to)?;
                self.secrets.set(to, &value)?;
                undo.push((to.clone(), before));
                Ok(())
            })();
            if let Err(error) = step {
                self.restore_secrets(undo);
                return Err(error);
            }
        }
        Ok(undo)
    }

    fn restore_secrets(&self, undo: Vec<(String, Option<Vec<u8>>)>) {
        for (account, before) in undo.into_iter().rev() {
            let _ = match before {
                Some(value) => self.secrets.set(&account, &value),
                None => self.secrets.delete(&account),
            };
        }
    }

    fn profile(&self, edit: &Edit, name: &str) -> Result<profiles::Profile> {
        let profile =
            profiles::read_profiles(&edit.config, &edit.credentials, self.files, self.helper, 0)
                .into_iter()
                .find(|p| p.name == name)
                .ok_or_else(|| anyhow::anyhow!("aws_profile_not_found"))?;
        ensure!(!profile.duplicated, "aws_profile_duplicated");
        Ok(profile)
    }

    fn exists(&self, edit: &Edit, name: &str) -> bool {
        profiles::read_profiles(&edit.config, &edit.credentials, self.files, None, 0)
            .iter()
            .any(|p| p.name == name)
    }

    /// Sets the settings of a profile's config section, creating the section when it is missing
    /// and something is to be written.
    fn set_all(edit: &mut Edit, name: &str, settings: &[(&str, Option<&str>)]) -> Result<()> {
        let section = profiles::config_section(&edit.config, name)?;
        if edit.config.find(&section)?.is_none() {
            let present: Vec<(&str, String)> = settings
                .iter()
                .filter_map(|(k, v)| v.map(|v| (*k, v.to_string())))
                .collect();
            if !present.is_empty() {
                edit.config.append(&section, &present)?;
            }
            return Ok(());
        }
        for (key, value) in settings {
            edit.config.set(&section, key, *value)?;
        }
        Ok(())
    }

    /// A new profile. Static keys go to `credentials` (as the CLI does) or, with `keychain`, to the
    /// Keychain behind Stack's credential process.
    pub fn create(&self, draft: Draft, keys: Option<Keys>, keychain: bool) -> Result<()> {
        draft.validate()?;
        let mut edit = self.open()?;
        ensure!(!self.exists(&edit, &draft.name), "aws_profile_exists");
        let mut settings: Vec<(&str, Option<&str>)> = Vec::new();
        let process;
        match draft.kind.as_str() {
            "static" => {
                let keys = keys
                    .filter(Keys::valid)
                    .ok_or_else(|| anyhow::anyhow!("aws_invalid_keys"))?;
                if keychain {
                    let program = self
                        .helper
                        .ok_or_else(|| anyhow::anyhow!("aws_helper_path_unsupported"))?;
                    process = helper::line(program, &draft.name)?;
                    let stored =
                        serde_json::json!({"AccessKeyId": keys.id, "SecretAccessKey": keys.secret});
                    self.secrets
                        .set(&draft.name, stored.to_string().as_bytes())?;
                    settings.push(("credential_process", Some(&process)));
                } else {
                    edit.credentials.append(
                        &draft.name,
                        &[
                            ("aws_access_key_id", keys.id.clone()),
                            ("aws_secret_access_key", keys.secret.clone()),
                        ],
                    )?;
                }
            }
            "sso" => {
                ensure!(
                    some(&draft.sso_session).is_some()
                        && some(&draft.account_id).is_some()
                        && some(&draft.role_name).is_some(),
                    "aws_profile_incomplete"
                );
                let section = format!("sso-session {}", draft.sso_session);
                if edit.config.find(&section)?.is_none() {
                    ensure!(
                        some(&draft.sso_start_url).is_some() && some(&draft.sso_region).is_some(),
                        "aws_profile_incomplete"
                    );
                    edit.config.append(
                        &section,
                        &[
                            ("sso_start_url", draft.sso_start_url.clone()),
                            ("sso_region", draft.sso_region.clone()),
                            ("sso_registration_scopes", "sso:account:access".into()),
                        ],
                    )?;
                }
                settings.extend([
                    ("sso_session", some(&draft.sso_session)),
                    ("sso_account_id", some(&draft.account_id)),
                    ("sso_role_name", some(&draft.role_name)),
                ]);
            }
            "role" => {
                ensure!(some(&draft.role_arn).is_some(), "aws_profile_incomplete");
                ensure!(
                    self.exists(&edit, &draft.source_profile),
                    "aws_profile_incomplete"
                );
                settings.extend([
                    ("role_arn", some(&draft.role_arn)),
                    ("source_profile", some(&draft.source_profile)),
                ]);
            }
            _ => anyhow::bail!("aws_invalid_profile"),
        }
        settings.extend([
            ("region", some(&draft.region)),
            ("output", some(&draft.output)),
        ]);
        Self::set_all(&mut edit, &draft.name, &settings)?;
        let saved = self.save(edit);
        if saved.is_err() && keychain {
            let _ = self.secrets.delete(&draft.name);
        }
        saved
    }

    /// Renames a profile everywhere the files name it (both sections, `source_profile` of the
    /// others, Stack's credential process) and moves its Keychain item.
    fn rename(&self, edit: &mut Edit, from: &str, to: &str) -> Result<()> {
        ensure!(helper::valid_name(to), "aws_invalid_profile");
        ensure!(!self.exists(edit, to), "aws_profile_exists");
        let profile = self.profile(edit, from)?;
        let section = profiles::config_section(&edit.config, from)?;
        if edit.config.find(&section)?.is_some() {
            let new = if to == "default" {
                "default".to_string()
            } else {
                format!("profile {to}")
            };
            edit.config.rename(&section, &new)?;
        }
        if edit.credentials.find(from)?.is_some() {
            edit.credentials.rename(from, to)?;
        }
        edit.config.replace_values("source_profile", from, to)?;
        if profile.helper.is_some() {
            let new = profiles::config_section(&edit.config, to)?;
            let line = edit
                .config
                .find(&new)?
                .and_then(|s| edit.config.get(&s, "credential_process"))
                .unwrap_or_default();
            let program = profiles::words(&line)
                .into_iter()
                .next()
                .unwrap_or_default();
            edit.config.set(
                &new,
                "credential_process",
                Some(&helper::line(Path::new(&program), to)?),
            )?;
            edit.moves.push((from.to_string(), to.to_string()));
        }
        Ok(())
    }

    /// Region, output, the settings of its kind and, when the name changes, a rename.
    pub fn update(&self, name: &str, draft: Draft) -> Result<()> {
        draft.validate()?;
        let mut edit = self.open()?;
        let profile = self.profile(&edit, name)?;
        if draft.name != name {
            self.rename(&mut edit, name, &draft.name)?;
        }
        let mut settings = vec![
            ("region", some(&draft.region)),
            ("output", some(&draft.output)),
        ];
        match profile.kind {
            Kind::Sso => {
                ensure!(
                    some(&draft.account_id).is_some() && some(&draft.role_name).is_some(),
                    "aws_profile_incomplete"
                );
                settings.extend([
                    ("sso_account_id", some(&draft.account_id)),
                    ("sso_role_name", some(&draft.role_name)),
                ]);
            }
            Kind::Role if profile.source_profile.is_some() => {
                ensure!(some(&draft.role_arn).is_some(), "aws_profile_incomplete");
                ensure!(
                    draft.source_profile != draft.name && self.exists(&edit, &draft.source_profile),
                    "aws_profile_incomplete"
                );
                settings.extend([
                    ("role_arn", some(&draft.role_arn)),
                    ("source_profile", some(&draft.source_profile)),
                ]);
            }
            _ => {}
        }
        Self::set_all(&mut edit, &draft.name, &settings)?;
        self.save(edit)
    }

    /// A copy of the config section under a new name. Keys are never copied: a profile with
    /// static keys (in a file or in the Keychain) is refused.
    pub fn duplicate(&self, name: &str, new: &str) -> Result<()> {
        ensure!(helper::valid_name(new), "aws_invalid_profile");
        let mut edit = self.open()?;
        let profile = self.profile(&edit, name)?;
        ensure!(
            profile.key_file.is_none() && profile.helper.is_none(),
            "aws_has_keys"
        );
        ensure!(!self.exists(&edit, new), "aws_profile_exists");
        let from = profiles::config_section(&edit.config, name)?;
        let to = if new == "default" {
            "default".to_string()
        } else {
            format!("profile {new}")
        };
        edit.config.copy(&from, &to)?;
        self.save(edit)
    }

    /// Removes both sections and, for Stack's credential process, its Keychain item. A profile
    /// another one assumes a role from stays.
    pub fn delete(&self, name: &str) -> Result<()> {
        let mut edit = self.open()?;
        let profile = self.profile(&edit, name)?;
        let used = profiles::read_profiles(&edit.config, &edit.credentials, self.files, None, 0)
            .iter()
            .any(|p| p.source_profile.as_deref() == Some(name) && p.name != name);
        ensure!(!used, "aws_profile_in_use");
        let section = profiles::config_section(&edit.config, name)?;
        edit.config.remove(&section)?;
        edit.credentials.remove(name)?;
        self.save(edit)?;
        if profile.helper.is_some() {
            self.secrets.delete(name)?;
        }
        Ok(())
    }

    /// The CLI's default is the profile named `default`: this one takes the name and the current
    /// default (if any) is renamed to `previous`. Nothing is copied.
    pub fn set_default(&self, name: &str, previous: Option<&str>) -> Result<()> {
        if name == "default" {
            return Ok(());
        }
        let mut edit = self.open()?;
        self.profile(&edit, name)?;
        if self.exists(&edit, "default") {
            let previous = previous.filter(|p| helper::valid_name(p) && *p != "default");
            let previous = previous.ok_or_else(|| anyhow::anyhow!("aws_invalid_profile"))?;
            self.rename(&mut edit, "default", previous)?;
        }
        self.rename(&mut edit, name, "default")?;
        self.save(edit)
    }

    /// Points Stack's credential process of a profile at the engine that is running now.
    pub fn repair(&self, name: &str) -> Result<()> {
        let program = self
            .helper
            .ok_or_else(|| anyhow::anyhow!("aws_helper_path_unsupported"))?;
        let mut edit = self.open()?;
        let profile = self.profile(&edit, name)?;
        ensure!(profile.helper.is_some(), "aws_invalid_profile");
        let section = profiles::config_section(&edit.config, name)?;
        edit.config.set(
            &section,
            "credential_process",
            Some(&helper::line(program, name)?),
        )?;
        self.save(edit)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::aws::keychain::Memory;
    use crate::aws::profiles::tests::{CONFIG, CREDENTIALS};
    use std::{fs, os::unix::fs::PermissionsExt};

    struct Fixture {
        _temp: tempfile::TempDir,
        store: Store,
        files: Files,
        secrets: Memory,
        program: std::path::PathBuf,
    }

    fn fixture() -> Fixture {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path().join("home");
        fs::create_dir_all(home.join(".aws")).unwrap();
        fs::write(home.join(".aws/config"), CONFIG).unwrap();
        fs::write(home.join(".aws/credentials"), CREDENTIALS).unwrap();
        let program = temp.path().join("Stack QA.app/butake-stack");
        fs::create_dir_all(program.parent().unwrap()).unwrap();
        fs::write(&program, "").unwrap();
        Fixture {
            store: Store::new(temp.path().join("store")).unwrap(),
            files: Files {
                config: home.join(".aws/config"),
                credentials: home.join(".aws/credentials"),
                home,
            },
            secrets: Memory::default(),
            program,
            _temp: temp,
        }
    }

    impl Fixture {
        fn changes(&self) -> Changes<'_> {
            Changes {
                store: &self.store,
                files: &self.files,
                secrets: &self.secrets,
                helper: Some(&self.program),
            }
        }
        fn config(&self) -> String {
            fs::read_to_string(&self.files.config).unwrap()
        }
        fn credentials(&self) -> String {
            fs::read_to_string(&self.files.credentials).unwrap()
        }
        fn backups(&self) -> usize {
            fs::read_dir(self.store.root().join("aws-backups"))
                .map(|d| d.count())
                .unwrap_or(0)
        }
    }

    fn draft(name: &str, kind: &str) -> Draft {
        Draft {
            name: name.into(),
            kind: kind.into(),
            ..Default::default()
        }
    }

    #[test]
    fn editing_a_profile_changes_only_its_lines_with_a_private_backup() {
        let f = fixture();
        f.changes()
            .update(
                "acme-dev",
                Draft {
                    region: "us-west-2".into(),
                    output: "json".into(),
                    account_id: "111122223333".into(),
                    role_name: "Desarrollo".into(),
                    ..draft("acme-dev", "sso")
                },
            )
            .unwrap();
        assert_eq!(
            f.config(),
            CONFIG.replace(
                "region = sa-east-1\n",
                "region = us-west-2\noutput = json\n"
            )
        );
        // The credentials file did not change, so it was neither backed up nor written.
        assert_eq!(f.credentials(), CREDENTIALS);
        assert_eq!(f.backups(), 1);
        let backup = fs::read_dir(f.store.root().join("aws-backups"))
            .unwrap()
            .next()
            .unwrap()
            .unwrap()
            .path();
        assert_eq!(fs::read_to_string(&backup).unwrap(), CONFIG);
        assert!(
            backup
                .file_name()
                .unwrap()
                .to_str()
                .unwrap()
                .starts_with("config-20")
        );
        for path in [&backup, &f.files.config] {
            assert_eq!(
                fs::metadata(path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
        // Nothing to change: no write and no backup.
        f.changes()
            .update(
                "acme-dev",
                Draft {
                    region: "us-west-2".into(),
                    output: "json".into(),
                    account_id: "111122223333".into(),
                    role_name: "Desarrollo".into(),
                    ..draft("acme-dev", "sso")
                },
            )
            .unwrap();
        assert_eq!(f.backups(), 1);
    }

    #[test]
    fn new_profiles_of_each_kind() {
        let f = fixture();
        let keys = || {
            Keys::from_request(
                &serde_json::json!({"accessKeyId": "AKIAEJEMPLO00001", "secretAccessKey": "secreto/de+ejemplo/0001"}),
            )
        };
        // Plain text, as the CLI does: credentials gets the keys, config only what is set.
        f.changes()
            .create(draft("texto", "static"), keys(), false)
            .unwrap();
        assert_eq!(
            f.credentials(),
            format!(
                "{CREDENTIALS}\n[texto]\naws_access_key_id = AKIAEJEMPLO00001\naws_secret_access_key = secreto/de+ejemplo/0001\n"
            )
        );
        assert_eq!(f.config(), CONFIG);
        // Keychain: the keys go there, the config file points at the engine.
        f.changes()
            .create(
                Draft {
                    region: "sa-east-1".into(),
                    ..draft("seguro", "static")
                },
                keys(),
                true,
            )
            .unwrap();
        assert!(f.config().ends_with(&format!(
            "\n[profile seguro]\ncredential_process = \"{}\" aws-credential seguro\nregion = sa-east-1\n",
            f.program.display()
        )));
        assert!(!f.config().contains("secreto") && !f.credentials().contains("seguro"));
        assert!(
            String::from_utf8(f.secrets.get("seguro").unwrap().unwrap())
                .unwrap()
                .contains("secreto/de+ejemplo/0001")
        );
        // Single sign-on with a new session, and a role from an existing profile.
        f.changes()
            .create(
                Draft {
                    sso_session: "nueva".into(),
                    sso_start_url: "https://nueva.awsapps.com/start".into(),
                    sso_region: "us-east-1".into(),
                    account_id: "111122223333".into(),
                    role_name: "Lectura".into(),
                    ..draft("sso-nuevo", "sso")
                },
                None,
                false,
            )
            .unwrap();
        assert!(f.config().contains("[sso-session nueva]\nsso_start_url = https://nueva.awsapps.com/start\nsso_region = us-east-1\nsso_registration_scopes = sso:account:access\n\n[profile sso-nuevo]\nsso_session = nueva\nsso_account_id = 111122223333\nsso_role_name = Lectura\n"));
        f.changes()
            .create(
                Draft {
                    role_arn: "arn:aws:iam::111122223333:role/x".into(),
                    source_profile: "sso-nuevo".into(),
                    ..draft("rol", "role")
                },
                None,
                false,
            )
            .unwrap();
        assert!(f.config().ends_with("[profile rol]\nrole_arn = arn:aws:iam::111122223333:role/x\nsource_profile = sso-nuevo\n"));
        // Refused: an existing name, bad keys, a value that would add lines, an unknown source.
        let error = |result: Result<()>| result.unwrap_err().to_string();
        assert_eq!(
            error(f.changes().create(draft("acme-dev", "role"), None, false)),
            "aws_profile_exists"
        );
        assert_eq!(
            error(
                f.changes()
                    .create(draft("temporal", "static"), keys(), false)
            ),
            "aws_profile_exists"
        );
        assert_eq!(
            error(f.changes().create(draft("malo", "static"), None, false)),
            "aws_invalid_keys"
        );
        assert_eq!(
            error(f.changes().create(
                Draft {
                    region: "us-east-1\n[profile x]".into(),
                    ..draft("malo", "sso")
                },
                None,
                false
            )),
            "aws_invalid_profile"
        );
        assert_eq!(
            error(f.changes().create(
                Draft {
                    role_arn: "arn:aws:iam::1:role/x".into(),
                    source_profile: "nadie".into(),
                    ..draft("malo", "role")
                },
                None,
                false
            )),
            "aws_profile_incomplete"
        );
    }

    #[test]
    fn rename_duplicate_delete_and_default() {
        let f = fixture();
        f.changes().create(draft("seguro", "static"), Keys::from_request(&serde_json::json!({"accessKeyId": "AKIAEJEMPLO00001", "secretAccessKey": "secreto/de+ejemplo/0001"})), true).unwrap();
        // Renaming the source of a role follows it in the role; the header keeps its own form.
        f.changes()
            .update(
                "acme-dev",
                Draft {
                    account_id: "111122223333".into(),
                    role_name: "Desarrollo".into(),
                    region: "sa-east-1".into(),
                    ..draft("acme-desarrollo", "sso")
                },
            )
            .unwrap();
        assert!(
            f.config()
                .contains("[profile acme-desarrollo]\nsso_session = acme")
        );
        assert!(f.config().contains("source_profile = acme-desarrollo\n"));
        // A Keychain profile moves its item and its line.
        f.changes()
            .update("seguro", draft("seguro-2", "static"))
            .unwrap();
        assert!(
            f.secrets.get("seguro").unwrap().is_none()
                && f.secrets.get("seguro-2").unwrap().is_some()
        );
        assert!(f.config().contains("aws-credential seguro-2\n"));
        // Duplicates copy settings, never keys.
        f.changes().duplicate("acme-prod", "acme-prod-2").unwrap();
        assert!(f.config().ends_with("[profile acme-prod-2]\nrole_arn = arn:aws:iam::444455556666:role/Despliegue\nsource_profile = acme-desarrollo\nregion = us-east-1\n"));
        for keyed in ["default", "temporal", "seguro-2"] {
            assert_eq!(
                f.changes()
                    .duplicate(keyed, "copia")
                    .unwrap_err()
                    .to_string(),
                "aws_has_keys"
            );
        }
        // A profile others assume roles from stays; deleting the others is clean.
        assert_eq!(
            f.changes()
                .delete("acme-desarrollo")
                .unwrap_err()
                .to_string(),
            "aws_profile_in_use"
        );
        f.changes().delete("seguro-2").unwrap();
        assert!(f.secrets.get("seguro-2").unwrap().is_none() && !f.config().contains("seguro-2"));
        f.changes().delete("temporal").unwrap();
        assert!(!f.credentials().contains("temporal") && f.credentials().contains("[default]"));
        // The default: the old one takes another name in both files, the chosen one becomes default.
        assert_eq!(
            f.changes()
                .set_default("acme-prod", None)
                .unwrap_err()
                .to_string(),
            "aws_invalid_profile"
        );
        f.changes()
            .set_default("acme-prod", Some("anterior"))
            .unwrap();
        assert!(
            f.config()
                .contains("[profile anterior]\nregion = us-east-1\noutput = json\n")
        );
        assert!(
            f.config()
                .contains("[default]\nrole_arn = arn:aws:iam::444455556666:role/Despliegue\n")
        );
        assert!(
            f.credentials()
                .starts_with("[anterior]\naws_access_key_id = AKIAIOSFODNN7EXAMPLE\n")
        );
    }

    #[test]
    fn a_rename_whose_save_fails_leaves_the_keychain_item_where_the_files_say() {
        let f = fixture();
        f.changes().create(draft("seguro", "static"), Keys::from_request(&serde_json::json!({"accessKeyId": "AKIAEJEMPLO00001", "secretAccessKey": "secreto/de+ejemplo/0001"})), true).unwrap();
        let folder = f.files.home.join(".aws");
        // Nothing can be written in the folder of the files: the save fails after the rename.
        fs::set_permissions(&folder, fs::Permissions::from_mode(0o500)).unwrap();
        let failed = f.changes().update("seguro", draft("seguro-2", "static"));
        fs::set_permissions(&folder, fs::Permissions::from_mode(0o700)).unwrap();
        assert!(failed.is_err());
        assert!(f.secrets.get("seguro").unwrap().is_some());
        assert!(f.secrets.get("seguro-2").unwrap().is_none());
        assert!(f.config().contains("aws-credential seguro\n"));
    }

    #[test]
    fn missing_files_are_created_private_and_repair_points_at_this_engine() {
        let f = fixture();
        fs::remove_file(&f.files.config).unwrap();
        fs::remove_dir_all(f.files.home.join(".aws")).unwrap();
        f.changes()
            .create(
                Draft {
                    role_arn: "arn:aws:iam::1:role/x".into(),
                    source_profile: "nadie".into(),
                    ..draft("a", "role")
                },
                None,
                false,
            )
            .unwrap_err();
        f.changes()
            .create(
                Draft {
                    sso_session: "s".into(),
                    sso_start_url: "https://s.awsapps.com/start".into(),
                    sso_region: "us-east-1".into(),
                    account_id: "111122223333".into(),
                    role_name: "r".into(),
                    ..draft("a", "sso")
                },
                None,
                false,
            )
            .unwrap();
        assert_eq!(
            fs::metadata(&f.files.config).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(
            fs::metadata(f.files.home.join(".aws"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        assert!(!f.files.credentials.exists());
        // A profile whose engine moved is pointed at the running one.
        fs::write(&f.files.config, "[profile movido]\ncredential_process = \"/Applications/Viejo.app/butake-stack\" aws-credential movido\n").unwrap();
        f.changes().repair("movido").unwrap();
        assert_eq!(
            f.config(),
            format!(
                "[profile movido]\ncredential_process = \"{}\" aws-credential movido\n",
                f.program.display()
            )
        );
        assert_eq!(
            f.changes().repair("nadie").unwrap_err().to_string(),
            "aws_profile_not_found"
        );
    }
}
