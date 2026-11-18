//! Passphrases for `ssh-add` and `ssh-keygen` without a terminal, an argument, a variable or a
//! file: the engine runs the tool with `SSH_ASKPASS` pointing at itself and `SSH_ASKPASS_REQUIRE=force`.
//! When the tool asks, this same binary starts in helper mode, connects to a Unix socket the
//! parent opened in a private folder (0700), proves it is the expected child with a one-time
//! token and prints the passphrase it receives. The parent answers a fixed number of times, only
//! to the same user, and removes the socket when the tool exits. Passphrases are never logged.
use crate::core::rand::random_hex;
use crate::core::store::Store;
use anyhow::{Result, ensure};
use std::{
    io::{Read, Write},
    os::unix::{fs::DirBuilderExt, net::UnixListener},
    path::PathBuf,
    process::{Command, Output, Stdio},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};

const SOCKET: &str = "BUTAKE_ASKPASS_SOCKET";
const TOKEN: &str = "BUTAKE_ASKPASS_TOKEN";

/// Whether this process was started by ssh-add / ssh-keygen to answer a prompt.
pub fn helper_mode() -> bool {
    std::env::var_os(SOCKET).is_some() && std::env::var_os(TOKEN).is_some()
}

/// Helper side: prints the passphrase the parent sends, or fails (the tool then gives up).
pub fn run_helper() -> i32 {
    let (Some(socket), Some(token)) = (std::env::var_os(SOCKET), std::env::var(TOKEN).ok()) else {
        return 1;
    };
    let Ok(mut stream) = std::os::unix::net::UnixStream::connect(socket) else {
        return 1;
    };
    let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
    if stream.write_all(format!("{token}\n").as_bytes()).is_err() {
        return 1;
    }
    let mut answer = Vec::new();
    if stream.take(4097).read_to_end(&mut answer).is_err()
        || answer.is_empty()
        || answer.len() > 4096
    {
        return 1;
    }
    let mut out = std::io::stdout();
    if out
        .write_all(&answer)
        .and_then(|_| out.write_all(b"\n"))
        .and_then(|_| out.flush())
        .is_err()
    {
        return 1;
    }
    0
}

/// Whether the peer of a Unix socket runs as this same user.
pub(crate) fn same_user(stream: &std::os::unix::net::UnixStream) -> bool {
    use std::os::unix::io::AsRawFd;
    let mut uid: libc::uid_t = 0;
    let mut gid: libc::gid_t = 0;
    // SAFETY: the descriptor is open for as long as `stream` is borrowed, and `uid` and `gid` are
    // valid for writes; getpeereid reads nothing else.
    let ok = unsafe { libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) } == 0;
    // SAFETY: `geteuid` takes no arguments, touches no memory and cannot fail.
    ok && uid == unsafe { libc::geteuid() }
}

/// Runs `command` (ssh-add, ssh-keygen) answering up to `answers` passphrase prompts with
/// `passphrase`. The command's environment is cleared except HOME and the agent socket.
pub fn run(mut command: Command, passphrase: &str, answers: usize) -> Result<Output> {
    ensure!(
        !passphrase.is_empty()
            && passphrase.len() <= 1024
            && !passphrase.contains(['\n', '\r', '\0']),
        "ssh_key_passphrase"
    );
    // Everything that can fail without touching the disk comes first: after the folder and the
    // socket exist, a failing step would leave them (and a server thread) behind.
    let token = random_hex(24)?;
    let exe = std::env::current_exe()?;
    // Unix socket paths are short (104 bytes): the per-user temporary folder, never the store.
    let dir = std::env::temp_dir().join(format!("bsa-{}", random_hex(8)?));
    std::fs::DirBuilder::new().mode(0o700).create(&dir)?;
    let socket: PathBuf = dir.join("s");
    let cleanup = |dir: &PathBuf| {
        let _ = std::fs::remove_file(dir.join("s"));
        let _ = std::fs::remove_dir(dir);
    };
    let listener = match UnixListener::bind(&socket) {
        Ok(listener) => listener,
        Err(error) => {
            cleanup(&dir);
            return Err(error.into());
        }
    };
    if let Err(error) = listener.set_nonblocking(true) {
        cleanup(&dir);
        return Err(error.into());
    }
    let done = Arc::new(AtomicBool::new(false));
    let server = {
        let done = done.clone();
        let token = token.clone();
        let secret = passphrase.as_bytes().to_vec();
        std::thread::spawn(move || {
            let mut served = 0;
            let started = Instant::now();
            while served < answers
                && !done.load(Ordering::Relaxed)
                && started.elapsed() < Duration::from_secs(120)
            {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        let _ = stream.set_nonblocking(false);
                        let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
                        if !same_user(&stream) {
                            continue;
                        }
                        let mut line = Vec::new();
                        let mut byte = [0u8; 1];
                        while line.len() < 128 {
                            match stream.read(&mut byte) {
                                Ok(1) if byte[0] != b'\n' => line.push(byte[0]),
                                _ => break,
                            }
                        }
                        if line == token.as_bytes() {
                            let _ = stream.write_all(&secret);
                            served += 1;
                        }
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(20))
                    }
                    Err(_) => break,
                }
            }
        })
    };
    command.env_clear();
    if let Some(home) = Store::home() {
        command.env("HOME", home);
    }
    if let Some(agent) = std::env::var_os("SSH_AUTH_SOCK") {
        command.env("SSH_AUTH_SOCK", agent);
    }
    command
        .env("SSH_ASKPASS", exe)
        .env("SSH_ASKPASS_REQUIRE", "force")
        .env(SOCKET, &socket)
        .env(TOKEN, &token)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let output = command.output();
    done.store(true, Ordering::Relaxed);
    let _ = server.join();
    cleanup(&dir);
    Ok(output?)
}
