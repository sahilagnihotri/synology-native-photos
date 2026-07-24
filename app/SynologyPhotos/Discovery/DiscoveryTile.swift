import PhotosCore

/// A single tile in a discovery-browse grid (People/Places/Subjects/Tags),
/// normalized from whichever core model backs it so the grid view has one
/// shape to render regardless of collection type.
///
/// `coverUnitId` is `nil` for every kind except Person: Places/Subjects/Tags
/// carry no cover thumbnail on the real NAS (verified: Geocoding, Concept,
/// and GeneralTag list rows have no thumbnail field), so those tiles show a
/// glyph placeholder instead of a photo.
///
/// `isNameless` drives the disabled "Add Name" placeholder for an unnamed
/// person; naming is a later, gated mutation, never implemented by
/// selecting this tile.
struct DiscoveryTile: Identifiable, Hashable {
    let id: Int64
    let displayName: String
    let itemCount: UInt32
    let coverUnitId: Int64?
    let isNameless: Bool
    /// What selecting this tile should route to, or `nil` if the tile is
    /// not selectable (a Subject tile: Subjects has no working photo
    /// filter on this NAS, see `DiscoveryKind.subjects`'s doc comment).
    let collection: DiscoveryCollection?

    init(person: Person) {
        id = person.id
        displayName = person.name
        itemCount = person.itemCount
        coverUnitId = person.coverUnitId
        isNameless = person.name.isEmpty
        collection = .person(id: person.id)
    }

    init(place: Place) {
        id = place.id
        displayName = place.name
        itemCount = place.itemCount
        coverUnitId = nil
        isNameless = false
        collection = .place(id: place.id)
    }

    init(subject: Subject) {
        id = subject.id
        displayName = subject.name
        itemCount = subject.itemCount
        coverUnitId = nil
        isNameless = false
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
        isNameless = false
        collection = .tag(id: tag.id)
    }
}
