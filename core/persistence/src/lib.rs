//! SQLite persistence via rusqlite: migrations and windowed queries.

mod albums;
mod app_state;
mod assets;
mod schema;
mod sync_state;

use models::CoreError;
use rusqlite::Connection;
use std::path::Path;

pub use sync_state::SyncStateRow;

/// Facade over a single SQLite connection holding the local mirror of NAS state.
pub struct Store {
    pub(crate) conn: Connection,
}

impl Store {
    /// Opens an in-memory database and applies migrations. Used by tests and any
    /// caller that does not need the mirror to survive process restarts.
    pub fn open_in_memory() -> Result<Store, CoreError> {
        let conn = Connection::open_in_memory().map_err(schema::map_sql)?;
        schema::run_migrations(&conn)?;
        Ok(Store { conn })
    }

    /// Opens (or creates) the database file at `path` and applies migrations.
    pub fn open_at(path: &Path) -> Result<Store, CoreError> {
        let conn = Connection::open(path).map_err(schema::map_sql)?;
        schema::run_migrations(&conn)?;
        Ok(Store { conn })
    }

    /// Returns the applied schema version recorded in `schema_meta`.
    pub fn schema_version(&self) -> Result<i64, CoreError> {
        self.conn
            .query_row(
                "SELECT value FROM schema_meta WHERE key = 'schema_version'",
                [],
                |r| r.get::<_, String>(0),
            )
            .map_err(schema::map_sql)?
            .parse::<i64>()
            .map_err(|e| CoreError::Storage { message: e.to_string() })
    }
}
