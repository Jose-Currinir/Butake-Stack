//! Projects: detection of a folder, creation with the official generators, environments,
//! renaming and moving, what each one needs (attention), the services it uses, watched folders
//! the folders of the disk the sidebar follows and the Git state of its folder.

pub mod attention;
pub mod detect;
pub mod disk;
mod dispatch;
pub mod envs;
pub mod git;
pub mod rename;
pub mod scaffold;
pub mod service_use;
pub mod watch;

pub use dispatch::dispatch;
