//! Hides secret **values** in a line of a process's output and keeps the rest, so a line that only
//! names variables (a server listing its disabled modules, a missing `API_KEY`) still helps to
//! diagnose. What is hidden is replaced by [`MASK`]. When in doubt, the value is hidden.
//!
//! Hidden (see `docs/operations.md`, «Registros»):
//! - the value of an assignment to a sensitive name: `NAME=value`, `name: value`,
//!   `"name": "value"`, `'name' => 'value'`, `--name=value` and `--name value`, cookie and
//!   `Authorization`/`X-…-Key` headers included (the value runs to the end of the line unless
//!   another `name=` or `name:` follows);
//! - the password of a URL with credentials (`scheme://user:password@host`), and the whole user
//!   part of an `http(s)` one (`https://TOKEN@host`);
//! - JSON Web Tokens and keys with a known prefix (`sk_live_`, `ghp_`, `AKIA`…), anywhere;
//! - a random-looking word right after a sensitive name (`token 9f8e…`);
//! - every line of a PEM private key block (with [`Redactor`]).
//!
//! A name is sensitive when it contains PASSWORD, PASSWD, PWD, PASS, SECRET, TOKEN, AUTH,
//! CREDENTIAL, PRIVATE, COOKIE, SESSION, SIGNATURE, SALT, DSN or ends in KEY (`_` and `-` alike).

pub const MASK: &str = "[oculto]";

/// Words that make a name sensitive (upper case, `-` read as `_`).
const SENSITIVE: &[&str] = &[
    "PASSWORD",
    "PASSWD",
    "PWD",
    "PASS",
    "SECRET",
    "TOKEN",
    "AUTH",
    "CREDENTIAL",
    "PRIVATE",
    "COOKIE",
    "SESSION",
    "SIGNATURE",
    "SALT",
    "DSN",
];

/// Prefixes of well-known secret keys (cloud, payment, source hosting, chat, mail providers).
const KNOWN_PREFIXES: &[&str] = &[
    "sk_live_",
    "sk_test_",
    "rk_live_",
    "rk_test_",
    "pk_live_",
    "whsec_",
    "sk-ant-",
    "sk-proj-",
    "sk-",
    "ghp_",
    "gho_",
    "ghs_",
    "ghu_",
    "ghr_",
    "github_pat_",
    "glpat-",
    "xoxb-",
    "xoxp-",
    "xoxa-",
    "xoxs-",
    "AKIA",
    "ASIA",
    "AIza",
    "ya29.",
    "SG.",
    "re_",
    "shpat_",
    "npm_",
    "hf_",
    "dop_v1_",
    "sq0csp-",
];

pub fn sensitive_name(name: &str) -> bool {
    let name = name
        .trim_start_matches('-')
        .to_ascii_uppercase()
        .replace('-', "_");
    !name.is_empty()
        && (SENSITIVE.iter().any(|word| name.contains(word))
            || name.ends_with("KEY")
            || name.ends_with("KEYS"))
}

fn word_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.' | '+' | '/' | '~')
}

/// A key with a known prefix and, after it, enough characters with a digit among them to be one
/// (so an identifier like `re_render_component` is not taken for a key).
fn known_secret(word: &str) -> bool {
    KNOWN_PREFIXES.iter().any(|prefix| {
        word.strip_prefix(prefix)
            .is_some_and(|rest| rest.len() >= 12 && rest.chars().any(|c| c.is_ascii_digit()))
    })
}

/// Headers whose whole value is a credential, whatever it looks like.
fn credential_header(name: &str) -> bool {
    [
        "cookie",
        "set-cookie",
        "authorization",
        "proxy-authorization",
    ]
    .contains(&name.to_ascii_lowercase().as_str())
}

/// `header.payload.signature`, each part base64url, the first two starting with `eyJ` (`{"`).
fn jwt(word: &str) -> bool {
    let parts: Vec<&str> = word.split('.').collect();
    parts.len() == 3
        && parts[0].starts_with("eyJ")
        && parts[1].starts_with("eyJ")
        && parts[..2].iter().all(|p| p.len() >= 8)
}

/// Long, mixes letters and digits, and is not written like a variable name (`MY_TOKEN_V2`).
fn looks_random(word: &str) -> bool {
    word.len() >= 16
        && word.chars().any(|c| c.is_ascii_digit())
        && word.chars().any(|c| c.is_ascii_alphabetic())
        && !word
            .chars()
            .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_')
}

/// Where an assignment's value starts after a name that ends at `at`: optional closing quote,
/// spaces, `=`, `:` or `=>`, spaces. `None` when what follows is not an assignment (`::`, `://`).
fn assignment(chars: &[char], at: usize, quote: Option<char>) -> Option<usize> {
    let mut i = at;
    if quote.is_some() && chars.get(i).copied() == quote {
        i += 1;
    }
    while chars.get(i) == Some(&' ') {
        i += 1;
    }
    match chars.get(i) {
        Some('=') if chars.get(i + 1) == Some(&'>') => i += 2,
        Some('=') if chars.get(i + 1) != Some(&'=') => i += 1,
        Some(':') if !matches!(chars.get(i + 1), Some(':') | Some('/')) => i += 1,
        _ => return None,
    }
    while chars.get(i) == Some(&' ') || chars.get(i) == Some(&'\t') {
        i += 1;
    }
    Some(i)
}

/// Whether `chars[i..]` starts with another assignment (`name=`, `name:`, `"name":`).
fn next_assignment(chars: &[char], mut i: usize) -> bool {
    while matches!(chars.get(i), Some(' ' | '\t' | ',' | ';' | '&')) {
        i += 1;
    }
    let quote = chars.get(i).copied().filter(|c| *c == '"' || *c == '\'');
    if quote.is_some() {
        i += 1;
    }
    let start = i;
    while chars.get(i).is_some_and(|c| word_char(*c)) {
        i += 1;
    }
    i > start && assignment(chars, i, quote).is_some()
}

/// Where an unquoted value ends: the end of the line, or a separator followed by another
/// assignment. Everything up to there is hidden.
fn value_end(chars: &[char], start: usize) -> usize {
    let mut i = start;
    while i < chars.len() {
        if matches!(chars[i], ' ' | '\t' | ',' | ';' | '&') && next_assignment(chars, i) {
            return i;
        }
        i += 1;
    }
    chars.len()
}

/// Where a quoted value ends (its closing quote, `\` escapes), or the end of the line.
fn quoted_end(chars: &[char], start: usize, quote: char) -> usize {
    let mut i = start;
    while i < chars.len() {
        match chars[i] {
            '\\' => i += 2,
            c if c == quote => return i,
            _ => i += 1,
        }
    }
    chars.len()
}

/// The line with every secret value replaced by [`MASK`].
pub fn redact(line: &str) -> String {
    let chars: Vec<char> = line.chars().collect();
    let mut out = String::with_capacity(line.len());
    let mut i = 0;
    // A sensitive name without `=` or `:` just before: the next word, if it looks random (or the
    // name was a `--flag`), is its value.
    let mut after_name: Option<bool> = None;
    while i < chars.len() {
        let c = chars[i];
        // scheme://user:password@host
        if c == ':' && chars.get(i + 1) == Some(&'/') && chars.get(i + 2) == Some(&'/') {
            // The scheme just written: for the web ones, the user part is a token as often as
            // a name (`https://TOKEN@host`), so all of it goes.
            let web = out
                .rsplit(|c: char| !c.is_ascii_alphabetic())
                .next()
                .is_some_and(|scheme| {
                    scheme.eq_ignore_ascii_case("http") || scheme.eq_ignore_ascii_case("https")
                });
            out.push_str("://");
            i += 3;
            let mut j = i;
            while j < chars.len() && !matches!(chars[j], '/' | ' ' | '\t' | '"' | '\'' | '@') {
                j += 1;
            }
            if chars.get(j) == Some(&'@') {
                if web && j > i {
                    out.push_str(MASK);
                    i = j;
                } else if let Some(colon) = (i..j).find(|k| chars[*k] == ':') {
                    out.extend(&chars[i..=colon]);
                    out.push_str(MASK);
                    i = j;
                }
            }
            continue;
        }
        if !word_char(c) {
            out.push(c);
            i += 1;
            if !c.is_whitespace() {
                after_name = None;
            }
            continue;
        }
        let start = i;
        while i < chars.len() && word_char(chars[i]) {
            i += 1;
        }
        let word: String = chars[start..i].iter().collect();
        let pending = after_name.take();
        if known_secret(&word)
            || jwt(&word)
            || pending.is_some_and(|flag| flag || looks_random(&word))
        {
            out.push_str(MASK);
            continue;
        }
        out.push_str(&word);
        if !sensitive_name(&word) {
            continue;
        }
        let quote = start
            .checked_sub(1)
            .map(|p| chars[p])
            .filter(|c| *c == '"' || *c == '\'');
        let Some(value) = assignment(&chars, i, quote) else {
            after_name = Some(word.starts_with('-'));
            continue;
        };
        if value >= chars.len() {
            continue;
        }
        out.extend(&chars[i..value]);
        let (end, closing) = match chars[value] {
            q @ ('"' | '\'') => (quoted_end(&chars, value + 1, q), Some(q)),
            _ if credential_header(&word) => (chars.len(), None),
            _ => (value_end(&chars, value), None),
        };
        match closing {
            Some(q) => {
                out.push(q);
                if end > value + 1 {
                    out.push_str(MASK);
                }
                i = end;
            }
            None => {
                out.push_str(MASK);
                i = end;
            }
        }
    }
    out
}

/// Redacts line after line, hiding whole PEM private key blocks (their lines carry no names).
#[derive(Default)]
pub struct Redactor {
    in_private_key: bool,
}

impl Redactor {
    pub fn line(&mut self, line: &str) -> String {
        let upper = line.to_ascii_uppercase();
        if upper.contains("-----BEGIN") && upper.contains("PRIVATE KEY") {
            self.in_private_key = !upper.contains("-----END");
            return MASK.into();
        }
        if self.in_private_key {
            if upper.contains("-----END") {
                self.in_private_key = false;
            }
            return MASK.into();
        }
        redact(line)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SENTINELS: &[&str] = &[
        "centinela-uno-3141",
        "Centinela2Dos$x",
        "c3nt1n3l4tr3s",
        "centinela cuatro con espacios",
        "s3cr3t-c1nc0",
    ];

    /// Every sentinel disappears, whatever the shape of the line; what is not a value stays.
    #[test]
    fn values_are_hidden_and_the_rest_of_the_line_stays() {
        let [one, two, three, four, five] = SENTINELS else {
            unreachable!()
        };
        let cases = [
            (
                format!("DB_PASSWORD={one}"),
                "DB_PASSWORD=[oculto]".to_string(),
            ),
            (
                format!("export API_KEY=\"{two}\""),
                "export API_KEY=\"[oculto]\"".into(),
            ),
            (format!("password: {four}"), "password: [oculto]".into()),
            (
                format!("{{\"user\":\"ana\",\"password\":\"{two}\",\"port\":5432}}"),
                "{\"user\":\"ana\",\"password\":\"[oculto]\",\"port\":5432}".into(),
            ),
            (
                format!("'secret' => '{three}',"),
                "'secret' => '[oculto]',".into(),
            ),
            (
                format!("Authorization: Bearer {one}"),
                "Authorization: [oculto]".into(),
            ),
            (format!("X-Api-Key: {three}"), "X-Api-Key: [oculto]".into()),
            (
                format!("Cookie: session={five}; theme=dark"),
                "Cookie: [oculto]".into(),
            ),
            (
                format!("session={five}; theme=dark"),
                "session=[oculto]; theme=dark".into(),
            ),
            (
                format!("connecting to postgres://app:{two}@127.0.0.1:5432/app"),
                "connecting to postgres://app:[oculto]@127.0.0.1:5432/app".into(),
            ),
            // A token used as the user of a web address (no prefix to recognise, or Bitbucket's).
            (
                "fatal: unable to access 'https://ATATT3xFfGF0abcDEF123456789@bitbucket.org/ws/r.git/': 403".into(),
                "fatal: unable to access 'https://[oculto]@bitbucket.org/ws/r.git/': 403".into(),
            ),
            (
                "origin\thttps://abcdef0123456789abcdef@github.com/a/b.git (fetch)".into(),
                "origin\thttps://[oculto]@github.com/a/b.git (fetch)".into(),
            ),
            (
                "origin\thttps://abcdef:x-oauth-basic@github.com/a/b.git (push)".into(),
                "origin\thttps://[oculto]@github.com/a/b.git (push)".into(),
            ),
            // Not a web address: the user of an SSH one is a name.
            (
                "ssh://git@github.com/a/b.git".into(),
                "ssh://git@github.com/a/b.git".into(),
            ),
            (
                format!("GET /cb?code=1&access_token={one}&state=ok"),
                "GET /cb?code=1&access_token=[oculto]&state=ok".into(),
            ),
            (
                format!("run --password {three} --verbose"),
                "run --password [oculto] --verbose".into(),
            ),
            (
                format!("DB_PASSWORD={one} DB_HOST=127.0.0.1"),
                "DB_PASSWORD=[oculto] DB_HOST=127.0.0.1".into(),
            ),
            (
                format!("loaded token {}", "9f8e7d6c5b4a39281706f5e4d3c2b1a0"),
                "loaded token [oculto]".into(),
            ),
        ];
        for (line, expected) in &cases {
            let safe = redact(line);
            assert_eq!(&safe, expected, "{line}");
            for sentinel in SENTINELS {
                assert!(!safe.contains(sentinel), "{sentinel} in {safe}");
            }
        }
        // Keys and tokens with a known shape, anywhere in the line.
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJjZW50aW5lbGEifQ.c2lnbmF0dXJh";
        for secret in [
            "sk_live_51Hc3nt1n3l4XYZ",
            "ghp_c3nt1n3l4c3nt1n3l4c3nt1n3l4",
            "AKIAC3NT1N3L4EXAMPLE",
            "xoxb-1234-c3nt1n3l4-abcdef",
            jwt,
        ] {
            let safe = redact(&format!("request failed with {secret} (retry)"));
            assert_eq!(safe, "request failed with [oculto] (retry)", "{secret}");
        }
    }

    /// Lines that only name variables keep every character.
    #[test]
    fn names_alone_are_kept() {
        for line in [
            "Disabled modules: TOKEN_SERVICE, SECRET_SCANNER, API_KEY_ROTATION",
            "Missing environment variables: API_KEY, DB_PASSWORD, JWT_SECRET",
            "Using SESSION_DRIVER from .env",
            "the token expired, asking for a new one",
            "API_KEY=",
            "password reset mail queued for user 42",
            "Listening on http://127.0.0.1:8080",
            "SELECT id FROM accounts WHERE password_hash IS NULL",
            "std::env::var(\"API_KEY\") failed",
        ] {
            assert_eq!(redact(line), line);
        }
    }

    #[test]
    fn private_key_blocks_are_hidden_whole() {
        let mut redactor = Redactor::default();
        let lines = [
            "loading key",
            "-----BEGIN OPENSSH PRIVATE KEY-----",
            "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQ",
            "-----END OPENSSH PRIVATE KEY-----",
            "ready",
        ];
        let out: Vec<String> = lines.iter().map(|l| redactor.line(l)).collect();
        assert_eq!(
            out,
            ["loading key", MASK, MASK, MASK, "ready"].map(String::from)
        );
    }
}
