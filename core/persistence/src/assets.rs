//! Asset upsert, windowed fetch, and per-space count.
//!
//! `fetch_assets` is the query the grid pages against: it orders rows to match
//! `idx_assets_space_taken` (space, taken_at DESC, server_id DESC) so paging by
//! offset/limit stays cheap even at 100k-asset libraries, and the `server_id`
//! tiebreak keeps paging stable when multiple assets share the same `taken_at`.

use crate::schema::map_sql;
use crate::Store;
use models::{Asset, CoreError, MediaKind, Space};
use rusqlite::params;

/// Converts `Space` to its storage representation (0 Personal, 1 Shared).
///
/// This is the single place in the crate that knows the Space<->i64 mapping;
/// every module that needs to store or query by space should call this pair
/// instead of re-deriving the encoding.
pub(crate) fn space_to_int(space: Space) -> i64 {
    match space {
        Space::Personal => 0,
        Space::Shared => 1,
    }
}

pub(crate) fn int_to_space(v: i64) -> Space {
    match v {
        1 => Space::Shared,
        _ => Space::Personal,
    }
}

pub(crate) fn media_kind_to_int(k: MediaKind) -> i64 {
    match k {
        MediaKind::Photo => 0,
        MediaKind::Video => 1,
        MediaKind::Unknown => 2,
    }
}

pub(crate) fn int_to_media_kind(v: i64) -> MediaKind {
    match v {
        0 => MediaKind::Photo,
        1 => MediaKind::Video,
        _ => MediaKind::Unknown,
    }
}

pub(crate) fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

impl Store {
    /// Inserts a new asset row or updates it in place, keyed on `(space, server_id)`.
    /// Re-crawling the same server item never duplicates a row.
    pub fn upsert_asset(&self, asset: &Asset) -> Result<(), CoreError> {
        self.conn
            .execute(
                "INSERT INTO assets
                    (space, server_id, cache_key, filename, media_kind,
                     taken_at, added_at, width, height, file_size, server_version, updated_at)
                 VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)
                 ON CONFLICT(space, server_id) DO UPDATE SET
                     cache_key      = excluded.cache_key,
                     filename       = excluded.filename,
                     media_kind     = excluded.media_kind,
                     taken_at       = excluded.taken_at,
                     added_at       = excluded.added_at,
                     width          = excluded.width,
                     height         = excluded.height,
                     file_size      = excluded.file_size,
                     server_version = excluded.server_version,
                     updated_at     = excluded.updated_at",
                params![
                    space_to_int(asset.space),
                    asset.id,
                    asset.cache_key,
                    asset.filename,
                    media_kind_to_int(asset.media_kind),
                    asset.taken_at,
                    asset.added_at,
                    asset.width,
                    asset.height,
                    asset.file_size,
                    asset.server_version,
                    now_secs(),
                ],
            )
            .map_err(map_sql)?;
        Ok(())
    }

    /// Upserts a batch of assets in a single transaction. Used by the crawl/sync
    /// engine so a page of server results lands atomically.
    pub fn upsert_assets(&self, assets: &[Asset]) -> Result<(), CoreError> {
        self.conn.execute_batch("BEGIN").map_err(map_sql)?;
        for a in assets {
            if let Err(e) = self.upsert_asset(a) {
                let _ = self.conn.execute_batch("ROLLBACK");
                return Err(e);
            }
        }
        self.conn.execute_batch("COMMIT").map_err(map_sql)?;
        Ok(())
    }

    /// Total number of assets stored for `space`.
    pub fn asset_count(&self, space: Space) -> Result<u64, CoreError> {
        let n: i64 = self
            .conn
            .query_row(
                "SELECT COUNT(*) FROM assets WHERE space = ?1",
                params![space_to_int(space)],
                |r| r.get(0),
            )
            .map_err(map_sql)?;
        Ok(n as u64)
    }

    /// Deletes every local row in `space` whose `server_id` is not in
    /// `keep_ids`. Used by delta reconciliation to mirror server-side
    /// deletions: after paging the *entire* current server listing for a
    /// space, any local row absent from that listing is stale and is removed
    /// so the local mirror matches server reality. This only ever removes
    /// local rows; it never talks to the NAS and never deletes anything
    /// server-side.
    pub fn delete_assets_not_in(&self, space: Space, keep_ids: &[i64]) -> Result<u64, CoreError> {
        self.conn.execute_batch("BEGIN").map_err(map_sql)?;
        let placeholders: Vec<String> = (0..keep_ids.len()).map(|i| format!("?{}", i + 2)).collect();
        let sql = format!(
            "DELETE FROM assets WHERE space = ?1 AND server_id NOT IN ({})",
            placeholders.join(",")
        );
        let mut params_vec: Vec<&dyn rusqlite::ToSql> = Vec::with_capacity(keep_ids.len() + 1);
        let space_param = space_to_int(space);
        params_vec.push(&space_param);
        for id in keep_ids {
            params_vec.push(id);
        }
        let deleted = if keep_ids.is_empty() {
            // No placeholders to bind: everything in the space is stale.
            self.conn
                .execute("DELETE FROM assets WHERE space = ?1", params![space_to_int(space)])
        } else {
            self.conn.execute(&sql, params_vec.as_slice())
        };
        let deleted = match deleted {
            Ok(n) => n,
            Err(e) => {
                let _ = self.conn.execute_batch("ROLLBACK");
                return Err(map_sql(e));
            }
        };
        self.conn.execute_batch("COMMIT").map_err(map_sql)?;
        Ok(deleted as u64)
    }

    /// Returns a window of assets for `space`, newest-first by `taken_at` with
    /// `server_id` as a tiebreak (NULLs last). The ORDER BY matches
    /// `idx_assets_space_taken` exactly, so this stays an index-only scan as the
    /// library grows, and the tiebreak guarantees paging by offset/limit never
    /// skips or duplicates a row when two assets share the same `taken_at`.
    pub fn fetch_assets(&self, space: Space, offset: u32, limit: u32) -> Result<Vec<Asset>, CoreError> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT server_id, cache_key, filename, media_kind, taken_at,
                        added_at, width, height, file_size, server_version, space
                 FROM assets
                 WHERE space = ?1
                 ORDER BY (taken_at IS NULL) ASC, taken_at DESC, server_id DESC
                 LIMIT ?2 OFFSET ?3",
            )
            .map_err(map_sql)?;
        let rows = stmt
            .query_map(
                params![space_to_int(space), limit as i64, offset as i64],
                |r| {
                    Ok(Asset {
                        id: r.get(0)?,
                        cache_key: r.get(1)?,
                        filename: r.get(2)?,
                        media_kind: int_to_media_kind(r.get::<_, i64>(3)?),
                        taken_at: r.get(4)?,
                        added_at: r.get(5)?,
                        width: r.get::<_, Option<i64>>(6)?.map(|v| v as u32),
                        height: r.get::<_, Option<i64>>(7)?.map(|v| v as u32),
                        file_size: r.get::<_, Option<i64>>(8)?.map(|v| v as u64),
                        server_version: r.get(9)?,
                        space: int_to_space(r.get::<_, i64>(10)?),
                    })
                },
            )
            .map_err(map_sql)?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row.map_err(map_sql)?);
        }
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use crate::Store;
    use models::{Asset, MediaKind, Space};

    fn asset(space: Space, id: i64, taken: Option<i64>, ver: Option<i64>) -> Asset {
        Asset {
            id,
            cache_key: format!("ck{id}"),
            filename: format!("IMG_{id}.jpg"),
            media_kind: MediaKind::Photo,
            taken_at: taken,
            added_at: Some(1000),
            width: Some(4000),
            height: Some(3000),
            file_size: Some(2_000_000),
            space,
            server_version: ver,
        }
    }

    #[test]
    fn upsert_then_count_and_fetch_newest_first() {
        let store = Store::open_in_memory().unwrap();
        store.upsert_asset(&asset(Space::Personal, 1, Some(100), Some(1))).unwrap();
        store.upsert_asset(&asset(Space::Personal, 2, Some(300), Some(1))).unwrap();
        store.upsert_asset(&asset(Space::Personal, 3, Some(200), Some(1))).unwrap();
        store.upsert_asset(&asset(Space::Shared, 9, Some(999), Some(1))).unwrap();
        assert_eq!(store.asset_count(Space::Personal).unwrap(), 3);
        assert_eq!(store.asset_count(Space::Shared).unwrap(), 1);
        let page = store.fetch_assets(Space::Personal, 0, 10).unwrap();
        let ids: Vec<i64> = page.iter().map(|a| a.id).collect();
        assert_eq!(ids, vec![2, 3, 1]);
        assert_eq!(page[0].space, Space::Personal);
    }

    #[test]
    fn upsert_is_idempotent_on_space_server_id() {
        let store = Store::open_in_memory().unwrap();
        store.upsert_asset(&asset(Space::Personal, 1, Some(100), Some(1))).unwrap();
        let mut updated = asset(Space::Personal, 1, Some(555), Some(2));
        updated.cache_key = "ck1-new".into();
        store.upsert_asset(&updated).unwrap();
        assert_eq!(store.asset_count(Space::Personal).unwrap(), 1);
        let page = store.fetch_assets(Space::Personal, 0, 10).unwrap();
        assert_eq!(page[0].cache_key, "ck1-new");
        assert_eq!(page[0].taken_at, Some(555));
        assert_eq!(page[0].server_version, Some(2));
    }

    #[test]
    fn null_taken_at_sorts_last() {
        let store = Store::open_in_memory().unwrap();
        store.upsert_asset(&asset(Space::Personal, 1, Some(100), Some(1))).unwrap();
        store.upsert_asset(&asset(Space::Personal, 2, None, Some(1))).unwrap();
        let ids: Vec<i64> = store
            .fetch_assets(Space::Personal, 0, 10)
            .unwrap()
            .iter()
            .map(|a| a.id)
            .collect();
        assert_eq!(ids, vec![1, 2]);
    }

    #[test]
    fn windowing_offset_limit() {
        let store = Store::open_in_memory().unwrap();
        for id in 1..=5 {
            store.upsert_asset(&asset(Space::Personal, id, Some(id * 10), Some(1))).unwrap();
        }
        let ids: Vec<i64> = store
            .fetch_assets(Space::Personal, 1, 2)
            .unwrap()
            .iter()
            .map(|a| a.id)
            .collect();
        assert_eq!(ids, vec![4, 3]);
    }

    #[test]
    fn upserting_same_asset_again_does_not_increase_count() {
        let store = Store::open_in_memory().unwrap();
        for _ in 0..3 {
            store.upsert_asset(&asset(Space::Personal, 1, Some(100), Some(1))).unwrap();
        }
        assert_eq!(store.asset_count(Space::Personal).unwrap(), 1);
    }

    #[test]
    fn upsert_assets_batch_is_idempotent() {
        let store = Store::open_in_memory().unwrap();
        let batch: Vec<Asset> = (1..=10).map(|id| asset(Space::Personal, id, Some(id * 10), Some(1))).collect();
        store.upsert_assets(&batch).unwrap();
        store.upsert_assets(&batch).unwrap();
        assert_eq!(store.asset_count(Space::Personal).unwrap(), 10);
    }

    /// Paging must be stable (no skips, no duplicates) even when several assets
    /// share the same `taken_at`, because the grid pages purely by offset/limit
    /// and relies on the `server_id DESC` tiebreak to keep a total order.
    #[test]
    fn paging_with_tied_taken_at_has_no_duplicates_or_skips() {
        let store = Store::open_in_memory().unwrap();
        // 12 assets: ids 1..=6 all share taken_at=100, ids 7..=12 all share taken_at=200.
        for id in 1..=6 {
            store.upsert_asset(&asset(Space::Personal, id, Some(100), Some(1))).unwrap();
        }
        for id in 7..=12 {
            store.upsert_asset(&asset(Space::Personal, id, Some(200), Some(1))).unwrap();
        }
        assert_eq!(store.asset_count(Space::Personal).unwrap(), 12);

        let mut seen: Vec<i64> = Vec::new();
        let page_size = 5u32;
        let mut offset = 0u32;
        loop {
            let page = store.fetch_assets(Space::Personal, offset, page_size).unwrap();
            if page.is_empty() {
                break;
            }
            seen.extend(page.iter().map(|a| a.id));
            offset += page_size;
        }

        // Expect exactly the 200-taken_at group (12..7 descending server_id) followed
        // by the 100-taken_at group (6..1 descending server_id) with no repeats.
        let expected: Vec<i64> = vec![12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1];
        assert_eq!(seen, expected);

        let unique: std::collections::HashSet<i64> = seen.iter().copied().collect();
        assert_eq!(unique.len(), seen.len(), "paging produced duplicates");
        assert_eq!(unique.len(), 12, "paging skipped an asset");
    }

    #[test]
    fn fetch_assets_does_not_leak_across_spaces() {
        let store = Store::open_in_memory().unwrap();
        store.upsert_asset(&asset(Space::Personal, 1, Some(100), Some(1))).unwrap();
        store.upsert_asset(&asset(Space::Shared, 2, Some(200), Some(1))).unwrap();
        store.upsert_asset(&asset(Space::Shared, 3, Some(300), Some(1))).unwrap();

        let personal = store.fetch_assets(Space::Personal, 0, 100).unwrap();
        assert_eq!(personal.len(), 1);
        assert!(personal.iter().all(|a| a.space == Space::Personal));
        assert!(personal.iter().all(|a| a.id != 2 && a.id != 3));

        let shared = store.fetch_assets(Space::Shared, 0, 100).unwrap();
        assert_eq!(shared.len(), 2);
        assert!(shared.iter().all(|a| a.space == Space::Shared));
    }

    #[test]
    fn delete_assets_not_in_removes_only_stale_rows_in_space() {
        let store = Store::open_in_memory().unwrap();
        store.upsert_asset(&asset(Space::Personal, 1, Some(100), Some(1))).unwrap();
        store.upsert_asset(&asset(Space::Personal, 2, Some(200), Some(1))).unwrap();
        store.upsert_asset(&asset(Space::Personal, 3, Some(300), Some(1))).unwrap();
        store.upsert_asset(&asset(Space::Shared, 9, Some(999), Some(1))).unwrap();

        let deleted = store.delete_assets_not_in(Space::Personal, &[1, 3]).unwrap();
        assert_eq!(deleted, 1);

        let ids: Vec<i64> = store.fetch_assets(Space::Personal, 0, 10).unwrap().iter().map(|a| a.id).collect();
        assert_eq!(ids, vec![3, 1]);
        // Shared space untouched by a Personal-space sweep.
        assert_eq!(store.asset_count(Space::Shared).unwrap(), 1);
    }

    #[test]
    fn delete_assets_not_in_with_empty_keep_list_clears_the_space() {
        let store = Store::open_in_memory().unwrap();
        store.upsert_asset(&asset(Space::Personal, 1, Some(100), Some(1))).unwrap();
        store.upsert_asset(&asset(Space::Shared, 2, Some(200), Some(1))).unwrap();

        let deleted = store.delete_assets_not_in(Space::Personal, &[]).unwrap();
        assert_eq!(deleted, 1);
        assert_eq!(store.asset_count(Space::Personal).unwrap(), 0);
        assert_eq!(store.asset_count(Space::Shared).unwrap(), 1);
    }

    #[test]
    fn round_trip_preserves_all_fields() {
        let store = Store::open_in_memory().unwrap();
        let original = Asset {
            id: 77,
            cache_key: "ck-round-trip".to_string(),
            filename: "IMG_0077.HEIC".to_string(),
            media_kind: MediaKind::Video,
            taken_at: Some(1_700_000_123),
            added_at: Some(1_700_000_500),
            width: Some(1920),
            height: Some(1080),
            file_size: Some(12_345_678),
            space: Space::Shared,
            server_version: Some(4),
        };
        store.upsert_asset(&original).unwrap();
        let page = store.fetch_assets(Space::Shared, 0, 10).unwrap();
        assert_eq!(page.len(), 1);
        let round_tripped = &page[0];
        assert_eq!(round_tripped.id, original.id);
        assert_eq!(round_tripped.cache_key, original.cache_key);
        assert_eq!(round_tripped.filename, original.filename);
        assert_eq!(round_tripped.media_kind, original.media_kind);
        assert_eq!(round_tripped.taken_at, original.taken_at);
        assert_eq!(round_tripped.added_at, original.added_at);
        assert_eq!(round_tripped.width, original.width);
        assert_eq!(round_tripped.height, original.height);
        assert_eq!(round_tripped.file_size, original.file_size);
        assert_eq!(round_tripped.space, original.space);
        assert_eq!(round_tripped.server_version, original.server_version);
    }
}
