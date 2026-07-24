//! The UniFFI boundary crate exposing PhotosCore to Swift.

use std::sync::{Arc, Mutex};

use models::{ApiCapability, Connection, CoreError, CrawlProgress, Session};
use persistence::Store;
use synology_api::Transport;

uniffi::setup_scaffolding!("photoscore");

/// Trivial cross-boundary smoke function. Returns the core crate version.
/// Proves Swift can call into Rust over UniFFI before the full PhotosCore lands.
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// Implemented on the Swift side; called from Rust during crawl_space.
#[uniffi::export(callback_interface)]
pub trait FfiCrawlObserver: Send + Sync {
    fn on_progress(&self, progress: CrawlProgress);
}

/// Post-login connection state held inside the core.
struct Live {
    transport: Transport,
    session: Session,
    connection: Connection,
    capabilities: Vec<ApiCapability>,
}

/// The single UniFFI-exported facade. Swift holds one instance per app run.
///
/// `Store` wraps a `rusqlite::Connection`, whose internal statement cache uses
/// a `RefCell` and so is not `Sync`. UniFFI objects are shared across threads
/// as `Arc<Self>`, so `store` is held behind a `Mutex` (like `live`) rather
/// than bare, to satisfy `Send + Sync` and to make the cross-thread access
/// pattern explicit rather than accidental.
#[derive(uniffi::Object)]
pub struct PhotosCore {
    store: Mutex<Store>,
    cache_dir: String,
    live: Mutex<Option<Live>>,
}

#[uniffi::export]
impl PhotosCore {
    /// Construct with a local DB directory. Opens/creates SQLite + runs migrations.
    #[uniffi::constructor]
    pub fn new(db_dir: String, cache_dir: String) -> Result<Arc<Self>, CoreError> {
        let db_path = std::path::Path::new(&db_dir).join("photos.sqlite");
        let store = Store::open_at(&db_path)?;
        Ok(Arc::new(PhotosCore { store: Mutex::new(store), cache_dir, live: Mutex::new(None) }))
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn core_version_matches_cargo_pkg_version() {
        assert_eq!(crate::core_version(), env!("CARGO_PKG_VERSION"));
        assert_eq!(crate::core_version(), "0.1.0");
    }
}

#[cfg(test)]
mod core_tests {
    use super::*;

    #[test]
    fn new_opens_store() {
        let dir = std::env::temp_dir().join(format!("photoscore-new-{}", std::process::id()));
        let db = dir.join("db");
        let cache = dir.join("cache");
        std::fs::create_dir_all(&db).unwrap();
        std::fs::create_dir_all(&cache).unwrap();
        let _core = PhotosCore::new(db.to_string_lossy().into(), cache.to_string_lossy().into())
            .expect("core opens");
    }
}
