use super::*;
use crate::skills::skill_file;
use std::os::unix::fs::PermissionsExt;

#[test]
fn create_read_save_and_parse_the_frontmatter() {
    let env = env();
    let skill = env.create("mi-skill");
    assert_eq!(skill["id"], "mi-skill");
    assert_eq!(skill["description"], "Hace algo");
    assert_eq!(skill["group"], "personal");
    let text = env.ok("skillsRead", json!({"id": "mi-skill"}))["text"]
        .as_str()
        .unwrap()
        .to_string();
    assert!(text.starts_with("---\nname: mi-skill\ndescription: Hace algo\n---"));
    let saved = env.ok(
        "skillsSave",
        json!({"id": "mi-skill", "text": "---\nname: \"Otro: nombre\"\ndescription: >\n  Primera parte\n  segunda parte\n---\n\nCuerpo\n"}),
    );
    assert_eq!(saved["name"], "Otro: nombre");
    assert_eq!(saved["description"], "Primera parte segunda parte");
    let mode = std::fs::metadata(env.skills_dir().join("mi-skill/SKILL.md"))
        .unwrap()
        .permissions()
        .mode();
    assert_eq!(mode & 0o777, 0o600);
    let index_mode = std::fs::metadata(env.skills_dir().join("index.json"))
        .unwrap()
        .permissions()
        .mode();
    assert_eq!(index_mode & 0o777, 0o600);
    // Without frontmatter the name is the id and the description is empty.
    let bare = env.ok(
        "skillsSave",
        json!({"id": "mi-skill", "text": "solo texto"}),
    );
    assert_eq!(bare["name"], "mi-skill");
    assert_eq!(bare["description"], "");
}

#[test]
fn frontmatter_parsing_and_quoting_round_trip() {
    let meta =
        skill_file::parse("---\r\nname: 'it''s'\r\ndescription: \"a \\\"b\\\"\"\r\n---\r\nx");
    assert_eq!(meta.name, "it's");
    assert_eq!(meta.description, "a \"b\"");
    assert_eq!(skill_file::parse("---\nname: x\n"), Default::default());
    for value in [
        "simple",
        "con: dos puntos",
        "#hash",
        " espacio",
        "comilla \"x\"",
        "",
    ] {
        let text = format!(
            "---\nname: n\ndescription: {}\n---\n",
            skill_file::quote(value)
        );
        assert_eq!(skill_file::parse(&text).description, value, "{value}");
    }
}

#[test]
fn invalid_ids_paths_and_sizes_are_refused() {
    let env = env();
    for bad in [
        "",
        "Mayus",
        "-a",
        "a-",
        "a_b",
        "../x",
        "a/b",
        ".hidden",
        &"a".repeat(65),
    ] {
        assert_eq!(
            env.code("skillsCreate", json!({"id": bad, "group": "personal", "template": "blank", "name": "x", "description": ""})),
            "skills_invalid_id",
            "{bad}"
        );
    }
    env.create("a");
    assert_eq!(
        env.code(
            "skillsCreate",
            json!({"id": "a", "group": "personal", "template": "blank"})
        ),
        "skills_exists"
    );
    assert_eq!(
        env.code(
            "skillsCreate",
            json!({"id": "b", "group": "nope", "template": "blank"})
        ),
        "skills_invalid_group"
    );
    assert_eq!(
        env.code("skillsRead", json!({"id": "../store"})),
        "skills_invalid_id"
    );
    assert_eq!(
        env.code("skillsRead", json!({"id": "zzz"})),
        "skills_not_found"
    );
    let big = "x".repeat(256 * 1024 + 1);
    assert_eq!(
        env.code("skillsSave", json!({"id": "a", "text": big})),
        "skills_too_large"
    );
    let fits = "x".repeat(256 * 1024);
    env.ok("skillsSave", json!({"id": "a", "text": fits}));
    assert_eq!(
        env.code(
            "skillsRename",
            json!({"id": "a", "newId": "../b", "confirmed": true})
        ),
        "skills_invalid_id"
    );
    assert_eq!(
        env.code("skillsRename", json!({"id": "a", "newId": "b"})),
        "confirmation_required"
    );
    assert_eq!(
        env.code("skillsDelete", json!({"id": "a"})),
        "confirmation_required"
    );
    assert_eq!(env.code("skillsNope", json!({})), "unknown_method");
}

#[test]
fn skill_files_are_never_read_through_links() {
    let env = env();
    env.create("a");
    let secret = env.temp.path().join("secret.txt");
    std::fs::write(&secret, "sentinel").unwrap();
    let file = env.skills_dir().join("a/SKILL.md");
    std::fs::remove_file(&file).unwrap();
    std::os::unix::fs::symlink(&secret, &file).unwrap();
    assert_eq!(
        env.code("skillsRead", json!({"id": "a"})),
        "skills_not_found"
    );
    assert_eq!(
        env.code("skillsSave", json!({"id": "a", "text": "x"})),
        "unsafe_store_path"
    );
    assert_eq!(std::fs::read_to_string(&secret).unwrap(), "sentinel");
    // The folder itself as a link is refused too.
    let folder = env.skills_dir().join("b");
    std::os::unix::fs::symlink(env.temp.path(), &folder).unwrap();
    assert_eq!(
        env.code("skillsRead", json!({"id": "b"})),
        "skills_not_found"
    );
}

#[test]
fn templates_update_duplicate_and_tags() {
    let env = env();
    for template in ["blank", "commits", "publish-app"] {
        let id = template.to_string();
        env.ok("skillsCreate", json!({"id": id, "group": "butake", "template": template, "name": id, "description": "Una skill"}));
    }
    let commits = env.ok("skillsRead", json!({"id": "commits"}))["text"]
        .as_str()
        .unwrap()
        .to_string();
    assert!(commits.contains("Sin coautoría de IA"));
    let publish = env.ok("skillsRead", json!({"id": "publish-app"}))["text"]
        .as_str()
        .unwrap()
        .to_string();
    assert!(publish.contains("Bóveda") && publish.contains("iOS") && publish.contains("Android"));
    assert_eq!(
        env.code(
            "skillsCreate",
            json!({"id": "x", "group": "butake", "template": "otra"})
        ),
        "invalid_request"
    );
    assert!(!env.skills_dir().join("x").exists());

    let updated = env.ok(
        "skillsUpdate",
        json!({"id": "commits", "group": "trabajo", "tags": ["Git", "git", " Flujo "]}),
    );
    assert_eq!(updated["group"], "trabajo");
    assert_eq!(updated["tags"], json!(["git", "flujo"]));
    assert_eq!(
        env.code("skillsUpdate", json!({"id": "commits", "group": "nope"})),
        "skills_invalid_group"
    );

    std::fs::write(env.skills_dir().join("commits/helper.sh"), "echo").unwrap();
    env.link("commits", "claude");
    let copy = env.ok(
        "skillsDuplicate",
        json!({"id": "commits", "newId": "commits-2"}),
    );
    assert_eq!(copy["agents"], json!([]));
    assert_eq!(copy["group"], "trabajo");
    assert_eq!(copy["name"], "commits-2");
    assert_eq!(copy["files"], json!(["helper.sh"]));
    assert_eq!(
        env.code(
            "skillsDuplicate",
            json!({"id": "commits", "newId": "commits-2"})
        ),
        "skills_exists"
    );
    let list = env.ok("skillsList", json!({}));
    assert_eq!(list["skills"].as_array().unwrap().len(), 4);
    assert_eq!(list["tags"], json!(["flujo", "git"]));
    assert_eq!(list["agents"].as_array().unwrap().len(), 4);
}

#[test]
fn folders_found_on_disk_are_adopted() {
    let env = env();
    env.ok("skillsList", json!({}));
    let dir = env.skills_dir().join("llegada");
    std::fs::create_dir(&dir).unwrap();
    std::fs::write(
        dir.join("SKILL.md"),
        "---\nname: llegada\ndescription: Hola\n---\n",
    )
    .unwrap();
    let list = env.ok("skillsList", json!({}));
    assert_eq!(list["skills"][0]["id"], "llegada");
    assert_eq!(list["skills"][0]["group"], "personal");
}
