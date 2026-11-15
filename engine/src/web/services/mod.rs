//! The stack's services: their recipes (`engines`), php-fpm and Caddy generated from the model
//! (`web_server`), the databases and accounts of a project and PostgreSQL's password.

pub mod databases;
mod dispatch;
pub mod engines;
pub mod postgres_auth;
pub mod web_server;

pub use dispatch::dispatch;
