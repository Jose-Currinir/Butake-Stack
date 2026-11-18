//! Sockets for ports 53, 80 and 443. Under the LaunchAgent, launchd opens them on 127.0.0.1
//! (macOS refuses those ports to normal processes on a specific address) and hands them over
//! through `launch_activate_socket`. Outside launchd the daemon binds the configured ports.
use crate::core::model::StackConfig;
use serde_json::{Map, Value, json};
use std::{
    net::{TcpListener, UdpSocket},
    os::fd::{AsRawFd, FromRawFd},
};

unsafe extern "C" {
    fn launch_activate_socket(
        name: *const libc::c_char,
        fds: *mut *mut libc::c_int,
        count: *mut libc::size_t,
    ) -> libc::c_int;
}

/// Returns the descriptors launchd opened for a named socket of this job, if any.
fn from_launchd(name: &str) -> Vec<i32> {
    let name = std::ffi::CString::new(name).unwrap();
    let mut fds: *mut libc::c_int = std::ptr::null_mut();
    let mut count: libc::size_t = 0;
    // SAFETY: `name` is a NUL-terminated string that outlives the call, and `fds` and `count` are
    // valid for writes. launchd only fills them in when it returns 0.
    let status = unsafe { launch_activate_socket(name.as_ptr(), &mut fds, &mut count) };
    if status != 0 || fds.is_null() {
        return vec![];
    }
    // SAFETY: on success (status 0) and with `fds` not null, launchd returned a `malloc`ed array
    // of exactly `count` descriptors; it is read once, before being freed below.
    let list = unsafe { std::slice::from_raw_parts(fds, count) }.to_vec();
    // SAFETY: the array belongs to the caller (launch_activate_socket's contract: free it with
    // `free`), it came from `malloc`, and `list` holds a copy, so nothing reads it afterwards.
    unsafe { libc::free(fds.cast()) };
    list
}

/// Supervised processes never inherit these sockets by accident: the supervisor hands a process
/// its own copies (`dup2` clears the flag on the copy) and everything else closes on exec.
fn close_on_exec(fd: i32) {
    // SAFETY: `fcntl` with `F_SETFD` takes integers and touches no memory; `fd` belongs to the
    // socket the caller holds.
    unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) };
}

/// Process listening on a local port, for a readable "port in use" message.
pub fn port_owner(port: u16, udp: bool) -> Option<String> {
    let filter = if udp {
        format!("-iUDP:{port}")
    } else {
        format!("-iTCP:{port}")
    };
    let mut command = std::process::Command::new("/usr/sbin/lsof");
    command.args(["-nP", &filter, "-Fc"]);
    if !udp {
        command.arg("-sTCP:LISTEN");
    }
    let output = command.env_clear().output().ok()?;
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .find_map(|l| l.strip_prefix('c').map(str::to_string))
}

#[derive(Default)]
pub struct Listeners {
    http: Option<TcpListener>,
    https: Option<TcpListener>,
    https_udp: Option<UdpSocket>,
    dns_udp: Option<UdpSocket>,
    dns_tcp: Option<TcpListener>,
    pub status: Map<String, Value>,
}

impl Listeners {
    pub fn open(config: &StackConfig) -> Self {
        let mut this = Self::default();
        let ports = &config.ports;
        let wanted = [
            ("http", ports.http, false),
            ("https", ports.https, false),
            ("https-udp", ports.https, true),
            ("dns", ports.dns, true),
            ("dns-tcp", ports.dns, false),
        ];
        for (name, port, udp) in wanted {
            let launchd = from_launchd(name);
            // The port launchd really listens on: the agent keeps the ports it was installed with.
            let mut actual = port;
            let (mode, ok) = if let Some(fd) = launchd.first() {
                for extra in &launchd[1..] {
                    // SAFETY: launchd handed these descriptors to this process and nothing else
                    // holds them; each is closed once, and only the first one is kept.
                    unsafe { libc::close(*extra) };
                }
                if udp {
                    // SAFETY: launchd transferred ownership of `fd` (open, not used elsewhere) to
                    // this process, and the socket takes it over: it is closed only by its drop.
                    let socket = unsafe { UdpSocket::from_raw_fd(*fd) };
                    actual = socket.local_addr().map_or(port, |a| a.port());
                    this.set_udp(name, socket);
                } else {
                    // SAFETY: as above: `fd` is an owned, open descriptor not used by anyone else.
                    let listener = unsafe { TcpListener::from_raw_fd(*fd) };
                    actual = listener.local_addr().map_or(port, |a| a.port());
                    this.set_tcp(name, listener);
                }
                ("launchd", true)
            } else if udp {
                match UdpSocket::bind(("127.0.0.1", port)) {
                    Ok(socket) => {
                        this.set_udp(name, socket);
                        ("bound", true)
                    }
                    Err(_) => ("unavailable", false),
                }
            } else {
                match TcpListener::bind(("127.0.0.1", port)) {
                    Ok(listener) => {
                        this.set_tcp(name, listener);
                        ("bound", true)
                    }
                    Err(_) => ("unavailable", false),
                }
            };
            let owner = if ok { None } else { port_owner(port, udp) };
            this.status.insert(
                name.into(),
                // `stale`: launchd's socket is not on the configured port (the agent must be
                // installed again); `port` is the one really in use.
                json!({"port": actual, "mode": mode, "owner": owner, "stale": actual != port}),
            );
        }
        this
    }
    fn set_udp(&mut self, name: &str, socket: UdpSocket) {
        close_on_exec(socket.as_raw_fd());
        if name == "https-udp" {
            self.https_udp = Some(socket);
        } else {
            self.dns_udp = Some(socket);
        }
    }
    fn set_tcp(&mut self, name: &str, listener: TcpListener) {
        close_on_exec(listener.as_raw_fd());
        match name {
            "http" => self.http = Some(listener),
            "https" => self.https = Some(listener),
            _ => self.dns_tcp = Some(listener),
        }
    }
    pub fn fds(&self) -> crate::daemon::WebFds {
        crate::daemon::WebFds {
            http: self.http.as_ref().map(|l| l.as_raw_fd()),
            https: self.https.as_ref().map(|l| l.as_raw_fd()),
            https_udp: self.https_udp.as_ref().map(|l| l.as_raw_fd()),
        }
    }
    pub fn take_dns_udp(&mut self) -> Option<tokio::net::UdpSocket> {
        let socket = self.dns_udp.take()?;
        socket.set_nonblocking(true).ok()?;
        tokio::net::UdpSocket::from_std(socket).ok()
    }
    pub fn take_dns_tcp(&mut self) -> Option<tokio::net::TcpListener> {
        let listener = self.dns_tcp.take()?;
        listener.set_nonblocking(true).ok()?;
        tokio::net::TcpListener::from_std(listener).ok()
    }
}
