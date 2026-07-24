import Testing
import PhotosCore
@testable import SynologyPhotos

/// Exercises the normalization from each core model into the shared
/// `DiscoveryTile` shape the tile grid renders, independent of any SwiftUI
/// view.
struct DiscoveryTileTests {
    @Test func unnamedPersonIsMarkedNamelessAndCarriesItsCollection() {
        let person = Person(id: 12279, name: "", itemCount: 23, coverUnitId: 39646, show: true)
        let tile = DiscoveryTile(person: person)
        #expect(tile.isNameless)
        #expect(tile.displayName.isEmpty)
        #expect(tile.coverUnitId == 39646)
        #expect(tile.collection == .person(id: 12279))
    }

    @Test func namedPersonIsNotNameless() {
        let person = Person(id: 1, name: "Sahil", itemCount: 5, coverUnitId: nil, show: true)
        let tile = DiscoveryTile(person: person)
        #expect(!tile.isNameless)
        #expect(tile.displayName == "Sahil")
        #expect(tile.coverUnitId == nil)
    }

    @Test func placeCarriesNoCoverAndRoutesToItsOwnId() {
        let place = Place(id: 756, name: "Sentrum, Norway", country: "Norway", firstLevel: "Norway", secondLevel: "Sentrum", itemCount: 16)
        let tile = DiscoveryTile(place: place)
        #expect(tile.coverUnitId == nil)
        #expect(!tile.isNameless)
        #expect(tile.collection == .place(id: 756))
        #expect(tile.itemCount == 16)
    }

    @Test func subjectHasNoRoutableCollection() {
        let subject = Subject(id: 103, name: "Food", itemCount: 2)
        let tile = DiscoveryTile(subject: subject)
        #expect(tile.collection == nil, "Subjects has no working photo filter on this NAS, so a subject tile must not be selectable")
        #expect(tile.displayName == "Food")
    }

    @Test func tagRoutesToItsOwnId() {
        let tag = Tag(id: 5, name: "vacation", itemCount: 4)
        let tile = DiscoveryTile(tag: tag)
        #expect(tile.collection == .tag(id: 5))
        #expect(!tile.isNameless)
    }
}
