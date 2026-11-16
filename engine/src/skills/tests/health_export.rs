use super::*;
use std::fs;

fn kinds(env: &Env) -> Vec<(String, String)> {
    env.ok("skillsHealth", json!({}))
        .as_array()
        .unwrap()
        .iter()
        .map(|i| {
            (
                i["kind"].as_str().unwrap().to_string(),
                i["skill"]
                    .as_str()
                    .or(i["agent"].as_str())
                    .unwrap_or("")
                    .to_string(),
            )
        })
        .collect()
}

#[test]
fn health_reports_each_kind() {
    let env = env();
    env.ok("skillsCreate", json!({"id": "sin-desc", "group": "personal", "template": "blank", "name": "sin-desc", "description": ""}));
    env.create("uno");
    env.create("dos");
    env.ok(
        "skillsSave",
        json!({"id": "dos", "text": "---\nname: uno\ndescription: Igual\n---\n"}),
    );
    env.create("enlazada");
    env.link("enlazada", "claude");
    env.link("enlazada", "codex");
    env.create("perdida");
    env.link("perdida", "claude");
    env.create("falta");

    // A conflict (codex), a link that went missing (claude), and a link left behind for a gone skill.
    let codex = env.link_path(".agents/skills", "enlazada");
    fs::remove_file(&codex).unwrap();
    fs::create_dir(&codex).unwrap();
    fs::remove_file(env.link_path(".claude/skills", "perdida")).unwrap();
    std::os::unix::fs::symlink(
        env.skills_dir().join("fantasma"),
        env.link_path(".claude/skills", "fantasma"),
    )
    .unwrap();
    // A link of someone else is not ours to report.
    std::os::unix::fs::symlink(
        env.temp.path().join("x"),
        env.link_path(".claude/skills", "ajena"),
    )
    .unwrap();
    fs::remove_dir_all(env.skills_dir().join("falta")).unwrap();
    // An index entry without folder is adopted only when the folder exists, so add one by hand.
    let index_path = env.skills_dir().join("index.json");
    let mut index: Value = serde_json::from_str(&fs::read_to_string(&index_path).unwrap()).unwrap();
    index["skills"]["huerfana"] =
        json!({"group": "personal", "tags": [], "enabled": true, "agents": []});
    fs::write(&index_path, index.to_string()).unwrap();
    env.ok(
        "skillsAgentSave",
        json!({"id": "mia", "name": "Mía", "folder": "~/.mia/skills"}),
    );

    let found = kinds(&env);
    let has = |kind: &str, who: &str| found.iter().any(|(k, w)| k == kind && w == who);
    assert!(has("no_description", "sin-desc"), "{found:?}");
    assert!(
        has("duplicate_name", "uno") && has("duplicate_name", "dos"),
        "{found:?}"
    );
    assert!(has("conflict", "enlazada"), "{found:?}");
    assert!(has("broken_link", "perdida"), "{found:?}");
    assert!(has("broken_link", "claude"), "{found:?}");
    assert!(has("unused", "sin-desc"), "{found:?}");
    assert!(has("missing_folder", "huerfana"), "{found:?}");
    assert!(has("missing_folder", "mia"), "{found:?}");
    assert!(!found.iter().any(|(_, w)| w == "ajena"), "{found:?}");
    assert!(!has("unused", "enlazada"), "{found:?}");
}

#[test]
fn export_is_text_ready_to_paste() {
    let env = env();
    env.ok(
        "skillsCreate",
        json!({"id": "commits", "group": "butake", "template": "commits", "name": "commits", "description": "Reglas de commits"}),
    );
    env.create("otra");
    fs::write(env.skills_dir().join("commits/plantilla.txt"), "x").unwrap();
    let text = env.ok(
        "skillsExport",
        json!({"id": "commits", "format": "markdown"}),
    )["text"]
        .as_str()
        .unwrap()
        .to_string();
    assert!(text.starts_with("# commits\n\nReglas de commits\n\n## Instrucciones\n\n# Commits"));
    assert!(!text.contains("name: commits"));
    assert!(text.ends_with("## Archivos de apoyo\n\n- plantilla.txt\n"));
    let both = env.ok(
        "skillsExport",
        json!({"ids": ["commits", "otra"], "format": "markdown"}),
    )["text"]
        .as_str()
        .unwrap()
        .to_string();
    assert!(both.contains("\n---\n\n# otra\n"));
    assert_eq!(
        env.code("skillsExport", json!({"id": "commits", "format": "pdf"})),
        "invalid_request"
    );
    assert_eq!(
        env.code("skillsExport", json!({"ids": []})),
        "skills_not_found"
    );
    assert_eq!(
        env.code("skillsExport", json!({"id": "nada"})),
        "skills_not_found"
    );
}

fn agent_paths(env: &Env, skill: &str) -> Vec<String> {
    env.ok("skillsHealth", json!({}))
        .as_array()
        .unwrap()
        .iter()
        .filter(|p| p["kind"] == "agent_path" && p["skill"] == skill)
        .map(|p| p["agent"].as_str().unwrap().to_string())
        .collect()
}

#[test]
fn health_reports_paths_to_unlinked_agents() {
    let env = env();
    env.create("ruta");
    let dir = env.skills_dir().join("ruta");
    let sentinel = "SENTINEL-4f9a1c";
    fs::write(
        dir.join("SKILL.md"),
        format!(
            "---\nname: ruta\ndescription: Hace algo\n---\n\n{sentinel} Corre `~/.claude/skills/ruta/run.sh`\n"
        ),
    )
    .unwrap();
    env.link("ruta", "codex");

    // Named for claude, linked only to codex.
    assert_eq!(agent_paths(&env, "ruta"), ["claude"]);
    let health = env.ok("skillsHealth", json!({}));
    let finding = health
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["kind"] == "agent_path")
        .unwrap();
    assert_eq!(
        finding["path"],
        env.home.join(".claude/skills").to_string_lossy().as_ref()
    );
    assert!(!health.to_string().contains(sentinel));
    assert!(!health.to_string().contains("run.sh"));

    // Linked to claude: nothing.
    env.link("ruta", "claude");
    assert!(agent_paths(&env, "ruta").is_empty());

    // The absolute form with the real home, in a support file, for the agent not linked (gemini).
    fs::create_dir(dir.join("scripts")).unwrap();
    fs::write(
        dir.join("scripts/go.sh"),
        format!("cat {}/.gemini/skills/ruta/x\n", env.home.display()),
    )
    .unwrap();
    assert_eq!(agent_paths(&env, "ruta"), ["gemini"]);
}

#[test]
fn health_agent_path_counts_only_own_id_and_text_files() {
    let env = env();
    env.create("propia");
    let dir = env.skills_dir().join("propia");
    // Another skill's id, and an id that only starts with ours: not ours.
    fs::write(
        dir.join("SKILL.md"),
        "---\nname: propia\ndescription: Hace algo\n---\n\nVer ~/.claude/skills/otra/run.sh y ~/.claude/skills/propia-2/x\n",
    )
    .unwrap();
    assert!(agent_paths(&env, "propia").is_empty());

    // Binary, oversized and linked files are skipped.
    let path = b"~/.claude/skills/propia/x";
    let mut binary = vec![0u8];
    binary.extend_from_slice(path);
    fs::write(dir.join("bin.dat"), binary).unwrap();
    let mut big = vec![b' '; super::super::model::MAX_TEXT as usize + 1];
    big.extend_from_slice(path);
    fs::write(dir.join("big.txt"), big).unwrap();
    let outside = env.temp.path().join("outside.txt");
    fs::write(&outside, path).unwrap();
    std::os::unix::fs::symlink(&outside, dir.join("link.txt")).unwrap();
    assert!(agent_paths(&env, "propia").is_empty());

    // A regular text file does count.
    fs::write(dir.join("ok.txt"), path).unwrap();
    assert_eq!(agent_paths(&env, "propia"), ["claude"]);
}
