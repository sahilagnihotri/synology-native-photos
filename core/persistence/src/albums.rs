//! Album upsert and per-space fetch (local index only; nothing crawls
//! albums into this table yet, so this is currently exercised only by
//! tests, kept ready for a future album-crawl pass).
//!
//! Mirrors the asset pattern in `assets.rs`: idempotent upsert keyed on
//! `(space, server_id)`, ordered fetch scoped to a single space.
//!
//! The local `albums` table has no columns for `cover_unit_id`/`is_shared`/
//! `is_smart` (added to `models::Album` for the live NAS-backed albums
//! browse feature, which reads directly from `synology_api::list_albums`,
//! never through this local index). `upsert_album` silently drops those
//! three fields and `fetch_albums` always reconstructs them as `None`/
//! `false`/`false`; this is safe today because nothing populates them via
//! this path, and a future album-crawl pass is the natural place to extend
//! the schema alongside actually writing real values into it.
use crate::assets::{int_to_space, now_secs, space_to_int};
use crate::schema::map_sql;
use crate::Store;
use models::{Album, CoreError, Space};
use rusqlite::params;

impl Store {
    /// Inserts a new album row or updates it in place, keyed on `(space, server_id)`.
    /// Re-crawling the same server album never duplicates a row.
    pub fn upsert_album(&self, album: &Album) -> Result<(), CoreError> {
        self.conn
            .execute(
                "INSERT INTO albums
                    (space, server_id, name, item_count, cover_cache_key, updated_at)
                 VALUES (?1,?2,?3,?4,?5,?6)
                 ON CONFLICT(space, server_id) DO UPDATE SET
                     name            = excluded.name,
                     item_count      = excluded.item_count,
                     cover_cache_key = excluded.cover_cache_key,
                     updated_at      = excluded.updated_at",
                params![
                    space_to_int(album.space),
                    album.id,
                    album.name,
                    album.item_count as i64,
                    album.cover_cache_key,
                    now_secs(),
                ],
            )
            .map_err(map_sql)?;
        Ok(())
    }

    /// Returns all albums for `space`, ordered by name. Space isolation is
    /// enforced by the WHERE clause: a Personal fetch never returns Shared rows.
    pub fn fetch_albums(&self, space: Space) -> Result<Vec<Album>, CoreError> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT server_id, name, item_count, cover_cache_key, space
                 FROM albums WHERE space = ?1 ORDER BY name ASC",
            )
            .map_err(map_sql)?;
        let rows = stmt
            .query_map(params![space_to_int(space)], |r| {
                Ok(Album {
                    id: r.get(0)?,
                    name: r.get(1)?,
                    item_count: r.get::<_, i64>(2)? as u32,
                    cover_cache_key: r.get(3)?,
                    cover_unit_id: None,
                    is_shared: false,
                    is_smart: false,
                    space: int_to_space(r.get::<_, i64>(4)?),
                })
            })
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
    use models::{Album, Space};

    fn album(space: Space, id: i64, name: &str) -> Album {
        Album {
            id,
            name: name.to_string(),
            item_count: 5,
            cover_cache_key: Some(format!("cover{id}")),
            cover_unit_id: None,
            is_shared: false,
            is_smart: false,
            space,
        }
    }

    #[test]
    fn upsert_and_fetch_albums_ordered_by_name_within_space() {
        let store = Store::open_in_memory().unwrap();
        store.upsert_album(&album(Space::Personal, 1, "Zebra")).unwrap();
        store.upsert_album(&album(Space::Personal, 2, "Apple")).unwrap();
        store.upsert_album(&album(Space::Shared, 3, "ShouldNotAppear")).unwrap();
        let names: Vec<String> = store
            .fetch_albums(Space::Personal)
            .unwrap()
            .iter()
            .map(|a| a.name.clone())
            .collect();
        assert_eq!(names, vec!["Apple", "Zebra"]);
    }

    #[test]
    fn upsert_album_idempotent() {
        let store = Store::open_in_memory().unwrap();
        store.upsert_album(&album(Space::Personal, 1, "Trip")).unwrap();
        let mut updated = album(Space::Personal, 1, "Trip 2024");
        updated.item_count = 42;
        store.upsert_album(&updated).unwrap();
        let albums = store.fetch_albums(Space::Personal).unwrap();
        assert_eq!(albums.len(), 1);
        assert_eq!(albums[0].name, "Trip 2024");
        assert_eq!(albums[0].item_count, 42);
    }

    #[test]
    fn fetch_albums_does_not_leak_across_spaces() {
        let store = Store::open_in_memory().unwrap();
        store.upsert_album(&album(Space::Personal, 1, "Family")).unwrap();
        store.upsert_album(&album(Space::Shared, 2, "Team Trip")).unwrap();
        store.upsert_album(&album(Space::Shared, 3, "Team Party")).unwrap();

        let personal = store.fetch_albums(Space::Personal).unwrap();
        assert_eq!(personal.len(), 1);
        assert!(personal.iter().all(|a| a.space == Space::Personal));
        assert!(personal.iter().all(|a| a.id != 2 && a.id != 3));

        let shared = store.fetch_albums(Space::Shared).unwrap();
        assert_eq!(shared.len(), 2);
        assert!(shared.iter().all(|a| a.space == Space::Shared));
    }

    #[test]
    fn round_trip_preserves_all_fields() {
        let store = Store::open_in_memory().unwrap();
        let original = Album {
            id: 88,
            name: "Round Trip".to_string(),
            item_count: 123,
            cover_cache_key: Some("cover-round-trip".to_string()),
            cover_unit_id: None,
            is_shared: false,
            is_smart: false,
            space: Space::Shared,
        };
        store.upsert_album(&original).unwrap();
        let albums = store.fetch_albums(Space::Shared).unwrap();
        assert_eq!(albums.len(), 1);
        let round_tripped = &albums[0];
        assert_eq!(round_tripped.id, original.id);
        assert_eq!(round_tripped.name, original.name);
        assert_eq!(round_tripped.item_count, original.item_count);
        assert_eq!(round_tripped.cover_cache_key, original.cover_cache_key);
        assert_eq!(round_tripped.space, original.space);
    }

    #[test]
    fn cover_cache_key_none_round_trips() {
        let store = Store::open_in_memory().unwrap();
        let mut a = album(Space::Personal, 1, "No Cover");
        a.cover_cache_key = None;
        store.upsert_album(&a).unwrap();
        let albums = store.fetch_albums(Space::Personal).unwrap();
        assert_eq!(albums[0].cover_cache_key, None);
    }
}
