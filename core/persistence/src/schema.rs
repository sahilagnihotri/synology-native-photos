//! Embedded DDL and migration runner for the local SQLite mirror.
//!
//! The schema is applied via `CREATE TABLE IF NOT EXISTS` / `CREATE INDEX IF NOT EXISTS`,
//! so re-running it is a no-op once the tables exist. `schema_meta` records the applied
//! schema version so future migrations can branch on it instead of re-deriving state from
//! `sqlite_master`.

use models::CoreError;
use rusqlite::Connection;

const DDL: &str = r#"
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

/// Maps a rusqlite error into the crate-wide `CoreError`.
///
/// This is the single shared rusqlite -> CoreError mapping for the persistence crate.
/// Later modules (queries, writers, sync-state accessors) should call this instead of
/// re-deriving their own conversion.
pub(crate) fn map_sql(e: rusqlite::Error) -> CoreError {
    CoreError::Storage { message: e.to_string() }
}

/// Applies the embedded DDL and seeds `schema_meta`. Safe to call repeatedly: every
/// statement is idempotent (`IF NOT EXISTS` / `INSERT OR IGNORE`).
pub(crate) fn run_migrations(conn: &Connection) -> Result<(), CoreError> {
    conn.execute_batch(DDL).map_err(map_sql)?;
    add_unit_id_column_if_missing(conn)?;
    conn.execute(
        "INSERT OR IGNORE INTO schema_meta (key, value) VALUES ('schema_version', '1')",
        [],
    )
    .map_err(map_sql)?;
    Ok(())
}

/// Adds the `unit_id` column to a pre-existing `assets` table that predates
/// this migration. `CREATE TABLE IF NOT EXISTS` in the embedded DDL above
/// only takes effect on a brand new database; a database created before
/// `unit_id` was added to the schema keeps its old column set forever unless
/// something explicitly alters it. Checked via `PRAGMA table_info` rather
/// than trying the `ALTER TABLE` and swallowing a "duplicate column" error,
/// so this stays idempotent and cheap to call on every open. Existing rows
/// get `unit_id = 0` (the same default a fresh insert would apply), which is
/// safe: those rows already cannot be thumbnailed until the next crawl
/// repopulates them with a real unit_id.
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

    #[test]
    fn migrations_are_idempotent() {
        let store = crate::Store::open_in_memory().expect("open");
        run_migrations(&store.conn).expect("rerun");
        assert_eq!(store.schema_version().expect("version"), 1);
    }

    /// A database created before `unit_id` existed (simulated here by
    /// creating the pre-migration `assets` shape directly) must still open
    /// cleanly: `run_migrations` adds the missing column rather than
    /// erroring on a table that already exists without it.
    #[test]
    fn legacy_assets_table_gains_unit_id_column_on_migration() {
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
            );",
        )
        .expect("legacy table");
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

        // Running again must not fail with a duplicate-column error.
        run_migrations(&conn).expect("second run is a no-op");
    }
}
