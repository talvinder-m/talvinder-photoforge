import Testing
@testable import PFCore

@Suite struct AlbumRuleTests {
    let items = [
        AlbumRule.Item(id: 1, name: "Farm Visit 001", isVideo: false, favorite: true),
        AlbumRule.Item(id: 2, name: "Farm Visit 002", isVideo: true, favorite: false),
        AlbumRule.Item(id: 3, name: "IMG_1234.JPG", isVideo: false, favorite: false),
        AlbumRule.Item(id: 4, name: "Goat shed", isVideo: false, favorite: true),
    ]
    let ctx = AlbumRule.Context(personAssets: [10: [1, 3], 11: [3, 4]],
                                tagAssets: ["Strawberry": [2, 4]], categoryAssets: ["receipt": [3]])

    @Test func personAny() {
        var r = AlbumRule(); r.people = [10, 11]
        #expect(r.evaluate(items, ctx) == [1, 3, 4])
    }
    @Test func peopleTogether() {
        var r = AlbumRule(); r.people = [10, 11]; r.peopleMatch = .all
        #expect(r.evaluate(items, ctx) == [3])
    }
    @Test func nameContainsIgnoresCase() {
        var r = AlbumRule(); r.nameContains = "farm visit"
        #expect(r.evaluate(items, ctx) == [1, 2])
    }
    @Test func tagIgnoresCase() {
        var r = AlbumRule(); r.tags = ["strawberry"]
        #expect(r.evaluate(items, ctx) == [2, 4])
    }
    @Test func allVersusAny() {
        var r = AlbumRule(); r.people = [10]; r.nameContains = "farm"
        #expect(r.evaluate(items, ctx) == [1])
        r.match = .any
        #expect(r.evaluate(items, ctx) == [1, 2, 3])
    }
    @Test func filtersAlwaysApply() {
        var r = AlbumRule(); r.nameContains = "farm"; r.media = .photos
        #expect(r.evaluate(items, ctx) == [1])
        var f = AlbumRule(); f.favoritesOnly = true
        #expect(f.evaluate(items, ctx) == [1, 4])
    }
    @Test func roundTrips() {
        var r = AlbumRule(); r.people = [5]; r.tags = ["a"]; r.categories = ["receipt"]; r.match = .any
        #expect(AlbumRule.decode(r.encoded()) == r)
        #expect(r.summary { $0 == 5 ? "Ravi" : nil }.contains("Ravi"))
    }
}
