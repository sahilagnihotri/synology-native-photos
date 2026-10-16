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
pub use browse::{
    filter_items, list_albums, list_items, list_items_filtered, search, search_filtered, CollectionFilter,
};
pub use delete_item::permanent_delete;
pub use discovery::{list_people, list_places, list_subjects, list_tags};
pub use download::download_original;
pub use envelope::{decode_envelope, decode_write_success, map_error_code, SynoError, SynoResponse};
pub use info::{pin_version, probe_capabilities};
pub use recycle::{
    delete_recycle_item, ensure_recycle_photos_path, list_recycle_photos, recycle_thumbnail, restore_recycle_item, trigger_reindex,
};
pub use search_filter::search_facets;
pub use thumbnail::fetch_thumbnail;
pub use transport::{build_client, fetch_server_cert_der, Transport};
pub use upload::upload_file;

#[cfg(test)]
mod facade_tests {
    #[test]
    fn reexports_are_reachable() {
        let _ = crate::login;
        let _ = crate::logout;
        let _ = crate::probe_capabilities;
        let _ = crate::pin_version;
        let _ = crate::list_items;
        let _ = crate::list_items_filtered;
        let _ = crate::filter_items;
        let _ = crate::list_albums;
        let _ = crate::create_album;
        let _ = crate::add_items;
        let _ = crate::remove_items;
        let _ = crate::delete_album;
        let _ = crate::permanent_delete;
        let _ = crate::list_recycle_photos;
        let _ = crate::restore_recycle_item;
        let _ = crate::delete_recycle_item;
        let _ = crate::recycle_thumbnail;
        let _ = crate::trigger_reindex;
        let _ = crate::decode_write_success;
        let _ = crate::search;
        let _ = crate::search_filtered;
        let _ = crate::search_facets;
        let _ = crate::list_people;
        let _ = crate::list_places;
        let _ = crate::list_subjects;
        let _ = crate::list_tags;
        let _ = crate::fetch_thumbnail;
        let _ = crate::download_original;
        let _ = crate::upload_file;
        let _ = crate::build_client;
        let _ = crate::fetch_server_cert_der;
        let _ = crate::decode_envelope::<serde_json::Value>;
        let _ = crate::map_error_code;
    }
}
