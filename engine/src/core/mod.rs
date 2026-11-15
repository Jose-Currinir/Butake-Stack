//! Shared building blocks: one implementation per utility (hashing, archives, downloads,
//! private writes, JSON files, validation, child processes, external command lines, time and
//! randomness).

pub mod archive;
pub mod cache;
pub mod cli_tool;
pub mod codec;
pub mod download;
pub mod fsutil;
pub mod github;
pub mod hash;
pub mod journal;
pub mod json;
pub mod model;
pub mod process;
pub mod progress;
pub mod project_database;
pub mod rand;
pub mod signature;
pub mod store;
pub mod time;
pub mod validate;
pub mod watch;
