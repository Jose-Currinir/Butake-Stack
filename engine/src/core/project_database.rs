//! `databases[]` of a project: a database's name, and the extensions it needs (P-43). Without
//! extensions it is written as before, a plain name, so older records and older builds read it;
//! with them it is `{"name": "…", "extensions": ["postgis", …]}`.
use serde::{Deserialize, Deserializer, Serialize, Serializer};

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ProjectDatabase {
    pub name: String,
    pub extensions: Vec<String>,
}

impl ProjectDatabase {
    /// Name of letters, digits and `_` (up to 64); at most 32 extensions, each a name `CREATE
    /// EXTENSION` accepts.
    pub fn valid(&self) -> bool {
        !self.name.is_empty()
            && self.name.len() <= 64
            && self
                .name
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || c == b'_')
            && self.extensions.len() <= 32
            && self.extensions.iter().all(|e| extension_name(e))
    }
}

/// What `CREATE EXTENSION` may name in Stack: lowercase letters, digits, `_` and `-` (`uuid-ossp`),
/// up to 63 bytes, never starting with `-`.
pub fn extension_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 63
        && name
            .bytes()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'_' || c == b'-')
        && !name.starts_with('-')
}

/// Records compare with plain names (`databases == ["app"]`).
impl PartialEq<String> for ProjectDatabase {
    fn eq(&self, other: &String) -> bool {
        self.extensions.is_empty() && &self.name == other
    }
}

impl From<&str> for ProjectDatabase {
    fn from(name: &str) -> Self {
        Self {
            name: name.into(),
            extensions: vec![],
        }
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Full {
    name: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    extensions: Vec<String>,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum Raw {
    Name(String),
    Full(Full),
}

impl Serialize for ProjectDatabase {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        if self.extensions.is_empty() {
            serializer.serialize_str(&self.name)
        } else {
            Full {
                name: self.name.clone(),
                extensions: self.extensions.clone(),
            }
            .serialize(serializer)
        }
    }
}

impl<'de> Deserialize<'de> for ProjectDatabase {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Ok(match Raw::deserialize(deserializer)? {
            Raw::Name(name) => Self {
                name,
                extensions: vec![],
            },
            Raw::Full(full) => Self {
                name: full.name,
                extensions: full.extensions,
            },
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn plain_names_and_names_with_extensions() {
        let list: Vec<ProjectDatabase> = serde_json::from_value(json!([
            "app", {"name": "geo", "extensions": ["postgis", "vector"]}, {"name": "solo"}
        ]))
        .unwrap();
        assert_eq!(list[0], "app".to_string());
        assert_eq!(list[1].extensions, ["postgis", "vector"]);
        assert!(list.iter().all(ProjectDatabase::valid));
        assert_eq!(
            serde_json::to_value(&list).unwrap(),
            json!(["app", {"name": "geo", "extensions": ["postgis", "vector"]}, "solo"])
        );
        assert!(
            serde_json::from_value::<ProjectDatabase>(json!({"name": "x", "otra": 1})).is_err()
        );
        let bad = ProjectDatabase {
            name: "geo".into(),
            extensions: vec!["x'; drop".into()],
        };
        assert!(!bad.valid());
    }
}
