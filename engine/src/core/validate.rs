//! Validators shared by more than one module. Each returns a plain `bool`; callers decide the
//! error code that goes with it.

/// Printable text of at most `max` characters: no control characters (no newlines).
pub fn printable(text: &str, max: usize) -> bool {
    text.chars().count() <= max && !text.chars().any(char::is_control)
}

/// A stored id: lowercase letters, digits and dashes, 1 to `max` bytes.
pub fn id(id: &str, max: usize) -> bool {
    !id.is_empty()
        && id.len() <= max
        && id
            .bytes()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-')
}

/// A host name or address as `ssh` and the database clients take it: it can never look like an
/// option (no leading dash) and carries no shell or option separators.
pub fn host(host: &str) -> bool {
    !host.is_empty()
        && host.len() <= 253
        && !host.starts_with('-')
        && host
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'.' | b'-' | b':' | b'_'))
}

/// A login name for `ssh`: it can never look like an option.
pub fn user(user: &str) -> bool {
    !user.is_empty()
        && user.len() <= 64
        && !user.starts_with('-')
        && user
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'.' | b'-' | b'_'))
}

/// An account of Google Cloud's CLI as `--account=` takes it (a user's address or a service
/// account's): one `@`, no spaces, never looking like an option.
pub fn gcp_account(account: &str) -> bool {
    let Some((name, domain)) = account.split_once('@') else {
        return false;
    };
    account.len() <= 254
        && !name.is_empty()
        && !name.starts_with('-')
        && domain.contains('.')
        && !domain.contains('@')
        && !domain.starts_with('.')
        && !domain.ends_with('.')
        && account.bytes().all(|c| {
            c.is_ascii_alphanumeric() || matches!(c, b'.' | b'-' | b'_' | b'+' | b'@' | b'%')
        })
}

/// A Google Cloud project id: 6 to 30 lowercase letters, digits and dashes, starting with a
/// letter and not ending with a dash; the old ones may carry a domain (`example.com:name`).
pub fn gcp_project(project: &str) -> bool {
    let id = match project.rsplit_once(':') {
        Some((domain, id)) => {
            let domain_ok = !domain.is_empty()
                && domain.len() <= 253
                && domain.bytes().all(|c| {
                    c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, b'.' | b'-')
                });
            if !domain_ok {
                return false;
            }
            id
        }
        None => project,
    };
    (6..=30).contains(&id.len())
        && id.starts_with(|c: char| c.is_ascii_lowercase())
        && !id.ends_with('-')
        && id
            .bytes()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn printable_counts_characters_and_rejects_controls() {
        assert!(printable("Producción Ñuñoa", 16));
        assert!(!printable("Producción Ñuñoa", 15));
        assert!(!printable("a\nb", 10));
        assert!(printable("", 0));
    }

    #[test]
    fn ids_respect_their_own_limit() {
        assert!(id("prod-1", 40));
        assert!(id(&"a".repeat(40), 40) && !id(&"a".repeat(41), 40));
        assert!(id(&"a".repeat(48), 48) && !id(&"a".repeat(49), 48));
        for bad in ["", "Prod", "a_b", "a b", "../x", "ñ"] {
            assert!(!id(bad, 48), "{bad}");
        }
    }

    #[test]
    fn hosts_and_users_never_look_like_options() {
        assert!(host("db.example.com") && host("::1") && host("10.0.0.1") && host("my_host"));
        assert!(!host("-oProxyCommand=x") && !host("a b") && !host("") && !host("a;b"));
        assert!(!host(&"a".repeat(254)));
        assert!(user("deploy") && user("a.b-c_d"));
        assert!(!user("-x") && !user("a b") && !user("") && !user(&"a".repeat(65)));
    }

    #[test]
    fn google_accounts_and_projects_are_never_options() {
        for good in [
            "ana@ejemplo.cl",
            "qa.ficticia+dev@ejemplo.test",
            "despliegue@proyecto-ficticio.iam.gserviceaccount.com",
        ] {
            assert!(gcp_account(good), "{good}");
        }
        for bad in [
            "",
            "-x@ejemplo.cl",
            "ana",
            "ana@",
            "@ejemplo.cl",
            "ana@ejemplo",
            "a b@ejemplo.cl",
            "ana@ejemplo.cl;rm",
            "a@b@ejemplo.cl",
        ] {
            assert!(!gcp_account(bad), "{bad}");
        }
        for good in ["tienda-ficticia", "proyecto-qa-123", "ejemplo.cl:tienda-qa"] {
            assert!(gcp_project(good), "{good}");
        }
        for bad in [
            "",
            "corto",
            "Tienda-Qa",
            "1tienda",
            "tienda-",
            "--account=x",
            "tienda qa",
            ":tienda-qa",
            &"a".repeat(31),
        ] {
            assert!(!gcp_project(bad), "{bad}");
        }
    }
}
