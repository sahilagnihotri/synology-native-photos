import PhotosCore

/// A single tile in a discovery-browse grid (People/Places/Subjects/Tags/
/// Albums), normalized from whichever core model backs it so the grid view
/// has one shape to render regardless of collection type.
///
/// `coverUnitId` is `nil` for every kind except Person and Album:
/// Places/Subjects/Tags carry no cover thumbnail on the real NAS (verified:
/// Geocoding, Concept, and GeneralTag list rows have no thumbnail field),
/// so those tiles show a glyph placeholder instead of a photo. An Album's
/// `coverUnitId` is `nil` whenever the album has no cover yet (e.g. empty).
///
/// `isNameless` drives the disabled "Add Name" placeholder for an unnamed
/// person; naming is a later, gated mutation, never implemented by
/// selecting this tile.
///
/// `isSmart`/`isShared` are only ever set for an Album tile (`false` for
/// every other kind); the grid view uses them to show a small smart/shared
/// badge, per the brief.
struct DiscoveryTile: Identifiable, Hashable {
    let id: Int64
    let displayName: String
    let itemCount: UInt32
    let coverUnitId: Int64?
    /// The cache key to send alongside `coverUnitId` when fetching the
    /// cover thumbnail. Empty for every kind except Album (Person carries
    /// no cache_key on the real NAS, see `DiscoveryCoverCache`'s doc
    /// comment).
    let coverCacheKey: String
    let isNameless: Bool
    let isSmart: Bool
    let isShared: Bool
    /// What selecting this tile should route to, or `nil` if the tile is
    /// not selectable (a Subject tile: Subjects has no working photo
    /// filter on this NAS, see `DiscoveryKind.subjects`'s doc comment).
    let collection: DiscoveryCollection?

    init(person: Person) {
        id = person.id
        displayName = person.name
        itemCount = person.itemCount
        coverUnitId = person.coverUnitId
        coverCacheKey = ""
        isNameless = person.name.isEmpty
        isSmart = false
        isShared = false
        collection = .person(id: person.id)
    }

    init(place: Place) {
        id = place.id
        displayName = place.name
        itemCount = place.itemCount
        coverUnitId = nil
        coverCacheKey = ""
        isNameless = false
        isSmart = false
        isShared = false
        collection = .place(id: place.id)
    }

    init(subject: Subject) {
        id = subject.id
        displayName = subject.name
        itemCount = subject.itemCount
        coverUnitId = nil
        coverCacheKey = ""
        isNameless = false
        isSmart = false
        isShared = false
        // Subjects (Concept) has no working Browse.Item filter on the real
        // NAS (every candidate param tried was rejected or silently
        // ignored; see the discovery-browse plan doc), so a subject tile
        // has nothing to route to yet.
        collection = nil
    }

    init(tag: Tag) {
        id = tag.id
        displayName = tag.name
        itemCount = tag.itemCount
        coverUnitId = nil
        coverCacheKey = ""
        isNameless = false
        isSmart = false
        isShared = false
        collection = .tag(id: tag.id)
    }

    init(album: Album) {
        id = album.id
        displayName = album.name
        itemCount = album.itemCount
        coverUnitId = album.coverUnitId
        coverCacheKey = album.coverCacheKey ?? ""
        isNameless = false
        isSmart = album.isSmart
        isShared = album.isShared
        collection = .album(id: album.id)
    }
}
