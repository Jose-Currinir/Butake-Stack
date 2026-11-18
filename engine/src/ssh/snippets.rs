//! Snippets of the SSH terminal: saved commands, global or for one host. The app inserts them in
//! the active terminal (and only sends Return when the user chose to run it). Only printable text,
//! tabs and line breaks are kept: a snippet can never carry terminal escape sequences.
use crate::core::json;
use crate::core::validate;
use crate::{core::store::Store, ssh::hosts};
use anyhow::{Result, bail, ensure};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Snippet {
    #[serde(default)]
    pub id: String,
    pub name: String,
    pub command: String,
    #[serde(default)]
    pub description: String,
    /// A saved host's id; none = every terminal (local ones too).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host: Option<String>,
}

fn file(store: &Store) -> Result<PathBuf> {
    let dir = store.directory("config")?.join("ssh");
    std::fs::create_dir_all(&dir)?;
    Ok(dir.join("snippets.json"))
}

pub fn list(store: &Store) -> Result<Vec<Snippet>> {
    let path = file(store)?;
    if !path.exists() {
        return Ok(vec![]);
    }
    json::read_regular(&path, None)
}

fn write(store: &Store, snippets: &mut [Snippet]) -> Result<()> {
    snippets.sort_by_key(|s| (s.host.is_some(), s.name.to_lowercase()));
    json::write(&file(store)?, snippets)
}

impl Snippet {
    fn validate(&self, store: &Store) -> Result<()> {
        ensure!(validate::id(&self.id, hosts::MAX_ID), "invalid_snippet");
        ensure!(
            !self.name.trim().is_empty()
                && validate::printable(&self.name, 80)
                && validate::printable(&self.description, 400),
            "invalid_snippet"
        );
        ensure!(
            !self.command.trim().is_empty() && self.command.chars().count() <= 8000,
            "invalid_snippet"
        );
        ensure!(
            self.command
                .chars()
                .all(|c| !c.is_control() || c == '\n' || c == '\t'),
            "invalid_snippet"
        );
        if let Some(host) = &self.host {
            hosts::find(store, host).map_err(|_| anyhow::anyhow!("invalid_snippet"))?;
        }
        Ok(())
    }
}

pub fn save(store: &Store, mut snippet: Snippet) -> Result<Snippet> {
    snippet.name = snippet.name.trim().into();
    snippet.description = snippet.description.trim().into();
    // Windows line endings would send a stray carriage return (Enter) to the terminal.
    snippet.command = snippet
        .command
        .replace("\r\n", "\n")
        .trim_end_matches(['\n', ' ', '\t'])
        .to_string();
    snippet.host = snippet.host.filter(|h| !h.is_empty());
    let mut snippets = list(store)?;
    if snippet.id.is_empty() {
        snippet.id = hosts::unique(hosts::slug(&snippet.name, "snippet"), |id| {
            snippets.iter().any(|s| s.id == id)
        });
    }
    snippet.validate(store)?;
    snippets.retain(|s| s.id != snippet.id);
    snippets.push(snippet.clone());
    write(store, &mut snippets)?;
    Ok(snippet)
}

pub fn delete(store: &Store, id: &str) -> Result<()> {
    let mut snippets = list(store)?;
    ensure!(snippets.iter().any(|s| s.id == id), "unknown_snippet");
    snippets.retain(|s| s.id != id);
    write(store, &mut snippets)
}

/// When a host goes, its own snippets go with it.
pub fn delete_for_host(store: &Store, host: &str) -> Result<()> {
    let mut snippets = list(store)?;
    let before = snippets.len();
    snippets.retain(|s| s.host.as_deref() != Some(host));
    if snippets.len() != before {
        write(store, &mut snippets)?;
    }
    Ok(())
}

pub fn delete_all(store: &Store) -> Result<()> {
    let path = file(store)?;
    if path.exists() {
        std::fs::remove_file(path)?;
    }
    Ok(())
}

pub fn dispatch(
    store: &Store,
    method: &str,
    request: &serde_json::Value,
) -> Result<serde_json::Value> {
    match method {
        "sshSnippets" => Ok(serde_json::to_value(list(store)?)?),
        "sshSnippetSave" => {
            let snippet: Snippet = serde_json::from_value(request["snippet"].clone())
                .map_err(|_| anyhow::anyhow!("invalid_snippet"))?;
            Ok(serde_json::to_value(save(store, snippet)?)?)
        }
        "sshSnippetDelete" => {
            delete(store, request["id"].as_str().unwrap_or(""))?;
            Ok(serde_json::json!(true))
        }
        _ => bail!("invalid_request"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snippets_keep_plain_text_and_follow_their_host() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::new(temp.path().join("store")).unwrap();
        let host = hosts::save(
            &store,
            hosts::Host {
                id: String::new(),
                name: "Web".into(),
                description: String::new(),
                group: String::new(),
                tags: vec![],
                host: "web.ejemplo.cl".into(),
                port: 22,
                user: "deploy".into(),
                key: None,
                identity: None,
                jump: None,
                forwards: vec![],
            },
        )
        .unwrap();
        let global = save(
            &store,
            Snippet {
                id: String::new(),
                name: "Espacio".into(),
                command: "df -h\r\n".into(),
                description: String::new(),
                host: None,
            },
        )
        .unwrap();
        assert_eq!(global.id, "espacio");
        assert_eq!(global.command, "df -h");
        let own = save(
            &store,
            Snippet {
                id: String::new(),
                name: "Logs".into(),
                command: "cd /var/log\ntail -f syslog".into(),
                description: String::new(),
                host: Some(host.id.clone()),
            },
        )
        .unwrap();
        assert_eq!(list(&store).unwrap().len(), 2);
        // Escape sequences and unknown hosts are refused.
        let bad = Snippet {
            id: String::new(),
            name: "x".into(),
            command: "echo \u{1b}]52;c;AAAA\u{7}".into(),
            description: String::new(),
            host: None,
        };
        assert_eq!(
            save(&store, bad).unwrap_err().to_string(),
            "invalid_snippet"
        );
        let bad = Snippet {
            id: String::new(),
            name: "x".into(),
            command: "ls".into(),
            description: String::new(),
            host: Some("nope".into()),
        };
        assert_eq!(
            save(&store, bad).unwrap_err().to_string(),
            "invalid_snippet"
        );
        hosts::delete(&store, &host.id).unwrap();
        let left = list(&store).unwrap();
        assert!(left.iter().all(|s| s.id != own.id) && left.len() == 1);
        delete(&store, &global.id).unwrap();
        assert_eq!(
            delete(&store, "espacio").unwrap_err().to_string(),
            "unknown_snippet"
        );
    }
}
