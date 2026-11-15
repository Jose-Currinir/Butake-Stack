//! The `.env` a project's processes start with: whether Stack wrote it and, only then, its values (the engine's only reader of a `.env`'s values; see `AGENTS.md`).

use super::*;

/// The `.env` the site's processes start with: the one Stack wrote for its active environment,
/// unless the user turned «Pasar el entorno activo a los procesos» off.
pub fn process_env_file(store: &Store, project: &Project) -> Option<PathBuf> {
    let site = load(store, &project.id).ok()?;
    (site.pass_to_processes && site.active.is_some()).then(|| project.path.join(".env"))
}

/// Whether `path` is a regular file (never a link), at most 1 MiB, whose first line is the header
/// Stack writes. Reads that first line only: no value.
pub fn written_by_stack(path: &std::path::Path) -> bool {
    let Ok(meta) = fs::symlink_metadata(path) else {
        return false;
    };
    if !meta.is_file() || meta.len() > 1_048_576 {
        return false;
    }
    let mut first = String::new();
    let read = fs::File::open(path).map(|file| {
        std::io::BufRead::read_line(
            &mut std::io::BufReader::new(std::io::Read::take(file, 512)),
            &mut first,
        )
    });
    let first = first.trim_end_matches('\n');
    matches!(read, Ok(Ok(_))) && first.starts_with(HEADER_START) && first.ends_with(HEADER_END)
}

/// The variables of a `.env` Stack wrote (its first line says so), for a site's process. `None`
/// when the file is missing, a link, too large, or not Stack's. Dynamic-loader variables
/// (`DYLD_*`) never pass. Nothing here logs or returns an error with a value. The only reader of
/// values of a `.env` in the engine (see `AGENTS.md`).
pub fn read_stack_dotenv(path: &std::path::Path) -> Option<BTreeMap<String, String>> {
    if !written_by_stack(path) {
        return None;
    }
    let text = fs::read_to_string(path).ok()?;
    // The same text that is parsed carries the header (the file may have changed meanwhile).
    let first = text.lines().next()?;
    if text.len() > 1_048_576 || !(first.starts_with(HEADER_START) && first.ends_with(HEADER_END)) {
        return None;
    }
    let mut out = parse_dotenv(&text);
    out.retain(|key, _| !key.starts_with("DYLD_"));
    Some(out)
}

/// Reads `.env` lines as [`line`] writes them (and as dotenv reads them): bare values (a ` #`
/// starts a comment), single quotes literal, double quotes with `\\`, `\"` and `\$` escapes and
/// `${KEY}` taken from a key defined above.
pub(super) fn parse_dotenv(text: &str) -> BTreeMap<String, String> {
    let mut out: BTreeMap<String, String> = BTreeMap::new();
    for raw in text.lines() {
        let line = raw.trim().trim_start_matches("export ").trim();
        if line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let key = key.trim();
        if validate_key(key).is_err() {
            continue;
        }
        let value = value.trim();
        let value = if let Some(inner) = value.strip_prefix('"').and_then(|v| v.strip_suffix('"')) {
            let mut text = String::new();
            let mut chars = inner.chars().peekable();
            while let Some(c) = chars.next() {
                match c {
                    '\\' => text.push(chars.next().unwrap_or('\\')),
                    '$' if chars.peek() == Some(&'{') => {
                        chars.next();
                        let name: String = chars.by_ref().take_while(|c| *c != '}').collect();
                        match out.get(&name) {
                            Some(value) => text.push_str(value),
                            None => text.push_str(&format!("${{{name}}}")),
                        }
                    }
                    c => text.push(c),
                }
            }
            text
        } else if let Some(inner) = value.strip_prefix('\'').and_then(|v| v.strip_suffix('\'')) {
            inner.to_string()
        } else {
            value.split(" #").next().unwrap_or("").trim().to_string()
        };
        out.insert(key.to_string(), value);
    }
    out
}
