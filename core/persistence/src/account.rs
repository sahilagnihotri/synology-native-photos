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
    /// - No identity stored yet and an empty index: the identity is
    ///   recorded, nothing is cleared.
    /// - No identity stored yet but rows present (a database from before
    ///   this check): treated like a different account and cleared, because
    ///   nothing says whose rows they are. Costs one fresh crawl.
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
        // No stored identity means nobody can say whose rows these are (a
        // database from before this check, or the first launch after the
        // upgrade). Fail closed: adopt only an empty index, clear otherwise.
        let reset = stored.is_some() || self.index_has_rows()?;
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

    /// True when any NAS mirrored table holds data. Default `sync_state`
    /// rows (created on first read, no progress recorded) do not count.
    fn index_has_rows(&self) -> Result<bool, CoreError> {
        self.conn
            .query_row(
                "SELECT EXISTS (SELECT 1 FROM assets)
                     OR EXISTS (SELECT 1 FROM albums)
                     OR EXISTS (SELECT 1 FROM app_state)
                     OR EXISTS (SELECT 1 FROM sync_state
                                WHERE initial_crawl_complete != 0
                                   OR expected_total != 0
                                   OR last_offset != 0
                                   OR highest_seen_version IS NOT NULL
                                   OR last_crawl_at IS NOT NULL
                                   OR last_reconcile_at IS NOT NULL)",
                [],
                |r| r.get::<_, bool>(0),
            )
            .map_err(map_sql)
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

    /// An index bound to `identity` while empty, then filled.
    fn owned_by(identity: &str) -> Store {
        let store = Store::open_in_memory().unwrap();
        assert!(!store.bind_account(identity).unwrap());
        seed(store)
    }

    /// Rows with no recorded owner (a database from before the check).
    fn seeded() -> Store {
        seed(Store::open_in_memory().unwrap())
    }

    fn seed(store: Store) -> Store {
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

    /// A database written before the identity existed (or on the first
    /// launch after the upgrade) cannot say whose rows it holds, so they
    /// must not be shown to whoever signs in: fail closed and clear.
    #[test]
    fn first_bind_over_unowned_rows_clears_them() {
        let store = seeded();
        assert!(store.bind_account("https://nas-a:5001|alice").unwrap());
        assert_eq!(store.asset_count(Space::Personal).unwrap(), 0);
        assert!(store.fetch_albums(Space::Personal).unwrap().is_empty());
        assert_eq!(
            store
                .get_app_state(Space::Personal, "owned_album_id")
                .unwrap(),
            None
        );
        assert!(
            !store
                .load_sync_state(Space::Personal)
                .unwrap()
                .initial_crawl_complete
        );
        assert_eq!(
            store.account_identity().unwrap().as_deref(),
            Some("https://nas-a:5001|alice")
        );
    }

    /// An empty index (a fresh install, even one whose default sync_state
    /// rows were already created by a read) is adopted without a reset.
    #[test]
    fn first_bind_over_an_empty_index_adopts_it() {
        let store = Store::open_in_memory().unwrap();
        let _ = store.load_sync_state(Space::Personal).unwrap();
        assert!(!store.bind_account("https://nas-a:5001|alice").unwrap());
        assert_eq!(
            store.account_identity().unwrap().as_deref(),
            Some("https://nas-a:5001|alice")
        );
    }

    /// Each kind of mirrored data on its own is enough to make an unowned
    /// index count as someone's, so the first bind clears it. One case per
    /// branch of `index_has_rows`, so dropping any single branch fails here.
    #[test]
    fn first_bind_clears_an_index_holding_any_single_kind_of_row() {
        type Case = (&'static str, fn(&Store));
        let cases: [Case; 9] = [
            ("an asset", |s| s.upsert_assets(&[asset(1)]).unwrap()),
            ("an album", |s| {
                s.upsert_album(&Album {
                    id: 7,
                    name: "Trip".into(),
                    item_count: 0,
                    cover_cache_key: None,
                    cover_unit_id: None,
                    is_shared: false,
                    is_smart: false,
                    space: Space::Personal,
                })
                .unwrap()
            }),
            ("app state", |s| {
                s.set_app_state(Space::Personal, "owned_album_id", "7")
                    .unwrap()
            }),
            ("the crawl barrier", |s| {
                set_sync_column(s, "initial_crawl_complete = 1")
            }),
            ("an expected total", |s| {
                set_sync_column(s, "expected_total = 5")
            }),
            ("a crawl offset", |s| {
                set_sync_column(s, "last_offset = 200")
            }),
            ("a version watermark", |s| {
                set_sync_column(s, "highest_seen_version = 3")
            }),
            ("a crawl time", |s| set_sync_column(s, "last_crawl_at = 9")),
            ("a reconcile time", |s| {
                set_sync_column(s, "last_reconcile_at = 9")
            }),
        ];
        for (what, fill) in cases {
            let store = Store::open_in_memory().unwrap();
            fill(&store);
            assert!(
                store.bind_account("https://nas-a:5001|alice").unwrap(),
                "an unowned index holding only {what} must be cleared"
            );
        }
    }

    /// Writes one column of a default `sync_state` row directly, so each
    /// progress column can be set without the others.
    fn set_sync_column(store: &Store, assignment: &str) {
        store
            .conn
            .execute("INSERT OR IGNORE INTO sync_state (space) VALUES (0)", [])
            .unwrap();
        let changed = store
            .conn
            .execute(
                &format!("UPDATE sync_state SET {assignment} WHERE space = 0"),
                [],
            )
            .unwrap();
        assert_eq!(changed, 1);
    }

    #[test]
    fn same_account_keeps_the_index() {
        let store = owned_by("https://nas-a:5001|alice");
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
        let store = owned_by("https://nas-a:5001|alice");
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
        let store = owned_by("https://nas-a:5001|alice");
        assert!(store.bind_account("https://nas-b:5001|alice").unwrap());
        assert_eq!(store.asset_count(Space::Personal).unwrap(), 0);
    }
}
