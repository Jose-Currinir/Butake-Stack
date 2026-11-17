//! Who is at the other end of the askpass socket. The helper that answers Git is this binary,
//! started by Git's HTTPS transport (`git-remote-https`). A hook or filter that Git runs during the
//! same command inherits the socket and the one-time token from the environment, but its parent is
//! a shell or the hook itself, never the transport: such a peer gets no answer.
use std::os::unix::{io::AsRawFd, net::UnixStream};

/// Pid of the process connected to `stream` (`LOCAL_PEERPID`).
fn peer_pid(stream: &UnixStream) -> Option<libc::pid_t> {
    let mut pid: libc::pid_t = 0;
    let mut length = std::mem::size_of::<libc::pid_t>() as libc::socklen_t;
    // SAFETY: `fd` is an open socket owned by `stream`; `pid` and `length` are valid for writes
    // and `length` is the size of `pid`, as getsockopt requires.
    let status = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_LOCAL,
            libc::LOCAL_PEERPID,
            (&mut pid as *mut libc::pid_t).cast(),
            &mut length,
        )
    };
    (status == 0 && pid > 0).then_some(pid)
}

/// Parent of `pid`.
fn parent_pid(pid: libc::pid_t) -> Option<libc::pid_t> {
    // SAFETY: `proc_bsdinfo` is plain data for which all-zero bytes are valid.
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
    // SAFETY: `info` is a valid buffer of exactly `size` bytes for the PROC_PIDTBSDINFO flavor.
    let read = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDTBSDINFO,
            0,
            (&mut info as *mut libc::proc_bsdinfo).cast(),
            size,
        )
    };
    (read == size && info.pbi_ppid > 0).then_some(info.pbi_ppid as libc::pid_t)
}

/// Name of the program file `pid` runs.
fn program_name(pid: libc::pid_t) -> Option<String> {
    let mut buffer = vec![0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    // SAFETY: `buffer` is writable for the `buffer.len()` bytes passed.
    let length =
        unsafe { libc::proc_pidpath(pid, buffer.as_mut_ptr().cast(), buffer.len() as u32) };
    let path = std::str::from_utf8(buffer.get(..usize::try_from(length).ok()?)?).ok()?;
    path.rsplit('/').next().map(str::to_string)
}

/// Whether `pid` was started by Git's HTTP transport (`git-remote-http` or `git-remote-https`).
pub(crate) fn started_by_git_transport(pid: libc::pid_t) -> bool {
    parent_pid(pid)
        .and_then(program_name)
        .is_some_and(|name| matches!(name.as_str(), "git-remote-http" | "git-remote-https"))
}

/// Whether the peer of `stream` was started by Git's HTTP transport.
pub(crate) fn is_git_transport_child(stream: &UnixStream) -> bool {
    peer_pid(stream).is_some_and(started_by_git_transport)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_peer_of_a_socket_is_this_process_and_not_a_git_transport_child() {
        let (a, _b) = UnixStream::pair().unwrap();
        assert_eq!(peer_pid(&a), Some(std::process::id() as libc::pid_t));
        // The test runner is a child of cargo or a shell, not of `git-remote-https`.
        assert!(!is_git_transport_child(&a));
        assert!(program_name(std::process::id() as libc::pid_t).is_some());
        assert!(parent_pid(std::process::id() as libc::pid_t).is_some());
    }
}
