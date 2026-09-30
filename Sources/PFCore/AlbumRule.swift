import Foundation

/// The rule of a smart album: which photos belong is decided by who is in them, their names,
/// tags and categories, so the album keeps itself up to date as photos are added, named or
/// recognised.
public struct AlbumRule: Codable, Sendable, Hashable {
    public enum Match: String, Codable, Sendable, CaseIterable, Identifiable {
        case all, any
        public var id: String { rawValue }
    }
    public enum Media: String, Codable, Sendable, CaseIterable, Identifiable {
        case any, photos, videos
        public var id: String { rawValue }
    }

    /// How the criteria combine: every one must match, or any one is enough.
    public var match: Match = .all
    /// Person ids. `peopleMatch == .all` means photos where all of them appear together.
    public var people: [Int64] = []
    public var peopleMatch: Match = .any
    /// Name (title or file name) contains this text, ignoring case. Empty = not used.
    public var nameContains: String = ""
    /// Any of these tags. Empty = not used.
    public var tags: [String] = []
    /// Any of these categories (PhotoCategory raw values). Empty = not used.
    public var categories: [String] = []
    /// Always applied, whatever `match` says.
    public var media: Media = .any
    public var favoritesOnly = false

    public init() {}

    public var hasCriteria: Bool {
        !people.isEmpty || !nameContains.trimmingCharacters(in: .whitespaces).isEmpty || !tags.isEmpty || !categories.isEmpty
    }

    public struct Item: Sendable {
        public let id: Int64
        public let name: String
        public let isVideo: Bool
        public let favorite: Bool
        public init(id: Int64, name: String, isVideo: Bool, favorite: Bool) {
            self.id = id; self.name = name; self.isVideo = isVideo; self.favorite = favorite
        }
    }

    public struct Context: Sendable {
        public var personAssets: [Int64: Set<Int64>]
        public var tagAssets: [String: Set<Int64>]
        public var categoryAssets: [String: Set<Int64>]
        public init(personAssets: [Int64: Set<Int64>] = [:], tagAssets: [String: Set<Int64>] = [:],
                    categoryAssets: [String: Set<Int64>] = [:]) {
            self.personAssets = personAssets; self.tagAssets = tagAssets; self.categoryAssets = categoryAssets
        }
    }

    /// Ids of the items that belong to the album.
    public func evaluate(_ items: [Item], _ ctx: Context) -> Set<Int64> {
        var sets: [Set<Int64>] = []
        if !people.isEmpty {
            let each = people.map { ctx.personAssets[$0] ?? [] }
            sets.append(peopleMatch == .all ? each.dropFirst().reduce(each[0]) { $0.intersection($1) }
                                            : each.reduce(into: Set<Int64>()) { $0.formUnion($1) })
        }
        let needle = nameContains.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            sets.append(Set(items.lazy.filter { $0.name.localizedCaseInsensitiveContains(needle) }.map(\.id)))
        }
        if !tags.isEmpty {
            let lower = Dictionary(ctx.tagAssets.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { $0.union($1) })
            sets.append(tags.reduce(into: Set<Int64>()) { $0.formUnion(lower[$1.lowercased()] ?? []) })
        }
        if !categories.isEmpty {
            sets.append(categories.reduce(into: Set<Int64>()) { $0.formUnion(ctx.categoryAssets[$1] ?? []) })
        }
        let chosen: Set<Int64>?
        if sets.isEmpty { chosen = nil }
        else if match == .all { chosen = sets.dropFirst().reduce(sets[0]) { $0.intersection($1) } }
        else { chosen = sets.reduce(into: Set<Int64>()) { $0.formUnion($1) } }
        var out = Set<Int64>()
        for i in items {
            if let c = chosen, !c.contains(i.id) { continue }
            if media == .photos && i.isVideo { continue }
            if media == .videos && !i.isVideo { continue }
            if favoritesOnly && !i.favorite { continue }
            out.insert(i.id)
        }
        return out
    }

    /// One line describing the rule, e.g. "Ravi or Priya · name contains “farm”".
    public func summary(personName: (Int64) -> String?) -> String {
        var parts: [String] = []
        if !people.isEmpty {
            let names = people.compactMap(personName)
            parts.append(names.joined(separator: peopleMatch == .all ? " and " : " or ") + (peopleMatch == .all && names.count > 1 ? " together" : ""))
        }
        let needle = nameContains.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty { parts.append("name contains “\(needle)”") }
        if !tags.isEmpty { parts.append("tagged " + tags.joined(separator: " or ")) }
        if !categories.isEmpty { parts.append(categories.joined(separator: " or ")) }
        var s = parts.joined(separator: match == .all ? " · " : " — or — ")
        if media != .any { s += (s.isEmpty ? "" : " · ") + (media == .photos ? "photos only" : "videos only") }
        if favoritesOnly { s += (s.isEmpty ? "" : " · ") + "favorites" }
        return s.isEmpty ? "Everything" : s
    }

    public func encoded() -> String? { (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } }
    public static func decode(_ s: String?) -> AlbumRule? {
        guard let s, let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AlbumRule.self, from: d)
    }
}
