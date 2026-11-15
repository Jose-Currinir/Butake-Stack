//! What a Node.js project asks for and whether a version gives it: `engines.node` of
//! `package.json` (npm's ranges: `>=22.12.0`, `^20 || ^22`, `24.x`, `20 - 22`) and `.nvmrc`
//! (`24`, `v24.13.0`). Only the forms projects write; anything else reads as «unknown» and never
//! raises a warning.

/// A version as three numbers (`24.22.3`, `v24` → 24.0.0).
fn parse(version: &str) -> Option<[u64; 3]> {
    let mut out = [0u64; 3];
    let parts: Vec<&str> = version.trim().trim_start_matches('v').split('.').collect();
    if parts.is_empty() || parts.len() > 3 {
        return None;
    }
    for (slot, part) in out.iter_mut().zip(&parts) {
        *slot = part.parse().ok()?;
    }
    Some(out)
}

/// A bound as written: its numbers (one to three; `x` and `*` end it) and how many were given.
fn partial(text: &str) -> Option<(Vec<u64>, usize)> {
    let text = text.trim().trim_start_matches('v');
    if text.is_empty() || text == "*" || text == "x" || text == "X" {
        return Some((vec![], 0));
    }
    let mut numbers = vec![];
    for part in text.split('.') {
        if matches!(part, "x" | "X" | "*") {
            break;
        }
        numbers.push(part.parse::<u64>().ok()?);
    }
    if numbers.len() > 3 || numbers.is_empty() {
        return None;
    }
    let given = numbers.len();
    Some((numbers, given))
}

fn filled(numbers: &[u64]) -> [u64; 3] {
    let mut out = [0; 3];
    for (slot, n) in out.iter_mut().zip(numbers) {
        *slot = *n;
    }
    out
}

/// The first version after every one a partial bound names (`24` → 25.0.0, `24.1` → 24.2.0).
fn next(numbers: &[u64]) -> [u64; 3] {
    let mut out = filled(numbers);
    match numbers.len() {
        1 => out = [out[0] + 1, 0, 0],
        2 => out = [out[0], out[1] + 1, 0],
        _ => out[2] += 1,
    }
    out
}

/// One comparator (`>=22.12.0`, `^20`, `24.x`, `~24.1`) against a version.
fn comparator(text: &str, version: [u64; 3]) -> Option<bool> {
    let ops = [">=", "<=", ">", "<", "=", "^", "~"];
    let op = ops.iter().find(|op| text.starts_with(**op)).copied();
    let (numbers, given) = partial(&text[op.map_or(0, str::len)..])?;
    if given == 0 {
        return Some(true);
    }
    let low = filled(&numbers);
    Some(match op.unwrap_or("=") {
        ">=" => version >= low,
        ">" => {
            if given == 3 {
                version > low
            } else {
                version >= next(&numbers)
            }
        }
        "<=" => {
            if given == 3 {
                version <= low
            } else {
                version < next(&numbers)
            }
        }
        "<" => version < low,
        "^" => {
            let upper = if numbers[0] > 0 || given == 1 {
                [numbers[0] + 1, 0, 0]
            } else {
                next(&numbers)
            };
            version >= low && version < upper
        }
        "~" => version >= low && version < next(&numbers[..given.min(2)]),
        _ => {
            if given == 3 {
                version == low
            } else {
                version >= low && version < next(&numbers)
            }
        }
    })
}

/// Whether `version` satisfies an `engines.node` range; `None` when the range is not understood.
pub fn satisfies(range: &str, version: &str) -> Option<bool> {
    let version = parse(version)?;
    let range = range.trim();
    if range.is_empty() || range.len() > 200 {
        return None;
    }
    let mut any = false;
    for alternative in range.split("||") {
        let alternative = alternative.trim();
        let ok = if let Some((low, high)) = alternative.split_once(" - ") {
            comparator(&format!(">={}", low.trim()), version)?
                && comparator(&format!("<={}", high.trim()), version)?
        } else {
            // `>= 22` is one comparator: an operator alone takes the next word.
            let mut words = vec![];
            let mut pending = String::new();
            for word in alternative.split_whitespace() {
                if word.chars().all(|c| "<>=^~".contains(c)) {
                    pending.push_str(word);
                } else {
                    words.push(format!("{pending}{word}"));
                    pending.clear();
                }
            }
            if !pending.is_empty() {
                return None;
            }
            let mut all = true;
            for word in &words {
                all &= comparator(word, version)?;
            }
            all
        };
        any |= ok;
    }
    Some(any)
}

/// What `.nvmrc` asks for as a range: the same major, at least the version written (`24.13.0` →
/// `>=24.13.0 <25`). Aliases (`lts/*`, `node`) are not a version: `None`.
pub fn nvmrc_range(text: &str) -> Option<String> {
    let text = text.lines().next()?.trim().trim_start_matches('v');
    let (numbers, given) = partial(text)?;
    if given == 0 {
        return None;
    }
    Some(format!(">={text} <{}", numbers[0] + 1))
}

/// The major of a version (`24.22.3` → `24`).
pub fn major(version: &str) -> String {
    version
        .trim_start_matches('v')
        .chars()
        .take_while(char::is_ascii_digit)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_ranges_projects_write() {
        for (range, version, expected) in [
            (">=22.12.0", "24.22.3", true),
            (">=22.12.0", "22.11.0", false),
            (">=24", "22.23.5", false),
            ("^20 || ^22", "22.1.0", true),
            ("^20 || ^22", "24.0.0", false),
            ("24.x", "24.9.1", true),
            ("24", "26.13.1", false),
            ("~24.1", "24.1.9", true),
            ("~24.1", "24.2.0", false),
            ("20 - 22", "22.5.0", true),
            ("20 - 22", "23.0.0", false),
            (">= 20 < 23", "22.0.0", true),
            (">=24.13.0 <25", "24.22.3", true),
            (">=24.13.0 <25", "26.13.1", false),
            ("*", "18.0.0", true),
        ] {
            assert_eq!(
                satisfies(range, version),
                Some(expected),
                "{range} {version}"
            );
        }
        for range in ["lts/*", "latest", ">=", ""] {
            assert_eq!(satisfies(range, "24.0.0"), None, "{range}");
        }
        assert_eq!(nvmrc_range("v24.13.0\n").as_deref(), Some(">=24.13.0 <25"));
        assert_eq!(nvmrc_range("24").as_deref(), Some(">=24 <25"));
        assert_eq!(nvmrc_range("lts/*"), None);
        assert_eq!(major("24.22.3"), "24");
    }
}
