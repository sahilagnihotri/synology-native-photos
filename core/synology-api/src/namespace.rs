use models::Space;

pub fn browse_item_api(space: Space) -> &'static str {
    match space {
        Space::Personal => "SYNO.Foto.Browse.Item",
        Space::Shared => "SYNO.FotoTeam.Browse.Item",
    }
}

pub fn browse_album_api(space: Space) -> &'static str {
    match space {
        Space::Personal => "SYNO.Foto.Browse.Album",
        Space::Shared => "SYNO.FotoTeam.Browse.Album",
    }
}

/// The album-mutation surface used to create an album and add/remove its
/// members (`create`/`add_item`/`delete_item`). This is the `NormalAlbum`
/// API, distinct from `browse_album_api`'s generic `.Album` surface: verified
/// against the real NAS, `create`/`add_item`/`delete_item` live on
/// `SYNO.Foto.Browse.NormalAlbum`, while deleting a whole album goes through
/// the generic `SYNO.Foto.Browse.Album` `delete` (see `album_write.rs`).
/// Only Personal is exercised against the real NAS; the `FotoTeam` mapping is
/// kept for symmetry with the rest of this module.
pub fn normal_album_api(space: Space) -> &'static str {
    match space {
        Space::Personal => "SYNO.Foto.Browse.NormalAlbum",
        Space::Shared => "SYNO.FotoTeam.Browse.NormalAlbum",
    }
}

pub fn thumbnail_api(space: Space) -> &'static str {
    match space {
        Space::Personal => "SYNO.Foto.Thumbnail",
        Space::Shared => "SYNO.FotoTeam.Thumbnail",
    }
}

pub fn download_api(space: Space) -> &'static str {
    match space {
        Space::Personal => "SYNO.Foto.Download",
        Space::Shared => "SYNO.FotoTeam.Download",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn personal_maps_to_foto() {
        assert_eq!(browse_item_api(Space::Personal), "SYNO.Foto.Browse.Item");
        assert_eq!(browse_album_api(Space::Personal), "SYNO.Foto.Browse.Album");
        assert_eq!(normal_album_api(Space::Personal), "SYNO.Foto.Browse.NormalAlbum");
        assert_eq!(thumbnail_api(Space::Personal), "SYNO.Foto.Thumbnail");
        assert_eq!(download_api(Space::Personal), "SYNO.Foto.Download");
    }

    #[test]
    fn shared_maps_to_fototeam() {
        assert_eq!(browse_item_api(Space::Shared), "SYNO.FotoTeam.Browse.Item");
        assert_eq!(browse_album_api(Space::Shared), "SYNO.FotoTeam.Browse.Album");
        assert_eq!(normal_album_api(Space::Shared), "SYNO.FotoTeam.Browse.NormalAlbum");
        assert_eq!(thumbnail_api(Space::Shared), "SYNO.FotoTeam.Thumbnail");
        assert_eq!(download_api(Space::Shared), "SYNO.FotoTeam.Download");
    }
}
