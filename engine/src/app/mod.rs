//! What the app manages about itself: the backup of the configuration, the optional tools
//! (plugins) and the update check.

pub mod backup;
mod dispatch;
pub mod migrate;
pub mod plugins;
#[cfg(target_os = "macos")]
pub mod update;

pub use dispatch::dispatch;
