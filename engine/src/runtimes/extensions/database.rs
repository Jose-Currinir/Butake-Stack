//! Second level: an extension *active in a database* (`CREATE EXTENSION`) of Stack's PostgreSQL,
//! which must be running. Names are checked against what the server offers and against a strict
//! pattern before they reach SQL; databases are Stack's identifiers (`validate_database`).
use crate::web::services::databases::{Postgres, validate_database};
use anyhow::{Result, anyhow, bail, ensure};
use serde::{Deserialize, Serialize};

/// A name `CREATE EXTENSION` may receive (see `core::project_database::extension_name`).
pub fn validate_name(name: &str) -> Result<()> {
    ensure!(
        crate::core::project_database::extension_name(name),
        "invalid_extension"
    );
    Ok(())
}

/// PostgreSQL's own language: present in every database, never deactivated from here.
const PROTECTED: &[&str] = &["plpgsql"];

fn json_rows<T: for<'de> Deserialize<'de>>(pg: &Postgres, sql: &str, database: &str) -> Result<T> {
    let text = pg.run(sql, database)?;
    Ok(serde_json::from_str(if text.is_empty() {
        "[]"
    } else {
        &text
    })?)
}

/// The databases of the server (not templates); a server that does not answer is said as such.
pub fn databases(pg: &Postgres) -> Result<Vec<String>> {
    json_rows(
        pg,
        "SELECT coalesce(json_agg(datname ORDER BY datname), '[]') FROM pg_database \
         WHERE datallowconn AND NOT datistemplate;",
        "postgres",
    )
    .map_err(|_| anyhow!("postgres_not_running"))
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Active {
    pub name: String,
    pub version: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Offered {
    pub name: String,
    pub default_version: Option<String>,
    pub installed_version: Option<String>,
    pub comment: Option<String>,
}

pub fn active(pg: &Postgres, database: &str) -> Result<Vec<Active>> {
    validate_database(database)?;
    json_rows(
        pg,
        "SELECT coalesce(json_agg(json_build_object('name', extname, 'version', extversion) \
         ORDER BY extname), '[]') FROM pg_extension;",
        database,
    )
}

/// What the engine copy offers to this database (its control files), active or not.
pub fn offered(pg: &Postgres, database: &str) -> Result<Vec<Offered>> {
    validate_database(database)?;
    json_rows(
        pg,
        "SELECT coalesce(json_agg(json_build_object('name', name, 'defaultVersion', default_version, \
         'installedVersion', installed_version, 'comment', comment) ORDER BY name), '[]') \
         FROM pg_available_extensions;",
        database,
    )
}

/// The databases where any of `names` is active: an extension is not removed while one uses it.
pub fn in_use(pg: &Postgres, names: &[&str]) -> Result<Vec<String>> {
    for name in names {
        validate_name(name)?;
    }
    let list = names
        .iter()
        .map(|n| format!("'{n}'"))
        .collect::<Vec<_>>()
        .join(", ");
    let mut out = vec![];
    for database in databases(pg)? {
        if validate_database(&database).is_err() && database != "postgres" {
            continue;
        }
        let found = pg.run(
            &format!("SELECT 1 FROM pg_extension WHERE extname IN ({list}) LIMIT 1;"),
            &database,
        )?;
        if !found.is_empty() {
            out.push(database);
        }
    }
    Ok(out)
}

/// `CREATE EXTENSION` (with what it requires) in `database`, only for a name the server offers.
pub fn activate(pg: &Postgres, database: &str, name: &str) -> Result<()> {
    validate_name(name)?;
    let offered = offered(pg, database)?;
    ensure!(
        offered.iter().any(|o| o.name == name),
        "extension_not_installed"
    );
    pg.run(
        &format!("CREATE EXTENSION IF NOT EXISTS \"{name}\" CASCADE;"),
        database,
    )?;
    Ok(())
}

/// What deactivating `name` would take with it: objects of the database built on it (a column of
/// type `geometry`, an index) and the extensions that require it. What hangs from the extension's
/// own objects (the members of its operator families, the columns of its composite types, the rules
/// of its views) is part of it, not something the user would lose.
pub fn dependents(pg: &Postgres, database: &str, name: &str) -> Result<Vec<String>> {
    validate_name(name)?;
    validate_database(database)?;
    json_rows(
        pg,
        &format!(
            "WITH x AS (SELECT oid FROM pg_extension WHERE extname = '{name}'), \
             members AS (SELECT classid, objid FROM pg_depend WHERE deptype = 'e' \
               AND refclassid = 'pg_extension'::regclass AND refobjid IN (SELECT oid FROM x)), \
             found AS ( \
               SELECT DISTINCT pg_describe_object(d.classid, d.objid, d.objsubid) AS what \
               FROM pg_depend d JOIN members m ON d.refclassid = m.classid AND d.refobjid = m.objid \
               WHERE d.deptype = 'n' AND NOT EXISTS (SELECT 1 FROM pg_depend o \
                 WHERE o.classid = d.classid AND o.objid = d.objid AND o.deptype = 'e') \
                 AND d.classid NOT IN ('pg_amop'::regclass, 'pg_amproc'::regclass) \
                 AND NOT EXISTS (SELECT 1 FROM pg_depend o JOIN members m2 \
                   ON o.refclassid = m2.classid AND o.refobjid = m2.objid \
                   WHERE o.classid = d.classid AND o.objid = d.objid AND o.deptype IN ('i', 'a')) \
               UNION SELECT pg_describe_object(d.classid, d.objid, 0) FROM pg_depend d \
               WHERE d.classid = 'pg_extension'::regclass AND d.refclassid = 'pg_extension'::regclass \
                 AND d.refobjid IN (SELECT oid FROM x) AND d.deptype = 'n') \
             SELECT coalesce(json_agg(what ORDER BY what), '[]') FROM (SELECT what FROM found LIMIT 200) f;"
        ),
        database,
    )
}

/// `DROP EXTENSION`. With dependents, only when the user confirmed losing them (`cascade`).
pub fn deactivate(pg: &Postgres, database: &str, name: &str, cascade: bool) -> Result<()> {
    validate_name(name)?;
    ensure!(!PROTECTED.contains(&name), "extension_protected");
    let found = dependents(pg, database, name)?;
    if !found.is_empty() && !cascade {
        bail!("extension_has_dependents");
    }
    pg.run(
        &format!(
            "DROP EXTENSION IF EXISTS \"{name}\"{};",
            if cascade { " CASCADE" } else { "" }
        ),
        database,
    )?;
    Ok(())
}

/// After a new version of the files: every database that uses `names` moves to it.
pub fn update_everywhere(pg: &Postgres, names: &[&str]) -> Result<Vec<String>> {
    let mut updated = vec![];
    for database in in_use(pg, names)? {
        for row in active(pg, &database).unwrap_or_default() {
            if names.contains(&row.name.as_str()) {
                pg.run(
                    &format!("ALTER EXTENSION \"{}\" UPDATE;", row.name),
                    &database,
                )?;
            }
        }
        updated.push(database);
    }
    Ok(updated)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_reach_sql_only_when_safe() {
        for good in ["postgis", "uuid-ossp", "pg_trgm", "vector"] {
            assert!(validate_name(good).is_ok(), "{good}");
        }
        for bad in [
            "",
            "Postgis",
            "x\"; drop",
            "-x",
            "a b",
            "x'y",
            &"a".repeat(64),
        ] {
            assert!(validate_name(bad).is_err(), "{bad}");
        }
    }
}
