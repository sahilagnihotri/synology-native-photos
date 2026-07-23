//! Synology Web API HTTP client, auth, capability probe, tolerant decode.

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

pub mod auth;
pub mod envelope;
pub mod info;
pub mod namespace;
pub mod transport;
