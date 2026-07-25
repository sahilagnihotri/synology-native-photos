//! Synology Web API HTTP client, auth, capability probe, tolerant decode.

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

pub mod album_write;
pub mod auth;
pub mod browse;
pub mod delete_item;
pub mod discovery;
pub mod download;
pub mod envelope;
pub mod info;
pub mod namespace;
pub mod recycle;
pub mod search_filter;
pub mod thumbnail;
pub mod transport;
pub mod upload;

pub use album_write::{add_items, create_album, delete_album, remove_items};
pub use auth::{login, logout};
pub use browse::{list_albums, list_items, list_items_filtered, search, search_filtered, CollectionFilter};
pub use delete_item::permanent_delete;
pub use discovery::{list_people, list_places, list_subjects, list_tags};
pub use download::download_original;
pub use envelope::{decode_envelope, decode_write_success, map_error_code, SynoError, SynoResponse};
pub use info::{pin_version, probe_capabilities};
pub use recycle::{
    delete_recycle_item, list_recycle_photos, recycle_thumbnail, restore_recycle_item, trigger_reindex,
};
pub use search_filter::search_facets;
pub use thumbnail::fetch_thumbnail;
pub use transport::{build_client, fetch_server_cert_der, Transport};
pub use upload::upload_file;

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
        let _ = crate::create_album as usize;
        let _ = crate::add_items as usize;
        let _ = crate::remove_items as usize;
        let _ = crate::delete_album as usize;
        let _ = crate::permanent_delete as usize;
        let _ = crate::list_recycle_photos as usize;
        let _ = crate::restore_recycle_item as usize;
        let _ = crate::delete_recycle_item as usize;
        let _ = crate::recycle_thumbnail as usize;
        let _ = crate::trigger_reindex as usize;
        let _ = crate::decode_write_success as usize;
        let _ = crate::search as usize;
        let _ = crate::search_filtered as usize;
        let _ = crate::search_facets as usize;
        let _ = crate::list_people as usize;
        let _ = crate::list_places as usize;
        let _ = crate::list_subjects as usize;
        let _ = crate::list_tags as usize;
        let _ = crate::fetch_thumbnail as usize;
        let _ = crate::download_original as usize;
        let _ = crate::upload_file as usize;
        let _ = crate::build_client as usize;
        let _ = crate::fetch_server_cert_der as usize;
        let _ = crate::decode_envelope::<serde_json::Value> as usize;
        let _ = crate::map_error_code as usize;
    }
}
