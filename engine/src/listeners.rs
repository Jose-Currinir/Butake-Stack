//! Sockets for ports 53, 80 and 443. Under the LaunchAgent, launchd opens them on 127.0.0.1
//! (macOS refuses those ports to normal processes on a specific address) and hands them over
//! through `launch_activate_socket`. Outside launchd the daemon binds the configured ports.
use crate::model::StackConfig;
use serde_json::{json, Map, Value};
use std::{
    net::{TcpListener, UdpSocket},
    os::fd::{AsRawFd, FromRawFd},
};

extern "C" {
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
    let status = unsafe { launch_activate_socket(name.as_ptr(), &mut fds, &mut count) };
    if status != 0 || fds.is_null() {
        return vec![];
    }
    let list = unsafe { std::slice::from_raw_parts(fds, count) }.to_vec();
    unsafe { libc::free(fds.cast()) };
    list
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
            let (mode, ok) = if let Some(fd) = launchd.first() {
                for extra in &launchd[1..] {
                    unsafe { libc::close(*extra) };
                }
                // Safety: launchd transferred ownership of this descriptor to us.
                if udp {
                    this.set_udp(name, unsafe { UdpSocket::from_raw_fd(*fd) });
                } else {
                    this.set_tcp(name, unsafe { TcpListener::from_raw_fd(*fd) });
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
                json!({"port": port, "mode": mode, "owner": owner}),
            );
        }
        this
    }
    fn set_udp(&mut self, name: &str, socket: UdpSocket) {
        if name == "https-udp" {
            self.https_udp = Some(socket);
        } else {
            self.dns_udp = Some(socket);
        }
    }
    fn set_tcp(&mut self, name: &str, listener: TcpListener) {
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
