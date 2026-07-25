//! Small per-space key/value store for app-owned identifiers that must
//! survive process restarts.
//!
//! The first (and, for now, only) use is the id of the app-created
//! "Recently Deleted" album. Owning that album by a PERSISTED id rather than
//! by a name match is a safety property: without it, the delete feature would
//! adopt any album a user happened to name "Recently Deleted" and start
//! treating its contents as permanent-delete eligible. Storing the id the app
//! itself created, and never adopting by name, closes that off.

use crate::assets::space_to_int;
use crate::schema::map_sql;
use crate::Store;
use models::{CoreError, Space};
use rusqlite::{params, OptionalExtension};

impl Store {
    /// Reads the value stored under `(space, key)`, or `None` if unset.
    pub fn get_app_state(&self, space: Space, key: &str) -> Result<Option<String>, CoreError> {
        self.conn
            .query_row(
                "SELECT value FROM app_state WHERE space = ?1 AND key = ?2",
                params![space_to_int(space), key],
                |r| r.get::<_, String>(0),
            )
            .optional()
            .map_err(map_sql)
    }

    /// Inserts or replaces the value stored under `(space, key)`.
    pub fn set_app_state(&self, space: Space, key: &str, value: &str) -> Result<(), CoreError> {
        self.conn
            .execute(
                "INSERT INTO app_state (space, key, value) VALUES (?1, ?2, ?3)
                 ON CONFLICT(space, key) DO UPDATE SET value = excluded.value",
                params![space_to_int(space), key, value],
            )
            .map_err(map_sql)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use crate::Store;
    use models::Space;

    #[test]
    fn get_is_none_when_unset() {
        let store = Store::open_in_memory().unwrap();
        assert_eq!(store.get_app_state(Space::Personal, "trash_album_id").unwrap(), None);
    }

    #[test]
    fn set_then_get_round_trips() {
        let store = Store::open_in_memory().unwrap();
        store.set_app_state(Space::Personal, "trash_album_id", "500").unwrap();
        assert_eq!(store.get_app_state(Space::Personal, "trash_album_id").unwrap(), Some("500".to_string()));
    }

    #[test]
    fn set_overwrites_existing_value() {
        let store = Store::open_in_memory().unwrap();
        store.set_app_state(Space::Personal, "trash_album_id", "500").unwrap();
        store.set_app_state(Space::Personal, "trash_album_id", "777").unwrap();
        assert_eq!(store.get_app_state(Space::Personal, "trash_album_id").unwrap(), Some("777".to_string()));
    }

    #[test]
    fn spaces_are_isolated() {
        let store = Store::open_in_memory().unwrap();
        store.set_app_state(Space::Personal, "trash_album_id", "500").unwrap();
        assert_eq!(store.get_app_state(Space::Shared, "trash_album_id").unwrap(), None);
        store.set_app_state(Space::Shared, "trash_album_id", "900").unwrap();
        assert_eq!(store.get_app_state(Space::Personal, "trash_album_id").unwrap(), Some("500".to_string()));
        assert_eq!(store.get_app_state(Space::Shared, "trash_album_id").unwrap(), Some("900".to_string()));
    }
}
