//! Skills as text ready to paste into an AI that has no skills folder (ChatGPT).
use super::model::{fail, Ctx, Index};
use super::skill_file;
use anyhow::Result;

pub fn markdown(ctx: &Ctx, index: &Index, ids: &[String]) -> Result<String> {
    if ids.is_empty() || ids.len() > 50 {
        return fail("skills_not_found");
    }
    let mut parts = vec![];
    for id in ids {
        if !index.skills.contains_key(id) {
            return fail("skills_not_found");
        }
        let dir = ctx.dir(id)?;
        let text = skill_file::read_text(&dir)?;
        let meta = skill_file::parse(&text);
        let name = if meta.name.is_empty() {
            id.clone()
        } else {
            meta.name
        };
        let mut part = format!("# {name}\n\n");
        if !meta.description.is_empty() {
            part.push_str(&format!("{}\n\n", meta.description));
        }
        part.push_str("## Instrucciones\n\n");
        part.push_str(skill_file::split(&text).1.trim());
        part.push('\n');
        let files = skill_file::files(&dir);
        if !files.is_empty() {
            part.push_str("\n## Archivos de apoyo\n\n");
            for file in files {
                part.push_str(&format!("- {file}\n"));
            }
        }
        parts.push(part);
    }
    Ok(parts.join("\n---\n\n"))
}
