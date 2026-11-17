//! The token of a connected account (GitHub, Bitbucket Cloud) for one transfer over HTTPS. The app
//! sends it with the request, only for a remote of that provider; here it lives in memory while
//! that one Git command runs and reaches Git through an askpass helper: this same binary, which
//! Git starts when the server asks, connects to a Unix socket in a private folder (0700), proves
//! it is the expected child with a one-time token and says what Git asked. The answer goes only
//! to a question about the provider's own origin. Never in an argument, a variable, the remote's
//! address, Git's configuration, a file, a log or a response; Git's credential managers are off
//! for that command, so nothing stores it either.
use super::runner::{error, Result};
use crate::core::{rand::random_hex, validate};
use serde_json::Value;
use std::{
    io::{Read, Write},
    os::unix::{fs::DirBuilderExt, net::UnixListener},
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};

const SOCKET: &str = "BUTAKE_GIT_ASKPASS_SOCKET";
const TOKEN: &str = "BUTAKE_GIT_ASKPASS_TOKEN";

#[derive(Clone)]
pub struct Credentials {
    /// `https://host[:port]`: the only origin the answers are for.
    origin: String,
    username: String,
    password: String,
}

/// The credentials of this request (the engine serves one request per process).
static CURRENT: Mutex<Option<Credentials>> = Mutex::new(None);

fn invalid() -> super::runner::GitError {
    error(
        "invalid_arguments",
        "Las credenciales de la cuenta no tienen la forma esperada.",
    )
}

/// `https://host[:port]`, or plain HTTP only to this Mac's loopback address (the fake server of
/// the tests): nothing else may receive a token.
fn valid_origin(origin: &str) -> bool {
    let (authority, loopback) = match origin.strip_prefix("https://") {
        Some(rest) => (rest, false),
        None => match origin.strip_prefix("http://") {
            Some(rest) => (rest, true),
            None => return false,
        },
    };
    let (host, port) = match authority.rsplit_once(':') {
        Some((host, port)) => (host, Some(port)),
        None => (authority, None),
    };
    validate::host(host)
        && !host.contains(':')
        && port.is_none_or(|p| p.parse::<u16>().is_ok_and(|n| n > 0))
        && (!loopback || host == "127.0.0.1")
}

/// `scheme://host` as compared with the origin: lower case and without the default HTTPS port
/// (`https://github.com:443` is `https://github.com`).
fn same_origin(candidate: &str, origin: &str) -> bool {
    let plain = |value: &str| {
        let value = value.to_ascii_lowercase();
        value.strip_suffix(":443").map_or(value.clone(), |rest| {
            if value.starts_with("https://") {
                rest.to_string()
            } else {
                value.clone()
            }
        })
    };
    plain(candidate) == plain(origin)
}

/// Whether credentials are attached to this request: Git then must not fall back to the user's
/// own credential managers.
pub fn active() -> bool {
    CURRENT.lock().unwrap_or_else(|e| e.into_inner()).is_some()
}

impl Credentials {
    /// Reads and checks what the app sent. The values never appear in an error.
    pub fn parse(value: &Value) -> Result<Self> {
        let text = |key: &str| value[key].as_str().unwrap_or("").to_string();
        let credentials = Credentials {
            origin: text("origin"),
            username: text("username"),
            password: text("password"),
        };
        let name_ok = !credentials.username.is_empty()
            && credentials.username.len() <= 100
            && credentials
                .username
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'-' | b'_' | b'.'));
        let secret_ok = !credentials.password.is_empty()
            && credentials.password.len() <= 4096
            && !credentials.password.chars().any(char::is_control);
        if valid_origin(&credentials.origin) && name_ok && secret_ok {
            Ok(credentials)
        } else {
            Err(invalid())
        }
    }

    /// Whether `url` is an address of this origin (`https://[user@]host/…`).
    pub fn serves(&self, url: &str) -> bool {
        let Some((scheme, rest)) = url.split_once("://") else {
            return false;
        };
        let (authority, path) = rest.split_at(rest.find('/').unwrap_or(rest.len()));
        let host = authority.rsplit_once('@').map_or(authority, |(_, h)| h);
        path.starts_with('/') && same_origin(&format!("{scheme}://{host}"), &self.origin)
    }

    /// What to answer to a question of Git («Username for 'https://host': », «Password for
    /// 'https://user@host': »); nothing when it is about any other place.
    pub fn answer(&self, prompt: &str) -> Option<&str> {
        let start = prompt.find('\'')?;
        let end = prompt.rfind('\'')?;
        let target = prompt.get(start + 1..end)?;
        let (scheme, rest) = target.split_once("://")?;
        if rest.contains('/') {
            return None;
        }
        let host = rest.rsplit_once('@').map_or(rest, |(_, h)| h);
        if !same_origin(&format!("{scheme}://{host}"), &self.origin) {
            return None;
        }
        if prompt.starts_with("Username for ") {
            Some(&self.username)
        } else if prompt.starts_with("Password for ") {
            Some(&self.password)
        } else {
            None
        }
    }
}

/// Keeps the credentials of the request for its network commands, when one of `urls` (the
/// address to clone or publish to, or the repository's remotes) is of their origin. For any other
/// remote they are dropped: Git then works as without them.
pub fn accept(value: &Value, urls: &[String]) -> Result<()> {
    if value.is_null() {
        return Ok(());
    }
    let credentials = Credentials::parse(value)?;
    if urls.iter().any(|url| credentials.serves(url)) {
        *CURRENT.lock().unwrap_or_else(|e| e.into_inner()) = Some(credentials);
    }
    Ok(())
}

/// Whether this process was started by Git to answer a question.
pub fn helper_mode() -> bool {
    std::env::var_os(SOCKET).is_some() && std::env::var_os(TOKEN).is_some()
}

/// Helper side: sends Git's question to the parent and prints its answer, or fails (Git then
/// reports that it has no credentials).
pub fn run_helper() -> i32 {
    let (Some(socket), Ok(token)) = (std::env::var_os(SOCKET), std::env::var(TOKEN)) else {
        return 1;
    };
    let prompt = std::env::args().nth(1).unwrap_or_default();
    if prompt.len() > 512 || prompt.contains('\n') {
        return 1;
    }
    let Ok(mut stream) = std::os::unix::net::UnixStream::connect(socket) else {
        return 1;
    };
    let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
    if stream
        .write_all(format!("{token}\n{prompt}\n").as_bytes())
        .is_err()
    {
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
    let written = out
        .write_all(&answer)
        .and_then(|_| out.write_all(b"\n"))
        .and_then(|_| out.flush());
    i32::from(written.is_err())
}

/// The answering side of one Git command: ends, and removes its socket, when dropped.
pub struct Session {
    done: Arc<AtomicBool>,
    server: Option<std::thread::JoinHandle<()>>,
    dir: PathBuf,
}

impl Drop for Session {
    fn drop(&mut self) {
        self.done.store(true, Ordering::Relaxed);
        if let Some(server) = self.server.take() {
            let _ = server.join();
        }
        let _ = std::fs::remove_file(self.dir.join("s"));
        let _ = std::fs::remove_dir(&self.dir);
    }
}

fn read_line(stream: &mut std::os::unix::net::UnixStream, limit: usize) -> Option<String> {
    let mut line = Vec::new();
    let mut byte = [0u8; 1];
    loop {
        match stream.read(&mut byte) {
            Ok(1) if byte[0] == b'\n' => return String::from_utf8(line).ok(),
            Ok(1) if line.len() < limit => line.push(byte[0]),
            _ => return None,
        }
    }
}

fn serve(listener: UnixListener, token: String, credentials: Credentials, done: Arc<AtomicBool>) {
    // Git asks twice per attempt (user and password); a few attempts at most.
    let mut served = 0;
    while served < 8 && !done.load(Ordering::Relaxed) {
        match listener.accept() {
            Ok((mut stream, _)) => {
                let _ = stream.set_nonblocking(false);
                let _ = stream.set_read_timeout(Some(Duration::from_secs(1)));
                if !crate::ssh::askpass::same_user(&stream) {
                    continue;
                }
                let proven = read_line(&mut stream, 128).is_some_and(|line| line == token);
                let prompt = read_line(&mut stream, 512);
                if let (true, Some(answer)) = (
                    proven,
                    prompt.as_deref().and_then(|p| credentials.answer(p)),
                ) {
                    let _ = stream.write_all(answer.as_bytes());
                    served += 1;
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(20))
            }
            Err(_) => break,
        }
    }
}

/// For a network command (`clone`, `fetch`, `pull`, `push`) of a request that brought
/// credentials: turns Git's credential managers off for it and points its askpass at this binary.
/// Call it before the subcommand's arguments are added; keep the session until Git ends.
pub fn attach(command: &mut tokio::process::Command, args: &[&str]) -> Result<Option<Session>> {
    if !matches!(
        args.first().copied(),
        Some("clone" | "push" | "pull" | "fetch")
    ) {
        return Ok(None);
    }
    let Some(credentials) = CURRENT.lock().unwrap_or_else(|e| e.into_inner()).clone() else {
        return Ok(None);
    };
    // Without the helper Git would run with the user's own credential managers and could use
    // another account's token: the transfer is refused instead.
    let unavailable = || {
        error(
            "credential_helper_unavailable",
            "No se pudo preparar el acceso con tu cuenta conectada. Vuelve a intentar.",
        )
    };
    // Unix socket paths are short (104 bytes): the per-user temporary folder, never the store.
    let dir =
        std::env::temp_dir().join(format!("bga-{}", random_hex(8).map_err(|_| unavailable())?));
    std::fs::DirBuilder::new()
        .mode(0o700)
        .create(&dir)
        .map_err(|_| unavailable())?;
    let socket = dir.join("s");
    let done = Arc::new(AtomicBool::new(false));
    let mut session = Session {
        done: done.clone(),
        server: None,
        dir,
    };
    let listener = UnixListener::bind(&socket).map_err(|_| unavailable())?;
    listener.set_nonblocking(true).map_err(|_| unavailable())?;
    let token = random_hex(24).map_err(|_| unavailable())?;
    let exe = std::env::current_exe().map_err(|_| unavailable())?;
    command
        // An empty value clears the list: no manager offers another credential or stores this one.
        .args(["-c", "credential.helper="])
        .env("GIT_ASKPASS", exe)
        .env(SOCKET, &socket)
        .env(TOKEN, &token);
    session.server = Some(std::thread::spawn(move || {
        serve(listener, token, credentials, done)
    }));
    Ok(Some(session))
}

#[cfg(test)]
mod tests {
    use super::same_origin;

    #[test]
    fn the_default_https_port_is_the_same_origin() {
        assert!(same_origin("https://github.com:443", "https://github.com"));
        assert!(same_origin("https://GitHub.com", "https://github.com:443"));
        assert!(!same_origin(
            "https://github.com:8443",
            "https://github.com"
        ));
        assert!(!same_origin("http://127.0.0.1:443", "http://127.0.0.1"));
        assert!(!same_origin("https://evil.example", "https://github.com"));
    }
}
