import Foundation
import GRDB

/// One library the user has: Apple Photos, a PhotoForge Library, or a read-only external
/// library/folder. Every library has its own database in its own data folder.
public struct LibraryEntry: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case applePhotos      // the System Photo Library, through PhotoKit
        case photoForge       // PhotoForge's own library package (.pflibrary): photos + database together
        case external         // another Photos/iPhoto library or a folder, read-only
    }
    public var id: UUID
    public var kind: Kind
    public var name: String
    /// External: the library or folder path. PhotoForge: the .pflibrary package path.
    public var sourcePath: String?
    /// Folder holding photoforge.sqlite, vector.key, FaceCrops/ and Backups/.
    public var dataPath: String
    public var createdAt: Date
    public var lastOpened: Date?
    public var assetCount: Int

    public init(id: UUID = UUID(), kind: Kind, name: String, sourcePath: String?, dataPath: String,
                createdAt: Date = .now, lastOpened: Date? = nil, assetCount: Int = 0) {
        self.id = id; self.kind = kind; self.name = name; self.sourcePath = sourcePath; self.dataPath = dataPath
        self.createdAt = createdAt; self.lastOpened = lastOpened; self.assetCount = assetCount
    }

    public var dataURL: URL { URL(fileURLWithPath: dataPath, isDirectory: true) }
    public var databaseURL: URL { dataURL.appendingPathComponent("photoforge.sqlite") }
    public var keyURL: URL { dataURL.appendingPathComponent("vector.key") }
    public var faceCropDir: URL { dataURL.appendingPathComponent("FaceCrops", isDirectory: true) }
    public var isReadOnly: Bool { kind == .external }
    public var kindLabel: String {
        switch kind {
        case .applePhotos: "Apple Photos"
        case .photoForge: "PhotoForge Library"
        case .external: "Read-only"
        }
    }
    /// Files that make up a library's data (what "Move Data" copies).
    public static let dataItems = ["photoforge.sqlite", "photoforge.sqlite-wal", "photoforge.sqlite-shm", "vector.key", "FaceCrops", "Backups"]
}

/// The list of libraries, stored as JSON in Application Support. It only points at
/// libraries; each library's data lives in its own folder, so the list can be rebuilt
/// ("Open Existing Library…") and survives app upgrades and reinstalls.
public final class LibraryRegistry: @unchecked Sendable {
    public private(set) var entries: [LibraryEntry] = []
    public var activeID: UUID? { didSet { try? save() } }
    public let fileURL: URL
    private let lock = NSLock()

    struct Stored: Codable { var libraries: [LibraryEntry]; var activeID: UUID?; var format: Int }

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let d = try? Data(contentsOf: fileURL), let s = try? Self.decoder.decode(Stored.self, from: d) {
            entries = s.libraries
            activeID = s.activeID
        }
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }
    public var active: LibraryEntry? { entries.first { $0.id == activeID } ?? entries.first }

    public func save() throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Self.encoder.encode(Stored(libraries: entries, activeID: activeID, format: 1))
        try data.write(to: fileURL, options: .atomic)
    }

    public func upsert(_ e: LibraryEntry) {
        if let i = entries.firstIndex(where: { $0.id == e.id }) { entries[i] = e } else { entries.append(e) }
        try? save()
    }

    public func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        if activeID == id { activeID = entries.first?.id }
        try? save()
    }

    public func entry(_ id: UUID) -> LibraryEntry? { entries.first { $0.id == id } }
    public func entry(sourcePath: String) -> LibraryEntry? { entries.first { $0.sourcePath == sourcePath } }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e
    }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    // MARK: One-time upgrade from the single combined database (builds 1–28)

    /// Earlier versions kept every library in one database. This gives each its own:
    /// the Apple Photos data stays exactly where it is (no rescan), and every other library
    /// gets a pruned copy in `Libraries/<id>/`. Nothing is lost; the combined file is backed up first.
    @discardableResult
    public static func upgradeCombinedDatabase(supportDir: URL, registry: LibraryRegistry) throws -> [LibraryEntry] {
        let fm = FileManager.default
        let legacy = supportDir.appendingPathComponent("photoforge.sqlite")
        var created: [LibraryEntry] = []
        guard fm.fileExists(atPath: legacy.path) else {
            let apple = LibraryEntry(kind: .applePhotos, name: "Apple Photos", sourcePath: nil, dataPath: supportDir.path)
            registry.upsert(apple)
            registry.activeID = apple.id
            return [apple]
        }
        let db = try AppDatabase.open(at: legacy)
        try? db.backup(reason: "before-split", keep: 5)
        let sources = try db.sourceIDs()
        let systemID: Int64
        if let sys = sources.first(where: { $0.kind == "photokit_system" }) { systemID = sys.id } else { systemID = try db.systemSourceID() }
        let lastActive = db.setting("activeLibraryID").flatMap(Int64.init)
        var activeEntry: UUID?

        for s in sources where s.id != systemID {
            let entry = LibraryEntry(kind: .external, name: s.name, sourcePath: s.path,
                                     dataPath: supportDir.appendingPathComponent("Libraries/\(UUID().uuidString)").path)
            try fm.createDirectory(at: entry.dataURL, withIntermediateDirectories: true)
            try db.copy(to: entry.databaseURL)
            let copy = try AppDatabase.open(at: entry.databaseURL)
            try copy.pruneToSource(keep: s.id)
            copy.setSetting("activeLibraryID", String(s.id))
            // Same key, so the copied (encrypted) vectors stay readable.
            let key = supportDir.appendingPathComponent("vector.key")
            if fm.fileExists(atPath: key.path) { try? fm.copyItem(at: key, to: entry.keyURL) }
            // Face thumbnails used by this library.
            try? fm.createDirectory(at: entry.faceCropDir, withIntermediateDirectories: true)
            for c in (try? copy.faceCropPaths()) ?? [] {
                try? fm.copyItem(at: supportDir.appendingPathComponent("FaceCrops/\(c)"), to: entry.faceCropDir.appendingPathComponent(c))
            }
            let n = (try? copy.stats(sourceID: s.id).photos) ?? 0
            var e = entry; e.assetCount = n
            registry.upsert(e)
            created.append(e)
            if lastActive == s.id { activeEntry = e.id }
        }
        if sources.count > 1 { try db.pruneToSource(keep: systemID) }
        db.setSetting("activeLibraryID", String(systemID))
        var apple = LibraryEntry(kind: .applePhotos, name: "Apple Photos", sourcePath: nil, dataPath: supportDir.path)
        apple.assetCount = (try? db.stats(sourceID: systemID).photos) ?? 0
        registry.upsert(apple)
        registry.activeID = activeEntry ?? apple.id
        return [apple] + created
    }
}

/// A PhotoForge Library: a folder package (`Name.pflibrary`) holding the photos and their
/// database together, so it can live on any drive and be moved or reopened on another Mac.
///
///     Name.pflibrary/
///       Library.json        manifest (format, id, name, created)
///       Database/           photoforge.sqlite, vector.key, FaceCrops/, Backups/
///       Originals/YYYY/MM/  imported photos and videos (never modified)
///       Edits/              edited and upscaled copies
///       Trash/              deleted items, recoverable until emptied
public enum PhotoForgePackage {
    public static let pathExtension = "pflibrary"
    public struct Manifest: Codable, Sendable {
        public var format: Int
        public var id: UUID
        public var name: String
        public var created: Date
        public var createdBy: String
    }

    public static func create(named name: String, in parent: URL) throws -> (url: URL, manifest: Manifest) {
        let fm = FileManager.default
        let safe = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        var url = parent.appendingPathComponent("\(safe.isEmpty ? "PhotoForge Library" : safe).\(pathExtension)")
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = parent.appendingPathComponent("\(safe) \(n).\(pathExtension)"); n += 1
        }
        for sub in ["Database", "Originals", "Edits", "Trash"] {
            try fm.createDirectory(at: url.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let m = Manifest(format: 1, id: UUID(), name: safe, created: .now, createdBy: "PhotoForge")
        try LibraryRegistry.encoder.encode(m).write(to: url.appendingPathComponent("Library.json"), options: .atomic)
        return (url, m)
    }

    public static func open(_ url: URL) throws -> Manifest {
        let data = try Data(contentsOf: url.appendingPathComponent("Library.json"))
        let m = try LibraryRegistry.decoder.decode(Manifest.self, from: data)
        guard m.format <= 1 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "This library was made by a newer PhotoForge."])
        }
        return m
    }

    public static func isPackage(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == pathExtension && FileManager.default.fileExists(atPath: url.appendingPathComponent("Library.json").path)
    }
}
