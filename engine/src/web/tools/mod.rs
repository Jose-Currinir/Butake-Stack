//! The tools of the base that receive from the projects: the SMTP mail catcher (Correo) and the
//! VarDumper receiver (Dumps).

mod dispatch;
pub mod dumps;
pub mod mail;

pub use dispatch::dispatch;
