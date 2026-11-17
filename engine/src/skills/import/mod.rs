//! Import of the skills already in the AI folders: scan, plan, apply, undo and the import trash.
//! Nothing is deleted: a real folder moves to `skills-trash/import-<id>-<epoch>/` and stays there
//! until the user empties the import trash (see docs/herramientas/skills.md).
mod apply;
mod plan;
mod record;
mod scan;
mod tree;
mod undo;

use super::model::{Ctx, Index, fail};
use anyhow::Result;
use serde_json::Value;

#[cfg(test)]
pub(crate) use apply::FAIL_AFTER_FIRST;
pub(super) use record::is_import;
#[cfg(test)]
pub(crate) use tree::DIGESTS;

/// Methods that only read, or answer `plan: true`, take no lock.
pub fn mutates(method: &str, request: &Value) -> bool {
    match method {
        "skillsImportScan" | "skillsImportPlan" | "skillsImportTrashList" => false,
        "skillsImportUndo" | "skillsImportTrashEmpty" => request["plan"] != true,
        _ => true,
    }
}

pub fn dispatch(ctx: &Ctx, index: &mut Index, method: &str, request: &Value) -> Result<Value> {
    let confirmed = request["confirmed"] == true;
    let trash_id = request["trashId"].as_str().unwrap_or("");
    match method {
        "skillsImportScan" => Ok(scan::json(&scan::scan(ctx, index))),
        "skillsImportPlan" => {
            let parsed = plan::parse(request, index)?;
            Ok(plan::json(&plan::build(ctx, index, &parsed)?))
        }
        "skillsImportApply" => {
            if !confirmed {
                return fail("confirmation_required");
            }
            let parsed = plan::parse(request, index)?;
            let built = plan::build(ctx, index, &parsed)?;
            apply::run(ctx, index, &built)
        }
        "skillsImportTrashList" => Ok(record::list(ctx)),
        "skillsImportUndo" => {
            let undo = undo::plan(ctx, index, trash_id)?;
            if request["plan"] == true {
                return Ok(undo::plan_json(&undo));
            }
            if !confirmed {
                return fail("confirmation_required");
            }
            undo::apply(ctx, index, &undo)
        }
        "skillsImportTrashEmpty" => undo::empty(ctx, request, confirmed),
        _ => anyhow::bail!("unknown_method"),
    }
}
