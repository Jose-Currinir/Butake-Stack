//! Languages and tools Stack installs, by responsibility: the languages and their versions
//! (`languages`: PHP builds, Python, the Node, Java, Rust and Swift toolchains), the utilities
//! (`utilities`: the Utilidades page, the developer tools placed in the user's home and the
//! catalog of downloadable pieces) and the extensions of the components (`extensions`, P-43).

mod dispatch;
pub mod extensions;
pub mod languages;
pub mod utilities;

pub use dispatch::dispatch;
