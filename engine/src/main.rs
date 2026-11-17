mod app;
mod aws;
mod core;
mod daemon;
mod db;
#[cfg(test)]
#[path = "error_texts_tests.rs"]
mod error_texts_tests;
mod gcp;
mod git;
mod runtimes;
mod ssh;
mod web;
use anyhow::{bail, Result};
use serde_json::{json, Value};
use std::io::Read;

fn dispatch(request: Value) -> Result<Value> {
    let method = request["method"].as_str().unwrap_or("");
    // Moving the data folder works on both folders, before any store is opened.
    if let Some(value) = app::migrate::dispatch(method, &request)? {
        return Ok(value);
    }
    let store = crate::core::store::Store::from_environment()?;
    dispatch_with(&store, method, &request)
}

fn dispatch_with(
    store: &crate::core::store::Store,
    method: &str,
    request: &Value,
) -> Result<Value> {
    // One gate for every tool's methods (see `plugins::tool_of`): off, they answer
    // `plugin_disabled` before anything runs.
    let tool = app::plugins::tool_of(method);
    if let Some(tool) = tool {
        app::plugins::require(store, tool)?;
    }
    // SSH keys belong to the base (database tunnels and the SSH terminal share them).
    if method.starts_with("sshKey") {
        return ssh::keys::dispatch(store, method, request);
    }
    match tool {
        Some("database-client") => return db::ops::dispatch(store, method, request),
        Some("ssh-terminal") => return ssh::hosts::dispatch(store, method, request),
        Some("aws") => return aws::dispatch(store, method, request),
        Some("gcp") => return gcp::dispatch(store, method, request),
        Some("git") => return git::dispatch(store, method, request),
        _ => {}
    }
    // Extensions of the components (P-43), before `installSteps` of the other installs.
    if let Some(value) = runtimes::extensions::dispatch(store, method, request)? {
        return Ok(value);
    }
    if let Some(value) = app::dispatch(store, method, request)? {
        return Ok(value);
    }
    if let Some(value) = web::net::tunnels::dispatch(store, method, request)? {
        return Ok(value);
    }
    if let Some(value) = web::dispatch(store, method, request)? {
        return Ok(value);
    }
    if let Some(value) = runtimes::dispatch(store, method, request)? {
        return Ok(value);
    }
    if let Some(value) = daemon::dispatch(store, method, request)? {
        return Ok(value);
    }
    bail!("unknown_method")
}
/// Error codes the app may show with their own message.
const PUBLIC_ERRORS: &[&str] = &[
    // Renaming and moving a project (P-41).
    "invalid_new_id",
    "same_id",
    "id_in_use",
    "unknown_project",
    "same_folder",
    "target_exists",
    "invalid_rename_step",
    "folder_exists",
    "folder_missing",
    "folder_in_use",
    "not_a_project",
    "site_exists",
    "invalid_name",
    "node_not_installed",
    "php_not_installed",
    "scaffold_step_failed",
    "kmp_use_wizard",
    "unknown_template",
    "domain_in_use",
    "postgres_not_installed",
    "postgres_command_failed",
    "invalid_database_user",
    "unknown_database_user",
    "mysql_root_password_required",
    "postgres_not_trust",
    "postgres_not_running",
    "postgres_no_backup",
    "unknown_port_project",
    "project_without_port",
    "no_free_port",
    "invalid_group_name",
    "too_many_repositories",
    "checksum_mismatch",
    "checksum_not_found",
    "devtool_step_failed",
    "licenses_not_accepted",
    "jdk_not_installed",
    "uv_not_installed",
    "python_not_installed",
    "swiftly_not_installed",
    "version_not_in_catalog",
    "download_failed",
    "download_offline",
    "install_cancelled",
    "source_rate_limited",
    "signature_invalid",
    // Utilities: Apple's notarization, a copy installed some other way, what Stack did not install.
    "not_notarized",
    "installed_elsewhere",
    "not_managed",
    "unexpected_artifact",
    "version_mismatch",
    "build_failed",
    "unsupported_platform",
    "cargo_not_installed",
    "clt_not_installed",
    "xcode_license_pending",
    "invalid_backup",
    "clone_failed",
    "invalid_remote",
    "unknown_connection",
    "invalid_connection",
    "invalid_ssh",
    "ssh_host_unknown",
    "ssh_host_changed",
    "ssh_auth_failed",
    "ssh_failed",
    "client_not_installed",
    "invalid_password",
    "invalid_database_name",
    "database_protected",
    "user_protected",
    "invalid_user",
    "needs_primary_key",
    "invalid_file",
    "file_too_large",
    "csv_columns_mismatch",
    "unknown_table",
    "unsupported_engine",
    "empty_query",
    "unknown_ssh_key",
    "ssh_key_invalid",
    "ssh_key_passphrase",
    "ssh_key_exists",
    "ssh_key_in_use",
    "terminal_failed",
    "invalid_filter",
    "mysql_command_failed",
    "mysql_not_installed",
    "plugin_disabled",
    "unknown_plugin",
    "plugin_not_installed",
    "vault_data_kept",
    "confirmation_required",
    "unknown_ssh_host",
    "invalid_ssh_host",
    "invalid_forward",
    "forward_port_busy",
    "ssh_host_not_found",
    "ssh_unreachable",
    // Database client: sessions, read-only and production connections, structure, exports.
    "session_failed",
    "session_timeout",
    "result_too_large",
    "client_failed",
    "query_failed",
    "dump_failed",
    "restore_failed",
    "export_failed",
    "read_only_connection",
    "transaction_open",
    "transaction_lost",
    "invalid_ddl",
    "unsupported_ddl",
    "invalid_explain",
    "request_too_large",
    "authorization_cancelled",
    "authority_missing",
    "site_off",
    "cloudflared_missing",
    // Fixed public addresses (P-35): each cause with its way out.
    "cloudflare_not_connected",
    "tunnel_name_taken",
    "tunnel_offline",
    "tunnel_failed",
    "tunnel_not_found",
    "zone_not_authorized",
    "invalid_zone",
    "invalid_public_hostname",
    "public_hostname_outside_zone",
    "public_hostname_taken",
    "public_hostname_unchanged",
    "public_address_exists",
    "public_address_missing",
    "unknown_public_project",
    "project_without_public_address",
    "xdebug_missing",
    "duplicate_port",
    "invalid_port",
    "ssh_agent_missing",
    "ssh_host_in_use",
    "invalid_ssh_jump",
    "invalid_snippet",
    "unknown_snippet",
    "ssh_config_unreadable",
    "sftp_failed",
    "sftp_not_found",
    "sftp_denied",
    "sftp_exists",
    "sftp_unsupported_name",
    "sftp_not_empty",
    "sftp_too_many",
    // AWS tool: profiles of AWS CLI and what the CLI answered, as fixed codes.
    "aws_cli_missing",
    "aws_file_unreadable",
    "aws_invalid_profile",
    "aws_invalid_keys",
    "aws_profile_exists",
    "aws_profile_not_found",
    "aws_profile_duplicated",
    "aws_profile_incomplete",
    "aws_profile_in_use",
    "aws_has_keys",
    "aws_helper_path_unsupported",
    "aws_keychain_failed",
    "aws_keychain_missing",
    "aws_session_expired",
    "aws_offline",
    "aws_invalid_credentials",
    "aws_access_denied",
    "aws_process_failed",
    "aws_timeout",
    "aws_login_timeout",
    "aws_cancelled",
    "aws_check_failed",
    // Google Cloud tool: what gcloud answered, as fixed codes.
    "gcp_cli_missing",
    "gcp_invalid_account",
    "gcp_invalid_project",
    "gcp_unknown_account",
    "gcp_account_active",
    "gcp_session_expired",
    "gcp_offline",
    "gcp_api_disabled",
    "gcp_access_denied",
    "gcp_timeout",
    "gcp_cancelled",
    "gcp_failed",
    // Projects without a server, removing a version in use and one-click fixes (P-42).
    "project_not_served",
    "runtime_global",
    "unknown_fix",
    // Moving the data folder (the run itself answers with its own report).
    "migration_isolated",
    "migration_conflict",
    "migration_cross_volume",
    "migration_no_space",
    "migration_target_exists",
    // Extensions of the components (P-43); `extension_in_use` says where (below).
    "extension_component_unsupported",
    "unknown_extension",
    "extension_unsupported",
    "extension_not_installed",
    "extension_conflict",
    "extension_has_dependents",
    "extension_protected",
    "invalid_extension",
    "relocate_failed",
    "package_incomplete",
    // Domains, folders, environments and the launch agent: causes the user can fix.
    "invalid_domain",
    "duplicate_domain",
    "invalid_docroot",
    "invalid_path",
    "invalid_executable",
    "unknown_process",
    "production_locked",
    "env_not_ignored",
    "env_tracked_by_git",
    "environment_active",
    "unknown_environment",
    "agent_exists",
    "agent_bootstrap_failed",
    "agent_bootout_failed",
    "download_too_large",
    "insecure_url",
    "worktree_already_served",
    "mysql_init_failed",
    "ssh_known_hosts_unreadable",
];

/// Error codes that carry who holds what (`<code>:<detail>`): the detail goes to the app.
const DETAILED_ERRORS: &[&str] = &[
    "port_in_use",
    "service_in_use",
    "runtime_in_use",
    "extension_in_use",
];

#[tokio::main]
async fn main() {
    let args: Vec<_> = std::env::args_os().collect();
    let topic = match args.get(1).and_then(|arg| arg.to_str()) {
        Some("watch-status") => Some("state"),
        Some("watch-logs") => Some("logs"),
        Some("watch-dumps") => Some("dumps"),
        _ => None,
    };
    if let Some(topic) = topic {
        if crate::core::store::Store::from_environment()
            .and_then(|store| {
                daemon::watch(&store, topic, args.get(2).and_then(|arg| arg.to_str()))
            })
            .is_err()
        {
            std::process::exit(1);
        }
        return;
    }
    #[cfg(target_os = "macos")]
    if std::env::args_os().nth(1).as_deref() == Some(std::ffi::OsStr::new("replace-app")) {
        if let Err(error) = app::update::replace(std::env::args_os().skip(2)) {
            eprintln!("Stack update: {error}");
            std::process::exit(1);
        }
        return;
    }
    // Started by ssh-add / ssh-keygen as SSH_ASKPASS (see askpass.rs): answer and leave.
    if ssh::askpass::helper_mode() {
        std::process::exit(ssh::askpass::run_helper());
    }
    // Started by Git as GIT_ASKPASS for a transfer with a connected account (git/credentials.rs).
    if git::credentials::helper_mode() {
        std::process::exit(git::credentials::run_helper());
    }
    // AWS CLI asks for the keys of a profile kept in the Keychain (credential_process).
    if std::env::args().nth(1).as_deref() == Some(aws::helper::SUBCOMMAND) {
        std::process::exit(aws::helper::run(&args[2..]));
    }
    // The Git tool's console inside a tab of the Terminal, and its rebase sequence editor.
    if std::env::args().nth(1).as_deref() == Some("git-write-plan") {
        std::process::exit(git::write_plan(&args[2..]));
    }
    if std::env::args().nth(1).as_deref() == Some("git-console") {
        let allowed = crate::core::store::Store::from_environment()
            .and_then(|store| app::plugins::require(&store, "git"));
        let code = match allowed {
            Ok(()) => match git::run_console(&args[2..]).await {
                Ok(code) => code,
                Err(failure) => {
                    eprintln!("{}", git::public_detail(&failure.detail));
                    1
                }
            },
            Err(error) => {
                eprintln!("{error}");
                1
            }
        };
        std::process::exit(code);
    }
    // Moving the data to the folder of the new name, only when the user asks (see app/migrate).
    if std::env::args().nth(1).as_deref() == Some("migrate-data") {
        std::process::exit(app::migrate::command(&args[2..]));
    }
    // A persistent read session of the database client (see dbsession.rs).
    if std::env::args().nth(1).as_deref() == Some("dbsession") {
        if let Err(error) = db::session::serve() {
            if std::env::var_os("BUTAKE_STACK_DEBUG").is_some() {
                eprintln!("{error:#}");
            }
        }
        return;
    }
    if std::env::args().nth(1).as_deref() == Some("daemon") {
        if let Err(error) = daemon::run().await {
            let already_running = error.to_string() == "daemon_already_running";
            // launchd drops stdout: keep the cause where a person can read it (the file holds only
            // fixed codes and system errors, never project data).
            // A second copy losing the lock race is not a failure: keep the real cause, if any.
            if !already_running {
                daemon::record_failure(&error);
            }
            println!(
                "{}",
                daemon::failure(
                    Value::Null,
                    if already_running {
                        "daemon_already_running"
                    } else {
                        "daemon_failed"
                    },
                    if already_running {
                        "daemon.alreadyRunning"
                    } else {
                        "daemon.requestFailed"
                    }
                )
            );
            // A migration re-bootstraps the agent itself when it ends: launchd (KeepAlive on
            // failure only) must not relaunch the daemon meanwhile. Another daemon still holding the
            // lock (one started by hand, or still stopping its services) is a failure, so launchd
            // tries again after its ThrottleInterval and a daemon is running once that one is gone.
            let permanent = error.to_string() == "migration_in_progress";
            std::process::exit(if permanent { 0 } else { 1 });
        }
        return;
    }
    let result = (|| -> Result<Value> {
        let mut input = Vec::new();
        std::io::stdin()
            .take(git::REQUEST_LIMIT as u64 + 1)
            .read_to_end(&mut input)?;
        anyhow::ensure!(input.len() <= git::REQUEST_LIMIT, "request_too_large");
        let request: Value = serde_json::from_slice(&input)?;
        // Only the Git tool takes more than 1 MiB (a whole file of its editor or a resolution).
        anyhow::ensure!(
            input.len() <= 1_048_576 || git::is_method(request["method"].as_str().unwrap_or("")),
            "request_too_large"
        );
        dispatch(request)
    })();
    // Never reflect request data or filesystem errors into UI/logs.
    let response = match result {
        Ok(value) => json!({"ok":true,"value":value}),
        Err(error) => {
            // Diagnostics only on demand and only to stderr; responses never carry details.
            if std::env::var_os("BUTAKE_STACK_DEBUG").is_some() {
                eprintln!("{error:#}");
            }
            // The Git tool says what failed and why (its message or Git's own output, without
            // credentials): the app guides the user from both.
            if let Some(failure) = error.downcast_ref::<git::GitError>() {
                println!(
                    "{}",
                    json!({"ok":false,"error":{"code":failure.code,"messageKey":format!("git.error.{}", failure.code),"detail":git::public_detail(&failure.detail)}})
                );
                return;
            }
            // Known codes are fixed strings of this engine (never request data or paths), so the
            // app can say what happened; anything else stays generic.
            let code = error.to_string();
            // The database's own message (a failed statement, a refused login): the client exists to
            // show it. Only request responses carry it, never logs.
            if let Some(detail) = code.strip_prefix("db:") {
                let detail: String = detail.chars().take(2000).collect();
                println!(
                    "{}",
                    json!({"ok":false,"error":{"code":"database_error","messageKey":"error.database_error","detail":detail}})
                );
                return;
            }
            // A key in use says where: host and connection names, which are the user's own words.
            if let Some(used) = code.strip_prefix("ssh_key_in_use:") {
                let detail: String = used.chars().take(300).collect();
                println!(
                    "{}",
                    json!({"ok":false,"error":{"code":"ssh_key_in_use","messageKey":"error.ssh_key_in_use","detail":detail}})
                );
                return;
            }
            // A port, a service, a version or an extension in use says by whom (P-42, P-43): ports and the names of
            // projects, which are the user's own words.
            if let Some((name, detail)) = code
                .split_once(':')
                .filter(|(name, _)| DETAILED_ERRORS.contains(name))
            {
                let detail: String = detail.chars().take(600).collect();
                println!(
                    "{}",
                    json!({"ok":false,"error":{"code":name,"messageKey":format!("error.{name}"),"detail":detail}})
                );
                return;
            }
            // GitHub limited this network: the minutes until it resets.
            if let Some(minutes) = code.strip_prefix("source_rate_limited:") {
                let detail: String = minutes
                    .chars()
                    .filter(char::is_ascii_digit)
                    .take(4)
                    .collect();
                println!(
                    "{}",
                    json!({"ok":false,"error":{"code":"source_rate_limited","messageKey":"error.source_rate_limited","detail":detail}})
                );
                return;
            }
            if PUBLIC_ERRORS.contains(&code.as_str()) {
                json!({"ok":false,"error":{"code":code,"messageKey":format!("error.{code}")}})
            } else {
                json!({"ok":false,"error":{"code":"invalid_request","messageKey":"engine.requestFailed"}})
            }
        }
    };
    println!("{response}");
}
