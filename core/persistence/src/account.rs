//! Ties the local index to one NAS account (host plus username).
//!
//! The index is a mirror of exactly one account's library. Signing in to a
//! different NAS, or as a different user on the same NAS, must never show the
//! previous account's rows, album ids or crawl cursor as if they were the new
//! account's. The identity of the account the index belongs to lives in
//! `schema_meta` under `account_identity` (an existing key/value table, so no
//! schema change and no migration step is needed).

use crate::schema::map_sql;
use crate::Store;
use models::CoreError;
use rusqlite::{params, OptionalExtension};

const ACCOUNT_KEY: &str = "account_identity";

impl Store {
    /// The account identity the index is bound to, or `None` before the
    /// first bind (a fresh database, or one written before this existed).
    pub fn account_identity(&self) -> Result<Option<String>, CoreError> {
        self.conn
            .query_row(
                "SELECT value FROM schema_meta WHERE key = ?1",
                params![ACCOUNT_KEY],
                |r| r.get::<_, String>(0),
            )
            .optional()
            .map_err(map_sql)
    }

    /// Binds the index to `identity`. Returns `true` when the index belonged
    /// to a DIFFERENT account and was cleared.
    ///
    /// - Same identity: nothing changes.
    /// - No identity stored yet: the existing rows are adopted as this
    ///   account's (a database from before this check was written by the one
    ///   account the app was used with) and the identity is recorded.
    /// - Different identity: every NAS mirrored table is emptied (assets,
    ///   albums, per space app state such as owned album ids and the
    ///   reconcile sweep fingerprint, and the crawl cursor and barrier), so
    ///   the next crawl starts fresh from page zero. Local index only;
    ///   nothing on any NAS is touched. All in one transaction.
    pub fn bind_account(&self, identity: &str) -> Result<bool, CoreError> {
        let stored = self.account_identity()?;
        if stored.as_deref() == Some(identity) {
            return Ok(false);
        }
        let reset = stored.is_some();
        let tx = self.conn.unchecked_transaction().map_err(map_sql)?;
        if reset {
            tx.execute_batch(
                "DELETE FROM assets;
                 DELETE FROM albums;
                 DELETE FROM app_state;
                 DELETE FROM sync_state;",
            )
            .map_err(map_sql)?;
        }
        tx.execute(
            "INSERT INTO schema_meta (key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![ACCOUNT_KEY, identity],
        )
        .map_err(map_sql)?;
        tx.commit().map_err(map_sql)?;
        Ok(reset)
    }
}

#[cfg(test)]
mod tests {
    use crate::Store;
    use models::{Album, Asset, MediaKind, Space};

    fn asset(id: i64) -> Asset {
        Asset {
            id,
            unit_id: id + 9000,
            cache_key: format!("ck{id}"),
            filename: format!("IMG_{id}.jpg"),
            media_kind: MediaKind::Photo,
            space: Space::Personal,
            server_version: Some(1),
            ..Default::default()
        }
    }

    fn seeded() -> Store {
        let store = Store::open_in_memory().unwrap();
        store.upsert_assets(&[asset(1), asset(2)]).unwrap();
        store
            .upsert_album(&Album {
                id: 7,
                name: "Trip".into(),
                item_count: 2,
                cover_cache_key: None,
                cover_unit_id: None,
                is_shared: false,
                is_smart: false,
                space: Space::Personal,
            })
            .unwrap();
        store
            .set_app_state(Space::Personal, "owned_album_id", "7")
            .unwrap();
        store.set_crawl_complete(Space::Personal, true, 1).unwrap();
        store
    }

    #[test]
    fn first_bind_adopts_the_existing_rows() {
        let store = seeded();
        assert!(!store.bind_account("https://nas-a:5001|alice").unwrap());
        assert_eq!(store.asset_count(Space::Personal).unwrap(), 2);
        assert_eq!(
            store.account_identity().unwrap().as_deref(),
            Some("https://nas-a:5001|alice")
        );
    }

    #[test]
    fn same_account_keeps_the_index() {
        let store = seeded();
        store.bind_account("https://nas-a:5001|alice").unwrap();
        assert!(!store.bind_account("https://nas-a:5001|alice").unwrap());
        assert_eq!(store.asset_count(Space::Personal).unwrap(), 2);
        assert!(
            store
                .load_sync_state(Space::Personal)
                .unwrap()
                .initial_crawl_complete
        );
    }

    #[test]
    fn a_different_account_clears_the_index_and_the_crawl_barrier() {
        let store = seeded();
        store.bind_account("https://nas-a:5001|alice").unwrap();
        assert!(store.bind_account("https://nas-a:5001|bob").unwrap());
        assert_eq!(store.asset_count(Space::Personal).unwrap(), 0);
        assert!(store.fetch_albums(Space::Personal).unwrap().is_empty());
        assert_eq!(
            store
                .get_app_state(Space::Personal, "owned_album_id")
                .unwrap(),
            None
        );
        let sync = store.load_sync_state(Space::Personal).unwrap();
        assert!(!sync.initial_crawl_complete);
        assert_eq!(sync.last_offset, 0);
        assert_eq!(
            store.account_identity().unwrap().as_deref(),
            Some("https://nas-a:5001|bob")
        );
        // The schema version mirror shares the table and must survive.
        assert!(store.schema_version().is_ok());
    }

    #[test]
    fn a_different_host_with_the_same_username_also_clears() {
        let store = seeded();
        store.bind_account("https://nas-a:5001|alice").unwrap();
        assert!(store.bind_account("https://nas-b:5001|alice").unwrap());
        assert_eq!(store.asset_count(Space::Personal).unwrap(), 0);
    }
}
