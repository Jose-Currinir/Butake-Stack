//! AWS CLI's `config` and `credentials` files as text: a tolerant reader and a line editor.
//!
//! The file is kept as its own lines (with their own line endings). Reading never fails: a line
//! that is not a section, a setting or a comment is kept and ignored. Editing changes only the
//! lines of one setting or one section header, so comments, blank lines, the order, the spacing
//! style and every setting Stack does not understand stay byte for byte (never a re-serialization).
//!
//! Format (as the CLI reads it): `[section]` headers; `name = value` (or `name: value`) settings;
//! lines starting with `#` or `;` are comments; an indented line continues the setting above it
//! (nested settings such as `s3 =` followed by `  max_concurrent_requests = 20`).

use anyhow::{ensure, Result};

/// One section: its header line, the line after its last line, and the name between brackets.
#[derive(Debug, Clone, PartialEq)]
pub struct Section {
    pub header: usize,
    pub end: usize,
    pub name: String,
}

/// One setting of a section: its line, name and value (trimmed; empty for a nested block).
#[derive(Debug, Clone, PartialEq)]
pub struct Setting {
    pub line: usize,
    pub key: String,
    pub value: String,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Document {
    lines: Vec<String>,
}

fn content(line: &str) -> &str {
    line.trim_end_matches(['\n', '\r'])
}

fn is_comment(line: &str) -> bool {
    let trimmed = content(line).trim_start();
    trimmed.starts_with('#') || trimmed.starts_with(';')
}

fn is_blank(line: &str) -> bool {
    content(line).trim().is_empty()
}

/// The name of a section header (`[profile dev]` → `profile dev`), when the line is one.
fn header_name(line: &str) -> Option<String> {
    let trimmed = content(line).trim();
    let rest = trimmed.strip_prefix('[')?;
    let close = rest.find(']')?;
    let after = rest[close + 1..].trim();
    if !(after.is_empty() || after.starts_with('#') || after.starts_with(';')) {
        return None;
    }
    let name = rest[..close].trim();
    (!name.is_empty()).then(|| name.to_string())
}

/// `name = value` at the start of a line: the name and where the value starts.
fn setting(line: &str) -> Option<(String, usize)> {
    let text = content(line);
    if text.starts_with([' ', '\t']) || is_comment(line) || header_name(line).is_some() {
        return None;
    }
    let delimiter = text.find(['=', ':'])?;
    let key = text[..delimiter].trim();
    if key.is_empty() {
        return None;
    }
    let after = &text[delimiter + 1..];
    let start = delimiter + 1 + (after.len() - after.trim_start().len());
    Some((key.to_string(), start))
}

impl Document {
    pub fn parse(text: &str) -> Self {
        Self {
            lines: text.split_inclusive('\n').map(str::to_string).collect(),
        }
    }

    pub fn text(&self) -> String {
        self.lines.concat()
    }

    /// The line ending the file already uses.
    fn newline(&self) -> &'static str {
        if self.lines.first().is_some_and(|l| l.ends_with("\r\n")) {
            "\r\n"
        } else {
            "\n"
        }
    }

    pub fn sections(&self) -> Vec<Section> {
        let mut out: Vec<Section> = Vec::new();
        for (index, line) in self.lines.iter().enumerate() {
            if let Some(name) = header_name(line) {
                if let Some(last) = out.last_mut() {
                    last.end = index;
                }
                out.push(Section {
                    header: index,
                    end: self.lines.len(),
                    name,
                });
            }
        }
        out
    }

    /// The one section with this name; `Ok(None)` when there is none and `aws_profile_duplicated`
    /// when there are several (the CLI itself refuses such a file).
    pub fn find(&self, name: &str) -> Result<Option<Section>> {
        let mut found = self.sections().into_iter().filter(|s| s.name == name);
        let first = found.next();
        ensure!(found.next().is_none(), "aws_profile_duplicated");
        Ok(first)
    }

    pub fn settings(&self, section: &Section) -> Vec<Setting> {
        (section.header + 1..section.end)
            .filter_map(|line| {
                let (key, start) = setting(&self.lines[line])?;
                Some(Setting {
                    line,
                    key,
                    value: content(&self.lines[line])[start..].trim().to_string(),
                })
            })
            .collect()
    }

    pub fn get(&self, section: &Section, key: &str) -> Option<String> {
        self.settings(section)
            .into_iter()
            .find(|s| s.key == key)
            .map(|s| s.value)
    }

    /// Lines of the setting at `line`: itself and the indented lines that continue it.
    fn setting_span(&self, section: &Section, line: usize) -> usize {
        let mut end = line + 1;
        while end < section.end
            && content(&self.lines[end]).starts_with([' ', '\t'])
            && !is_blank(&self.lines[end])
        {
            end += 1;
        }
        end
    }

    /// The spacing of the section's first setting (`a = b` or `a=b`), for new ones.
    fn style(&self, section: &Section) -> &'static str {
        match self.settings(section).first() {
            Some(first) if !content(&self.lines[first.line]).contains(" =") => "=",
            _ => " = ",
        }
    }

    /// Sets, adds or (with `None`) removes one setting of the section named `name`. An existing
    /// setting keeps its line and spacing; a new one goes after the section's last setting.
    pub fn set(&mut self, name: &str, key: &str, value: Option<&str>) -> Result<()> {
        let section = self
            .find(name)?
            .ok_or_else(|| anyhow::anyhow!("aws_profile_not_found"))?;
        let existing = self.settings(&section).into_iter().find(|s| s.key == key);
        match (existing, value) {
            (Some(found), Some(value)) => {
                let line = &self.lines[found.line];
                let (_, start) = setting(line).expect("a setting line");
                let ending = &line[content(line).len()..];
                let updated = format!("{}{value}{ending}", &content(line)[..start]);
                let span = self.setting_span(&section, found.line);
                self.lines.splice(found.line..span, [updated]);
            }
            (Some(found), None) => {
                let span = self.setting_span(&section, found.line);
                self.lines.drain(found.line..span);
            }
            (None, Some(value)) => {
                let newline = self.newline();
                let style = self.style(&section);
                let at = (section.header + 1..section.end)
                    .rev()
                    .find(|&line| !is_blank(&self.lines[line]) && !is_comment(&self.lines[line]))
                    .map_or(section.header + 1, |line| line + 1);
                if !self.lines[at - 1].ends_with('\n') {
                    self.lines[at - 1].push_str(newline);
                }
                self.lines
                    .insert(at, format!("{key}{style}{value}{newline}"));
            }
            (None, None) => {}
        }
        Ok(())
    }

    /// Adds a section at the end of the file, separated by a blank line from what is above.
    pub fn append(&mut self, name: &str, settings: &[(&str, String)]) -> Result<()> {
        ensure!(self.find(name)?.is_none(), "aws_profile_exists");
        let newline = self.newline();
        if let Some(last) = self.lines.last_mut() {
            if !last.ends_with('\n') {
                last.push_str(newline);
            }
        }
        if self.lines.last().is_some_and(|l| !is_blank(l)) {
            self.lines.push(newline.to_string());
        }
        self.lines.push(format!("[{name}]{newline}"));
        for (key, value) in settings {
            self.lines.push(format!("{key} = {value}{newline}"));
        }
        Ok(())
    }

    /// Copies a section's lines (comments and unknown settings included) under a new name.
    pub fn copy(&mut self, from: &str, to: &str) -> Result<()> {
        let section = self
            .find(from)?
            .ok_or_else(|| anyhow::anyhow!("aws_profile_not_found"))?;
        let body: Vec<(String, String)> = self
            .settings(&section)
            .into_iter()
            .map(|s| {
                let span = self.setting_span(&section, s.line);
                let raw: String = self.lines[s.line..span].concat();
                (s.key, raw)
            })
            .collect();
        ensure!(self.find(to)?.is_none(), "aws_profile_exists");
        let newline = self.newline();
        self.append(to, &[])?;
        for (_, raw) in body {
            let raw = if raw.ends_with('\n') {
                raw
            } else {
                format!("{raw}{newline}")
            };
            self.lines.push(raw);
        }
        Ok(())
    }

    /// Renames a section, keeping the rest of its header line (spacing, a trailing comment).
    pub fn rename(&mut self, from: &str, to: &str) -> Result<()> {
        let section = self
            .find(from)?
            .ok_or_else(|| anyhow::anyhow!("aws_profile_not_found"))?;
        ensure!(self.find(to)?.is_none(), "aws_profile_exists");
        let line = &self.lines[section.header];
        let open = line.find('[').expect("a header");
        let close = open + 1 + line[open + 1..].find(']').expect("a header");
        let updated = format!("{}[{to}]{}", &line[..open], &line[close + 1..]);
        self.lines[section.header] = updated;
        Ok(())
    }

    /// Removes a section: its header and its lines, except the comments right before the next
    /// section (they usually describe that one).
    pub fn remove(&mut self, name: &str) -> Result<()> {
        let Some(section) = self.find(name)? else {
            return Ok(());
        };
        let mut end = section.end;
        if section.end < self.lines.len() {
            while end > section.header + 1
                && (is_comment(&self.lines[end - 1]) || is_blank(&self.lines[end - 1]))
            {
                end -= 1;
            }
            // Blank lines between the removed settings and those comments stay one separator.
            while end < section.end && is_blank(&self.lines[end]) {
                end += 1;
            }
        }
        self.lines.drain(section.header..end);
        Ok(())
    }

    /// Every setting named `key` whose value is `from`, in any section, now says `to`.
    pub fn replace_values(&mut self, key: &str, from: &str, to: &str) -> Result<()> {
        for section in self.sections() {
            if self.get(&section, key).as_deref() == Some(from) {
                self.set(&section.name, key, Some(to))?;
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const CONFIG: &str = "# Archivo de ejemplo\n[default]\nregion=us-east-1\noutput=json\n\n[profile acme-dev]   # desarrollo\nsso_session = acme\nsso_account_id = 111122223333\nsso_role_name = Desarrollo\nregion = sa-east-1\ns3 =\n  max_concurrent_requests = 20\ncli_pager =\n\n# La sesión única de Acme\n[sso-session acme]\nsso_start_url = https://acme.awsapps.com/start\nsso_region: us-east-1\n";

    #[test]
    fn reads_sections_settings_comments_and_nested_blocks() {
        let doc = Document::parse(CONFIG);
        let names: Vec<_> = doc.sections().into_iter().map(|s| s.name).collect();
        assert_eq!(names, ["default", "profile acme-dev", "sso-session acme"]);
        let dev = doc.find("profile acme-dev").unwrap().unwrap();
        assert_eq!(doc.get(&dev, "region").as_deref(), Some("sa-east-1"));
        assert_eq!(doc.get(&dev, "s3").as_deref(), Some(""));
        assert_eq!(doc.get(&dev, "max_concurrent_requests"), None);
        let sso = doc.find("sso-session acme").unwrap().unwrap();
        assert_eq!(doc.get(&sso, "sso_region").as_deref(), Some("us-east-1"));
        assert_eq!(doc.text(), CONFIG);
        assert_eq!(Document::parse("").sections(), []);
        assert_eq!(Document::parse("basura sin formato\n[]\n").sections(), []);
    }

    #[test]
    fn editing_one_setting_leaves_every_other_byte() {
        let mut doc = Document::parse(CONFIG);
        doc.set("profile acme-dev", "region", Some("us-west-2"))
            .unwrap();
        assert_eq!(
            doc.text(),
            CONFIG.replace("region = sa-east-1", "region = us-west-2")
        );
        // The compact style of [default] is kept, both for a change and for a new setting.
        let mut doc = Document::parse(CONFIG);
        doc.set("default", "output", Some("table")).unwrap();
        doc.set("default", "cli_pager", Some("")).unwrap();
        assert_eq!(
            doc.text(),
            CONFIG.replace("output=json\n", "output=table\ncli_pager=\n")
        );
        // A new setting goes after the last one, before the blank line and the next comment.
        let mut doc = Document::parse(CONFIG);
        doc.set("profile acme-dev", "output", Some("yaml")).unwrap();
        assert_eq!(
            doc.text(),
            CONFIG.replace("cli_pager =\n", "cli_pager =\noutput = yaml\n")
        );
        // Removing a nested block takes its indented lines with it.
        let mut doc = Document::parse(CONFIG);
        doc.set("profile acme-dev", "s3", None).unwrap();
        assert_eq!(
            doc.text(),
            CONFIG.replace("s3 =\n  max_concurrent_requests = 20\n", "")
        );
    }

    #[test]
    fn sections_are_added_renamed_copied_and_removed_in_place() {
        let mut doc = Document::parse(CONFIG);
        doc.rename("profile acme-dev", "profile acme-desarrollo")
            .unwrap();
        assert_eq!(
            doc.text(),
            CONFIG.replace(
                "[profile acme-dev]   # desarrollo",
                "[profile acme-desarrollo]   # desarrollo"
            )
        );
        let mut doc = Document::parse(CONFIG);
        doc.remove("profile acme-dev").unwrap();
        assert_eq!(
            doc.text(),
            "# Archivo de ejemplo\n[default]\nregion=us-east-1\noutput=json\n\n# La sesión única de Acme\n[sso-session acme]\nsso_start_url = https://acme.awsapps.com/start\nsso_region: us-east-1\n"
        );
        let mut doc = Document::parse(CONFIG);
        doc.remove("sso-session acme").unwrap();
        assert!(doc
            .text()
            .ends_with("cli_pager =\n\n# La sesión única de Acme\n"));
        let mut doc = Document::parse("[default]\nregion = x");
        doc.append("profile nuevo", &[("region", "us-east-1".into())])
            .unwrap();
        assert_eq!(
            doc.text(),
            "[default]\nregion = x\n\n[profile nuevo]\nregion = us-east-1\n"
        );
        assert_eq!(
            doc.append("profile nuevo", &[]).unwrap_err().to_string(),
            "aws_profile_exists"
        );
        let mut doc = Document::parse(CONFIG);
        doc.copy("profile acme-dev", "profile acme-qa").unwrap();
        assert!(doc.text().starts_with(CONFIG));
        assert!(doc.text().ends_with("\n\n[profile acme-qa]\nsso_session = acme\nsso_account_id = 111122223333\nsso_role_name = Desarrollo\nregion = sa-east-1\ns3 =\n  max_concurrent_requests = 20\ncli_pager =\n"));
    }

    #[test]
    fn repeated_sections_and_crlf_files() {
        let doc = Document::parse("[a]\nx = 1\n[a]\nx = 2\n");
        assert_eq!(
            doc.find("a").unwrap_err().to_string(),
            "aws_profile_duplicated"
        );
        let mut doc = Document::parse("[default]\r\nregion = us-east-1\r\n");
        doc.set("default", "output", Some("json")).unwrap();
        doc.append("other", &[("region", "x".into())]).unwrap();
        assert_eq!(
            doc.text(),
            "[default]\r\nregion = us-east-1\r\noutput = json\r\n\r\n[other]\r\nregion = x\r\n"
        );
        let mut doc =
            Document::parse("[profile a]\nsource_profile = b\n[profile c]\nsource_profile = b\n");
        doc.replace_values("source_profile", "b", "z").unwrap();
        assert_eq!(
            doc.text(),
            "[profile a]\nsource_profile = z\n[profile c]\nsource_profile = z\n"
        );
    }
}
