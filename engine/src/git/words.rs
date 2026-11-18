//! Arguments typed in the console, split the way a POSIX shell splits words (quotes and
//! backslashes) but never expanded: no variables, globs, substitutions or comments. The result is
//! passed to Git as separate arguments; `join` writes them back for the preview.

/// Splits `text` into words; `None` when a quote is not closed or a backslash ends the text.
pub fn split(text: &str) -> Option<Vec<String>> {
    let mut words = Vec::new();
    let mut word = String::new();
    let mut in_word = false;
    let mut chars = text.chars();
    while let Some(c) = chars.next() {
        match c {
            ' ' | '\t' | '\n' => {
                if in_word {
                    words.push(std::mem::take(&mut word));
                    in_word = false;
                }
            }
            '\\' => match chars.next()? {
                '\n' => {}
                next => {
                    word.push(next);
                    in_word = true;
                }
            },
            '\'' => {
                in_word = true;
                loop {
                    match chars.next()? {
                        '\'' => break,
                        other => word.push(other),
                    }
                }
            }
            '"' => {
                in_word = true;
                loop {
                    match chars.next()? {
                        '"' => break,
                        '\\' => match chars.next()? {
                            '\n' => {}
                            escaped @ ('$' | '`' | '"' | '\\') => word.push(escaped),
                            other => {
                                word.push('\\');
                                word.push(other);
                            }
                        },
                        other => word.push(other),
                    }
                }
            }
            other => {
                word.push(other);
                in_word = true;
            }
        }
    }
    if in_word {
        words.push(word);
    }
    Some(words)
}

/// `word` as a shell would need it: unchanged when it only has safe characters, else between
/// single quotes.
pub fn quote(word: &str) -> String {
    let safe = |c: char| c.is_ascii_alphanumeric() || "_-./=:@,+%^".contains(c);
    if !word.is_empty() && word.chars().all(safe) {
        word.to_string()
    } else {
        format!("'{}'", word.replace('\'', "'\\''"))
    }
}

pub fn join<S: AsRef<str>>(words: &[S]) -> String {
    words
        .iter()
        .map(|w| quote(w.as_ref()))
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_like_a_shell_without_expanding() {
        assert_eq!(
            split(r#"log --format="%h %s" 'a b' c\ d "$HOME" `x`"#).unwrap(),
            ["log", "--format=%h %s", "a b", "c d", "$HOME", "`x`"]
        );
        assert_eq!(
            split(r#""a\"b" "c\d" '' x"#).unwrap(),
            ["a\"b", "c\\d", "", "x"]
        );
        assert_eq!(split("  ").unwrap(), Vec::<String>::new());
        assert!(split("'broken").is_none());
        assert!(split("\"broken").is_none());
        assert!(split("end\\").is_none());
    }

    #[test]
    fn quotes_round_trip() {
        for word in [
            "plain",
            "a b",
            "it's",
            "",
            "$(rm -rf /)",
            "refs/heads/x:refs/heads/x",
        ] {
            assert_eq!(split(&quote(word)).unwrap(), [word]);
        }
        assert_eq!(join(&["git", "a b"]), "git 'a b'");
    }
}
