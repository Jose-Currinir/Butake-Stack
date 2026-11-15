//! The local network: internal DNS, the sockets of ports 53, 80 and 443, and the tunnels that
//! share a project (temporary or with a fixed address).

mod dispatch;
pub mod dns;
pub mod listeners;
pub mod tunnels;

pub use dispatch::dispatch;
