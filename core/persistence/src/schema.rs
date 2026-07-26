//! Embedded DDL and the versioned migration runner for the local SQLite mirror.
//!
//! Schema changes are applied as an ordered list of numbered steps, tracked via
//! `PRAGMA user_version` (a SQLite built-in integer counter, so there is no extra
//! table to keep in sync with reality). On open, the runner reads the current
//! `user_version`, applies every step whose number is greater than it in order,
//! and commits the new version in the same transaction as the step's own work.
//! A crash mid-migration rolls back to the pre-migration version, so a step is
//! never left half-applied.
//!
//! ## Data-bearing migrations must reset the crawl barrier
//!
//! Some steps add or change a column whose correct value can only come from the
//! NAS (`unit_id`, and future columns like `resolution` or `taken_at` corrections
//! are the same shape of problem). `ALTER TABLE ... ADD COLUMN` can only backfill
//! existing rows with a static default, and that default is stale data, not a
//! real value. If `initial_crawl_complete` is left `true`, the app never re-crawls
//! and that stale default ships to the user forever (this is exactly how `unit_id`
//! shipped as `0` for every pre-existing row and broke thumbnails).
//!
//! A step that introduces a data-bearing column must set `requires_recrawl: true`
//! on its `MigrationStep`. The runner resets the crawl barrier (`initial_crawl_complete
//! = 0` and the paging cursor back to the start) for every space that had a
//! completed crawl, but only when such a step actually ran on this database, and
//! only once per migration run. A fresh database has nothing to backfill (the
//! barrier already starts at 0), and a database already on the latest version
//! does not re-run the step, so neither case pays for a reset it does not need.
//!
//! To add a new data-bearing migration: add a new `MigrationStep` with the next
//! version number, set `requires_recrawl: true`, and write the DDL/backfill in its
//! `apply` function. Nothing else needs to change; the reset is automatic.

use models::CoreError;
use rusqlite::Connection;

/// Base DDL for a brand-new database. `CREATE TABLE IF NOT EXISTS` /
/// `CREATE INDEX IF NOT EXISTS` make this safe to execute unconditionally: on a
/// fresh database it creates everything at the current shape; on an existing
/// database it is a no-op, and any shape changes since the tables were first
/// created are handled by the versioned steps below, not by editing this DDL.
const BASE_DDL: &str = r#"
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS assets (
    rowid_pk       INTEGER PRIMARY KEY AUTOINCREMENT,
    space          INTEGER NOT NULL,            -- 0 Personal, 1 Shared
    server_id      INTEGER NOT NULL,            -- Synology item id (identity within space)
    unit_id        INTEGER NOT NULL DEFAULT 0,  -- Synology unit id, required by thumbnail/download
    cache_key      TEXT    NOT NULL,            -- version token, NOT identity
    filename       TEXT    NOT NULL,
    media_kind     INTEGER NOT NULL DEFAULT 2,  -- 0 photo, 1 video, 2 unknown
    taken_at       INTEGER,
    added_at       INTEGER,
    width          INTEGER,
    height         INTEGER,
    file_size      INTEGER,
    server_version INTEGER,
    in_trash       INTEGER NOT NULL DEFAULT 0,  -- 0/1: sitting in the app "Recently Deleted" album
    trashed_at     INTEGER,                     -- epoch seconds the item was moved to trash, NULL when not trashed
    rating         INTEGER NOT NULL DEFAULT 0,  -- 0..5 stars, 0 = unrated (NAS-derived)
    description    TEXT    NOT NULL DEFAULT '',  -- caption/description (NAS-derived)
    camera         TEXT    NOT NULL DEFAULT '',  -- EXIF camera model
    aperture       TEXT    NOT NULL DEFAULT '',  -- EXIF aperture
    exposure_time  TEXT    NOT NULL DEFAULT '',  -- EXIF exposure/shutter time
    focal_length   TEXT    NOT NULL DEFAULT '',  -- EXIF focal length
    iso            TEXT    NOT NULL DEFAULT '',  -- EXIF ISO
    lens           TEXT    NOT NULL DEFAULT '',  -- EXIF lens model
    duration       TEXT    NOT NULL DEFAULT '',  -- video duration, raw server value
    framerate      TEXT    NOT NULL DEFAULT '',  -- video frame rate, raw server value
    video_codec    TEXT    NOT NULL DEFAULT '',  -- video codec
    container_type TEXT    NOT NULL DEFAULT '',  -- video container type
    latitude       REAL,                        -- GPS latitude, NULL when unlocated (NAS-derived)
    longitude      REAL,                        -- GPS longitude, NULL when unlocated (NAS-derived)
    updated_at     INTEGER NOT NULL,
    UNIQUE (space, server_id)
);
CREATE INDEX IF NOT EXISTS idx_assets_space_taken ON assets (space, taken_at DESC, server_id DESC);
CREATE INDEX IF NOT EXISTS idx_assets_space_ver   ON assets (space, server_id, server_version);

CREATE TABLE IF NOT EXISTS albums (
    rowid_pk        INTEGER PRIMARY KEY AUTOINCREMENT,
    space           INTEGER NOT NULL,
    server_id       INTEGER NOT NULL,
    name            TEXT    NOT NULL,
    item_count      INTEGER NOT NULL DEFAULT 0,
    cover_cache_key TEXT,
    updated_at      INTEGER NOT NULL,
    UNIQUE (space, server_id)
);
CREATE INDEX IF NOT EXISTS idx_albums_space ON albums (space, name);

CREATE TABLE IF NOT EXISTS sync_state (
    space                  INTEGER PRIMARY KEY,
    initial_crawl_complete INTEGER NOT NULL DEFAULT 0,
    expected_total         INTEGER NOT NULL DEFAULT 0,
    last_offset            INTEGER NOT NULL DEFAULT 0,
    last_page_limit        INTEGER NOT NULL DEFAULT 0,
    highest_seen_version   INTEGER,
    last_crawl_at          INTEGER,
    last_reconcile_at      INTEGER
);

CREATE TABLE IF NOT EXISTS schema_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- Small per-space key/value store for app-owned identifiers that must survive
-- restarts, such as the id of the app-created "Recently Deleted" album (so the
-- delete feature owns that album by a stored id, never by a name match that
-- could hijack a user's own same-named album). Created via CREATE TABLE IF NOT
-- EXISTS so it lands on both fresh and existing databases without needing a
-- versioned ALTER migration step.
CREATE TABLE IF NOT EXISTS app_state (
    space INTEGER NOT NULL,
    key   TEXT    NOT NULL,
    value TEXT    NOT NULL,
    PRIMARY KEY (space, key)
);
"#;

/// One versioned migration step. `version` must be unique and steps run in
/// ascending order starting just above the database's current
/// `PRAGMA user_version`. `requires_recrawl` marks a step that adds or changes
/// a column the runner cannot fill with a correct value on its own (only the
/// NAS has the real data); the runner resets the crawl barrier once if any
/// applied step sets this.
struct MigrationStep {
    version: i64,
    requires_recrawl: bool,
    apply: fn(&Connection) -> Result<(), CoreError>,
}

/// Ordered migration steps, applied in ascending `version` order. Append new
/// steps here; never renumber or remove an existing one, since a database's
/// `user_version` records exactly how far through this list it has already
/// progressed.
const STEPS: &[MigrationStep] = &[
    MigrationStep {
        version: 1,
        requires_recrawl: true,
        apply: add_unit_id_column_if_missing,
    },
    MigrationStep {
        // Phase 2a hybrid safe-delete: local trash tracking. Adds in_trash /
        // trashed_at to assets and the index the trash and library-grid
        // queries page against. NOT `requires_recrawl`: unlike unit_id, these
        // columns hold app-local state, not NAS-derived data. Their defaults
        // (0 / NULL = "not trashed") are the correct value for every existing
        // row, so no re-crawl is needed to backfill them; `reconcile_trash`
        // in the facade is what later reconciles them against the real NAS
        // trash-album membership.
        version: 2,
        requires_recrawl: false,
        apply: add_trash_columns_if_missing,
    },
    MigrationStep {
        // Media model enrichment: per-asset EXIF, rating, description, and
        // video metadata. Adds the twelve metadata columns to a pre-existing
        // assets table. `requires_recrawl: true` because every one of these
        // columns is NAS-derived: `ALTER TABLE ADD COLUMN` can only backfill
        // existing rows with the static default ('' / 0), which is stale, not
        // the real value. Left un-recrawled, existing libraries would show
        // blank EXIF and rating 0 forever (the exact shape of the unit_id
        // bug). Marking it forces one full re-crawl that repopulates the real
        // values; the crawl is resumable and idempotent, so this is cheap and
        // safe. Does NOT touch in_trash/trashed_at (schema v2), so the app
        // trash survives the upgrade untouched.
        version: 3,
        requires_recrawl: true,
        apply: add_metadata_columns_if_missing,
    },
    MigrationStep {
        // Per-asset GPS for the Map view: latitude / longitude. Adds the two
        // nullable REAL columns to a pre-existing assets table.
        // `requires_recrawl: true` for the same reason as the v3 metadata step:
        // lat/lon are NAS-derived (Browse.Item `additional.gps`), and
        // `ALTER TABLE ADD COLUMN` can only backfill existing rows with NULL,
        // never the real coordinate. Left un-recrawled, every existing row
        // would read as unlocated forever; marking it forces one resumable,
        // idempotent re-crawl that populates the true coordinates. Does not
        // touch in_trash/trashed_at (v2) so the app trash survives untouched.
        version: 4,
        requires_recrawl: true,
        apply: add_location_columns_if_missing,
    },
];

/// Highest version among `STEPS`; also the schema version a freshly created
/// database ends up at, since `BASE_DDL` already creates tables at their
/// current shape and every step's job on a fresh database is a no-op.
fn latest_version() -> i64 {
    STEPS.iter().map(|s| s.version).max().unwrap_or(0)
}

/// Maps a rusqlite error into the crate-wide `CoreError`.
///
/// This is the single shared rusqlite -> CoreError mapping for the persistence crate.
/// Later modules (queries, writers, sync-state accessors) should call this instead of
/// re-deriving their own conversion.
pub(crate) fn map_sql(e: rusqlite::Error) -> CoreError {
    CoreError::Storage { message: e.to_string() }
}

fn user_version(conn: &Connection) -> Result<i64, CoreError> {
    conn.query_row("PRAGMA user_version", [], |r| r.get(0)).map_err(map_sql)
}

fn set_user_version(conn: &Connection, version: i64) -> Result<(), CoreError> {
    conn.execute_batch(&format!("PRAGMA user_version = {version}")).map_err(map_sql)
}

/// Applies the base DDL, then runs every migration step whose version is
/// greater than the database's current `user_version`, in order. All pending
/// steps and the barrier reset (if any of them require it) run inside a
/// single transaction with the version bump, so a crash mid-migration leaves
/// `user_version` unchanged and the whole batch rolls back rather than
/// landing half-applied. Safe to call on every open: a database already at
/// `latest_version()` finds no pending steps and is a no-op.
pub(crate) fn run_migrations(conn: &Connection) -> Result<(), CoreError> {
    conn.execute_batch(BASE_DDL).map_err(map_sql)?;

    let current = user_version(conn)?;
    if current < latest_version() {
        let pending: Vec<&MigrationStep> = STEPS.iter().filter(|s| s.version > current).collect();
        if !pending.is_empty() {
            conn.execute_batch("BEGIN IMMEDIATE").map_err(map_sql)?;
            match run_pending_steps(conn, &pending) {
                Ok(()) => {
                    conn.execute_batch("COMMIT").map_err(map_sql)?;
                }
                Err(e) => {
                    let _ = conn.execute_batch("ROLLBACK");
                    return Err(e);
                }
            }
        }
    }

    // Reconcile the human-readable `schema_meta.schema_version` mirror to the
    // version actually applied (the authoritative `PRAGMA user_version`).
    // Kept in sync on every open, including the already-current path, so a
    // database that predates this mirror being maintained still reports the
    // right number. `Store::schema_version()` reads this value.
    let applied = user_version(conn)?;
    conn.execute(
        "INSERT INTO schema_meta (key, value) VALUES ('schema_version', ?1)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        [applied.to_string()],
    )
    .map_err(map_sql)?;
    Ok(())
}

/// Runs each pending step, then resets the crawl barrier once if any of them
/// require it, then bumps `user_version` to the highest version just applied.
/// Split out from `run_migrations` purely so the BEGIN/COMMIT/ROLLBACK
/// bracketing above has one obvious place to wrap.
fn run_pending_steps(conn: &Connection, pending: &[&MigrationStep]) -> Result<(), CoreError> {
    let mut needs_recrawl_reset = false;
    let mut highest_applied = user_version(conn)?;
    for step in pending {
        (step.apply)(conn)?;
        needs_recrawl_reset |= step.requires_recrawl;
        highest_applied = highest_applied.max(step.version);
    }
    if needs_recrawl_reset {
        reset_crawl_barrier_for_completed_spaces(conn)?;
    }
    set_user_version(conn, highest_applied)
}

/// Forces a re-crawl for every space that had already finished its initial
/// crawl: clears `initial_crawl_complete` and rewinds the paging cursor
/// (`last_offset`/`last_page_limit`) back to the start, so
/// `PhotosCore::crawl_space` starts over from page zero on next launch and
/// repopulates whatever data-bearing column the triggering migration just
/// added. Spaces that never completed a crawl are left untouched: their
/// barrier is already down and a partial cursor is exactly what a resumed
/// crawl expects.
fn reset_crawl_barrier_for_completed_spaces(conn: &Connection) -> Result<(), CoreError> {
    conn.execute(
        "UPDATE sync_state
         SET initial_crawl_complete = 0, last_offset = 0, last_page_limit = 0
         WHERE initial_crawl_complete != 0",
        [],
    )
    .map_err(map_sql)?;
    Ok(())
}

/// Migration step 1: adds the `unit_id` column to a pre-existing `assets`
/// table that predates this migration. `CREATE TABLE IF NOT EXISTS` in
/// `BASE_DDL` only takes effect on a brand new database; a database created
/// before `unit_id` was added to the schema keeps its old column set forever
/// unless something explicitly alters it. Checked via `PRAGMA table_info`
/// rather than trying the `ALTER TABLE` and swallowing a "duplicate column"
/// error, so this stays idempotent and cheap. Existing rows get
/// `unit_id = 0`, the same default a fresh insert would apply; that default
/// is stale, which is exactly why this step is marked `requires_recrawl`.
fn add_unit_id_column_if_missing(conn: &Connection) -> Result<(), CoreError> {
    let mut stmt = conn.prepare("PRAGMA table_info(assets)").map_err(map_sql)?;
    let has_unit_id = stmt
        .query_map([], |row| row.get::<_, String>(1))
        .map_err(map_sql)?
        .filter_map(|r| r.ok())
        .any(|name| name == "unit_id");
    drop(stmt);
    if !has_unit_id {
        conn.execute("ALTER TABLE assets ADD COLUMN unit_id INTEGER NOT NULL DEFAULT 0", [])
            .map_err(map_sql)?;
    }
    Ok(())
}

/// Migration step 2: adds the `in_trash` / `trashed_at` columns (and the
/// trash index) to a pre-existing `assets` table that predates the hybrid
/// safe-delete feature. Each `ALTER TABLE ADD COLUMN` is guarded by a
/// `PRAGMA table_info` check rather than run unconditionally, because
/// re-adding an existing column is a hard error in SQLite; this keeps the
/// step idempotent (a re-run, or a fresh database whose `BASE_DDL` already
/// created these columns, does nothing). The index is `CREATE INDEX IF NOT
/// EXISTS` so it is naturally idempotent, and it is created HERE rather than
/// in `BASE_DDL` because `BASE_DDL` runs before this step: on a legacy
/// database the `in_trash` column does not exist yet when `BASE_DDL` runs, so
/// an index referencing it there would fail. Existing rows default to
/// `in_trash = 0` / `trashed_at = NULL` ("not trashed"), which is the correct
/// value, so this step is deliberately NOT `requires_recrawl`.
fn add_trash_columns_if_missing(conn: &Connection) -> Result<(), CoreError> {
    let existing: Vec<String> = {
        let mut stmt = conn.prepare("PRAGMA table_info(assets)").map_err(map_sql)?;
        let names = stmt
            .query_map([], |row| row.get::<_, String>(1))
            .map_err(map_sql)?
            .filter_map(|r| r.ok())
            .collect();
        names
    };
    if !existing.iter().any(|name| name == "in_trash") {
        conn.execute("ALTER TABLE assets ADD COLUMN in_trash INTEGER NOT NULL DEFAULT 0", [])
            .map_err(map_sql)?;
    }
    if !existing.iter().any(|name| name == "trashed_at") {
        conn.execute("ALTER TABLE assets ADD COLUMN trashed_at INTEGER", [])
            .map_err(map_sql)?;
    }
    conn.execute("CREATE INDEX IF NOT EXISTS idx_assets_space_trash ON assets (space, in_trash)", [])
        .map_err(map_sql)?;
    Ok(())
}

/// Migration step 3: adds the twelve media-enrichment columns (`rating`,
/// `description`, the six EXIF strings, and the four video-metadata strings)
/// to a pre-existing `assets` table. Each `ALTER TABLE ADD COLUMN` is guarded
/// by a `PRAGMA table_info` check so a re-run, or a fresh database whose
/// `BASE_DDL` already created these columns, is a no-op rather than a
/// duplicate-column error (keeping the step idempotent). Only columns that are
/// genuinely absent are added, so this survives being interrupted and re-run.
/// The `in_trash`/`trashed_at` columns from step 2 are never referenced here,
/// so the app trash is untouched by this upgrade. Existing rows get the static
/// defaults ('' / 0), which are stale, which is exactly why the step is marked
/// `requires_recrawl` in `STEPS`.
fn add_metadata_columns_if_missing(conn: &Connection) -> Result<(), CoreError> {
    let existing: Vec<String> = {
        let mut stmt = conn.prepare("PRAGMA table_info(assets)").map_err(map_sql)?;
        let names = stmt
            .query_map([], |row| row.get::<_, String>(1))
            .map_err(map_sql)?
            .filter_map(|r| r.ok())
            .collect();
        names
    };
    // (column name, column definition) for each new metadata column. TEXT
    // columns default to '' and rating to 0, matching a fresh insert and the
    // Asset model's own defaults.
    let columns: &[(&str, &str)] = &[
        ("rating", "INTEGER NOT NULL DEFAULT 0"),
        ("description", "TEXT NOT NULL DEFAULT ''"),
        ("camera", "TEXT NOT NULL DEFAULT ''"),
        ("aperture", "TEXT NOT NULL DEFAULT ''"),
        ("exposure_time", "TEXT NOT NULL DEFAULT ''"),
        ("focal_length", "TEXT NOT NULL DEFAULT ''"),
        ("iso", "TEXT NOT NULL DEFAULT ''"),
        ("lens", "TEXT NOT NULL DEFAULT ''"),
        ("duration", "TEXT NOT NULL DEFAULT ''"),
        ("framerate", "TEXT NOT NULL DEFAULT ''"),
        ("video_codec", "TEXT NOT NULL DEFAULT ''"),
        ("container_type", "TEXT NOT NULL DEFAULT ''"),
    ];
    for (name, def) in columns {
        if !existing.iter().any(|c| c == name) {
            conn.execute(&format!("ALTER TABLE assets ADD COLUMN {name} {def}"), [])
                .map_err(map_sql)?;
        }
    }
    Ok(())
}

/// Migration step 4: adds the `latitude` / `longitude` columns to a pre-existing
/// `assets` table. Each `ALTER TABLE ADD COLUMN` is guarded by a `PRAGMA
/// table_info` check so a re-run, or a fresh database whose `BASE_DDL` already
/// created these columns, is a no-op rather than a duplicate-column error
/// (keeping the step idempotent). The columns are nullable REAL with no default:
/// NULL is the correct "unlocated" value, and unlike unit_id there is no
/// sentinel to invent. Existing rows come out NULL (unlocated), which is stale
/// for any photo that actually carries GPS, which is exactly why the step is
/// marked `requires_recrawl` in `STEPS`.
fn add_location_columns_if_missing(conn: &Connection) -> Result<(), CoreError> {
    let existing: Vec<String> = {
        let mut stmt = conn.prepare("PRAGMA table_info(assets)").map_err(map_sql)?;
        let names = stmt
            .query_map([], |row| row.get::<_, String>(1))
            .map_err(map_sql)?
            .filter_map(|r| r.ok())
            .collect();
        names
    };
    let columns: &[(&str, &str)] = &[("latitude", "REAL"), ("longitude", "REAL")];
    for (name, def) in columns {
        if !existing.iter().any(|c| c == name) {
            conn.execute(&format!("ALTER TABLE assets ADD COLUMN {name} {def}"), [])
                .map_err(map_sql)?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Builds the pre-unit_id `assets` shape directly (no `unit_id` column),
    /// with `user_version` left at 0, mirroring a real database created
    /// before this migration existed.
    fn open_legacy_db_without_unit_id() -> Connection {
        let conn = rusqlite::Connection::open_in_memory().expect("open");
        conn.execute_batch(
            "CREATE TABLE assets (
                rowid_pk       INTEGER PRIMARY KEY AUTOINCREMENT,
                space          INTEGER NOT NULL,
                server_id      INTEGER NOT NULL,
                cache_key      TEXT    NOT NULL,
                filename       TEXT    NOT NULL,
                media_kind     INTEGER NOT NULL DEFAULT 2,
                taken_at       INTEGER,
                added_at       INTEGER,
                width          INTEGER,
                height         INTEGER,
                file_size      INTEGER,
                server_version INTEGER,
                updated_at     INTEGER NOT NULL,
                UNIQUE (space, server_id)
            );
            CREATE TABLE sync_state (
                space                  INTEGER PRIMARY KEY,
                initial_crawl_complete INTEGER NOT NULL DEFAULT 0,
                expected_total         INTEGER NOT NULL DEFAULT 0,
                last_offset            INTEGER NOT NULL DEFAULT 0,
                last_page_limit        INTEGER NOT NULL DEFAULT 0,
                highest_seen_version   INTEGER,
                last_crawl_at          INTEGER,
                last_reconcile_at      INTEGER
            );
            CREATE TABLE schema_meta (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );",
        )
        .expect("legacy tables");
        conn
    }

    /// Builds a v1-shaped `assets` table: it already has `unit_id` (so the
    /// step-1 migration is a no-op) but NOT the step-2 trash columns, with
    /// `user_version` pinned at 1, mirroring a real database created after the
    /// unit_id migration but before the hybrid-delete one.
    fn open_v1_db_without_trash_columns() -> Connection {
        let conn = rusqlite::Connection::open_in_memory().expect("open");
        conn.execute_batch(
            "CREATE TABLE assets (
                rowid_pk       INTEGER PRIMARY KEY AUTOINCREMENT,
                space          INTEGER NOT NULL,
                server_id      INTEGER NOT NULL,
                unit_id        INTEGER NOT NULL DEFAULT 0,
                cache_key      TEXT    NOT NULL,
                filename       TEXT    NOT NULL,
                media_kind     INTEGER NOT NULL DEFAULT 2,
                taken_at       INTEGER,
                added_at       INTEGER,
                width          INTEGER,
                height         INTEGER,
                file_size      INTEGER,
                server_version INTEGER,
                updated_at     INTEGER NOT NULL,
                UNIQUE (space, server_id)
            );
            CREATE TABLE sync_state (
                space                  INTEGER PRIMARY KEY,
                initial_crawl_complete INTEGER NOT NULL DEFAULT 0,
                expected_total         INTEGER NOT NULL DEFAULT 0,
                last_offset            INTEGER NOT NULL DEFAULT 0,
                last_page_limit        INTEGER NOT NULL DEFAULT 0,
                highest_seen_version   INTEGER,
                last_crawl_at          INTEGER,
                last_reconcile_at      INTEGER
            );
            CREATE TABLE schema_meta (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            PRAGMA user_version = 1;",
        )
        .expect("v1 tables");
        conn
    }

    /// Builds a v2-shaped `assets` table: it has `unit_id` and the hybrid-
    /// delete `in_trash`/`trashed_at` columns, but NOT the step-3 media
    /// metadata columns, with `user_version` pinned at 2. Mirrors a real
    /// database created after the delete work but before this enrichment step.
    fn open_v2_db_without_metadata_columns() -> Connection {
        let conn = rusqlite::Connection::open_in_memory().expect("open");
        conn.execute_batch(
            "CREATE TABLE assets (
                rowid_pk       INTEGER PRIMARY KEY AUTOINCREMENT,
                space          INTEGER NOT NULL,
                server_id      INTEGER NOT NULL,
                unit_id        INTEGER NOT NULL DEFAULT 0,
                cache_key      TEXT    NOT NULL,
                filename       TEXT    NOT NULL,
                media_kind     INTEGER NOT NULL DEFAULT 2,
                taken_at       INTEGER,
                added_at       INTEGER,
                width          INTEGER,
                height         INTEGER,
                file_size      INTEGER,
                server_version INTEGER,
                in_trash       INTEGER NOT NULL DEFAULT 0,
                trashed_at     INTEGER,
                updated_at     INTEGER NOT NULL,
                UNIQUE (space, server_id)
            );
            CREATE INDEX idx_assets_space_trash ON assets (space, in_trash);
            CREATE TABLE sync_state (
                space                  INTEGER PRIMARY KEY,
                initial_crawl_complete INTEGER NOT NULL DEFAULT 0,
                expected_total         INTEGER NOT NULL DEFAULT 0,
                last_offset            INTEGER NOT NULL DEFAULT 0,
                last_page_limit        INTEGER NOT NULL DEFAULT 0,
                highest_seen_version   INTEGER,
                last_crawl_at          INTEGER,
                last_reconcile_at      INTEGER
            );
            CREATE TABLE schema_meta (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            PRAGMA user_version = 2;",
        )
        .expect("v2 tables");
        conn
    }

    /// Builds a v3-shaped `assets` table: it has `unit_id`, the hybrid-delete
    /// columns, and all twelve media-enrichment columns, but NOT the step-4
    /// `latitude`/`longitude` columns, with `user_version` pinned at 3. Mirrors
    /// a real database created after the metadata enrichment but before GPS.
    fn open_v3_db_without_location_columns() -> Connection {
        let conn = rusqlite::Connection::open_in_memory().expect("open");
        conn.execute_batch(
            "CREATE TABLE assets (
                rowid_pk       INTEGER PRIMARY KEY AUTOINCREMENT,
                space          INTEGER NOT NULL,
                server_id      INTEGER NOT NULL,
                unit_id        INTEGER NOT NULL DEFAULT 0,
                cache_key      TEXT    NOT NULL,
                filename       TEXT    NOT NULL,
                media_kind     INTEGER NOT NULL DEFAULT 2,
                taken_at       INTEGER,
                added_at       INTEGER,
                width          INTEGER,
                height         INTEGER,
                file_size      INTEGER,
                server_version INTEGER,
                in_trash       INTEGER NOT NULL DEFAULT 0,
                trashed_at     INTEGER,
                rating         INTEGER NOT NULL DEFAULT 0,
                description    TEXT    NOT NULL DEFAULT '',
                camera         TEXT    NOT NULL DEFAULT '',
                aperture       TEXT    NOT NULL DEFAULT '',
                exposure_time  TEXT    NOT NULL DEFAULT '',
                focal_length   TEXT    NOT NULL DEFAULT '',
                iso            TEXT    NOT NULL DEFAULT '',
                lens           TEXT    NOT NULL DEFAULT '',
                duration       TEXT    NOT NULL DEFAULT '',
                framerate      TEXT    NOT NULL DEFAULT '',
                video_codec    TEXT    NOT NULL DEFAULT '',
                container_type TEXT    NOT NULL DEFAULT '',
                updated_at     INTEGER NOT NULL,
                UNIQUE (space, server_id)
            );
            CREATE INDEX idx_assets_space_trash ON assets (space, in_trash);
            CREATE TABLE sync_state (
                space                  INTEGER PRIMARY KEY,
                initial_crawl_complete INTEGER NOT NULL DEFAULT 0,
                expected_total         INTEGER NOT NULL DEFAULT 0,
                last_offset            INTEGER NOT NULL DEFAULT 0,
                last_page_limit        INTEGER NOT NULL DEFAULT 0,
                highest_seen_version   INTEGER,
                last_crawl_at          INTEGER,
                last_reconcile_at      INTEGER
            );
            CREATE TABLE schema_meta (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            PRAGMA user_version = 3;",
        )
        .expect("v3 tables");
        conn
    }

    /// A v3 database must gain the `latitude`/`longitude` columns on upgrade to
    /// v4, default them to NULL (unlocated) for existing rows, bump
    /// `user_version` and the `schema_meta` mirror to 4 (== `latest_version()`),
    /// and stay a no-op (no duplicate-column error) on a second run.
    #[test]
    fn migration_v3_to_v4_adds_location_columns_defaulted_and_is_idempotent() {
        let conn = open_v3_db_without_location_columns();
        conn.execute(
            "INSERT INTO assets (space, server_id, unit_id, cache_key, filename, updated_at) VALUES (0, 1, 10, 'ck1', 'a.jpg', 0)",
            [],
        )
        .expect("v3 row");

        run_migrations(&conn).expect("migration adds location columns");

        // The two new columns exist and default to NULL for the existing row.
        let (latitude, longitude): (Option<f64>, Option<f64>) = conn
            .query_row(
                "SELECT latitude, longitude FROM assets WHERE server_id = 1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .expect("location columns readable");
        assert_eq!(latitude, None, "existing row defaults latitude to NULL (unlocated)");
        assert_eq!(longitude, None, "existing row defaults longitude to NULL (unlocated)");
        assert_eq!(user_version(&conn).unwrap(), 4);
        assert_eq!(user_version(&conn).unwrap(), latest_version());
        let meta: String = conn
            .query_row("SELECT value FROM schema_meta WHERE key = 'schema_version'", [], |r| r.get(0))
            .expect("schema_meta mirror set");
        assert_eq!(meta, "4");

        // Second run must not fail with a duplicate-column error and must stay
        // a no-op at the latest version.
        run_migrations(&conn).expect("second run is a no-op");
        assert_eq!(user_version(&conn).unwrap(), latest_version());
    }

    /// The v4 location migration is NAS-derived (`requires_recrawl: true`), so a
    /// v3 database that had already completed its crawl must have its barrier
    /// reset and cursor rewound, exactly like the metadata migration, so the
    /// real coordinates get backfilled instead of every row staying unlocated.
    #[test]
    fn v3_to_v4_migration_resets_crawl_barrier_for_completed_space() {
        let conn = open_v3_db_without_location_columns();
        conn.execute(
            "INSERT INTO sync_state (space, initial_crawl_complete, expected_total, last_offset, last_page_limit)
             VALUES (0, 1, 151, 151, 200)",
            [],
        )
        .expect("personal sync_state");

        run_migrations(&conn).expect("v3 to v4 migration");

        let (complete, offset): (i64, i64) = conn
            .query_row(
                "SELECT initial_crawl_complete, last_offset FROM sync_state WHERE space = 0",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(complete, 0, "a data-bearing migration must reset a completed crawl");
        assert_eq!(offset, 0, "the paging cursor must rewind so the crawl restarts and backfills GPS");
    }

    /// A v2 database must gain all twelve media-enrichment columns on upgrade
    /// to v3, default them for existing rows, bump `user_version` and the
    /// `schema_meta` mirror to 3, and stay a no-op (no duplicate-column error)
    /// on a second run.
    #[test]
    fn migration_v2_to_v3_adds_metadata_columns_defaulted_and_is_idempotent() {
        let conn = open_v2_db_without_metadata_columns();
        conn.execute(
            "INSERT INTO assets (space, server_id, unit_id, cache_key, filename, updated_at) VALUES (0, 1, 10, 'ck1', 'a.jpg', 0)",
            [],
        )
        .expect("v2 row");

        run_migrations(&conn).expect("migration adds metadata columns");

        let (rating, description, camera, duration): (i64, String, String, String) = conn
            .query_row(
                "SELECT rating, description, camera, duration FROM assets WHERE server_id = 1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .expect("metadata columns readable");
        assert_eq!(rating, 0, "existing row defaults rating to 0");
        assert_eq!(description, "", "existing row defaults description to ''");
        assert_eq!(camera, "", "existing row defaults camera to ''");
        assert_eq!(duration, "", "existing row defaults duration to ''");
        // A v2 database runs every pending step in one batch, so it lands on
        // the latest version (v3 metadata + v4 location), not just v3.
        assert_eq!(user_version(&conn).unwrap(), latest_version());
        let meta: String = conn
            .query_row("SELECT value FROM schema_meta WHERE key = 'schema_version'", [], |r| r.get(0))
            .expect("schema_meta mirror set");
        assert_eq!(meta, latest_version().to_string());

        // Second run must not fail with a duplicate-column error and must stay
        // a no-op at the latest version.
        run_migrations(&conn).expect("second run is a no-op");
        assert_eq!(user_version(&conn).unwrap(), latest_version());
    }

    /// REGRESSION GUARD for the hybrid-delete work: the v3 migration must not
    /// touch the schema-v2 `in_trash`/`trashed_at` state. A row already flagged
    /// as trashed in a v2 database must stay trashed (and keep its
    /// `trashed_at`) after the metadata columns are added, and re-running the
    /// migration must not clear it either.
    #[test]
    fn v2_to_v3_migration_preserves_in_trash_state() {
        let conn = open_v2_db_without_metadata_columns();
        conn.execute(
            "INSERT INTO assets (space, server_id, unit_id, cache_key, filename, in_trash, trashed_at, updated_at)
             VALUES (0, 7, 70, 'ck7', 'trashed.jpg', 1, 9999, 0)",
            [],
        )
        .expect("trashed v2 row");

        run_migrations(&conn).expect("v2 to v3 migration");

        let (in_trash, trashed_at): (i64, Option<i64>) = conn
            .query_row("SELECT in_trash, trashed_at FROM assets WHERE server_id = 7", [], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })
            .expect("trash columns intact");
        assert_eq!(in_trash, 1, "the migration must not un-trash an already-trashed row");
        assert_eq!(trashed_at, Some(9999), "trashed_at must survive the v3 migration");

        // Re-run: still trashed, still v3.
        run_migrations(&conn).expect("second run is a no-op");
        let in_trash_after: i64 = conn
            .query_row("SELECT in_trash FROM assets WHERE server_id = 7", [], |r| r.get(0))
            .unwrap();
        assert_eq!(in_trash_after, 1, "re-running the migration must not clear in_trash");
    }

    /// The v3 metadata migration is NAS-derived (`requires_recrawl: true`), so
    /// a v2 database that had already completed its crawl must have its barrier
    /// reset and cursor rewound, exactly like the unit_id migration, so the
    /// real EXIF/rating/video values get backfilled instead of shipping the
    /// stale ''/0 defaults forever.
    #[test]
    fn v2_to_v3_migration_resets_crawl_barrier_for_completed_space() {
        let conn = open_v2_db_without_metadata_columns();
        conn.execute(
            "INSERT INTO sync_state (space, initial_crawl_complete, expected_total, last_offset, last_page_limit)
             VALUES (0, 1, 151, 151, 200)",
            [],
        )
        .expect("personal sync_state");

        run_migrations(&conn).expect("v2 to v3 migration");

        let (complete, offset): (i64, i64) = conn
            .query_row(
                "SELECT initial_crawl_complete, last_offset FROM sync_state WHERE space = 0",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(complete, 0, "a data-bearing migration must reset a completed crawl");
        assert_eq!(offset, 0, "the paging cursor must rewind so the crawl restarts and backfills metadata");
    }

    /// A database on v1 must gain the `in_trash` / `trashed_at` columns
    /// (step 2), default them for existing rows, and run through to the latest
    /// version (a v1 db has both step 2 and step 3 pending), bumping both
    /// `user_version` and the `schema_meta` mirror, and staying a no-op on a
    /// second run (no duplicate-column error).
    #[test]
    fn migration_from_v1_adds_trash_columns_defaulted_and_is_idempotent() {
        let conn = open_v1_db_without_trash_columns();
        conn.execute(
            "INSERT INTO assets (space, server_id, unit_id, cache_key, filename, updated_at) VALUES (0, 1, 10, 'ck1', 'a.jpg', 0)",
            [],
        )
        .expect("v1 row");

        run_migrations(&conn).expect("migration adds trash columns");

        let (in_trash, trashed_at): (i64, Option<i64>) = conn
            .query_row("SELECT in_trash, trashed_at FROM assets WHERE server_id = 1", [], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })
            .expect("trash columns readable");
        assert_eq!(in_trash, 0, "existing row defaults to not-trashed");
        assert_eq!(trashed_at, None, "existing row has a NULL trashed_at");
        assert_eq!(user_version(&conn).unwrap(), latest_version());
        let meta: String = conn
            .query_row("SELECT value FROM schema_meta WHERE key = 'schema_version'", [], |r| r.get(0))
            .expect("schema_meta mirror set");
        assert_eq!(meta, latest_version().to_string());

        // Second run must not fail with a duplicate-column error and must stay
        // a no-op at the latest version.
        run_migrations(&conn).expect("second run is a no-op");
        assert_eq!(user_version(&conn).unwrap(), latest_version());
    }

    /// A v1 database that had already completed its crawl, migrated all the
    /// way to the latest version, MUST have its crawl barrier reset: the batch
    /// of pending steps includes the data-bearing v3 metadata step
    /// (`requires_recrawl`), and a single such step anywhere in the batch is
    /// enough to force the one re-crawl that backfills the NAS-derived values.
    /// (The non-data-bearing v2 trash step, in isolation, would not; but it
    /// never runs in isolation from a v1 start now that v3 exists.)
    #[test]
    fn migration_from_v1_to_latest_resets_barrier_via_data_bearing_step() {
        let conn = open_v1_db_without_trash_columns();
        conn.execute(
            "INSERT INTO sync_state (space, initial_crawl_complete, expected_total, last_offset, last_page_limit)
             VALUES (0, 1, 151, 151, 200)",
            [],
        )
        .expect("personal sync_state");

        run_migrations(&conn).expect("v1 to latest migration");

        let (complete, offset): (i64, i64) = conn
            .query_row(
                "SELECT initial_crawl_complete, last_offset FROM sync_state WHERE space = 0",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(complete, 0, "a batch containing a data-bearing step must reset a completed crawl");
        assert_eq!(offset, 0, "the paging cursor must rewind so the crawl restarts and backfills metadata");
    }

    #[test]
    fn migrations_create_all_tables_and_seed_version() {
        let store = crate::Store::open_in_memory().expect("open");
        assert_eq!(store.schema_version().expect("version"), latest_version());
        let names: Vec<String> = {
            let mut stmt = store
                .conn
                .prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
                .unwrap();
            stmt.query_map([], |r| r.get::<_, String>(0))
                .unwrap()
                .map(|r| r.unwrap())
                .collect()
        };
        for expected in ["albums", "assets", "schema_meta", "sync_state"] {
            assert!(names.contains(&expected.to_string()), "missing table {expected}");
        }
    }

    /// A fresh database (nothing pre-existing) ends up at the latest version
    /// after one call, and calling `run_migrations` again is a no-op: no
    /// pending steps, `user_version` unchanged, no error.
    #[test]
    fn migrations_are_idempotent() {
        let store = crate::Store::open_in_memory().expect("open");
        assert_eq!(user_version(&store.conn).unwrap(), latest_version());
        run_migrations(&store.conn).expect("rerun");
        assert_eq!(store.schema_version().expect("version"), latest_version());
        assert_eq!(user_version(&store.conn).unwrap(), latest_version());
    }

    /// A database already at the latest `user_version` changes nothing when
    /// migrated again: same version, and (for this suite's only data-bearing
    /// step) the crawl barrier is left exactly as the caller set it, not
    /// reset again on every open.
    #[test]
    fn already_current_database_is_a_no_op_and_does_not_re_reset_barrier() {
        let store = crate::Store::open_in_memory().expect("open");
        store.set_crawl_complete(models::Space::Personal, true, 123).unwrap();

        run_migrations(&store.conn).expect("migrate again on current db");

        assert_eq!(user_version(&store.conn).unwrap(), latest_version());
        let s = store.load_sync_state(models::Space::Personal).unwrap();
        assert!(s.initial_crawl_complete, "already-current migration must not touch the barrier");
    }

    /// A database created before `unit_id` existed must still open cleanly:
    /// `run_migrations` adds the missing column rather than erroring on a
    /// table that already exists without it.
    #[test]
    fn legacy_assets_table_gains_unit_id_column_on_migration() {
        let conn = open_legacy_db_without_unit_id();
        conn.execute(
            "INSERT INTO assets (space, server_id, cache_key, filename, updated_at) VALUES (0, 1, 'ck1', 'a.jpg', 0)",
            [],
        )
        .expect("legacy row");

        run_migrations(&conn).expect("migration adds unit_id");

        let unit_id: i64 = conn
            .query_row("SELECT unit_id FROM assets WHERE server_id = 1", [], |r| r.get(0))
            .expect("unit_id column readable");
        assert_eq!(unit_id, 0, "legacy row defaults unit_id to 0");
        assert_eq!(user_version(&conn).unwrap(), latest_version());

        // Running again must not fail with a duplicate-column error, and must
        // stay a no-op (already at latest_version).
        run_migrations(&conn).expect("second run is a no-op");
        assert_eq!(user_version(&conn).unwrap(), latest_version());
    }

    /// The proven bug, reproduced and fixed: a pre-unit_id database that had
    /// already finished its initial crawl (`initial_crawl_complete = 1`) with
    /// a non-zero cursor must come out of `run_migrations` with the barrier
    /// reset to false and the cursor rewound, so `PhotosCore::crawl_space`
    /// re-runs and backfills real `unit_id` values instead of leaving every
    /// row stuck at the migration's default of 0.
    #[test]
    fn data_bearing_migration_resets_crawl_barrier_for_previously_complete_space() {
        let conn = open_legacy_db_without_unit_id();
        for id in 1..=3 {
            conn.execute(
                "INSERT INTO assets (space, server_id, cache_key, filename, updated_at) VALUES (0, ?1, ?2, ?3, 0)",
                rusqlite::params![id, format!("ck{id}"), format!("a{id}.jpg")],
            )
            .expect("legacy row");
        }
        // Simulate a NAS with two spaces: Personal already finished its
        // crawl with cursor state; Shared never started one.
        conn.execute(
            "INSERT INTO sync_state (space, initial_crawl_complete, expected_total, last_offset, last_page_limit)
             VALUES (0, 1, 151, 151, 200)",
            [],
        )
        .expect("personal sync_state");
        conn.execute(
            "INSERT INTO sync_state (space, initial_crawl_complete, expected_total, last_offset, last_page_limit)
             VALUES (1, 0, 0, 0, 0)",
            [],
        )
        .expect("shared sync_state");

        run_migrations(&conn).expect("migration backfills unit_id and resets barrier");

        // All rows gained unit_id=0 (the column exists; a real crawl will
        // overwrite it with the true value from the NAS).
        let zero_unit_id_count: i64 = conn
            .query_row("SELECT COUNT(*) FROM assets WHERE unit_id = 0", [], |r| r.get(0))
            .unwrap();
        assert_eq!(zero_unit_id_count, 3);

        // Personal had already completed a crawl: barrier must be forced
        // back down and its cursor rewound so the crawl restarts from the
        // beginning and repopulates unit_id for every asset.
        let (complete, offset, limit): (i64, i64, i64) = conn
            .query_row(
                "SELECT initial_crawl_complete, last_offset, last_page_limit FROM sync_state WHERE space = 0",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();
        assert_eq!(complete, 0, "previously-complete space must have its barrier reset");
        assert_eq!(offset, 0, "cursor must rewind so the crawl restarts from the beginning");
        assert_eq!(limit, 0);

        // Shared never had a completed crawl: nothing to reset, its all-zero
        // row is left exactly as it was.
        let shared_complete: i64 = conn
            .query_row("SELECT initial_crawl_complete FROM sync_state WHERE space = 1", [], |r| r.get(0))
            .unwrap();
        assert_eq!(shared_complete, 0);

        assert_eq!(user_version(&conn).unwrap(), latest_version());
    }

    /// A fresh database (current schema from the start) never had a
    /// completed crawl to begin with, so migrating it is a no-op for the
    /// barrier beyond the normal starting value of false: nothing gets
    /// reset because nothing was ever set.
    #[test]
    fn fresh_database_has_no_spurious_barrier_reset() {
        let store = crate::Store::open_in_memory().expect("open");
        let s = store.load_sync_state(models::Space::Personal).unwrap();
        assert!(!s.initial_crawl_complete, "fresh db starts with the barrier down, not reset");
    }
}
