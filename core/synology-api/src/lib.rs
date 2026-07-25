//! Synology Web API HTTP client, auth, capability probe, tolerant decode.

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

pub mod auth;
pub mod browse;
pub mod discovery;
pub mod download;
pub mod envelope;
pub mod info;
pub mod namespace;
pub mod thumbnail;
pub mod transport;

pub use auth::{login, logout};
pub use browse::{list_albums, list_items, list_items_filtered, search, CollectionFilter};
pub use discovery::{list_people, list_places, list_subjects, list_tags};
pub use download::download_original;
pub use envelope::{decode_envelope, map_error_code, SynoError, SynoResponse};
pub use info::{pin_version, probe_capabilities};
pub use thumbnail::fetch_thumbnail;
pub use transport::{build_client, fetch_server_cert_der, Transport};

#[cfg(test)]
mod facade_tests {
    #[test]
    fn reexports_are_reachable() {
        let _ = crate::login as usize;
        let _ = crate::logout as usize;
        let _ = crate::probe_capabilities as usize;
        let _ = crate::pin_version as usize;
        let _ = crate::list_items as usize;
        let _ = crate::list_items_filtered as usize;
        let _ = crate::list_albums as usize;
        let _ = crate::search as usize;
        let _ = crate::list_people as usize;
        let _ = crate::list_places as usize;
        let _ = crate::list_subjects as usize;
        let _ = crate::list_tags as usize;
        let _ = crate::fetch_thumbnail as usize;
        let _ = crate::download_original as usize;
        let _ = crate::build_client as usize;
        let _ = crate::fetch_server_cert_der as usize;
        let _ = crate::decode_envelope::<serde_json::Value> as usize;
        let _ = crate::map_error_code as usize;
    }
}
