//! What gcloud answers, reduced to what the tool shows: of an account its address, whether it is
//! a service account and whether it is gcloud's active one; of a project its id, name and number.
//! Anything else gcloud prints (labels, parents, dates) is dropped here.

use super::cli::{Cli, PROJECTS_LIMIT, SHORT_LIMIT};
use crate::core::validate;
use anyhow::{ensure, Result};
use serde::Serialize;
use serde_json::Value;
use std::path::Path;

#[derive(Debug, Serialize, PartialEq)]
pub struct Account {
    pub account: String,
    /// `user` or `service`.
    pub kind: &'static str,
    /// gcloud's active account (Stack never changes which one it is).
    pub active: bool,
}

#[derive(Debug, Serialize, PartialEq)]
pub struct Project {
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub number: Option<String>,
}

/// Most projects listed for one account.
const MAX_PROJECTS: usize = 2000;

/// `gcloud auth list --format=json`: the accounts with credentials on this Mac.
pub fn parse_accounts(text: &str) -> Result<Vec<Account>> {
    let value: Value = serde_json::from_str(text).map_err(|_| anyhow::anyhow!("gcp_failed"))?;
    let list = value
        .as_array()
        .ok_or_else(|| anyhow::anyhow!("gcp_failed"))?;
    let mut accounts: Vec<Account> = list
        .iter()
        .filter_map(|entry| {
            let account = entry["account"].as_str()?;
            validate::gcp_account(account).then(|| Account {
                account: account.to_string(),
                kind: if account.ends_with(".gserviceaccount.com") {
                    "service"
                } else {
                    "user"
                },
                active: entry["status"].as_str() == Some("ACTIVE"),
            })
        })
        .collect();
    accounts.sort_by(|a, b| a.account.cmp(&b.account));
    accounts.dedup_by(|a, b| a.account == b.account);
    Ok(accounts)
}

/// `gcloud projects list --format=json`: id, name and number of each project.
pub fn parse_projects(text: &str) -> Result<Vec<Project>> {
    let value: Value = serde_json::from_str(text).map_err(|_| anyhow::anyhow!("gcp_failed"))?;
    let list = value
        .as_array()
        .ok_or_else(|| anyhow::anyhow!("gcp_failed"))?;
    let mut projects: Vec<Project> = list
        .iter()
        .filter_map(|entry| {
            let id = entry["projectId"].as_str()?;
            validate::gcp_project(id).then(|| Project {
                id: id.to_string(),
                name: entry["name"]
                    .as_str()
                    .filter(|name| !name.is_empty() && validate::printable(name, 200))
                    .map(String::from),
                number: entry["projectNumber"]
                    .as_str()
                    .filter(|n| {
                        !n.is_empty() && n.len() <= 20 && n.bytes().all(|c| c.is_ascii_digit())
                    })
                    .map(String::from),
            })
        })
        .take(MAX_PROJECTS)
        .collect();
    projects.sort_by(|a, b| a.id.cmp(&b.id));
    Ok(projects)
}

pub fn list(cli: &Cli, records: &Path) -> Result<Vec<Account>> {
    parse_accounts(&cli.run(
        records,
        &["auth", "list", "--format=json", "--quiet"],
        SHORT_LIMIT,
    )?)
}

/// The projects `account` reaches. The account goes as `--account`, so gcloud's active one is
/// neither used nor changed.
pub fn projects(cli: &Cli, records: &Path, account: &str) -> Result<Vec<Project>> {
    ensure!(validate::gcp_account(account), "gcp_invalid_account");
    let flag = format!("--account={account}");
    parse_projects(&cli.run(
        records,
        &[
            "projects",
            "list",
            &flag,
            "--filter=lifecycleState:ACTIVE",
            "--format=json(projectId,name,projectNumber)",
            "--limit=2000",
            "--quiet",
        ],
        PROJECTS_LIMIT,
    )?)
}

/// «Cerrar sesión…»: gcloud forgets the account's credentials on this Mac. Never the active
/// account: revoking it would leave gcloud without one, and Stack does not change that.
pub fn revoke(cli: &Cli, records: &Path, account: &str) -> Result<()> {
    ensure!(validate::gcp_account(account), "gcp_invalid_account");
    let known = list(cli, records)?;
    let found = known
        .iter()
        .find(|a| a.account == account)
        .ok_or_else(|| anyhow::anyhow!("gcp_unknown_account"))?;
    ensure!(!found.active, "gcp_account_active");
    cli.run(
        records,
        &["auth", "revoke", account, "--quiet"],
        SHORT_LIMIT,
    )
    .map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accounts_keep_only_what_the_tool_shows() {
        let accounts = parse_accounts(
            r#"[{"account": "qa@ejemplo.test", "status": "ACTIVE"},
                {"account": "despliegue@tienda-ficticia.iam.gserviceaccount.com", "status": ""},
                {"account": "-x@ejemplo.test", "status": ""},
                {"account": "qa@ejemplo.test", "status": ""},
                {"status": "ACTIVE"}]"#,
        )
        .unwrap();
        assert_eq!(
            accounts,
            [
                Account {
                    account: "despliegue@tienda-ficticia.iam.gserviceaccount.com".into(),
                    kind: "service",
                    active: false
                },
                Account {
                    account: "qa@ejemplo.test".into(),
                    kind: "user",
                    active: true
                },
            ]
        );
        assert!(parse_accounts("[]").unwrap().is_empty());
        assert_eq!(
            parse_accounts("no es json").unwrap_err().to_string(),
            "gcp_failed"
        );
    }

    #[test]
    fn projects_keep_id_name_and_number() {
        let projects = parse_projects(
            r#"[{"projectId": "tienda-ficticia", "name": "Tienda ficticia", "projectNumber": "100000000001",
                 "labels": {"equipo": "qa"}, "parent": {"id": "1", "type": "organization"}},
                {"projectId": "Malo", "name": "x"},
                {"projectId": "agenda-de-prueba", "name": "con\nsalto", "projectNumber": "12a"}]"#,
        )
        .unwrap();
        assert_eq!(
            projects,
            [
                Project {
                    id: "agenda-de-prueba".into(),
                    name: None,
                    number: None
                },
                Project {
                    id: "tienda-ficticia".into(),
                    name: Some("Tienda ficticia".into()),
                    number: Some("100000000001".into())
                },
            ]
        );
    }
}
