//! Local mail catcher: an SMTP server on 127.0.0.1 that accepts every message the sites send and
//! keeps it in the store (`mail/`, 0600) instead of delivering it. Credentials sent with AUTH are
//! accepted and discarded; nothing leaves the Mac. Messages expire after the configured days and
//! the oldest go first beyond the configured count.
//!
//! `store` keeps the messages, `smtp` receives them, `mime` reads them and `view` serves them to the
//! interface.
mod mime;
mod smtp;
mod store;
mod view;

pub use smtp::serve;
pub use store::{count, delete};
pub use view::{changes, get, save_attachment};

#[cfg(test)]
mod tests;
