//! SKILL.md and the folder of a skill: reading without following links, the frontmatter, copies.
use super::model::{MAX_TEXT, fail};
use crate::core::fsutil;
use anyhow::Result;
use std::{
    fs,
    io::Read,
    os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
    path::Path,
};

#[derive(Debug, Default, Clone, PartialEq)]
pub struct Meta {
    pub name: String,
    pub description: String,
}

pub fn real_dir(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|m| m.is_dir())
}

/// SKILL.md of a skill folder: a regular file (never a link), at most [`MAX_TEXT`] bytes.
pub fn read_text(dir: &Path) -> Result<String> {
    if !real_dir(dir) {
        return fail("skills_not_found");
    }
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(dir.join("SKILL.md"))
        .map_err(|_| anyhow::anyhow!("skills_not_found"))?;
    let meta = file.metadata()?;
    if !meta.is_file() {
        return fail("skills_not_found");
    }
    if meta.len() > MAX_TEXT {
        return fail("skills_too_large");
    }
    let mut bytes = Vec::new();
    file.take(MAX_TEXT + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_TEXT {
        return fail("skills_too_large");
    }
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

pub fn write_text(dir: &Path, text: &str) -> Result<()> {
    if text.len() as u64 > MAX_TEXT {
        return fail("skills_too_large");
    }
    let target = dir.join("SKILL.md");
    if fs::symlink_metadata(&target).is_ok_and(|m| m.file_type().is_symlink()) {
        return fail("unsafe_store_path");
    }
    fsutil::write_private(&target, text)
}

pub fn modified(dir: &Path) -> u64 {
    fs::symlink_metadata(dir.join("SKILL.md"))
        .map(|m| m.mtime().max(0) as u64)
        .unwrap_or(0)
}

/// Splits the frontmatter (between the first two `---` lines) from the rest. Without a closed
/// frontmatter, everything is the rest.
pub fn split(text: &str) -> (Option<&str>, &str) {
    let mut lines = text.split_inclusive('\n');
    let mut offset = match lines.next() {
        Some(first) if first.trim_end() == "---" => first.len(),
        _ => return (None, text),
    };
    let start = offset;
    for line in lines {
        if line.trim_end() == "---" {
            return (Some(&text[start..offset]), &text[offset + line.len()..]);
        }
        offset += line.len();
    }
    (None, text)
}

fn unquote(raw: &str) -> String {
    let raw = raw.trim();
    if raw.len() >= 2 && raw.starts_with('"') && raw.ends_with('"') {
        let mut out = String::new();
        let mut chars = raw[1..raw.len() - 1].chars();
        while let Some(c) = chars.next() {
            if c == '\\' {
                match chars.next() {
                    Some('n') => out.push(' '),
                    Some(other) => out.push(other),
                    None => {}
                }
            } else {
                out.push(c);
            }
        }
        out
    } else if raw.len() >= 2 && raw.starts_with('\'') && raw.ends_with('\'') {
        raw[1..raw.len() - 1].replace("''", "'")
    } else {
        raw.to_string()
    }
}

/// `name` and `description` of the frontmatter (single line, quoted, or folded over indented lines).
pub fn parse(text: &str) -> Meta {
    let mut meta = Meta::default();
    let Some(front) = split(text).0 else {
        return meta;
    };
    let mut current: Option<(String, String)> = None;
    let mut done: Vec<(String, String)> = vec![];
    for line in front.lines() {
        if line.starts_with([' ', '\t']) {
            if let Some((_, value)) = current.as_mut() {
                if !value.is_empty() {
                    value.push(' ');
                }
                value.push_str(line.trim());
            }
        } else if let Some((key, value)) = line.split_once(':') {
            done.extend(current.take());
            let value = value.trim();
            let value = if matches!(value, ">" | "|" | ">-" | "|-" | ">+" | "|+") {
                ""
            } else {
                value
            };
            current = Some((key.trim().to_string(), value.to_string()));
        }
    }
    done.extend(current);
    for (key, value) in done {
        match key.as_str() {
            "name" => meta.name = unquote(&value),
            "description" => meta.description = unquote(&value),
            _ => {}
        }
    }
    meta
}

/// Plain text that YAML reads as something else: a boolean, null, a number or date, or a tag,
/// block or key indicator (`!x`, `- x`, `? x`).
fn yaml_reads_differently(value: &str) -> bool {
    let lower = value.to_lowercase();
    if matches!(
        lower.as_str(),
        "true" | "false" | "null" | "~" | "yes" | "no" | "on" | "off" | "y" | "n"
    ) {
        return true;
    }
    if value.starts_with('!')
        || matches!(value, "-" | "?")
        || value.starts_with("- ")
        || value.starts_with("? ")
    {
        return true;
    }
    let body = value.trim_start_matches(['+', '-']);
    let digits = |text: &str, radix: u32| {
        !text.is_empty() && text.chars().all(|c| c.is_digit(radix) || c == '_')
    };
    let based = ["0x", "0o", "0b"]
        .iter()
        .zip([16, 8, 2])
        .any(|(prefix, radix)| {
            lower
                .trim_start_matches(['+', '-'])
                .strip_prefix(prefix)
                .is_some_and(|rest| digits(rest, radix))
        });
    let number = body.starts_with(|c: char| c.is_ascii_digit() || c == '.')
        && (body.replace('_', "").parse::<f64>().is_ok()
            || matches!(body.to_lowercase().as_str(), ".inf" | ".nan"));
    // 2024-01-31: a date.
    let date = body.contains('-')
        && body.chars().all(|c| c.is_ascii_digit() || c == '-')
        && body.starts_with(|c: char| c.is_ascii_digit());
    based || number || date
}

/// A value for a frontmatter line: plain when safe, otherwise double-quoted.
pub fn quote(value: &str) -> String {
    let value: String = value
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    let plain = !value.is_empty()
        && !yaml_reads_differently(&value)
        && value.trim() == value
        && value
            .chars()
            .all(|c| c.is_alphanumeric() || " _.,/()+-¿?¡!".contains(c));
    if plain {
        value
    } else {
        format!("\"{}\"", value.replace('\\', "\\\\").replace('"', "\\\""))
    }
}

/// Replaces the `name` of the frontmatter when it is `old`.
pub fn rename_in_text(text: &str, old: &str, new: &str) -> String {
    let (Some(front), rest) = split(text) else {
        return text.to_string();
    };
    if parse(text).name != old {
        return text.to_string();
    }
    let front: String = front
        .split_inclusive('\n')
        .map(|line| {
            if line.starts_with("name:") {
                format!("name: {}\n", quote(new))
            } else {
                line.to_string()
            }
        })
        .collect();
    format!("---\n{front}---\n{rest}")
}

/// Relative names of the support files (everything but the top SKILL.md); links are listed by
/// name only and never followed.
pub fn files(dir: &Path) -> Vec<String> {
    fn walk(base: &Path, dir: &Path, depth: usize, out: &mut Vec<String>) {
        let Ok(read) = fs::read_dir(dir) else { return };
        let mut items: Vec<_> = read.flatten().collect();
        items.sort_by_key(|i| i.file_name());
        for item in items {
            if out.len() >= 200 {
                return;
            }
            let path = item.path();
            let Ok(kind) = item.file_type() else { continue };
            let rel = path
                .strip_prefix(base)
                .map(|p| p.to_string_lossy().to_string())
                .unwrap_or_default();
            if kind.is_dir() {
                if depth < 4 {
                    walk(base, &path, depth + 1, out);
                }
            } else if rel != "SKILL.md" {
                out.push(rel);
            }
        }
    }
    let mut out = vec![];
    walk(dir, dir, 0, &mut out);
    out
}

/// Copies a skill folder without following links (they are skipped), within fixed limits. Answers
/// the relative paths it left out (links and special files; sorted, at most 200).
pub fn copy_tree(from: &Path, to: &Path) -> Result<Vec<String>> {
    fn go(
        base: &Path,
        from: &Path,
        to: &Path,
        depth: usize,
        files: &mut usize,
        bytes: &mut u64,
        skipped: &mut Vec<String>,
    ) -> Result<()> {
        if depth > 6 {
            return fail("skills_too_large");
        }
        fs::create_dir(to)?;
        fs::set_permissions(to, fs::Permissions::from_mode(0o700))?;
        for item in fs::read_dir(from)?.flatten() {
            let kind = item.file_type()?;
            let target = to.join(item.file_name());
            if kind.is_dir() {
                go(
                    base,
                    &item.path(),
                    &target,
                    depth + 1,
                    files,
                    bytes,
                    skipped,
                )?;
            } else if kind.is_file() {
                *files += 1;
                *bytes += item.metadata()?.len();
                if *files > 500 || *bytes > 10 * 1024 * 1024 {
                    return fail("skills_too_large");
                }
                fs::copy(item.path(), &target)?;
                let mode = item.metadata()?.permissions().mode() & 0o700;
                fs::set_permissions(&target, fs::Permissions::from_mode(mode | 0o600))?;
            } else if skipped.len() < 200 {
                let path = item.path();
                let rel = path.strip_prefix(base).unwrap_or(&path);
                skipped.push(rel.to_string_lossy().to_string());
            }
        }
        Ok(())
    }
    let mut skipped = vec![];
    go(from, from, to, 0, &mut 0, &mut 0, &mut skipped)?;
    skipped.sort();
    Ok(skipped)
}
