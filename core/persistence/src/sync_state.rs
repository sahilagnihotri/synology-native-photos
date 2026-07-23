//! Per-space sync bookkeeping and the initial-crawl-complete barrier.
//!
//! `sync_state` holds one row per space: the resumable crawl cursor
//! (`last_offset`/`last_page_limit`), the server-reported `expected_total`,
//! a highest-seen server version/id watermark for delta sync, and the
//! `initial_crawl_complete` barrier itself. The barrier starts down (false)
//! and only the sync engine flips it up via `set_crawl_complete(space, true, ...)`
//! once a crawl has genuinely finished; a partial or interrupted crawl leaves
//! it down so the UI never presents a partial library as complete.

use crate::assets::space_to_int;
use crate::schema::map_sql;
use crate::Store;
use models::{CoreError, CrawlProgress, Space};
use rusqlite::{params, OptionalExtension};

/// Persisted sync bookkeeping for a single space.
#[derive(Clone, Debug)]
pub struct SyncStateRow {
    pub space: Space,
    /// The crawl-completion barrier. False until a crawl has fully finished;
    /// the UI must treat the library as partial while this is false.
    pub initial_crawl_complete: bool,
    pub expected_total: u64,
    pub last_offset: u32,
    pub last_page_limit: u32,
    pub highest_seen_version: Option<i64>,
    pub last_crawl_at: Option<i64>,
    pub last_reconcile_at: Option<i64>,
}

/// Ensures a `sync_state` row exists for `space` so subsequent UPDATEs are not
/// no-ops. Safe to call repeatedly: `INSERT OR IGNORE` is a no-op once the row
/// exists, matching the idempotent-migration convention used elsewhere in this
/// crate.
fn ensure_row(store: &Store, space: Space) -> Result<(), CoreError> {
    store
        .conn
        .execute(
            "INSERT OR IGNORE INTO sync_state (space) VALUES (?1)",
            params![space_to_int(space)],
        )
        .map_err(map_sql)?;
    Ok(())
}

impl Store {
    /// Reads the sync-state row for `space`, or a barrier-down default if no
    /// crawl has ever touched this space.
    pub fn load_sync_state(&self, space: Space) -> Result<SyncStateRow, CoreError> {
        let row = self
            .conn
            .query_row(
                "SELECT initial_crawl_complete, expected_total, last_offset,
                        last_page_limit, highest_seen_version, last_crawl_at, last_reconcile_at
                 FROM sync_state WHERE space = ?1",
                params![space_to_int(space)],
                |r| {
                    Ok((
                        r.get::<_, i64>(0)?,
                        r.get::<_, i64>(1)?,
                        r.get::<_, i64>(2)?,
                        r.get::<_, i64>(3)?,
                        r.get::<_, Option<i64>>(4)?,
                        r.get::<_, Option<i64>>(5)?,
                        r.get::<_, Option<i64>>(6)?,
                    ))
                },
            )
            .optional()
            .map_err(map_sql)?;
        match row {
            Some((complete, total, offset, limit, hv, lca, lra)) => Ok(SyncStateRow {
                space,
                initial_crawl_complete: complete != 0,
                expected_total: total as u64,
                last_offset: offset as u32,
                last_page_limit: limit as u32,
                highest_seen_version: hv,
                last_crawl_at: lca,
                last_reconcile_at: lra,
            }),
            None => Ok(SyncStateRow {
                space,
                initial_crawl_complete: false,
                expected_total: 0,
                last_offset: 0,
                last_page_limit: 0,
                highest_seen_version: None,
                last_crawl_at: None,
                last_reconcile_at: None,
            }),
        }
    }

    /// Persists the resumable crawl cursor: how far paging has gotten
    /// (`last_offset`/`last_page_limit`) and the server's current
    /// `expected_total`. Does not touch the completion barrier, so a crawl
    /// that is still in progress keeps reporting `initial_crawl_complete == false`
    /// no matter how many cursor updates land.
    pub fn save_cursor(
        &self,
        space: Space,
        last_offset: u32,
        last_page_limit: u32,
        expected_total: u64,
    ) -> Result<(), CoreError> {
        ensure_row(self, space)?;
        self.conn
            .execute(
                "UPDATE sync_state SET last_offset = ?2, last_page_limit = ?3, expected_total = ?4
                 WHERE space = ?1",
                params![
                    space_to_int(space),
                    last_offset as i64,
                    last_page_limit as i64,
                    expected_total as i64,
                ],
            )
            .map_err(map_sql)?;
        Ok(())
    }

    /// Flips the initial-crawl-complete barrier. Only the sync engine should
    /// call this with `complete = true`, and only once a crawl has genuinely
    /// finished (reconciling the final count against `expected_total` is the
    /// sync engine's job, not this module's); this method just stores the
    /// value it is given.
    pub fn set_crawl_complete(&self, space: Space, complete: bool, at_secs: i64) -> Result<(), CoreError> {
        ensure_row(self, space)?;
        self.conn
            .execute(
                "UPDATE sync_state SET initial_crawl_complete = ?2, last_crawl_at = ?3 WHERE space = ?1",
                params![space_to_int(space), complete as i64, at_secs],
            )
            .map_err(map_sql)?;
        Ok(())
    }

    /// Ratchets the highest-seen server version/id watermark upward only.
    /// Delta sync compares against server id/version, never wall-clock, so an
    /// out-of-order or stale call can never move the watermark backward.
    pub fn set_highest_version(&self, space: Space, version: i64) -> Result<(), CoreError> {
        ensure_row(self, space)?;
        self.conn
            .execute(
                "UPDATE sync_state
                 SET highest_seen_version =
                     CASE WHEN highest_seen_version IS NULL OR highest_seen_version < ?2
                          THEN ?2 ELSE highest_seen_version END
                 WHERE space = ?1",
                params![space_to_int(space), version],
            )
            .map_err(map_sql)?;
        Ok(())
    }

    /// Records when a reconciliation pass (final count vs. `expected_total`)
    /// last ran for `space`.
    pub fn set_reconcile_at(&self, space: Space, at_secs: i64) -> Result<(), CoreError> {
        ensure_row(self, space)?;
        self.conn
            .execute(
                "UPDATE sync_state SET last_reconcile_at = ?2 WHERE space = ?1",
                params![space_to_int(space), at_secs],
            )
            .map_err(map_sql)?;
        Ok(())
    }

    /// Reads back the persisted sync state as UI-facing crawl progress:
    /// `done` is the live row count in `assets`, `total` is the server's
    /// last-known `expected_total`, and `complete` is the barrier. This is
    /// the only place the barrier value should reach the UI layer.
    pub fn crawl_progress(&self, space: Space) -> Result<CrawlProgress, CoreError> {
        let state = self.load_sync_state(space)?;
        let done = self.asset_count(space)?;
        Ok(CrawlProgress {
            space,
            done,
            total: state.expected_total,
            complete: state.initial_crawl_complete,
        })
    }
}

#[cfg(test)]
mod tests {
    use crate::Store;
    use models::Space;

    #[test]
    fn default_state_when_no_row() {
        let store = Store::open_in_memory().unwrap();
        let s = store.load_sync_state(Space::Personal).unwrap();
        assert!(!s.initial_crawl_complete);
        assert_eq!(s.expected_total, 0);
        assert_eq!(s.last_offset, 0);
        assert_eq!(s.highest_seen_version, None);
    }

    #[test]
    fn save_cursor_then_reload() {
        let store = Store::open_in_memory().unwrap();
        store.save_cursor(Space::Personal, 200, 100, 1500).unwrap();
        let s = store.load_sync_state(Space::Personal).unwrap();
        assert_eq!(s.last_offset, 200);
        assert_eq!(s.last_page_limit, 100);
        assert_eq!(s.expected_total, 1500);
        assert!(!s.initial_crawl_complete);
    }

    #[test]
    fn spaces_are_independent_rows() {
        let store = Store::open_in_memory().unwrap();
        store.save_cursor(Space::Personal, 50, 50, 300).unwrap();
        store.save_cursor(Space::Shared, 10, 50, 80).unwrap();
        assert_eq!(store.load_sync_state(Space::Personal).unwrap().last_offset, 50);
        assert_eq!(store.load_sync_state(Space::Shared).unwrap().last_offset, 10);
        assert_eq!(store.load_sync_state(Space::Shared).unwrap().expected_total, 80);
    }

    #[test]
    fn set_complete_and_highest_version_and_progress() {
        let store = Store::open_in_memory().unwrap();
        store.save_cursor(Space::Personal, 0, 100, 0).unwrap();
        store.set_highest_version(Space::Personal, 42).unwrap();
        store.set_crawl_complete(Space::Personal, true, 9999).unwrap();
        let s = store.load_sync_state(Space::Personal).unwrap();
        assert!(s.initial_crawl_complete);
        assert_eq!(s.highest_seen_version, Some(42));
        assert_eq!(s.last_crawl_at, Some(9999));
        store.save_cursor(Space::Personal, 100, 100, 7).unwrap();
        let p = store.crawl_progress(Space::Personal).unwrap();
        assert_eq!(p.total, 7);
        assert!(p.complete);
        assert_eq!(p.space, Space::Personal);
    }
}
