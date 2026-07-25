//! Asset upsert, windowed fetch, and per-space count.
//!
//! `fetch_assets` is the query the grid pages against: it orders rows to match
//! `idx_assets_space_taken` (space, taken_at DESC, server_id DESC) so paging by
//! offset/limit stays cheap even at 100k-asset libraries, and the `server_id`
//! tiebreak keeps paging stable when multiple assets share the same `taken_at`.

use crate::schema::map_sql;
use crate::Store;
use models::{Asset, CoreError, DayCount, MediaKind, Space};
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

/// Builds the shared `WHERE` clause and its positional bind params for the
/// Quick Filter reads (`filter_assets` / `filter_count`). `space` and
/// `in_trash = 0` are always present; each optional facet (media kind, a
/// `taken_at` floor/ceiling, a minimum rating) appends its clause ONLY when
/// `Some`, so an all-`None` filter collapses to exactly the predicate
/// `fetch_assets`/`asset_count` use. That is what makes an unfiltered Quick
/// Filter behave identically to the plain library grid.
///
/// Params are returned as owned boxes so both callers can bind them
/// positionally (anonymous `?`, filled in declaration order) via
/// `params_from_iter` and append their own `LIMIT`/`OFFSET` afterwards, without
/// re-deriving the space/media-kind integer encodings. `media_kind` binds via
/// `media_kind_to_int`, matching exactly how `upsert_asset` writes the column.
fn build_filter_where(
    space: Space,
    media_kind: Option<MediaKind>,
    taken_after: Option<i64>,
    taken_before: Option<i64>,
    min_rating: Option<u8>,
) -> (String, Vec<Box<dyn rusqlite::ToSql>>) {
    let mut clause = String::from("space = ? AND in_trash = 0");
    let mut params: Vec<Box<dyn rusqlite::ToSql>> = vec![Box::new(space_to_int(space))];
    if let Some(kind) = media_kind {
        clause.push_str(" AND media_kind = ?");
        params.push(Box::new(media_kind_to_int(kind)));
    }
    if let Some(after) = taken_after {
        clause.push_str(" AND taken_at >= ?");
        params.push(Box::new(after));
    }
    if let Some(before) = taken_before {
        clause.push_str(" AND taken_at <= ?");
        params.push(Box::new(before));
    }
    if let Some(rating) = min_rating {
        clause.push_str(" AND rating >= ?");
        params.push(Box::new(i64::from(rating)));
    }
    (clause, params)
}

/// The asset columns, in the exact order `row_to_asset` reads them. Both
/// windowed reads (`fetch_assets`, `fetch_trash`) select this list verbatim so
/// the positional row mapping stays valid and the two queries can never drift
/// out of column order as the model grows.
const ASSET_SELECT_COLUMNS: &str = "server_id, unit_id, cache_key, filename, media_kind, taken_at, \
     added_at, width, height, file_size, server_version, space, \
     rating, description, camera, aperture, exposure_time, focal_length, \
     iso, lens, duration, framerate, video_codec, container_type";

/// Maps one row selected in `ASSET_SELECT_COLUMNS` order into an `Asset`.
/// Shared by `fetch_assets` and `fetch_trash` so the (now 24-field) mapping
/// lives in exactly one place. `in_trash`/`trashed_at` are intentionally not
/// read back: they are storage-only bookkeeping that partitions the two
/// queries, never surfaced on the `Asset` model.
fn row_to_asset(r: &rusqlite::Row) -> rusqlite::Result<Asset> {
    Ok(Asset {
        id: r.get(0)?,
        unit_id: r.get(1)?,
        cache_key: r.get(2)?,
        filename: r.get(3)?,
        media_kind: int_to_media_kind(r.get::<_, i64>(4)?),
        taken_at: r.get(5)?,
        added_at: r.get(6)?,
        width: r.get::<_, Option<i64>>(7)?.map(|v| v as u32),
        height: r.get::<_, Option<i64>>(8)?.map(|v| v as u32),
        file_size: r.get::<_, Option<i64>>(9)?.map(|v| v as u64),
        server_version: r.get(10)?,
        space: int_to_space(r.get::<_, i64>(11)?),
        rating: r.get::<_, i64>(12)? as i32,
        description: r.get(13)?,
        camera: r.get(14)?,
        aperture: r.get(15)?,
        exposure_time: r.get(16)?,
        focal_length: r.get(17)?,
        iso: r.get(18)?,
        lens: r.get(19)?,
        duration: r.get(20)?,
        framerate: r.get(21)?,
        video_codec: r.get(22)?,
        container_type: r.get(23)?,
    })
}

impl Store {
    /// Inserts a new asset row or updates it in place, keyed on `(space, server_id)`.
    /// Re-crawling the same server item never duplicates a row.
    pub fn upsert_asset(&self, asset: &Asset) -> Result<(), CoreError> {
        // NOTE: `in_trash` / `trashed_at` (schema v2) are deliberately absent
        // from the ON CONFLICT DO UPDATE SET below. A re-crawl re-upserts an
        // asset with server-derived fields only; it must NEVER reach in and
        // un-trash an item the user moved to the app trash. Leaving those two
        // columns out of the SET is exactly what preserves them across a
        // re-crawl (regression-tested in `upsert_preserves_trash_flag_*`). The
        // v3 metadata columns ARE in the SET so a re-crawl refreshes EXIF/
        // rating/video metadata as the NAS reports it.
        self.conn
            .execute(
                "INSERT INTO assets
                    (space, server_id, unit_id, cache_key, filename, media_kind,
                     taken_at, added_at, width, height, file_size, server_version,
                     rating, description, camera, aperture, exposure_time, focal_length,
                     iso, lens, duration, framerate, video_codec, container_type, updated_at)
                 VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25)
                 ON CONFLICT(space, server_id) DO UPDATE SET
                     unit_id        = excluded.unit_id,
                     cache_key      = excluded.cache_key,
                     filename       = excluded.filename,
                     media_kind     = excluded.media_kind,
                     taken_at       = excluded.taken_at,
                     added_at       = excluded.added_at,
                     width          = excluded.width,
                     height         = excluded.height,
                     file_size      = excluded.file_size,
                     server_version = excluded.server_version,
                     rating         = excluded.rating,
                     description    = excluded.description,
                     camera         = excluded.camera,
                     aperture       = excluded.aperture,
                     exposure_time  = excluded.exposure_time,
                     focal_length   = excluded.focal_length,
                     iso            = excluded.iso,
                     lens           = excluded.lens,
                     duration       = excluded.duration,
                     framerate      = excluded.framerate,
                     video_codec    = excluded.video_codec,
                     container_type = excluded.container_type,
                     updated_at     = excluded.updated_at",
                params![
                    space_to_int(asset.space),
                    asset.id,
                    asset.unit_id,
                    asset.cache_key,
                    asset.filename,
                    media_kind_to_int(asset.media_kind),
                    asset.taken_at,
                    asset.added_at,
                    asset.width,
                    asset.height,
                    asset.file_size,
                    asset.server_version,
                    asset.rating,
                    asset.description,
                    asset.camera,
                    asset.aperture,
                    asset.exposure_time,
                    asset.focal_length,
                    asset.iso,
                    asset.lens,
                    asset.duration,
                    asset.framerate,
                    asset.video_codec,
                    asset.container_type,
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

    /// Total number of NON-TRASHED assets stored for `space`. Items moved to
    /// the app trash (`in_trash = 1`) are excluded so the library-grid count
    /// matches what `fetch_assets` returns; `trash_count` reports the trash.
    pub fn asset_count(&self, space: Space) -> Result<u64, CoreError> {
        let n: i64 = self
            .conn
            .query_row(
                "SELECT COUNT(*) FROM assets WHERE space = ?1 AND in_trash = 0",
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
        let sql = format!(
            "SELECT {ASSET_SELECT_COLUMNS}
                 FROM assets
                 WHERE space = ?1 AND in_trash = 0
                 ORDER BY (taken_at IS NULL) ASC, taken_at DESC, server_id DESC
                 LIMIT ?2 OFFSET ?3"
        );
        let mut stmt = self.conn.prepare(&sql).map_err(map_sql)?;
        let rows = stmt
            .query_map(
                params![space_to_int(space), limit as i64, offset as i64],
                row_to_asset,
            )
            .map_err(map_sql)?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row.map_err(map_sql)?);
        }
        Ok(out)
    }

    /// Returns a window of assets for `space` matching the Quick Filter facets,
    /// in the exact same order as `fetch_assets` (newest `taken_at` first,
    /// `server_id` tiebreak, NULL `taken_at` last), so paging by
    /// `offset`/`limit` stays stable across the two. Every facet is optional; a
    /// facet left `None` imposes no constraint. Passing every facet `None`
    /// returns exactly what `fetch_assets` returns for the same window (see
    /// `filter_with_no_facets_equals_fetch_assets`).
    ///
    /// A `taken_after`/`taken_before` bound excludes NULL-`taken_at` rows,
    /// because a SQL comparison against NULL is never true. That is the
    /// intended behaviour: an undated asset cannot satisfy a "taken between"
    /// constraint, so it drops out of a date-filtered view.
    pub fn filter_assets(
        &self,
        space: Space,
        media_kind: Option<MediaKind>,
        taken_after: Option<i64>,
        taken_before: Option<i64>,
        min_rating: Option<u8>,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<Asset>, CoreError> {
        let (where_clause, mut params) =
            build_filter_where(space, media_kind, taken_after, taken_before, min_rating);
        let sql = format!(
            "SELECT {ASSET_SELECT_COLUMNS}
                 FROM assets
                 WHERE {where_clause}
                 ORDER BY (taken_at IS NULL) ASC, taken_at DESC, server_id DESC
                 LIMIT ? OFFSET ?"
        );
        params.push(Box::new(limit as i64));
        params.push(Box::new(offset as i64));
        let mut stmt = self.conn.prepare(&sql).map_err(map_sql)?;
        let rows = stmt
            .query_map(rusqlite::params_from_iter(params), row_to_asset)
            .map_err(map_sql)?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row.map_err(map_sql)?);
        }
        Ok(out)
    }

    /// Number of non-trashed assets in `space` matching the same Quick Filter
    /// facets as `filter_assets`. With every facet `None` this equals
    /// `asset_count(space)`. Lets the grid size a filtered result set (for
    /// windowing and readiness) without paging the rows.
    pub fn filter_count(
        &self,
        space: Space,
        media_kind: Option<MediaKind>,
        taken_after: Option<i64>,
        taken_before: Option<i64>,
        min_rating: Option<u8>,
    ) -> Result<u64, CoreError> {
        let (where_clause, params) =
            build_filter_where(space, media_kind, taken_after, taken_before, min_rating);
        let sql = format!("SELECT COUNT(*) FROM assets WHERE {where_clause}");
        let n: i64 = self
            .conn
            .query_row(&sql, rusqlite::params_from_iter(params), |r| r.get(0))
            .map_err(map_sql)?;
        Ok(n as u64)
    }

    /// Groups the non-trashed assets in `space` into one bucket per calendar
    /// day of `taken_at`, newest day first, for the grid's date-section
    /// headers and scrubber. A cheap `GROUP BY` (never loads the rows), so the
    /// grid can build its section structure without paging the whole library.
    ///
    /// CRITICAL ordering invariant: the concatenation of the returned buckets,
    /// and the counts within each, exactly reproduces `fetch_assets`' global
    /// ordering, so section `s`, row `r` maps to the flat absolute index
    /// `(sum of counts of all newer buckets) + r`. This holds because the
    /// bucketing key (`taken_at / 86400`, the UTC day index) is monotonic with
    /// `taken_at`: every row of a newer day has a strictly larger `taken_at`
    /// than every row of an older day, so `fetch_assets`' `taken_at DESC`
    /// order visits whole days in the same newest-first order this returns,
    /// and within a day the counts line up regardless of the intra-day
    /// `server_id DESC` tiebreak. (Integer division assumes `taken_at >= 0`,
    /// true for every real photo timestamp.)
    ///
    /// Assets with a NULL `taken_at` are collected into a single trailing
    /// bucket with `day_start = 0`, matching `fetch_assets` sorting NULL rows
    /// last. The bucket is omitted entirely when the space has no such rows.
    /// The returned counts sum to `asset_count(space)` (same filters).
    pub fn date_histogram(&self, space: Space) -> Result<Vec<DayCount>, CoreError> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT (taken_at / 86400) * 86400 AS day_start, COUNT(*) AS n
                     FROM assets
                     WHERE space = ?1 AND in_trash = 0 AND taken_at IS NOT NULL
                     GROUP BY taken_at / 86400
                     ORDER BY day_start DESC",
            )
            .map_err(map_sql)?;
        let rows = stmt
            .query_map(params![space_to_int(space)], |r| {
                Ok(DayCount {
                    day_start: r.get::<_, i64>(0)?,
                    count: r.get::<_, i64>(1)? as u32,
                })
            })
            .map_err(map_sql)?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row.map_err(map_sql)?);
        }
        // Trailing "Unknown Date" bucket for NULL taken_at rows (which
        // fetch_assets orders last), appended only when there are any.
        let null_count: i64 = self
            .conn
            .query_row(
                "SELECT COUNT(*) FROM assets WHERE space = ?1 AND in_trash = 0 AND taken_at IS NULL",
                params![space_to_int(space)],
                |r| r.get(0),
            )
            .map_err(map_sql)?;
        if null_count > 0 {
            out.push(DayCount { day_start: 0, count: null_count as u32 });
        }
        Ok(out)
    }

    /// Returns a window of TRASHED assets for `space` (`in_trash = 1`),
    /// most-recently-trashed first (`trashed_at DESC`, `server_id DESC`
    /// tiebreak, NULL `trashed_at` last). This is the mirror image of
    /// `fetch_assets`, which excludes exactly these rows; together they
    /// partition a space's assets into the library grid and the Recently
    /// Deleted view.
    pub fn fetch_trash(&self, space: Space, offset: u32, limit: u32) -> Result<Vec<Asset>, CoreError> {
        let sql = format!(
            "SELECT {ASSET_SELECT_COLUMNS}
                 FROM assets
                 WHERE space = ?1 AND in_trash = 1
                 ORDER BY (trashed_at IS NULL) ASC, trashed_at DESC, server_id DESC
                 LIMIT ?2 OFFSET ?3"
        );
        let mut stmt = self.conn.prepare(&sql).map_err(map_sql)?;
        let rows = stmt
            .query_map(params![space_to_int(space), limit as i64, offset as i64], row_to_asset)
            .map_err(map_sql)?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row.map_err(map_sql)?);
        }
        Ok(out)
    }

    /// Number of trashed assets (`in_trash = 1`) for `space`.
    pub fn trash_count(&self, space: Space) -> Result<u64, CoreError> {
        let n: i64 = self
            .conn
            .query_row(
                "SELECT COUNT(*) FROM assets WHERE space = ?1 AND in_trash = 1",
                params![space_to_int(space)],
                |r| r.get(0),
            )
            .map_err(map_sql)?;
        Ok(n as u64)
    }

    /// Sets the trash flag on every asset in `ids` for `space`, inside a
    /// single transaction. `in_trash = true` moves items into the trash (the
    /// caller supplies `trashed_at = Some(now)`); `in_trash = false` restores
    /// them (`trashed_at = None`). Only rows whose `server_id` is in `ids` and
    /// whose `space` matches are touched, so a Personal update never reaches a
    /// Shared row. An empty `ids` slice is a no-op (no rows, no error).
    ///
    /// This only ever changes local flags; it never talks to the NAS. The
    /// facade calls it ONLY after the server has confirmed the corresponding
    /// album membership change, so a failed server write leaves these flags
    /// untouched (fail closed).
    pub fn set_trash_flag(
        &self,
        space: Space,
        ids: &[i64],
        in_trash: bool,
        trashed_at: Option<i64>,
    ) -> Result<(), CoreError> {
        if ids.is_empty() {
            return Ok(());
        }
        self.conn.execute_batch("BEGIN").map_err(map_sql)?;
        let result = self.set_trash_flag_inner(space, ids, in_trash, trashed_at);
        match result {
            Ok(()) => {
                self.conn.execute_batch("COMMIT").map_err(map_sql)?;
                Ok(())
            }
            Err(e) => {
                let _ = self.conn.execute_batch("ROLLBACK");
                Err(e)
            }
        }
    }

    fn set_trash_flag_inner(
        &self,
        space: Space,
        ids: &[i64],
        in_trash: bool,
        trashed_at: Option<i64>,
    ) -> Result<(), CoreError> {
        let placeholders: Vec<String> = (0..ids.len()).map(|i| format!("?{}", i + 4)).collect();
        let sql = format!(
            "UPDATE assets SET in_trash = ?1, trashed_at = ?2 WHERE space = ?3 AND server_id IN ({})",
            placeholders.join(",")
        );
        let mut params_vec: Vec<&dyn rusqlite::ToSql> = Vec::with_capacity(ids.len() + 3);
        let in_trash_int: i64 = if in_trash { 1 } else { 0 };
        let space_param = space_to_int(space);
        params_vec.push(&in_trash_int);
        params_vec.push(&trashed_at);
        params_vec.push(&space_param);
        for id in ids {
            params_vec.push(id);
        }
        self.conn.execute(&sql, params_vec.as_slice()).map_err(map_sql)?;
        Ok(())
    }

    /// Removes the local rows for `ids` in `space` entirely, inside a single
    /// transaction. Used by permanent delete AFTER the NAS has confirmed the
    /// item is gone: unlike `delete_assets_not_in` (a reconciliation sweep),
    /// this targets an explicit id list. Space-scoped so a Personal delete
    /// never removes a Shared row. An empty `ids` slice is a no-op.
    ///
    /// Local-only: never talks to the NAS.
    pub fn delete_assets(&self, space: Space, ids: &[i64]) -> Result<u64, CoreError> {
        if ids.is_empty() {
            return Ok(0);
        }
        self.conn.execute_batch("BEGIN").map_err(map_sql)?;
        let placeholders: Vec<String> = (0..ids.len()).map(|i| format!("?{}", i + 2)).collect();
        let sql = format!(
            "DELETE FROM assets WHERE space = ?1 AND server_id IN ({})",
            placeholders.join(",")
        );
        let space_param = space_to_int(space);
        let mut params_vec: Vec<&dyn rusqlite::ToSql> = Vec::with_capacity(ids.len() + 1);
        params_vec.push(&space_param);
        for id in ids {
            params_vec.push(id);
        }
        let deleted = match self.conn.execute(&sql, params_vec.as_slice()) {
            Ok(n) => n,
            Err(e) => {
                let _ = self.conn.execute_batch("ROLLBACK");
                return Err(map_sql(e));
            }
        };
        self.conn.execute_batch("COMMIT").map_err(map_sql)?;
        Ok(deleted as u64)
    }

    /// Returns true iff EVERY id in `ids` currently exists in `space` with
    /// `in_trash = 1`. Used by the facade's `permanently_delete` guard: the
    /// raw NAS delete verb must be unreachable for any asset that has not
    /// first gone through the trash step, so the facade calls this and refuses
    /// (with no network call) unless it returns true. An empty `ids` slice
    /// returns true vacuously (nothing to check); the facade short-circuits an
    /// empty request before reaching here anyway.
    ///
    /// `ids` MUST be deduplicated by the caller: this compares a distinct
    /// COUNT against `ids.len()`, so a duplicated id would make an otherwise
    /// valid request fail closed (which is the safe direction, but the facade
    /// dedups so a legitimate request is not rejected).
    pub fn all_in_trash(&self, space: Space, ids: &[i64]) -> Result<bool, CoreError> {
        if ids.is_empty() {
            return Ok(true);
        }
        let placeholders: Vec<String> = (0..ids.len()).map(|i| format!("?{}", i + 2)).collect();
        let sql = format!(
            "SELECT COUNT(*) FROM assets WHERE space = ?1 AND in_trash = 1 AND server_id IN ({})",
            placeholders.join(",")
        );
        let space_param = space_to_int(space);
        let mut params_vec: Vec<&dyn rusqlite::ToSql> = Vec::with_capacity(ids.len() + 1);
        params_vec.push(&space_param);
        for id in ids {
            params_vec.push(id);
        }
        let matched: i64 = self
            .conn
            .query_row(&sql, params_vec.as_slice(), |r| r.get(0))
            .map_err(map_sql)?;
        Ok(matched as usize == ids.len())
    }
}

#[cfg(test)]
mod tests {
    use crate::Store;
    use models::{Asset, MediaKind, Space};

    fn asset(space: Space, id: i64, taken: Option<i64>, ver: Option<i64>) -> Asset {
        Asset {
            id,
            unit_id: id + 1000,
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
            ..Default::default()
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

    /// unit_id must survive upsert followed by a windowed fetch, and must
    /// update in place when a re-crawl reports a new unit_id for the same
    /// (space, server_id) row (mirrors how the real endpoint keys
    /// thumbnails/downloads on unit_id, not the item id).
    #[test]
    fn unit_id_round_trips_through_upsert_and_windowed_fetch() {
        let store = Store::open_in_memory().unwrap();
        let mut a = asset(Space::Personal, 73459, Some(100), Some(1));
        a.unit_id = 55805;
        store.upsert_asset(&a).unwrap();

        let page = store.fetch_assets(Space::Personal, 0, 10).unwrap();
        assert_eq!(page.len(), 1);
        assert_eq!(page[0].unit_id, 55805);

        // Re-upsert the same server_id with a different unit_id: the stored
        // row must update, not keep the stale value.
        let mut updated = a.clone();
        updated.unit_id = 60000;
        store.upsert_asset(&updated).unwrap();
        let page = store.fetch_assets(Space::Personal, 0, 10).unwrap();
        assert_eq!(page[0].unit_id, 60000);
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

    // --- Quick Filter: filter_assets / filter_count ---------------------

    /// Builds an asset with an explicit media kind and rating on top of the
    /// base `asset` helper, so the filter tests can seed a mix of photos and
    /// videos at various star ratings without restating every field.
    fn filtered_asset(space: Space, id: i64, taken: Option<i64>, kind: MediaKind, rating: i32) -> Asset {
        Asset {
            media_kind: kind,
            rating,
            ..asset(space, id, taken, Some(1))
        }
    }

    /// The load-bearing invariant: an all-`None` filter must be identical to
    /// `fetch_assets`/`asset_count`, both in the rows it returns (order and
    /// windowing) and in the count, including the NULL-`taken_at`-last tiebreak
    /// ordering. If this ever drifts, switching a cleared filter back to the
    /// library would silently change what the user sees.
    #[test]
    fn filter_with_no_facets_equals_fetch_assets() {
        let store = Store::open_in_memory().unwrap();
        // A mix: two videos, several photos, tied taken_at, and an undated row.
        store.upsert_asset(&filtered_asset(Space::Personal, 1, Some(100), MediaKind::Photo, 0)).unwrap();
        store.upsert_asset(&filtered_asset(Space::Personal, 2, Some(300), MediaKind::Video, 5)).unwrap();
        store.upsert_asset(&filtered_asset(Space::Personal, 3, Some(300), MediaKind::Photo, 3)).unwrap();
        store.upsert_asset(&filtered_asset(Space::Personal, 4, Some(200), MediaKind::Video, 2)).unwrap();
        store.upsert_asset(&filtered_asset(Space::Personal, 5, None, MediaKind::Photo, 4)).unwrap();
        store.upsert_asset(&filtered_asset(Space::Shared, 9, Some(999), MediaKind::Photo, 5)).unwrap();

        // Full window.
        let filtered = store.filter_assets(Space::Personal, None, None, None, None, 0, 100).unwrap();
        let plain = store.fetch_assets(Space::Personal, 0, 100).unwrap();
        let filtered_ids: Vec<i64> = filtered.iter().map(|a| a.id).collect();
        let plain_ids: Vec<i64> = plain.iter().map(|a| a.id).collect();
        assert_eq!(filtered_ids, plain_ids, "all-None filter must match fetch_assets row-for-row and in order");

        // A mid-stream window must page identically too.
        let fw: Vec<i64> = store.filter_assets(Space::Personal, None, None, None, None, 1, 2).unwrap().iter().map(|a| a.id).collect();
        let pw: Vec<i64> = store.fetch_assets(Space::Personal, 1, 2).unwrap().iter().map(|a| a.id).collect();
        assert_eq!(fw, pw, "all-None filter must window identically to fetch_assets");

        assert_eq!(
            store.filter_count(Space::Personal, None, None, None, None).unwrap(),
            store.asset_count(Space::Personal).unwrap(),
            "all-None filter_count must equal asset_count"
        );
    }

    /// The media-kind facet returns only rows of that kind and nothing else.
    #[test]
    fn filter_by_media_kind_alone() {
        let store = Store::open_in_memory().unwrap();
        store.upsert_asset(&filtered_asset(Space::Personal, 1, Some(100), MediaKind::Photo, 0)).unwrap();
        store.upsert_asset(&filtered_asset(Space::Personal, 2, Some(200), MediaKind::Video, 0)).unwrap();
        store.upsert_asset(&filtered_asset(Space::Personal, 3, Some(300), MediaKind::Photo, 0)).unwrap();
        store.upsert_asset(&filtered_asset(Space::Personal, 4, Some(400), MediaKind::Video, 0)).unwrap();

        let videos: Vec<i64> = store
            .filter_assets(Space::Personal, Some(MediaKind::Video), None, None, None, 0, 100)
            .unwrap()
            .iter()
            .map(|a| a.id)
            .collect();
        assert_eq!(videos, vec![4, 2], "only videos, newest first");
        assert_eq!(store.filter_count(Space::Personal, Some(MediaKind::Video), None, None, None).unwrap(), 2);

        let photos: Vec<i64> = store
            .filter_assets(Space::Personal, Some(MediaKind::Photo), None, None, None, 0, 100)
            .unwrap()
            .iter()
            .map(|a| a.id)
            .collect();
        assert_eq!(photos, vec![3, 1]);
        assert_eq!(store.filter_count(Space::Personal, Some(MediaKind::Photo), None, None, None).unwrap(), 2);
    }

    /// The minimum-rating facet is inclusive (`rating >= min`) and drops
    /// everything below the floor, including unrated (rating 0) rows.
    #[test]
    fn filter_by_min_rating_alone() {
        let store = Store::open_in_memory().unwrap();
        for r in 0..=5 {
            // id encodes the rating; taken_at ascending with the rating so the
            // newest-first order is predictable.
            store.upsert_asset(&filtered_asset(Space::Personal, r as i64 + 1, Some((r as i64 + 1) * 10), MediaKind::Photo, r)).unwrap();
        }
        let at_least_three: Vec<i32> = store
            .filter_assets(Space::Personal, None, None, None, Some(3), 0, 100)
            .unwrap()
            .iter()
            .map(|a| a.rating)
            .collect();
        assert_eq!(at_least_three, vec![5, 4, 3], "rating >= 3, newest first");
        assert_eq!(store.filter_count(Space::Personal, None, None, None, Some(3)).unwrap(), 3);

        // A floor of 1 excludes only the unrated row.
        assert_eq!(store.filter_count(Space::Personal, None, None, None, Some(1)).unwrap(), 5);
        // A floor of 0 keeps everything (matches all-None on the rating axis).
        assert_eq!(store.filter_count(Space::Personal, None, None, None, Some(0)).unwrap(), 6);
    }

    /// The date facet applies an inclusive floor/ceiling on `taken_at`, and a
    /// bound in either direction excludes NULL-`taken_at` rows entirely.
    #[test]
    fn filter_by_date_range_alone_and_excludes_undated() {
        let store = Store::open_in_memory().unwrap();
        store.upsert_asset(&filtered_asset(Space::Personal, 1, Some(100), MediaKind::Photo, 0)).unwrap();
        store.upsert_asset(&filtered_asset(Space::Personal, 2, Some(200), MediaKind::Photo, 0)).unwrap();
        store.upsert_asset(&filtered_asset(Space::Personal, 3, Some(300), MediaKind::Photo, 0)).unwrap();
        store.upsert_asset(&filtered_asset(Space::Personal, 4, None, MediaKind::Photo, 0)).unwrap();

        // Inclusive both ends: [200, 300] keeps ids 2 and 3.
        let ranged: Vec<i64> = store
            .filter_assets(Space::Personal, None, Some(200), Some(300), None, 0, 100)
            .unwrap()
            .iter()
            .map(|a| a.id)
            .collect();
        assert_eq!(ranged, vec![3, 2]);
        assert_eq!(store.filter_count(Space::Personal, None, Some(200), Some(300), None).unwrap(), 2);

        // Floor only.
        assert_eq!(store.filter_count(Space::Personal, None, Some(200), None, None).unwrap(), 2);
        // Ceiling only.
        assert_eq!(store.filter_count(Space::Personal, None, None, Some(200), None).unwrap(), 2);

        // Any date bound drops the undated row (id 4): a floor of 0 would keep
        // every dated row but still exclude the NULL one.
        let with_floor = store.filter_count(Space::Personal, None, Some(0), None, None).unwrap();
        assert_eq!(with_floor, 3, "undated row is excluded once a date bound is set");
        // Whereas no date bound at all keeps the undated row.
        assert_eq!(store.filter_count(Space::Personal, None, None, None, None).unwrap(), 4);
    }

    /// All three facets combine as an AND: only rows satisfying media kind,
    /// date range, and rating floor simultaneously survive.
    #[test]
    fn filter_combined_facets_and_together() {
        let store = Store::open_in_memory().unwrap();
        // Target row: a highly-rated video inside the date window.
        store.upsert_asset(&filtered_asset(Space::Personal, 1, Some(250), MediaKind::Video, 5)).unwrap();
        // Right kind + rating, wrong (too-early) date.
        store.upsert_asset(&filtered_asset(Space::Personal, 2, Some(100), MediaKind::Video, 5)).unwrap();
        // Right date + rating, wrong kind (photo).
        store.upsert_asset(&filtered_asset(Space::Personal, 3, Some(250), MediaKind::Photo, 5)).unwrap();
        // Right kind + date, rating below the floor.
        store.upsert_asset(&filtered_asset(Space::Personal, 4, Some(250), MediaKind::Video, 2)).unwrap();
        // Another qualifying video later in the window.
        store.upsert_asset(&filtered_asset(Space::Personal, 5, Some(280), MediaKind::Video, 4)).unwrap();

        let got: Vec<i64> = store
            .filter_assets(Space::Personal, Some(MediaKind::Video), Some(200), Some(300), Some(4), 0, 100)
            .unwrap()
            .iter()
            .map(|a| a.id)
            .collect();
        assert_eq!(got, vec![5, 1], "only videos rated >=4 taken in [200,300], newest first");
        assert_eq!(
            store.filter_count(Space::Personal, Some(MediaKind::Video), Some(200), Some(300), Some(4)).unwrap(),
            2
        );
    }

    /// A filtered read pages by offset/limit with the same stable ordering as
    /// `fetch_assets`, so a windowed scroll over a filtered set neither skips
    /// nor duplicates a row, even with tied `taken_at`.
    #[test]
    fn filter_windowing_is_stable_with_ties() {
        let store = Store::open_in_memory().unwrap();
        // Six qualifying videos, three sharing taken_at=100 and three sharing 200.
        for id in 1..=3 {
            store.upsert_asset(&filtered_asset(Space::Personal, id, Some(100), MediaKind::Video, 5)).unwrap();
        }
        for id in 4..=6 {
            store.upsert_asset(&filtered_asset(Space::Personal, id, Some(200), MediaKind::Video, 5)).unwrap();
        }
        // A non-qualifying photo interleaved, to prove the filter holds across pages.
        store.upsert_asset(&filtered_asset(Space::Personal, 7, Some(150), MediaKind::Photo, 5)).unwrap();

        let mut seen: Vec<i64> = Vec::new();
        let mut offset = 0u32;
        loop {
            let page = store
                .filter_assets(Space::Personal, Some(MediaKind::Video), None, None, None, offset, 2)
                .unwrap();
            if page.is_empty() {
                break;
            }
            seen.extend(page.iter().map(|a| a.id));
            offset += 2;
        }
        assert_eq!(seen, vec![6, 5, 4, 3, 2, 1], "filtered paging is stable and video-only");
        let unique: std::collections::HashSet<i64> = seen.iter().copied().collect();
        assert_eq!(unique.len(), seen.len(), "no duplicates across filtered pages");
    }

    /// The filter is space-scoped: a Personal filter never returns a Shared
    /// row, even one that would match every facet.
    #[test]
    fn filter_is_space_scoped() {
        let store = Store::open_in_memory().unwrap();
        store.upsert_asset(&filtered_asset(Space::Personal, 1, Some(100), MediaKind::Video, 5)).unwrap();
        store.upsert_asset(&filtered_asset(Space::Shared, 1, Some(200), MediaKind::Video, 5)).unwrap();

        let personal: Vec<i64> = store
            .filter_assets(Space::Personal, Some(MediaKind::Video), None, None, None, 0, 100)
            .unwrap()
            .iter()
            .map(|a| a.id)
            .collect();
        assert_eq!(personal, vec![1]);
        assert_eq!(store.filter_count(Space::Personal, Some(MediaKind::Video), None, None, None).unwrap(), 1);
        assert_eq!(store.filter_count(Space::Shared, Some(MediaKind::Video), None, None, None).unwrap(), 1);
    }

    /// Trashed rows are excluded from every filtered read, exactly like
    /// `fetch_assets`/`asset_count`, so a Quick Filter never surfaces an item
    /// sitting in Recently Deleted.
    #[test]
    fn filter_excludes_trashed_rows() {
        let store = Store::open_in_memory().unwrap();
        store.upsert_asset(&filtered_asset(Space::Personal, 1, Some(100), MediaKind::Video, 5)).unwrap();
        store.upsert_asset(&filtered_asset(Space::Personal, 2, Some(200), MediaKind::Video, 5)).unwrap();
        store.set_trash_flag(Space::Personal, &[2], true, Some(5000)).unwrap();

        let got: Vec<i64> = store
            .filter_assets(Space::Personal, Some(MediaKind::Video), None, None, None, 0, 100)
            .unwrap()
            .iter()
            .map(|a| a.id)
            .collect();
        assert_eq!(got, vec![1], "the trashed video must not appear in a filtered read");
        assert_eq!(store.filter_count(Space::Personal, Some(MediaKind::Video), None, None, None).unwrap(), 1);
    }

    // --- Phase 2a: trash flag and trash queries -------------------------

    /// A freshly upserted asset is not trashed: it appears in the library
    /// grid (`fetch_assets`) and counts toward `asset_count`, and the trash is
    /// empty.
    #[test]
    fn new_asset_defaults_to_not_trashed() {
        let store = Store::open_in_memory().unwrap();
        store.upsert_asset(&asset(Space::Personal, 1, Some(100), Some(1))).unwrap();
        assert_eq!(store.asset_count(Space::Personal).unwrap(), 1);
        assert_eq!(store.fetch_assets(Space::Personal, 0, 10).unwrap().len(), 1);
        assert_eq!(store.trash_count(Space::Personal).unwrap(), 0);
        assert!(store.fetch_trash(Space::Personal, 0, 10).unwrap().is_empty());
    }

    /// Flagging an asset as trashed removes it from `fetch_assets`/
    /// `asset_count` and moves it into `fetch_trash`/`trash_count`. Clearing
    /// the flag reverses it exactly.
    #[test]
    fn set_trash_flag_moves_asset_between_library_and_trash() {
        let store = Store::open_in_memory().unwrap();
        store.upsert_asset(&asset(Space::Personal, 1, Some(100), Some(1))).unwrap();
        store.upsert_asset(&asset(Space::Personal, 2, Some(200), Some(1))).unwrap();

        store.set_trash_flag(Space::Personal, &[1], true, Some(5000)).unwrap();

        assert_eq!(store.asset_count(Space::Personal).unwrap(), 1);
        let grid: Vec<i64> = store.fetch_assets(Space::Personal, 0, 10).unwrap().iter().map(|a| a.id).collect();
        assert_eq!(grid, vec![2], "trashed asset must not appear in the library grid");
        assert_eq!(store.trash_count(Space::Personal).unwrap(), 1);
        let trash: Vec<i64> = store.fetch_trash(Space::Personal, 0, 10).unwrap().iter().map(|a| a.id).collect();
        assert_eq!(trash, vec![1]);

        // Restore: clear the flag.
        store.set_trash_flag(Space::Personal, &[1], false, None).unwrap();
        assert_eq!(store.asset_count(Space::Personal).unwrap(), 2);
        assert_eq!(store.trash_count(Space::Personal).unwrap(), 0);
        assert!(store.fetch_trash(Space::Personal, 0, 10).unwrap().is_empty());
    }

    /// The trash view is ordered most-recently-trashed first.
    #[test]
    fn fetch_trash_orders_by_trashed_at_desc() {
        let store = Store::open_in_memory().unwrap();
        for id in 1..=3 {
            store.upsert_asset(&asset(Space::Personal, id, Some(id * 10), Some(1))).unwrap();
        }
        store.set_trash_flag(Space::Personal, &[1], true, Some(1000)).unwrap();
        store.set_trash_flag(Space::Personal, &[2], true, Some(3000)).unwrap();
        store.set_trash_flag(Space::Personal, &[3], true, Some(2000)).unwrap();

        let order: Vec<i64> = store.fetch_trash(Space::Personal, 0, 10).unwrap().iter().map(|a| a.id).collect();
        assert_eq!(order, vec![2, 3, 1], "newest trashed_at first");
    }

    /// CRITICAL invariant: a re-crawl (upsert on a conflicting (space,
    /// server_id)) must PRESERVE an asset's trash flag and trashed_at, never
    /// silently un-trash it back to the library.
    #[test]
    fn upsert_preserves_trash_flag_on_conflict() {
        let store = Store::open_in_memory().unwrap();
        store.upsert_asset(&asset(Space::Personal, 1, Some(100), Some(1))).unwrap();
        store.set_trash_flag(Space::Personal, &[1], true, Some(9999)).unwrap();

        // A re-crawl reports the same item again with a new cache_key/version.
        let mut recrawled = asset(Space::Personal, 1, Some(100), Some(2));
        recrawled.cache_key = "ck1-new".into();
        store.upsert_asset(&recrawled).unwrap();

        // Still trashed: absent from the grid, present in the trash, with its
        // trashed_at intact.
        assert_eq!(store.asset_count(Space::Personal).unwrap(), 0);
        let trash = store.fetch_trash(Space::Personal, 0, 10).unwrap();
        assert_eq!(trash.len(), 1);
        assert_eq!(trash[0].cache_key, "ck1-new", "the re-crawl still updated other fields");
        let trashed_at: Option<i64> = store
            .conn
            .query_row("SELECT trashed_at FROM assets WHERE server_id = 1", [], |r| r.get(0))
            .unwrap();
        assert_eq!(trashed_at, Some(9999), "trashed_at must survive a re-crawl upsert");
    }

    /// The batch upsert must preserve the trash flag too (the crawl/sync
    /// engine uses `upsert_assets`, not the single-row path).
    #[test]
    fn batch_upsert_preserves_trash_flag_on_conflict() {
        let store = Store::open_in_memory().unwrap();
        store.upsert_asset(&asset(Space::Personal, 1, Some(100), Some(1))).unwrap();
        store.set_trash_flag(Space::Personal, &[1], true, Some(8888)).unwrap();

        let mut recrawled = asset(Space::Personal, 1, Some(100), Some(2));
        recrawled.cache_key = "ck1-batch".into();
        store.upsert_assets(&[recrawled]).unwrap();

        assert_eq!(store.trash_count(Space::Personal).unwrap(), 1);
        assert_eq!(store.asset_count(Space::Personal).unwrap(), 0);
    }

    #[test]
    fn set_trash_flag_is_space_scoped() {
        let store = Store::open_in_memory().unwrap();
        store.upsert_asset(&asset(Space::Personal, 1, Some(100), Some(1))).unwrap();
        store.upsert_asset(&asset(Space::Shared, 1, Some(100), Some(1))).unwrap();

        // Trashing server_id 1 in Personal must not touch the Shared row that
        // happens to share the same server_id.
        store.set_trash_flag(Space::Personal, &[1], true, Some(5000)).unwrap();
        assert_eq!(store.trash_count(Space::Personal).unwrap(), 1);
        assert_eq!(store.trash_count(Space::Shared).unwrap(), 0);
        assert_eq!(store.asset_count(Space::Shared).unwrap(), 1);
    }

    #[test]
    fn set_trash_flag_empty_ids_is_a_no_op() {
        let store = Store::open_in_memory().unwrap();
        store.upsert_asset(&asset(Space::Personal, 1, Some(100), Some(1))).unwrap();
        store.set_trash_flag(Space::Personal, &[], true, Some(1)).unwrap();
        assert_eq!(store.trash_count(Space::Personal).unwrap(), 0);
    }

    #[test]
    fn delete_assets_removes_only_the_named_rows_in_space() {
        let store = Store::open_in_memory().unwrap();
        store.upsert_asset(&asset(Space::Personal, 1, Some(100), Some(1))).unwrap();
        store.upsert_asset(&asset(Space::Personal, 2, Some(200), Some(1))).unwrap();
        store.upsert_asset(&asset(Space::Shared, 1, Some(100), Some(1))).unwrap();

        let removed = store.delete_assets(Space::Personal, &[1]).unwrap();
        assert_eq!(removed, 1);
        let remaining: Vec<i64> = store.fetch_assets(Space::Personal, 0, 10).unwrap().iter().map(|a| a.id).collect();
        assert_eq!(remaining, vec![2]);
        assert_eq!(store.asset_count(Space::Shared).unwrap(), 1, "Shared row with same server_id untouched");
    }

    #[test]
    fn delete_assets_empty_ids_is_a_no_op() {
        let store = Store::open_in_memory().unwrap();
        store.upsert_asset(&asset(Space::Personal, 1, Some(100), Some(1))).unwrap();
        assert_eq!(store.delete_assets(Space::Personal, &[]).unwrap(), 0);
        assert_eq!(store.asset_count(Space::Personal).unwrap(), 1);
    }

    #[test]
    fn all_in_trash_is_true_only_when_every_id_is_trashed() {
        let store = Store::open_in_memory().unwrap();
        for id in 1..=3 {
            store.upsert_asset(&asset(Space::Personal, id, Some(id * 10), Some(1))).unwrap();
        }
        store.set_trash_flag(Space::Personal, &[1, 2], true, Some(5000)).unwrap();

        assert!(store.all_in_trash(Space::Personal, &[1, 2]).unwrap(), "both trashed");
        assert!(!store.all_in_trash(Space::Personal, &[1, 3]).unwrap(), "id 3 is not trashed");
        // A non-existent id can never be in trash, so the guard fails closed.
        assert!(!store.all_in_trash(Space::Personal, &[1, 999]).unwrap(), "missing id fails closed");
        // Empty is vacuously true.
        assert!(store.all_in_trash(Space::Personal, &[]).unwrap());
    }

    // --- date_histogram --------------------------------------------------

    /// Buckets one asset per distinct calendar day, newest day first, and the
    /// counts sum to `asset_count`. Days are spaced far enough apart (one per
    /// week) that each lands in its own UTC-day bucket regardless of the exact
    /// time-of-day the epoch base falls on.
    #[test]
    fn date_histogram_buckets_by_day_newest_first() {
        let store = Store::open_in_memory().unwrap();
        let base = 1_479_513_600; // 2016-11-19 00:00:00 UTC
        let day = 86_400;
        // Three days, with 1, 2, and 3 assets respectively (ascending age).
        store.upsert_asset(&asset(Space::Personal, 1, Some(base + 2 * 7 * day + 10), Some(1))).unwrap();
        store.upsert_asset(&asset(Space::Personal, 2, Some(base + 1 * 7 * day + 20), Some(1))).unwrap();
        store.upsert_asset(&asset(Space::Personal, 3, Some(base + 1 * 7 * day + 30), Some(1))).unwrap();
        store.upsert_asset(&asset(Space::Personal, 4, Some(base + 40), Some(1))).unwrap();
        store.upsert_asset(&asset(Space::Personal, 5, Some(base + 50), Some(1))).unwrap();
        store.upsert_asset(&asset(Space::Personal, 6, Some(base + 60), Some(1))).unwrap();

        let hist = store.date_histogram(Space::Personal).unwrap();
        assert_eq!(hist.len(), 3, "three distinct days");
        // Newest day first.
        assert_eq!(hist[0].count, 1);
        assert_eq!(hist[1].count, 2);
        assert_eq!(hist[2].count, 3);
        assert!(hist[0].day_start > hist[1].day_start);
        assert!(hist[1].day_start > hist[2].day_start);
        // Every day_start is a UTC-midnight multiple of 86400.
        for b in &hist {
            assert_eq!(b.day_start % day, 0, "day_start must be a UTC-day boundary");
        }
        // Counts sum to asset_count.
        let sum: u32 = hist.iter().map(|b| b.count).sum();
        assert_eq!(u64::from(sum), store.asset_count(Space::Personal).unwrap());
    }

    /// The histogram is space-scoped and excludes trashed rows, exactly like
    /// `fetch_assets`/`asset_count`.
    #[test]
    fn date_histogram_is_space_scoped_and_excludes_trash() {
        let store = Store::open_in_memory().unwrap();
        let base = 1_479_513_600;
        store.upsert_asset(&asset(Space::Personal, 1, Some(base + 10), Some(1))).unwrap();
        store.upsert_asset(&asset(Space::Personal, 2, Some(base + 20), Some(1))).unwrap();
        store.upsert_asset(&asset(Space::Shared, 9, Some(base + 30), Some(1))).unwrap();
        store.set_trash_flag(Space::Personal, &[2], true, Some(5000)).unwrap();

        let hist = store.date_histogram(Space::Personal).unwrap();
        let sum: u32 = hist.iter().map(|b| b.count).sum();
        assert_eq!(sum, 1, "trashed row excluded, Shared row not counted");
        assert_eq!(u64::from(sum), store.asset_count(Space::Personal).unwrap());
    }

    /// NULL-`taken_at` rows collapse into one trailing bucket with
    /// `day_start = 0`, appearing after every dated bucket, mirroring
    /// `fetch_assets` ordering those rows last.
    #[test]
    fn date_histogram_puts_null_taken_at_in_trailing_zero_bucket() {
        let store = Store::open_in_memory().unwrap();
        let base = 1_479_513_600;
        store.upsert_asset(&asset(Space::Personal, 1, Some(base + 10), Some(1))).unwrap();
        store.upsert_asset(&asset(Space::Personal, 2, None, Some(1))).unwrap();
        store.upsert_asset(&asset(Space::Personal, 3, None, Some(1))).unwrap();

        let hist = store.date_histogram(Space::Personal).unwrap();
        assert_eq!(hist.len(), 2);
        assert_eq!(hist[0].count, 1, "the one dated row");
        assert!(hist[0].day_start > 0);
        assert_eq!(hist.last().unwrap().day_start, 0, "Unknown Date bucket is last");
        assert_eq!(hist.last().unwrap().count, 2);
    }

    /// An empty (or all-dated) space produces no Unknown Date bucket, and an
    /// empty space produces an empty histogram.
    #[test]
    fn date_histogram_omits_unknown_bucket_when_no_null_rows_and_is_empty_when_no_rows() {
        let store = Store::open_in_memory().unwrap();
        assert!(store.date_histogram(Space::Personal).unwrap().is_empty());
        store.upsert_asset(&asset(Space::Personal, 1, Some(1_479_513_610), Some(1))).unwrap();
        let hist = store.date_histogram(Space::Personal).unwrap();
        assert_eq!(hist.len(), 1);
        assert!(hist.iter().all(|b| b.day_start != 0), "no Unknown Date bucket when every row is dated");
    }

    /// THE load-bearing invariant for the grid's (section, row) -> absolute
    /// index mapping: walking the histogram's prefix sums and reading each
    /// absolute index back through `fetch_assets` must return rows in the same
    /// day the bucket claims, with the bucket boundaries lining up exactly.
    /// This pages `fetch_assets` one row at a time and checks that the r-th row
    /// of bucket s lands at absolute index (prefix of s) + r and belongs to
    /// that bucket's day (dated buckets) or has a NULL taken_at (Unknown
    /// bucket). Uses ties within a day and multiple days to exercise the
    /// server_id tiebreak alongside the day boundaries.
    #[test]
    fn date_histogram_boundaries_line_up_with_fetch_assets() {
        let store = Store::open_in_memory().unwrap();
        let base = 1_479_513_600; // a UTC midnight
        let day = 86_400;
        // Day A (newest): 3 assets, two sharing a taken_at to force the tiebreak.
        store.upsert_asset(&asset(Space::Personal, 10, Some(base + 2 * day + 500), Some(1))).unwrap();
        store.upsert_asset(&asset(Space::Personal, 11, Some(base + 2 * day + 500), Some(1))).unwrap();
        store.upsert_asset(&asset(Space::Personal, 12, Some(base + 2 * day + 100), Some(1))).unwrap();
        // Day B: 2 assets.
        store.upsert_asset(&asset(Space::Personal, 20, Some(base + 1 * day + 700), Some(1))).unwrap();
        store.upsert_asset(&asset(Space::Personal, 21, Some(base + 1 * day + 10), Some(1))).unwrap();
        // Day C (oldest dated): 1 asset.
        store.upsert_asset(&asset(Space::Personal, 30, Some(base + 42), Some(1))).unwrap();
        // Two undated rows -> the trailing Unknown bucket.
        store.upsert_asset(&asset(Space::Personal, 40, None, Some(1))).unwrap();
        store.upsert_asset(&asset(Space::Personal, 41, None, Some(1))).unwrap();

        let hist = store.date_histogram(Space::Personal).unwrap();
        let total = store.asset_count(Space::Personal).unwrap();
        let sum: u32 = hist.iter().map(|b| b.count).sum();
        assert_eq!(u64::from(sum), total, "counts sum to asset_count");

        // Read the whole space back in one shot to index by absolute position.
        let all = store.fetch_assets(Space::Personal, 0, total as u32).unwrap();
        assert_eq!(all.len() as u64, total);

        let mut prefix = 0u32;
        for bucket in &hist {
            for r in 0..bucket.count {
                let absolute = (prefix + r) as usize;
                let a = &all[absolute];
                if bucket.day_start == 0 {
                    assert!(a.taken_at.is_none(), "Unknown bucket row must have NULL taken_at");
                } else {
                    let row_day = (a.taken_at.unwrap() / day) * day;
                    assert_eq!(
                        row_day, bucket.day_start,
                        "row at absolute {absolute} must fall in the bucket's day"
                    );
                }
            }
            prefix += bucket.count;
        }
        assert_eq!(prefix, sum, "prefix walk covered exactly every row");
    }

    #[test]
    fn round_trip_preserves_all_fields() {
        let store = Store::open_in_memory().unwrap();
        let original = Asset {
            id: 77,
            unit_id: 55805,
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
            rating: 5,
            description: "clip from the trip".to_string(),
            camera: "Apple iPhone 12".to_string(),
            aperture: "f/1.8".to_string(),
            exposure_time: "1/60".to_string(),
            focal_length: "26 mm".to_string(),
            iso: "200".to_string(),
            lens: "iPhone 12 back camera".to_string(),
            duration: "30000".to_string(),
            framerate: "29.97".to_string(),
            video_codec: "hevc".to_string(),
            container_type: "mov".to_string(),
        };
        store.upsert_asset(&original).unwrap();
        let page = store.fetch_assets(Space::Shared, 0, 10).unwrap();
        assert_eq!(page.len(), 1);
        let round_tripped = &page[0];
        assert_eq!(round_tripped.id, original.id);
        assert_eq!(round_tripped.unit_id, original.unit_id);
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
        // Media-enrichment fields (schema v3) round-trip too.
        assert_eq!(round_tripped.rating, original.rating);
        assert_eq!(round_tripped.description, original.description);
        assert_eq!(round_tripped.camera, original.camera);
        assert_eq!(round_tripped.aperture, original.aperture);
        assert_eq!(round_tripped.exposure_time, original.exposure_time);
        assert_eq!(round_tripped.focal_length, original.focal_length);
        assert_eq!(round_tripped.iso, original.iso);
        assert_eq!(round_tripped.lens, original.lens);
        assert_eq!(round_tripped.duration, original.duration);
        assert_eq!(round_tripped.framerate, original.framerate);
        assert_eq!(round_tripped.video_codec, original.video_codec);
        assert_eq!(round_tripped.container_type, original.container_type);
    }

    /// An asset that carries no enrichment metadata (the common case, e.g. a
    /// re-crawl before values are populated, or a photo with empty EXIF) must
    /// round-trip through upsert+fetch with the neutral defaults intact, not
    /// error and not turn "" into NULL.
    #[test]
    fn metadata_defaults_round_trip_when_absent() {
        let store = Store::open_in_memory().unwrap();
        // The `asset` helper spreads `..Default::default()`, so it carries the
        // neutral metadata defaults already.
        store.upsert_asset(&asset(Space::Personal, 1, Some(100), Some(1))).unwrap();
        let page = store.fetch_assets(Space::Personal, 0, 10).unwrap();
        assert_eq!(page.len(), 1);
        let a = &page[0];
        assert_eq!(a.rating, 0);
        assert_eq!(a.description, "");
        assert_eq!(a.camera, "");
        assert_eq!(a.iso, "");
        assert_eq!(a.duration, "");
        assert_eq!(a.framerate, "");
        assert_eq!(a.video_codec, "");
        assert_eq!(a.container_type, "");
    }

    /// A re-crawl updates the enrichment metadata in place (the fields ARE in
    /// the ON CONFLICT SET) while STILL preserving the trash flag (which is
    /// NOT). This pins both halves of the upsert contract at once: metadata
    /// refreshes, trash state is sacred.
    #[test]
    fn recrawl_updates_metadata_but_preserves_trash() {
        let store = Store::open_in_memory().unwrap();
        let mut a = asset(Space::Personal, 1, Some(100), Some(1));
        a.rating = 2;
        a.description = "old caption".to_string();
        store.upsert_asset(&a).unwrap();
        store.set_trash_flag(Space::Personal, &[1], true, Some(9999)).unwrap();

        // Re-crawl reports a higher rating and a new caption for the same item.
        let mut recrawled = asset(Space::Personal, 1, Some(100), Some(2));
        recrawled.rating = 5;
        recrawled.description = "new caption".to_string();
        recrawled.camera = "Apple iPhone 15".to_string();
        store.upsert_asset(&recrawled).unwrap();

        // Still trashed (not un-trashed by the re-crawl)...
        assert_eq!(store.asset_count(Space::Personal).unwrap(), 0);
        let trash = store.fetch_trash(Space::Personal, 0, 10).unwrap();
        assert_eq!(trash.len(), 1);
        // ...but the metadata reflects the re-crawl.
        assert_eq!(trash[0].rating, 5, "re-crawl must refresh rating");
        assert_eq!(trash[0].description, "new caption", "re-crawl must refresh description");
        assert_eq!(trash[0].camera, "Apple iPhone 15");
        let trashed_at: Option<i64> = store
            .conn
            .query_row("SELECT trashed_at FROM assets WHERE server_id = 1", [], |r| r.get(0))
            .unwrap();
        assert_eq!(trashed_at, Some(9999), "trashed_at must survive a metadata re-crawl");
    }
}
