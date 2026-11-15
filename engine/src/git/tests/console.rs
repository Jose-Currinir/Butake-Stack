//! The console's policy, its read-only queries, the dictionary and the console subcommand.
use super::{commit_file, sandbox};
use crate::git::console::{
    capabilities, check_query, command_help, command_names, prepare, public_output,
    rebase_candidates, run_console, validate_rebase, write_plan, RebasePlan, RebaseStep,
};
use crate::git::runner::git;
use std::ffi::OsString;

#[test]
fn policy_preserves_main_without_blocking_rebase_base() {
    assert!(prepare("commit", "-m test", "main", "main", true).is_err());
    assert!(prepare("log", "--all --oneline", "main", "main", true).is_ok());
    assert!(prepare("branch", "--list", "main", "main", true).is_ok());
    assert!(prepare("rebase", "main", "feature/test", "main", true).is_ok());
    assert!(prepare("branch", "-D main", "develop", "main", true).is_err());
    assert!(prepare("update-ref", "--stdin", "develop", "main", true).is_err());
    // Unprotected repositories may work on main; force and mass push stay blocked.
    assert!(prepare("commit", "-m test", "main", "main", false).is_ok());
    assert!(prepare("branch", "-D main", "develop", "main", false).is_ok());
    assert!(prepare("push", "--force origin main:main", "main", "main", false).is_err());
    // Repositories on master protect master, not a missing main.
    assert!(prepare("commit", "-m test", "master", "master", true).is_err());
    assert!(prepare("branch", "-D master", "develop", "master", true).is_err());
    assert!(prepare("commit", "-m test", "main", "master", true).is_ok());
}

#[test]
fn protected_main_cannot_be_moved_from_another_branch() {
    for (command, args) in [
        ("switch", "-C main"),
        ("switch", "--force-create main develop"),
        ("checkout", "-B main"),
        ("checkout", "-Bmain"),
        ("pull", ". develop:main"),
        ("rebase", "develop main"),
        ("rebase", "--onto develop feature main"),
        ("worktree", "add -B main ../w"),
        ("branch", "-f main develop"),
    ] {
        assert!(
            prepare(command, args, "develop", "main", true).is_err(),
            "{command} {args}"
        );
    }
    // Using main only as a base or a source stays allowed.
    for (command, args) in [
        ("rebase", "main"),
        ("rebase", "--onto main develop"),
        ("switch", "-c feature/x main"),
        ("pull", "origin main"),
        ("merge", "main"),
    ] {
        assert!(
            prepare(command, args, "develop", "main", true).is_ok(),
            "{command} {args}"
        );
    }
    assert!(prepare("switch", "-C main", "develop", "main", false).is_ok());
}

#[test]
fn push_requires_exact_destination_and_no_force() {
    assert!(prepare(
        "push",
        "origin refs/heads/develop:refs/heads/develop",
        "develop",
        "main",
        true
    )
    .is_ok());
    for args in [
        "",
        "origin",
        "origin develop",
        "origin refs/heads/develop:refs/heads/main",
        "--mirror origin",
        "--force origin refs/heads/develop:refs/heads/develop",
        "origin +refs/heads/develop:refs/heads/develop",
        "--force-with-lease origin refs/heads/develop:refs/heads/develop",
        "--all origin",
        "--tags origin refs/heads/develop:refs/heads/develop",
    ] {
        assert!(
            prepare("push", args, "develop", "main", true).is_err(),
            "{args}"
        );
        assert!(
            prepare("push", args, "develop", "main", false).is_err(),
            "unprotected {args}"
        );
    }
}

#[test]
fn command_arguments_are_tokens_not_shell() {
    let command = prepare("grep", "'$(touch /tmp/never-run)'", "develop", "main", true).unwrap();
    assert_eq!(command.args, ["$(touch /tmp/never-run)"]);
    assert_eq!(command.preview, "git grep '$(touch /tmp/never-run)'");
    assert!(prepare("bash", "-c whoami", "develop", "main", true).is_err());
    assert!(prepare("status", "'broken", "develop", "main", true).is_err());
    assert_eq!(
        prepare("sh-setup", "", "develop", "main", true)
            .unwrap_err()
            .code,
        "library_command"
    );
}

#[test]
fn queries_are_read_only() {
    let args = |text: &str| -> Vec<String> { text.split(' ').map(String::from).collect() };
    for ok in [
        "log --oneline -5",
        "show HEAD",
        "remote -v",
        "config --list",
        "tag --list",
        "stash list",
        "worktree list",
        "reflog show",
        "reflog --format=%H",
    ] {
        assert!(check_query(&args(ok)).is_ok(), "{ok}");
    }
    for refused in [
        "push origin x",
        "tag nueva",
        "tag -d v1",
        "config set user.name x",
        "remote add x y",
        "reflog expire --all",
        "reflog delete HEAD@{0}",
        "log --output=/tmp/x",
        "stash drop",
        "worktree add ../x",
    ] {
        assert!(check_query(&args(refused)).is_err(), "{refused}");
    }
    assert!(check_query(&[]).is_err());
}

#[test]
fn outputs_that_can_hold_credentials_are_cleaned() {
    let remotes = "origin\thttps://user:hunter2hunter2@example.invalid/a.git (fetch)".to_string();
    assert!(!public_output("remote", remotes).contains("hunter2"));
    let config = "http.extraheader=Authorization: Bearer abc.def.ghi".to_string();
    assert!(!public_output("config", config).contains("abc.def.ghi"));
    // File content and history stay as Git wrote them.
    let diff = "+PASSWORD=ejemplo-de-prueba".to_string();
    assert_eq!(public_output("diff", diff.clone()), diff);
}

#[tokio::test]
async fn dictionary_capabilities_and_help() {
    let names = command_names();
    assert!(names.len() > 100 && names.iter().any(|n| n == "rebase"));
    let found = capabilities().await.unwrap();
    assert!(found.version.starts_with("git version"));
    assert!(found
        .commands
        .iter()
        .any(|c| c.name == "status" && c.available));
    assert!(found
        .commands
        .iter()
        .any(|c| c.name == "sh-setup" && c.library && !c.available));
    assert_eq!(
        command_help("rm -rf").await.unwrap_err().code,
        "unknown_command"
    );
}

#[tokio::test]
async fn interactive_rebase_plans_are_checked() {
    let temp = sandbox().await;
    let root = temp.path();
    let base = git(root, &["rev-parse", "HEAD"])
        .await
        .unwrap()
        .trim()
        .to_string();
    let a = commit_file(root, "a.txt", "a\n", "feat: a").await;
    let b = commit_file(root, "b.txt", "b\n", "feat: b").await;
    let found = rebase_candidates(root, &base).await.unwrap();
    assert_eq!(found.commits.len(), 2);
    let step = |hash: &str, action: &str| RebaseStep {
        hash: hash.into(),
        action: action.into(),
    };
    let plan = |steps| RebasePlan {
        head: found.head.clone(),
        base: found.base.clone(),
        steps,
    };
    assert_eq!(
        validate_rebase(root, &plan(vec![step(&a, "pick"), step(&b, "squash")]))
            .await
            .unwrap(),
        format!("pick {a}\nsquash {b}\n")
    );
    for bad in [
        vec![step(&a, "squash"), step(&b, "pick")],
        vec![step(&a, "pick")],
        vec![step(&a, "pick"), step(&b, "exec")],
    ] {
        assert_eq!(
            validate_rebase(root, &plan(bad)).await.unwrap_err().code,
            "invalid_plan"
        );
    }
    assert!(rebase_candidates(root, "--evil").await.is_err());
}

#[tokio::test]
async fn console_subcommand_runs_the_checked_command_only() {
    let temp = sandbox().await;
    let root = temp.path();
    let os = |s: &str| OsString::from(s);
    let path = root.to_string_lossy().to_string();
    assert_eq!(
        run_console(&[os(&path), os("status"), os("--short")])
            .await
            .unwrap(),
        0
    );
    assert_eq!(
        run_console(&[os(&path), os("push"), os("--force origin x")])
            .await
            .unwrap_err()
            .code,
        "protected_branch"
    );
    assert_eq!(
        run_console(&[os(&path), os("status"), os(""), os("{}")])
            .await
            .unwrap_err()
            .code,
        "invalid_plan"
    );
    assert!(run_console(&[os(&path)]).await.is_err());
    // The sequence editor only copies the plan over the todo list.
    let plan = root.join("plan");
    let todo = root.join("todo");
    std::fs::write(&plan, "pick abc\n").unwrap();
    assert_eq!(write_plan(&[plan.clone().into(), todo.clone().into()]), 0);
    assert_eq!(std::fs::read_to_string(&todo).unwrap(), "pick abc\n");
    assert_eq!(write_plan(&[plan.into()]), 1);
}
