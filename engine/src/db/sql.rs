//! Text helpers of the database client: statement splitting, read-only detection, identifier and
//! literal quoting per dialect, and the parsers for what the engines' own clients print (MySQL's
//! XML, CSV from psql and sqlite3). Pure functions, so every rule here has a test.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Dialect {
    MySql,
    Postgres,
    Sqlite,
}

/// Splits a script into statements on `;`, outside strings, quoted identifiers, comments and
/// PostgreSQL dollar quotes. Statements keep their text (comments included) without the `;`;
/// empty ones and comment-only ones are dropped.
pub fn split(text: &str, dialect: Dialect) -> Vec<String> {
    let chars: Vec<char> = text.chars().collect();
    let mut out = vec![];
    let mut start = 0;
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        let next = chars.get(i + 1).copied();
        match c {
            '\'' | '"' | '`' => {
                i += 1;
                while i < chars.len() {
                    if chars[i] == '\\' && dialect == Dialect::MySql && c != '`' {
                        i += 2;
                        continue;
                    }
                    if chars[i] == c {
                        if chars.get(i + 1) == Some(&c) {
                            i += 2;
                            continue;
                        }
                        break;
                    }
                    i += 1;
                }
            }
            '-' if is_dash_comment(&chars, i, dialect) => {
                while i < chars.len() && chars[i] != '\n' {
                    i += 1;
                }
            }
            '#' if dialect == Dialect::MySql => {
                while i < chars.len() && chars[i] != '\n' {
                    i += 1;
                }
            }
            '/' if next == Some('*') => {
                i += 2;
                while i + 1 < chars.len() && !(chars[i] == '*' && chars[i + 1] == '/') {
                    i += 1;
                }
                i += 1;
            }
            '$' if dialect == Dialect::Postgres => {
                // $tag$ … $tag$ (tag of letters, digits, underscore; may be empty).
                let mut j = i + 1;
                while j < chars.len() && (chars[j].is_alphanumeric() || chars[j] == '_') {
                    j += 1;
                }
                if j < chars.len()
                    && chars[j] == '$'
                    && !(j > i + 1 && chars[i + 1].is_ascii_digit())
                {
                    let tag: String = chars[i..=j].iter().collect();
                    let rest: String = chars[j + 1..].iter().collect();
                    if let Some(end) = rest.find(&tag) {
                        i = j + 1 + rest[..end].chars().count() + tag.chars().count() - 1;
                    } else {
                        i = chars.len();
                    }
                }
            }
            ';' => {
                push(&mut out, &chars[start..i], dialect);
                start = i + 1;
            }
            _ => {}
        }
        i += 1;
    }
    if start < chars.len() {
        push(&mut out, &chars[start..], dialect);
    }
    out
}

/// `--` starts a comment, except in MySQL where it needs a whitespace or control character after it
/// (`SELECT 1--1` is arithmetic there).
fn is_dash_comment(chars: &[char], i: usize, dialect: Dialect) -> bool {
    chars[i] == '-'
        && chars.get(i + 1) == Some(&'-')
        && (dialect != Dialect::MySql
            || chars
                .get(i + 2)
                .is_none_or(|c| c.is_whitespace() || c.is_control()))
}

fn push(out: &mut Vec<String>, chars: &[char], dialect: Dialect) {
    let text: String = chars.iter().collect();
    let text = text.trim();
    if !strip_comments(text, dialect).trim().is_empty() {
        out.push(text.to_string());
    }
}

/// The statement without comments and with every string literal emptied: what the keyword checks see.
pub fn strip_comments(text: &str, dialect: Dialect) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::new();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        let next = chars.get(i + 1).copied();
        if is_dash_comment(&chars, i, dialect) || (c == '#' && dialect == Dialect::MySql) {
            while i < chars.len() && chars[i] != '\n' {
                i += 1;
            }
            out.push(' ');
            continue;
        }
        if c == '/' && next == Some('*') {
            i += 2;
            while i + 1 < chars.len() && !(chars[i] == '*' && chars[i + 1] == '/') {
                i += 1;
            }
            i += 2;
            out.push(' ');
            continue;
        }
        if c == '\'' || c == '"' || c == '`' {
            i += 1;
            while i < chars.len() {
                if chars[i] == '\\' && dialect == Dialect::MySql && c != '`' {
                    i += 2;
                    continue;
                }
                if chars[i] == c {
                    if chars.get(i + 1) == Some(&c) {
                        i += 2;
                        continue;
                    }
                    break;
                }
                i += 1;
            }
            i += 1;
            out.push_str(if c == '\'' { "''" } else { "\"x\"" });
            continue;
        }
        out.push(c);
        i += 1;
    }
    out
}

fn words(text: &str, dialect: Dialect) -> Vec<String> {
    strip_comments(text, dialect)
        .split(|c: char| !(c.is_alphanumeric() || c == '_'))
        .filter(|w| !w.is_empty())
        .map(|w| w.to_ascii_lowercase())
        .collect()
}

/// Text the engine's own client would act on instead of sending to the server: psql and mysql
/// backslash meta-commands (`\!`, `\gexec`, `\o |cmd`, `\copy`), the mysql client's line commands
/// (`system`, `source`...), executable `/*! ... */` comments and sqlite3 dot-commands (`.shell`,
/// `.import`...). Like the clients themselves, backslashes are looked for outside string
/// literals and comments (a regex `'\d+'` or an escaped `'it\'s'` is data). Postgres text with a
/// `$` is read raw: dollar quotes are not parsed here, so a quote inside one cannot hide a
/// command (over-reporting only costs a confirmation). The mysql client takes its named
/// commands only as the first word of a statement, so a column called `source` is not one.
pub fn has_client_directive(statement: &str, dialect: Dialect) -> bool {
    match dialect {
        Dialect::Sqlite => statement.lines().any(|l| l.trim_start().starts_with('.')),
        Dialect::Postgres => {
            if statement.contains('$') || has_escape_string(statement) {
                statement.contains('\\')
            } else {
                strip_comments(statement, dialect).contains('\\')
            }
        }
        Dialect::MySql => {
            const COMMANDS: &[&str] = &[
                "system",
                "source",
                "tee",
                "notee",
                "pager",
                "nopager",
                "edit",
                "ego",
                "go",
                "rehash",
                "connect",
                "charset",
                "delimiter",
                "prompt",
                "warnings",
                "nowarning",
                "resetconnection",
            ];
            let stripped = strip_comments(statement, dialect);
            let first = stripped
                .trim_start()
                .split(|c: char| !c.is_ascii_alphanumeric())
                .next()
                .unwrap_or("")
                .to_ascii_lowercase();
            statement.contains("/*!")
                || statement.contains("/*M!")
                || stripped.contains('\\')
                || COMMANDS.contains(&first.as_str())
        }
    }
}

/// Whether Postgres text has an `E'…'` escape string, whose `\'` the literal scanner does not know.
fn has_escape_string(statement: &str) -> bool {
    let chars: Vec<char> = statement.chars().collect();
    chars.windows(2).enumerate().any(|(i, pair)| {
        matches!(pair[0], 'e' | 'E')
            && pair[1] == '\''
            && (i == 0 || !(chars[i - 1].is_alphanumeric() || chars[i - 1] == '_'))
    })
}

/// True only for statements that cannot change data, structure, users or server settings. Anything
/// else needs the user's explicit confirmation before it runs.
pub fn is_read_only(statement: &str, dialect: Dialect) -> bool {
    if has_client_directive(statement, dialect) {
        return false;
    }
    let words = words(statement, dialect);
    let Some(first) = words.first() else {
        return true;
    };
    const READ: &[&str] = &[
        "select", "show", "explain", "describe", "desc", "with", "values", "table", "pragma",
        "use", "help",
    ];
    const WRITE: &[&str] = &[
        "insert",
        "update",
        "delete",
        "merge",
        "replace",
        "into",
        "create",
        "drop",
        "alter",
        "truncate",
        "rename",
        "grant",
        "revoke",
        "call",
        "do",
        "copy",
        "lock",
        "set",
        "load",
        "handler",
        "kill",
        "flush",
        "reset",
        "purge",
        "install",
        "uninstall",
        "shutdown",
        "restart",
        "vacuum",
        "analyze",
        "optimize",
        "repair",
        "attach",
        "detach",
        "reindex",
        "cluster",
        "refresh",
        "listen",
        "notify",
        "execute",
        "prepare",
        "deallocate",
        "import",
        "nextval",
        "setval",
        "pg_terminate_backend",
        "pg_cancel_backend",
        "lo_import",
        "lo_export",
        "dblink",
        "sleep",
        "benchmark",
    ];
    if !READ.contains(&first.as_str()) {
        return false;
    }
    // EXPLAIN ANALYZE runs the statement; PRAGMA x = y writes; SELECT … FOR UPDATE locks rows.
    if first == "pragma" && strip_comments(statement, dialect).contains('=') {
        return false;
    }
    !words.iter().skip(1).any(|w| WRITE.contains(&w.as_str()))
}

/// Whether a statement carries a password (CREATE/ALTER USER … PASSWORD, IDENTIFIED BY, SET
/// PASSWORD, replication credentials, Redis AUTH and friends). Such text never goes to the history.
fn statement_has_secret(statement: &str, dialect: Dialect) -> bool {
    let words = words(statement, dialect);
    let Some(first) = words.first().map(String::as_str) else {
        return false;
    };
    let password_word = |w: &String| {
        w == "password"
            || w.ends_with("_password")
            || w == "passwd"
            || w == "requirepass"
            || w == "masterauth"
    };
    if words.iter().any(|w| w == "identified") {
        return true;
    }
    let has = |w: &str| words.iter().any(|x| x == w);
    // Accounts, roles and foreign servers (a table with a `password` column is not a secret);
    // a subscription's connection string carries its password inside a literal.
    if matches!(first, "create" | "alter")
        && (((has("user") || has("role") || has("server") || has("mapping"))
            && words.iter().any(password_word))
            || has("subscription"))
    {
        return true;
    }
    if matches!(first, "set" | "change") && words.iter().any(password_word) {
        return true;
    }
    // Writes to the server's own accounts (mysql.user, pg_authid) carry password hashes.
    if matches!(first, "update" | "insert" | "replace")
        && (words
            .iter()
            .any(|w| w == "pg_authid" || w == "authentication_string")
            || words.windows(2).any(|p| p[0] == "mysql" && p[1] == "user"))
    {
        return true;
    }
    // Redis: AUTH, ACL SETUSER (passwords as >secret), CONFIG SET requirepass, MIGRATE … AUTH/AUTH2,
    // HELLO … AUTH.
    let lowered = statement.trim().to_ascii_lowercase();
    let mut redis = lowered.split_whitespace();
    let (r1, r2) = (redis.next().unwrap_or(""), redis.next().unwrap_or(""));
    r1 == "auth"
        || (r1 == "acl" && r2 == "setuser")
        || (r1 == "config" && r2 == "set" && words.iter().any(password_word))
        || (matches!(r1, "migrate" | "hello")
            && lowered
                .split_whitespace()
                .any(|w| w == "auth" || w == "auth2"))
}

/// True when any statement of a script carries a password, whatever the dialect's comment rules.
pub fn has_secret(script: &str) -> bool {
    [Dialect::MySql, Dialect::Postgres].iter().any(|d| {
        split(script, *d)
            .iter()
            .any(|s| statement_has_secret(s, *d))
            || script.lines().any(|l| statement_has_secret(l, *d))
    })
}

/// The first word of a statement (lowercase), outside comments.
pub fn first_word(statement: &str, dialect: Dialect) -> String {
    words(statement, dialect)
        .into_iter()
        .next()
        .unwrap_or_default()
}

/// Quoted identifier (names never travel unquoted).
pub fn ident(dialect: Dialect, name: &str) -> String {
    match dialect {
        Dialect::MySql => format!("`{}`", name.replace('`', "``")),
        _ => format!("\"{}\"", name.replace('"', "\"\"")),
    }
}

/// A string literal that is safe whatever the server's SQL mode: hex for MySQL, a dollar quote with
/// a tag absent from the value for PostgreSQL, doubled quotes for SQLite.
pub fn literal(dialect: Dialect, value: &str) -> String {
    match dialect {
        Dialect::MySql => {
            if value.is_empty() {
                "''".into()
            } else {
                format!(
                    "_utf8mb4 X'{}'",
                    value
                        .bytes()
                        .map(|b| format!("{b:02x}"))
                        .collect::<String>()
                )
            }
        }
        Dialect::Postgres => {
            // The closing tag must first appear right after the value.
            let mut n = 0;
            let mut tag = String::from("$b$");
            while format!("{value}{tag}").find(&tag) != Some(value.len()) {
                n += 1;
                tag = format!("$b{n}$");
            }
            format!("{tag}{value}{tag}")
        }
        Dialect::Sqlite => format!("'{}'", value.replace('\'', "''")),
    }
}

/// RFC 4180 CSV (as psql and sqlite3 print it): quoted fields may hold commas, quotes and newlines.
/// Each field says whether it was quoted, which tells an empty string from a missing value.
pub fn parse_csv(text: &str) -> Vec<Vec<(String, bool)>> {
    let mut rows = vec![];
    let mut row = vec![];
    let mut field = String::new();
    let mut quoted = false;
    let mut in_quotes = false;
    let mut chars = text.chars().peekable();
    let mut any = false;
    while let Some(c) = chars.next() {
        any = true;
        if in_quotes {
            if c == '"' {
                if chars.peek() == Some(&'"') {
                    field.push('"');
                    chars.next();
                } else {
                    in_quotes = false;
                }
            } else {
                field.push(c);
            }
            continue;
        }
        match c {
            '"' if field.is_empty() => {
                in_quotes = true;
                quoted = true;
            }
            ',' => {
                row.push((std::mem::take(&mut field), quoted));
                quoted = false;
            }
            '\r' if chars.peek() == Some(&'\n') => {}
            '\n' => {
                row.push((std::mem::take(&mut field), quoted));
                quoted = false;
                rows.push(std::mem::take(&mut row));
                any = false;
            }
            _ => field.push(c),
        }
    }
    if any {
        row.push((field, quoted));
        rows.push(row);
    }
    rows
}

#[derive(Debug, Default, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct ResultSet {
    pub columns: Vec<String>,
    pub rows: Vec<Vec<Option<String>>>,
    /// Rows changed (writes) or returned (reads), when the client says.
    pub affected: Option<i64>,
    pub statement: String,
    /// More rows existed than were kept.
    pub truncated: bool,
}

fn unescape_xml(text: &str) -> String {
    if !text.contains('&') {
        return text.to_string();
    }
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(at) = rest.find('&') {
        out.push_str(&rest[..at]);
        rest = &rest[at..];
        let end = rest.find(';').unwrap_or(0);
        let entity = &rest[..=end];
        let replaced = match entity {
            "&lt;" => Some("<".to_string()),
            "&gt;" => Some(">".to_string()),
            "&amp;" => Some("&".to_string()),
            "&quot;" => Some("\"".to_string()),
            "&apos;" => Some("'".to_string()),
            e if e.starts_with("&#x") => u32::from_str_radix(&e[3..e.len() - 1], 16)
                .ok()
                .and_then(char::from_u32)
                .map(String::from),
            e if e.starts_with("&#") => e[2..e.len() - 1]
                .parse()
                .ok()
                .and_then(char::from_u32)
                .map(String::from),
            _ => None,
        };
        match replaced {
            Some(value) if end > 0 => {
                out.push_str(&value);
                rest = &rest[end + 1..];
            }
            _ => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

/// The fields of one `<row>` of `mysql --xml` (what lies between `<row>` and `</row>`).
pub fn parse_mysql_row(mut fields_text: &str) -> Vec<(String, Option<String>)> {
    let mut row = vec![];
    while let Some(f) = fields_text.find("<field name=\"") {
        let tail = &fields_text[f + 13..];
        let name_end = tail.find('"').unwrap_or(0);
        let name = unescape_xml(&tail[..name_end]);
        let tag_tail = &tail[name_end..];
        let close = tag_tail.find('>').unwrap_or(0);
        let value = if tag_tail[..close].ends_with('/') {
            fields_text = &tag_tail[close + 1..];
            None
        } else {
            let content = &tag_tail[close + 1..];
            let end = content.find("</field>").unwrap_or(content.len());
            fields_text = &content[(end + 8).min(content.len())..];
            Some(unescape_xml(&content[..end]))
        };
        row.push((name, value));
    }
    row
}

/// The result sets of `mysql --xml`, in order. Only the tags that client writes are understood:
/// `<resultset>`, `<row>` and `<field name="…">value</field>` or `<field name="…" xsi:nil="true" />`.
/// Rows beyond `max_rows` are counted out, not kept.
pub fn parse_mysql_xml(text: &str, max_rows: usize) -> Vec<ResultSet> {
    let mut sets = vec![];
    let mut rest = text;
    while let Some(start) = rest.find("<resultset") {
        rest = &rest[start..];
        let body_end = rest.find("</resultset>").unwrap_or(rest.len());
        let open_end = rest.find('>').unwrap_or(0);
        let open = &rest[..open_end];
        let statement = open
            .split_once("statement=\"")
            .map(|(_, s)| {
                unescape_xml(
                    s.rsplit_once("\" xmlns")
                        .map(|(a, _)| a)
                        .unwrap_or(s)
                        .trim(),
                )
            })
            .unwrap_or_default();
        let empty_set = open.ends_with('/');
        let mut set = ResultSet {
            statement,
            ..Default::default()
        };
        let body = if empty_set {
            ""
        } else {
            &rest[open_end.min(body_end)..body_end]
        };
        let mut rows_text = body;
        let mut first = true;
        let mut count = 0usize;
        while let Some(row_start) = rows_text.find("<row>") {
            let after = &rows_text[row_start + 5..];
            let row_end = after.find("</row>").unwrap_or(after.len());
            let mut row = vec![];
            for (name, value) in parse_mysql_row(&after[..row_end]) {
                if first {
                    set.columns.push(name);
                }
                row.push(value);
            }
            first = false;
            count += 1;
            if count <= max_rows {
                set.rows.push(row);
            } else {
                set.truncated = true;
            }
            rows_text = &after[(row_end + 6).min(after.len())..];
        }
        sets.push(set);
        rest = &rest[(body_end + 12).min(rest.len())..];
    }
    sets
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_outside_strings_comments_and_dollar_quotes() {
        let sql = "select 'a;b'; -- c;d\nselect \"x;y\" /* ; */ ; select 1";
        assert_eq!(
            split(sql, Dialect::MySql),
            vec!["select 'a;b'", "-- c;d\nselect \"x;y\" /* ; */", "select 1"]
        );
        let pg = "create function f() returns int as $$ begin return 1; end $$ language plpgsql; select $tag$;$tag$;";
        assert_eq!(split(pg, Dialect::Postgres).len(), 2);
        assert_eq!(
            split("select 'it''s;'; ", Dialect::Postgres),
            vec!["select 'it''s;'"]
        );
        assert_eq!(split("select 'a\\';b'; select 2", Dialect::MySql).len(), 2);
        assert!(split("  -- only a comment\n ; ", Dialect::MySql).is_empty());
        assert_eq!(split("select $1, 2; select 3", Dialect::Postgres).len(), 2);
    }

    #[test]
    fn only_harmless_statements_are_read_only() {
        let m = Dialect::MySql;
        for sql in [
            "SELECT * FROM t",
            "show tables",
            "explain select 1",
            "with x as (select 1) select * from x",
            "select 'drop table'",
            "-- delete\nselect 1",
            "DESCRIBE t",
        ] {
            assert!(is_read_only(sql, m), "{sql}");
        }
        for sql in [
            "update t set a=1",
            "select * from t for update",
            "select * into outfile '/tmp/x' from t",
            "drop database x",
            "with d as (delete from t returning *) select * from d",
            "set global x=1",
            "select sleep(10)",
            "call p()",
            "kill 3",
            "/* select */ delete from t",
            "select nextval('s')",
            "explain analyze delete from t",
        ] {
            assert!(
                !is_read_only(
                    sql,
                    if sql.contains("nextval") || sql.contains("returning") {
                        Dialect::Postgres
                    } else {
                        m
                    }
                ),
                "{sql}"
            );
        }
        assert!(!is_read_only("pragma journal_mode = wal", Dialect::Sqlite));
        assert!(is_read_only("pragma table_info(t)", Dialect::Sqlite));
    }

    #[test]
    fn client_directives_are_never_read_only() {
        let (m, p, s) = (Dialect::MySql, Dialect::Postgres, Dialect::Sqlite);
        for (sql, d) in [
            ("SELECT 1 \\! touch /tmp/x", p),
            ("select 1 \\gexec", p),
            ("select 1 \\o |cat", p),
            ("select 1 \\copy t to 'x'", p),
            ("select E'\\'' \\! id", p),
            ("explain select 1 \\! id", p),
            ("SELECT 1 \\! id", m),
            ("system id", m),
            ("  source /tmp/x.sql", m),
            ("-- nota\nSOURCE /tmp/x.sql", m),
            ("select '$' \\! id", p),
            ("select $$ ' $$ \\! id", p),
            ("select 1 /*!50000 into outfile '/tmp/x' */", m),
            ("select 1 /*M!100100 truncate t */", m),
            ("select 1 --\\! id", m),
            ("select 1\n.shell id", s),
            ("select 1\n  .import f t", s),
        ] {
            assert!(!is_read_only(sql, d), "{sql}");
            assert!(has_client_directive(sql, d), "{sql}");
        }
        assert!(is_read_only("select 1 -- a note", m));
        assert!(is_read_only("select systems from t\nwhere go_id = 1", m));
        // Data, not commands: backslashes inside literals and a column named like a command.
        assert!(is_read_only("select * from t where name ~ '\\d+'", p));
        assert!(is_read_only("select * from t where name like 'a\\_b'", m));
        assert!(is_read_only("select 'it\\'s' from t", m));
        assert!(is_read_only("select id,\n  source,\n  name from t", m));
        assert!(is_read_only("select 1.5 from t", s));
    }

    #[test]
    fn mysql_double_dash_needs_a_space_to_be_a_comment() {
        let m = Dialect::MySql;
        // `--1` is arithmetic: the `;` after it ends the statement and the next one is separate.
        let parts = split("select 1--1; delete from t", m);
        assert_eq!(parts.len(), 2);
        assert!(!is_read_only(&parts[1], m));
        assert_eq!(split("select 1-- c; x\n; select 2", m).len(), 2);
        assert_eq!(split("select 1--1; select 2", Dialect::Postgres).len(), 1);
    }

    #[test]
    fn statements_with_passwords_are_recognized() {
        for secret in [
            "CREATE USER x IDENTIFIED BY 'y'",
            "alter role r with encrypted password 'p'",
            "SET PASSWORD = 'n'",
            "-- nota\nGRANT ALL ON *.* TO x IDENTIFIED BY 'p'",
            "auth s3creta",
            "HELLO 3 AUTH default p",
        ] {
            assert!(has_secret(secret), "{secret}");
        }
        for plain in [
            "select * from users where password is null",
            "SELECT 'identified' AS x",
            "create table t (password_hash text)",
            "create table users (id int, password text)",
            "alter table users add column password text",
            "update accounts set password = 'x'",
        ] {
            assert!(!has_secret(plain), "{plain}");
        }
    }

    #[test]
    fn quoting_never_lets_values_escape() {
        assert_eq!(ident(Dialect::MySql, "a`b"), "`a``b`");
        assert_eq!(ident(Dialect::Postgres, "a\"b"), "\"a\"\"b\"");
        assert_eq!(literal(Dialect::MySql, "a'"), "_utf8mb4 X'6127'");
        assert_eq!(literal(Dialect::MySql, ""), "''");
        assert_eq!(literal(Dialect::Sqlite, "it's"), "'it''s'");
        let tricky = "x $b$ y $b1$ z $";
        let quoted = literal(Dialect::Postgres, tricky);
        let tag = &quoted[..quoted.find('x').unwrap()];
        assert!(!tricky.contains(tag) && quoted.ends_with(tag));
        assert_eq!(literal(Dialect::Postgres, "plain"), "$b$plain$b$");
    }

    #[test]
    fn csv_keeps_quoted_empties_apart_from_missing_values() {
        let rows = parse_csv("id,name\n1,\"a,b\"\"c\"\n2,\n3,\"\"\n4,\"l1\nl2\"\n");
        assert_eq!(rows.len(), 5);
        assert_eq!(rows[1][1], ("a,b\"c".into(), true));
        assert_eq!(rows[2][1], (String::new(), false));
        assert_eq!(rows[3][1], (String::new(), true));
        assert_eq!(rows[4][1].0, "l1\nl2");
    }

    #[test]
    fn mysql_xml_keeps_nulls_entities_and_duplicate_columns() {
        let xml = "<?xml version=\"1.0\"?>\n\n<resultset statement=\"select * from t\n\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\n  <row>\n\t<field name=\"id\">1</field>\n\t<field name=\"note\" xsi:nil=\"true\" />\n  </row>\n\n  <row>\n\t<field name=\"id\">2</field>\n\t<field name=\"note\">&lt;x&amp;y&gt;\nz</field>\n  </row>\n</resultset>\n<?xml version=\"1.0\"?>\n<resultset statement=\"select 1 as a, 1 as a\" xmlns:xsi=\"x\">\n  <row>\n\t<field name=\"a\">1</field>\n\t<field name=\"a\">1</field>\n  </row>\n</resultset>\n";
        let sets = parse_mysql_xml(xml, 1);
        assert_eq!(sets.len(), 2);
        assert_eq!(sets[0].columns, vec!["id", "note"]);
        assert_eq!(sets[0].rows, vec![vec![Some("1".into()), None]]);
        assert!(sets[0].truncated);
        assert_eq!(sets[0].statement, "select * from t");
        let all = parse_mysql_xml(xml, 10);
        assert_eq!(all[0].rows[1][1].as_deref(), Some("<x&y>\nz"));
        assert_eq!(all[1].columns, vec!["a", "a"]);
    }
}
