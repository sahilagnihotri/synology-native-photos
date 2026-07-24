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
const STEPS: &[MigrationStep] = &[MigrationStep {
    version: 1,
    requires_recrawl: true,
    apply: add_unit_id_column_if_missing,
}];

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
    conn.execute(
        "INSERT OR IGNORE INTO schema_meta (key, value) VALUES ('schema_version', '1')",
        [],
    )
    .map_err(map_sql)?;

    let current = user_version(conn)?;
    if current >= latest_version() {
        return Ok(());
    }
    let pending: Vec<&MigrationStep> =
        STEPS.iter().filter(|s| s.version > current).collect();
    if pending.is_empty() {
        return Ok(());
    }

    conn.execute_batch("BEGIN IMMEDIATE").map_err(map_sql)?;
    let result = run_pending_steps(conn, &pending);
    match result {
        Ok(()) => {
            conn.execute_batch("COMMIT").map_err(map_sql)?;
            Ok(())
        }
        Err(e) => {
            let _ = conn.execute_batch("ROLLBACK");
            Err(e)
        }
    }
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

    #[test]
    fn migrations_create_all_tables_and_seed_version() {
        let store = crate::Store::open_in_memory().expect("open");
        assert_eq!(store.schema_version().expect("version"), 1);
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
        assert_eq!(store.schema_version().expect("version"), 1);
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
