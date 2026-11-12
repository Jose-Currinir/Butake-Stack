use crate::store::Store;
use anyhow::{ensure, Result};
use serde_json::{json, Value};
use std::{fs, process::Command};

fn escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}
fn socket(name: &str, port: u16, udp: bool) -> String {
    format!(
        "<key>{name}</key><dict><key>SockNodeName</key><string>127.0.0.1</string>\
         <key>SockServiceName</key><string>{port}</string>\
         <key>SockType</key><string>{}</string><key>SockFamily</key><string>IPv4</string></dict>",
        if udp { "dgram" } else { "stream" }
    )
}

/// launchd opens 53/80/443 on 127.0.0.1 for the agent: normal processes cannot.
pub fn manifest(
    executable: &std::path::Path,
    root: &std::path::Path,
    ports: &crate::model::Ports,
) -> String {
    let sockets = [
        socket("http", ports.http, false),
        socket("https", ports.https, false),
        socket("https-udp", ports.https, true),
        socket("dns", ports.dns, true),
        socket("dns-tcp", ports.dns, false),
    ]
    .join("");
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>cl.butake.stack.daemon</string>
<key>ProgramArguments</key><array><string>{}</string><string>daemon</string></array>
<key>EnvironmentVariables</key><dict><key>BUTAKE_STACK_HOME</key><string>{}</string></dict>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>10</integer>
<key>Sockets</key><dict>{}</dict>
</dict></plist>
"#,
        escape(&executable.to_string_lossy()),
        escape(&root.to_string_lossy()),
        sockets
    )
}

pub fn configure(request: &Value, install: bool) -> Result<Value> {
    let store = Store::from_environment()?;
    let executable = std::env::current_exe()?.canonicalize()?;
    let plist = manifest(&executable, store.root(), &store.config()?.ports);
    if request["preview"] == true {
        return Ok(json!({"plist":plist,"applied":false}));
    }
    ensure!(request["confirmed"] == true, "confirmation_required");
    // Isolated QA must never bootstrap an agent or touch the real LaunchAgents directory.
    ensure!(
        std::env::var_os("BUTAKE_STACK_HOME").is_none(),
        "agent_disabled_in_isolation"
    );
    let directory = dirs::home_dir()
        .ok_or_else(|| anyhow::anyhow!("home_unavailable"))?
        .join("Library/LaunchAgents");
    fs::create_dir_all(&directory)?;
    ensure!(
        !directory.symlink_metadata()?.file_type().is_symlink(),
        "unsafe_agent_path"
    );
    let path = directory.join("cl.butake.stack.daemon.plist");
    let domain = format!("gui/{}", unsafe { libc::geteuid() });
    if install {
        ensure!(!path.try_exists()?, "agent_exists");
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let mut file = fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(&path)?;
        file.write_all(plist.as_bytes())?;
        file.sync_all()?;
        let status = Command::new("/bin/launchctl")
            .args(["bootstrap", &domain])
            .arg(&path)
            .status()?;
        if !status.success() {
            let _ = fs::remove_file(path);
            anyhow::bail!("agent_bootstrap_failed");
        }
    } else {
        ensure!(
            !path.symlink_metadata()?.file_type().is_symlink(),
            "unsafe_agent_path"
        );
        let status = Command::new("/bin/launchctl")
            .args(["bootout", &domain])
            .arg(&path)
            .status()?;
        ensure!(status.success(), "agent_bootout_failed");
        fs::remove_file(&path)?;
    }
    Ok(json!({"applied":true}))
}

/// Whether the LaunchAgent file exists and launchd has it loaded.
pub fn status() -> Value {
    let path = dirs::home_dir().map(|h| h.join("Library/LaunchAgents/cl.butake.stack.daemon.plist"));
    let installed = path.as_ref().is_some_and(|p| p.exists());
    let domain = format!("gui/{}/cl.butake.stack.daemon", unsafe { libc::geteuid() });
    let loaded = Command::new("/bin/launchctl")
        .args(["print", &domain])
        .env_clear()
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    json!({"installed": installed, "loaded": loaded})
}
