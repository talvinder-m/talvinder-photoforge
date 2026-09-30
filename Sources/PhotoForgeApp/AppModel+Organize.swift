import Foundation
import PFCore
import PFDatabase

// MARK: - Smart albums, person albums and tags

extension AppModel {
    @discardableResult
    func createSmartAlbum(title: String, rule: AlbumRule, parent: Int64? = nil) -> Int64? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let db else { return nil }
        let id = try? db.createAlbum(title: t, parentID: parent, isFolder: false, sourceID: activeLibraryID, rule: rule)
        db.log("edit", "Created smart album “\(t)”")
        reloadAlbums()
        return id
    }

    func updateSmartAlbum(_ id: Int64, rule: AlbumRule) {
        try? db?.setAlbumRule(id, rule)
        reloadAlbums()
    }

    /// Turns a smart album into an ordinary album with the photos it has right now.
    func freezeSmartAlbum(_ id: Int64) {
        let current = Array(smartAlbumMembers[id] ?? [])
        try? db?.setAlbumRule(id, nil, freeze: current)
        reloadAlbums()
    }

    /// An album of everyone's photos of a person. `smart` keeps adding photos as PhotoForge
    /// recognises the person in more of them; otherwise it's a fixed album of today's photos.
    @discardableResult
    func createPersonAlbum(_ person: PersonVM, smart: Bool, title: String? = nil) -> Int64? {
        let name = title ?? person.name ?? "Person"
        if smart, let pid = person.personID {
            var r = AlbumRule(); r.people = [pid]
            return createSmartAlbum(title: name, rule: r)
        }
        var seen = Set<Int64>()
        let ids = person.faces.map(\.assetID).filter { seen.insert($0).inserted }
        return createAlbum(title: name, assetIDs: ids)
    }

    /// Photos in a smart album right now, for a live preview while editing its rule.
    func preview(_ rule: AlbumRule) -> Set<Int64> {
        let items = assets.map { AlbumRule.Item(id: $0.id, name: $0.displayName, isVideo: $0.isVideo, favorite: $0.favorite) }
        return rule.evaluate(items, ruleContext())
    }

    func personName(_ id: Int64) -> String? { people.first { $0.personID == id }?.name }

    // Tags

    var tagNames: [String] { userTags.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }

    func tags(of assetID: Int64) -> [String] { tagNames.filter { userTags[$0]?.contains(assetID) == true } }

    func addTag(_ label: String, to ids: [Int64]) async {
        let l = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty, !ids.isEmpty, let db else { return }
        await Task.detached { try? db.addTag(l, to: ids) }.value
        db.log("edit", "Tagged \(ids.count) item(s) “\(l)”")
        await reloadTags()
    }

    func removeTag(_ label: String, from ids: [Int64]) async {
        guard let db else { return }
        await Task.detached { try? db.removeTag(label, from: ids) }.value
        await reloadTags()
    }

    func renameTag(_ old: String, to new: String) async {
        try? db?.renameTag(old, to: new)
        if selection == .tag(old) { selection = .tag(new.trimmingCharacters(in: .whitespacesAndNewlines)) }
        await reloadTags()
    }

    func deleteTag(_ label: String) async {
        try? db?.deleteTag(label)
        if selection == .tag(label) { selection = .allPhotos }
        await reloadTags()
    }

    func reloadTags() async {
        guard let db else { return }
        let sid = activeLibraryID
        if let t = try? await Task.detached(operation: { try db.userTags(sourceID: sid) }).value { userTags = t }
        reloadAlbums()
    }
}
