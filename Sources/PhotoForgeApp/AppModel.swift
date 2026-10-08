import Foundation
import SwiftUI
import AppKit
import Observation
import PFCore
import PFDatabase
import PFPhotosBridge
import PFVision
import PFSimilarity
import PFPeople
import PFJobs
import PFEditing
import PFSafety
import PFClassify

enum DupSection: String, Hashable { case all, exact, near, burst, similar }

enum SidebarItem: Hashable {
    case category(PhotoCategory)
    case folder(String)
    case album(Int64)
    case tag(String)
    case duplicates(DupSection)
    case dashboard, allPhotos, videos, favorites, screenshots, blurry, iCloudOnly, sharedAlbums
    case removalQueue, people
    case activity, settings
}

/// One duplicate/similar group as shown in the UI.
struct DuplicateGroupVM: Identifiable, Hashable {
    let id: String                 // stable: type + sorted member ids
    let type: DuplicateGroupType
    let members: [AssetRow]        // in rank order (best first)
    let scores: [Int64: Double]
    let recommended: Int64?
    let explanation: String
    let similarity: Double
    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// A person as shown in the UI: a named/confirmed person, or a "Possible Person" cluster.
struct PersonVM: Identifiable, Hashable {
    let id: String                 // "p<personID>" or "c<index>"
    var personID: Int64?
    var name: String?
    var confidence: PersonConfidence
    var faces: [StoredFace]
    var isHidden: Bool
    var title: String { name ?? "Possible Person" }
    static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.faces.count == b.faces.count && a.name == b.name }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct ReviewFaceVM: Identifiable {
    let face: StoredFace
    let reason: ReviewItem.Reason
    var id: Int64 { face.id }
}

struct IndexStatus: Equatable {
    var running = false
    var paused = false
    var message = ""
    var fraction: Double = 0
    var throttle: String?
}

@MainActor
@Observable
final class AppModel {
    // Services
    var db: AppDatabase?
    var cipher: VectorCipher?
    let photos = PhotoLibraryService()
    let jobs = JobManager(maxConcurrentJobs: 1)
    let renderer = EditRenderer()
    let policy = GenerativeEditPolicy()
    let faceModel = FaceEmbedding.load()
    let superRes = SuperResolution(modelsDirectory: Bundle.main.resourceURL?.appendingPathComponent("Models"),
                                   computeUnits: MachineProfile.detect().mlComputeUnits)

    // State
    var startupError: String?
    var access: PhotoLibraryService.AccessState = .notDetermined
    var selection: SidebarItem? = .dashboard
    var assets: [AssetRow] = [] { didSet { dataVersion &+= 1 } }
    /// Bumped whenever anything the photo grid shows changes, so the grid recomputes only then.
    var dataVersion = 0
    var assetsByID: [Int64: AssetRow] = [:]
    var stats = LibraryStats()
    var status = IndexStatus()
    var syncing = false
    var duplicateGroups: [DuplicateGroupVM] = []
    /// Every group found by the last full scan, before hiding ones already dealt with.
    private var allDuplicateGroups: [DuplicateGroupVM] = []
    var removalQueue: [(assetID: Int64, reason: String)] = []
    var people: [PersonVM] = []
    var reviewFaces: [ReviewFaceVM] = []
    var activity: [ActivityEntry] = []
    var editingAsset: AssetRow?
    var upscaleRequest: AssetRow?
    var slideshowRequest: SlideshowRequest?

    // Categories and folders
    var categoryMembers: [PhotoCategory: Set<Int64>] = [:] { didSet { dataVersion &+= 1 } }
    var folderTree: [AlbumNode] = []
    var folderIndex: [String: AlbumNode] = [:] { didSet { dataVersion &+= 1 } }
    var banner: String?

    // Libraries. Each has its own database; only one is open at a time.
    let registry = LibraryRegistry(fileURL: AppModel.supportDir.appendingPathComponent("Libraries.json"))
    var libraries: [LibraryEntry] = []
    var activeEntry: LibraryEntry?
    /// The open library's id inside its own database (used to scope queries).
    var activeLibraryID: Int64?
    private(set) var externalSource: FileLibrarySource?
    private(set) var managedSource: ManagedLibrarySource?
    var isSystemLibrary: Bool { (activeEntry?.kind ?? .applePhotos) == .applePhotos }
    var isManagedLibrary: Bool { activeEntry?.kind == .photoForge }
    var faceCropDir: URL { activeEntry?.faceCropDir ?? Self.supportDir.appendingPathComponent("FaceCrops", isDirectory: true) }
    /// Assets of the active library (the database load is already scoped to it).
    var visibleAssets: [AssetRow] { assets }
    var mediaSource: any MediaSource {
        if let m = managedSource { return m }
        if let e = externalSource { return e }
        return photos
    }
    var canDelete: Bool { mediaSource.capabilities.canDelete }
    var canSaveToLibrary: Bool { mediaSource.capabilities.canAddToLibrary }

    func thumbnail(for key: String, side: Double) async -> NSImage? {
        await mediaSource.thumbnail(for: key, side: side)
    }

    // Settings (persisted in the settings table)
    var faceAnalysisEnabled = true { didSet { save("faceAnalysisEnabled", faceAnalysisEnabled) } }
    var storeFaceCrops = true { didSet { save("storeFaceCrops", storeFaceCrops) } }
    var sceneSimilarityEnabled = true { didSet { save("semanticIndexEnabled", sceneSimilarityEnabled) } }
    var allowICloudDownloads = false { didSet { save("allowICloudDownloads", allowICloudDownloads) } }
    var activityLogEnabled = true { didSet { save("activityLogEnabled", activityLogEnabled) } }
    var duplicateStrictness = 0.5 { didSet { save("duplicateStrictness", duplicateStrictness) } }
    var faceStrictness = 0.5 { didSet { save("faceStrictness", faceStrictness) } }
    var classifyEnabled = true { didSet { save("classifyEnabled", classifyEnabled) } }

    var currentJob: UUID?
    private var loadingSettings = false
    var storedFaces: [StoredFace] = []
    var importStatus: ImportProgress?

    // This Mac
    var machine = MachineProfile.detect()
    var performanceMode: PerformanceMode = PerformanceMode(rawValue: UserDefaults.standard.string(forKey: "performanceMode") ?? "") ?? .automatic {
        didSet { UserDefaults.standard.set(performanceMode.rawValue, forKey: "performanceMode"); applyMachineProfile() }
    }
    var analysisConcurrency = 2

    /// Face id → id of the PersonVM it's shown under.
    var faceOwnerIndex: [Int64: String] = [:]
    /// Nearest-neighbour lists for faces, kept between regroupings (per library).
    var faceGraph = FaceNeighborCache(k: 30, minSimilarity: 0.2)
    var regroupTask: Task<Void, Never>?
    /// True while faces are being regrouped in the background.
    var peopleBusy = false
    /// The person just named, so the People screen keeps it selected when its id changes.
    var lastNamedPersonKey: String?
    var playRequest: AssetRow?
    var importTask: Task<Void, Never>?

    // PhotoForge albums (custom groups) of the open library
    var albums: [PFAlbum] = [] { didSet { dataVersion &+= 1 } }
    /// Tags you added → items.
    var userTags: [String: Set<Int64>] = [:] { didSet { dataVersion &+= 1 } }
    /// Current members of each smart album (recomputed when photos, people or tags change).
    var smartAlbumMembers: [Int64: Set<Int64>] = [:]
    var albumTree: [AlbumNode] = []

    // Other apps' access
    let apiServer = LocalAPIServer()

    static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PhotoForge", isDirectory: true)
    }()

    // MARK: Startup

    func bootstrap() async {
        machine = MachineProfile.detect()
        applyMachineProfile()
        await jobs.startMonitoringSystem()
        Task { await self.consumeJobEvents() }
        do {
            if !registry.exists {
                // First launch of this version: give every existing library its own database.
                try LibraryRegistry.upgradeCombinedDatabase(supportDir: Self.supportDir, registry: registry)
            }
        } catch {
            startupError = "Couldn't prepare PhotoForge's libraries: \(error.localizedDescription)"
            return
        }
        libraries = registry.entries
        access = photos.accessState
        if let entry = registry.active, await open(entry) {
            // opened
        } else if let apple = libraries.first(where: { $0.kind == .applePhotos }), await open(apple) {
            // fell back to Apple Photos
        } else {
            startupError = "Couldn't open any library."
            return
        }
        if access == .authorized || access == .limited {
            _ = await photos.requestAccess()          // registers the change observer; no prompt when already decided
            watchLibraryChanges()
        }
        apiServer.restoreIfEnabled(model: self)
    }

    // MARK: Libraries

    func refreshLibraries() {
        if let e = activeEntry {
            var updated = e
            updated.assetCount = stats.photos + stats.videos
            updated.lastOpened = .now
            registry.upsert(updated)
            activeEntry = updated
        }
        libraries = registry.entries
    }

    /// Opens a library: its own database, key and photo source. Returns false (with a banner) on failure.
    @discardableResult
    func open(_ entry: LibraryEntry) async -> Bool {
        await cancelAnalysis()
        do {
            try FileManager.default.createDirectory(at: entry.dataURL, withIntermediateDirectories: true)
            let newDB = try AppDatabase.open(at: entry.databaseURL)
            let newCipher = try VectorCipher(store: .file(entry.keyURL))
            var sid: Int64
            var ext: FileLibrarySource? = nil, managed: ManagedLibrarySource? = nil
            switch entry.kind {
            case .applePhotos:
                sid = try newDB.systemSourceID()
            case .external:
                guard let path = entry.sourcePath else { throw CocoaError(.fileNoSuchFile) }
                let src = try FileLibrarySource(url: URL(fileURLWithPath: path))
                sid = try newDB.addLibrary(kind: src.inspection.kind == .folder ? "import_folder" : "photoslibrary_readonly",
                                           name: entry.name, path: path)
                src.register(try newDB.filePaths(sourceID: sid).mapValues { URL(fileURLWithPath: $0) })
                ext = src
            case .photoForge:
                guard let path = entry.sourcePath else { throw CocoaError(.fileNoSuchFile) }
                let url = URL(fileURLWithPath: path)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey:
                        "The library “\(entry.name)” isn't available. If it's on an external drive, connect the drive and try again."])
                }
                _ = try PhotoForgePackage.open(url)
                sid = try newDB.addLibrary(kind: "import_folder", name: entry.name, path: path)
                let src = ManagedLibrarySource(root: url)
                src.register(try newDB.filePaths(sourceID: sid))
                managed = src
            }
            // Switch over.
            db = newDB
            cipher = newCipher
            externalSource = ext
            managedSource = managed
            activeLibraryID = sid
            activeEntry = entry
            registry.activeID = entry.id
            loadSettings()
            if let inUse = try? newDB.faceEmbeddingModels(), !inUse.isEmpty, inUse != [faceModel.name] {
                _ = try? await newDB.deleteAllFaceData(faceCropDirectory: entry.faceCropDir, keepAnalysisEnabled: true)
                banner = "Face grouping was upgraded to a more accurate model. Run Analyze Photos to rebuild People."
            }
            ThumbnailCache.shared.removeAll()
            assets = []; assetsByID = [:]; duplicateGroups = []; allDuplicateGroups = []; people = []; reviewFaces = []; storedFaces = []
            userTags = [:]; smartAlbumMembers = [:]
            faceGraph = FaceNeighborCache(k: 30, minSimilarity: 0.2)
            categoryMembers = [:]; folderTree = []; folderIndex = [:]; albums = []
            if selection == .iCloudOnly || selection == .sharedAlbums { selection = .allPhotos }
            if case .folder = selection { selection = .allPhotos }
            if case .album = selection { selection = .allPhotos }
            if case .tag = selection { selection = .allPhotos }
            await reloadFromDatabase(full: true)
            refreshLibraries()
            if entry.kind != .applePhotos || access == .authorized || access == .limited { await syncLibrary() }
            return true
        } catch {
            banner = "Couldn't open “\(entry.name)”: \(error.localizedDescription)"
            return false
        }
    }

    func switchLibrary(_ id: UUID) async {
        guard id != activeEntry?.id, let e = registry.entry(id) else { return }
        await open(e)
    }

    /// Libraries found in the usual places that aren't already listed.
    func discoverLibraries() async -> [URL] {
        let known = Set(libraries.compactMap(\.sourcePath))
        return await Offload.run { FileLibrarySource.discoverLibraries() }.filter { !known.contains($0.path) }
    }

    func chooseLibraryWithPanel() async {
        let panel = NSOpenPanel()
        panel.title = "Open a Library or Folder"
        panel.message = "Pick a PhotoForge Library (.pflibrary), a Photos library (.photoslibrary), an iPhoto library, or any folder of photos."
        panel.prompt = "Open"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await openLibrary(at: url)
    }

    /// Adds (or reopens) a library at a path: a PhotoForge Library, or a read-only library/folder.
    func openLibrary(at url: URL) async {
        if let known = registry.entry(sourcePath: url.path) { await open(known); return }
        do {
            let entry: LibraryEntry
            if PhotoForgePackage.isPackage(url) {
                let m = try PhotoForgePackage.open(url)
                entry = LibraryEntry(id: m.id, kind: .photoForge, name: m.name, sourcePath: url.path,
                                     dataPath: url.appendingPathComponent("Database").path)
            } else {
                let inspection = try FileLibrarySource.inspect(url)
                entry = LibraryEntry(kind: .external, name: inspection.name, sourcePath: url.path,
                                     dataPath: Self.supportDir.appendingPathComponent("Libraries/\(UUID().uuidString)").path)
            }
            registry.upsert(entry)
            libraries = registry.entries
            if await open(entry) { db?.log("scan", "Opened library “\(entry.name)” (\(entry.kindLabel))") }
        } catch {
            banner = error.localizedDescription
        }
    }

    /// Removes a library from the list. Its photos are never touched. For read-only and Apple Photos
    /// libraries PhotoForge's data can also be deleted; a PhotoForge Library keeps its data inside it.
    func forgetLibrary(_ id: UUID, deleteData: Bool) async {
        guard let e = registry.entry(id) else { return }
        if id == activeEntry?.id {
            guard let other = libraries.first(where: { $0.id != id }) else { banner = "You need at least one library."; return }
            await open(other)
        }
        registry.remove(id)
        libraries = registry.entries
        if deleteData && e.kind == .external { try? FileManager.default.removeItem(at: e.dataURL) }
        db?.log("privacy", "Removed library “\(e.name)” from the list\(deleteData ? " and deleted its analysis data" : "")")
    }

    func connectPhotos() async {
        access = await photos.requestAccess()
        db?.log("privacy", "Photos access: \(access)")
        if access == .authorized || access == .limited {
            await syncLibrary()
            watchLibraryChanges()
        }
    }

    private func watchLibraryChanges() {
        Task { [weak self] in
            guard let stream = self?.photos.changes else { return }
            for await _ in stream {
                try? await Task.sleep(for: .seconds(2))      // coalesce bursts of changes
                await self?.syncLibrary()
            }
        }
    }

    // MARK: Library sync (metadata stage)

    /// Brings the database up to date with the library. For Apple Photos this reads only
    /// what changed since last time (Photos' change history), so deleting a photo or a change
    /// made in Photos doesn't re-read the whole library. `full` forces a complete re-read.
    func syncLibrary(full: Bool = false) async {
        guard let db, !syncing else { return }
        if let id = activeLibraryID, let src = externalSource {
            await syncFileLibrary(db: db, id: id, source: src)
            return
        }
        if let id = activeLibraryID, let src = managedSource {
            await syncManagedLibrary(db: db, id: id, source: src)
            return
        }
        guard access == .authorized || access == .limited else { return }
        syncing = true
        defer { syncing = false }
        let svc = photos
        let tokenKey = "photosChangeToken"
        let saved = db.setting(tokenKey).flatMap { Data(base64Encoded: $0) }
        let delta = await Offload.run { svc.fetchDelta(sinceArchivedToken: full ? nil : saved) }
        do {
            let source = try db.systemSourceID()
            if !full, saved != nil, !delta.requiresFullReconcile {
                let changed = Array(delta.inserted.union(delta.updated)), deleted = Array(delta.deleted)
                if changed.isEmpty && deleted.isEmpty {
                    if let t = delta.newTokenArchive { db.setSetting(tokenKey, t.base64EncodedString()) }
                    return
                }
                let stamp = Date()
                try await Offload.run {
                    let snaps = svc.snapshots(for: changed, includeLocation: false)
                    try db.upsert(snaps.map(Self.upsert), sourceID: source, scanStamp: stamp)
                    try db.markDeleted(localIdentifiers: deleted)
                }
                if let t = delta.newTokenArchive { db.setSetting(tokenKey, t.base64EncodedString()) }
                db.log("scan", "Library updated: \(changed.count) new or changed, \(deleted.count) removed")
                refreshLibraries()
                await reloadFromDatabase()
                return
            }
            let stamp = Date()
            var count = 0
            for try await batch in photos.allAssets(batchSize: 500, includeLocation: false) {
                let rows = batch.map(Self.upsert)
                try await Offload.run { try db.upsert(rows, sourceID: source, scanStamp: stamp) }
                count += rows.count
                status.message = "Reading library… \(count.formatted()) items"
            }
            let removed = try await Offload.run { try db.markUnseenDeleted(sourceID: source, scanStamp: stamp) }
            if let t = delta.newTokenArchive { db.setSetting(tokenKey, t.base64EncodedString()) }
            db.log("scan", "Library synced: \(count) items\(removed > 0 ? ", \(removed) removed from Photos" : "")", assetCount: count)
            if !status.running { status.message = "" }
            refreshLibraries()
            await reloadFromDatabase()
        } catch {
            banner = "Couldn't read the Photos library: \(error.localizedDescription)"
        }
    }

    nonisolated static func upsert(_ a: AssetSnapshot) -> AssetUpsert {
        AssetUpsert(localIdentifier: a.localIdentifier, mediaType: a.mediaType.rawValue,
                    subtypeMask: Int(a.subtypeMask), creationDate: a.creationDate,
                    modificationDate: a.modificationDate, pixelWidth: a.pixelWidth,
                    pixelHeight: a.pixelHeight, duration: a.duration, favorite: a.isFavorite,
                    hidden: a.isHidden, burstIdentifier: a.burstIdentifier,
                    assetSource: a.isShared ? "shared" : "library", filePath: nil,
                    availability: a.locallyAvailable.map { $0 ? "local" : "cloud_only" })
    }

    private func syncFileLibrary(db: AppDatabase, id: Int64, source: FileLibrarySource) async {
        syncing = true
        defer { syncing = false }
        status.message = "Reading “\(source.inspection.name)”…"
        let stamp = Date()
        do {
            let found = try await Offload.run { try source.scan() }
            let rows = found.map { a in
                AssetUpsert(localIdentifier: a.key, mediaType: a.mediaType, subtypeMask: a.subtypeMask,
                            creationDate: a.creationDate, modificationDate: a.modificationDate,
                            pixelWidth: a.pixelWidth, pixelHeight: a.pixelHeight, duration: a.duration,
                            favorite: a.favorite, hidden: a.hidden, burstIdentifier: a.burstIdentifier,
                            assetSource: "library", filePath: a.url?.path,
                            availability: a.isOriginalLocal ? "local" : "cloud_only")
            }
            for chunk in stride(from: 0, to: rows.count, by: 1000) {
                let part = Array(rows[chunk..<min(chunk + 1000, rows.count)])
                try await Offload.run { try db.upsert(part, sourceID: id, scanStamp: stamp) }
                status.message = "Reading “\(source.inspection.name)”… \(min(chunk + 1000, rows.count).formatted()) items"
            }
            _ = try await Offload.run { try db.markUnseenDeleted(sourceID: id, scanStamp: stamp) }
            db.log("scan", "Read \(rows.count) items from “\(source.inspection.name)” (read-only)", assetCount: rows.count)
            status.message = ""
            refreshLibraries()
            await reloadFromDatabase()
        } catch {
            status.message = ""
            banner = error.localizedDescription
        }
    }

    /// Reloads what the app shows from the database. A full reload also regroups duplicates
    /// and people and re-reads Photos' albums (seconds on a big library); the default light
    /// reload only refreshes the photo list and tidies the existing groups, which is instant.
    func reloadFromDatabase(full: Bool = false) async {
        guard let db else { return }
        let sid = activeLibraryID
        let loaded = try? await Offload.run { () -> ([AssetRow], LibraryStats, [(assetID: Int64, reason: String)], [ActivityEntry]) in
            (try db.assets(sourceID: sid), try db.stats(sourceID: sid), try db.removalQueue(sourceID: sid), try db.activity())
        }
        if let t = try? await Offload.run { try db.userTags(sourceID: sid) } { userTags = t }
        if let raw = try? await Offload.run { try db.categoryMembers(sourceID: sid) } {
            var m: [PhotoCategory: Set<Int64>] = [:]
            for (k, v) in raw { if let c = PhotoCategory(rawValue: k) { m[c] = v } }
            categoryMembers = m
        }
        if let (a, s, q, act) = loaded {
            assets = a
            assetsByID = Dictionary(uniqueKeysWithValues: a.map { ($0.id, $0) })
            stats = s
            removalQueue = q
            activity = act
        }
        if full || allDuplicateGroups.isEmpty && people.isEmpty {
            await rebuildDuplicates()
            await rebuildPeople()
            await rebuildFolders()
        } else {
            pruneToExistingAssets()
            await rebuildFolders(includePhotosAlbums: false)
        }
        reloadAlbums()
    }

    /// After deletions, renames or queue changes: drop missing items from the duplicate groups
    /// and people, refresh their details, and hide groups that are already dealt with.
    func pruneToExistingAssets() {
        allDuplicateGroups = allDuplicateGroups.compactMap { g in
            let members = g.members.compactMap { assetsByID[$0.id] }
            guard members.count > 1 else { return nil }
            return DuplicateGroupVM(id: g.id, type: g.type, members: members, scores: g.scores,
                                    recommended: g.recommended.flatMap { assetsByID[$0] != nil ? $0 : nil },
                                    explanation: g.explanation, similarity: g.similarity)
        }
        applyQueueFilter()
        if storedFaces.contains(where: { assetsByID[$0.assetID] == nil }) {
            storedFaces.removeAll { assetsByID[$0.assetID] == nil }
            people = people.compactMap { p in
                var p = p
                p.faces.removeAll { assetsByID[$0.assetID] == nil }
                return p.faces.isEmpty && p.personID == nil ? nil : p
            }
        }
    }

    /// Hides groups whose extra members are all already queued for removal.
    func applyQueueFilter() {
        let queued = Set(removalQueue.map(\.assetID))
        duplicateGroups = allDuplicateGroups.filter { g in g.members.filter { !queued.contains($0.id) }.count > 1 }
    }

    // MARK: Folders & albums

    func rebuildFolders(includePhotosAlbums: Bool = true) async {
        var tree: [AlbumNode]
        if !includePhotosAlbums, isSystemLibrary, !folderTree.isEmpty, !folderTree.contains(where: { $0.id.hasPrefix("date:") }) {
            return      // Photos' own albums: re-read only on a full reload
        }
        if let src = externalSource {
            tree = src.albums
        } else if isManagedLibrary {
            tree = []
        } else if access == .authorized || access == .limited {
            let svc = photos
            tree = await Offload.run(.utility) { svc.albumTree() }
        } else {
            tree = []
        }
        // Libraries without albums/folders get a Year › Month tree from capture dates.
        if tree.isEmpty {
            let rows = assets
            tree = await Offload.run { Self.dateTree(rows) }
        }
        folderTree = tree
        var index: [String: AlbumNode] = [:]
        func walk(_ n: AlbumNode) { index[n.id] = n; n.children.forEach(walk) }
        tree.forEach(walk)
        folderIndex = index
    }

    nonisolated static func dateTree(_ rows: [AssetRow]) -> [AlbumNode] {
        let cal = Calendar.current
        let monthFmt = DateFormatter(); monthFmt.setLocalizedDateFormatFromTemplate("MMMM")
        var byYear: [Int: [Int: [String]]] = [:]
        for r in rows where r.mediaType == "image" {
            guard let d = r.creationDate else { continue }
            let c = cal.dateComponents([.year, .month], from: d)
            byYear[c.year!, default: [:]][c.month!, default: []].append(r.localIdentifier)
        }
        return byYear.keys.sorted(by: >).map { y in
            let months = byYear[y]!.keys.sorted(by: >).map { m -> AlbumNode in
                let title = monthFmt.string(from: cal.date(from: DateComponents(year: y, month: m, day: 1)) ?? .now)
                return AlbumNode(id: "date:\(y)-\(m)", title: title, kind: .album, assetKeys: byYear[y]![m]!)
            }
            return AlbumNode(id: "date:\(y)", title: String(y), kind: .date, children: months).rolledUp()!
        }
    }

    // MARK: Categories & search

    func setCategory(_ c: PhotoCategory, assetIDs: [Int64], included: Bool) async {
        try? db?.setCategory(c.rawValue, assetIDs: assetIDs, included: included)
        db?.log("edit", "\(included ? "Added" : "Removed") \(assetIDs.count) photo(s) \(included ? "to" : "from") \(c.title)")
        await reloadFromDatabase()
    }

    func categoryDetails(_ assetID: Int64) -> [(category: String, confidence: Double, reason: String, source: String)] {
        (try? db?.categoryDetails(assetID: assetID)) ?? []
    }

    func searchText(_ q: String) async -> Set<Int64> {
        guard let db else { return [] }
        let sid = activeLibraryID
        return (try? await Offload.run { try db.searchText(q, sourceID: sid) }) ?? []
    }

    // MARK: Slideshow

    func startSlideshow(_ rows: [AssetRow], title: String, startAt: Int64? = nil) {
        let keys = rows.filter { $0.mediaType == "image" }.map(\.localIdentifier)
        guard !keys.isEmpty else { banner = "There are no photos to show."; return }
        let start = startAt.flatMap { id in rows.firstIndex { $0.id == id } } ?? 0
        slideshowRequest = SlideshowRequest(title: title, keys: keys, startIndex: min(start, keys.count - 1))
    }

    // MARK: Analysis

    func startAnalysis() async {
        guard let db, let cipher, currentJob == nil, let sid = activeLibraryID else { return }
        let options = AnalysisOptions(faceAnalysis: faceAnalysisEnabled, storeFaceCrops: storeFaceCrops,
                                      sceneSimilarity: sceneSimilarityEnabled, allowICloudDownloads: allowICloudDownloads,
                                      faceCropDirectory: faceCropDir, face: faceModel, classify: classifyEnabled,
                                      maxConcurrency: analysisConcurrency, ocrAccurate: machine.ocrAccurate && performanceMode != .batterySaver,
                                      classifyImageSize: machine.classifyImageSize, faceImageSize: machine.faceImageSize)
        let job = AnalysisJob(db: db, source: mediaSource, sourceID: sid, cipher: cipher, options: options)
        status = IndexStatus(running: true, message: "Starting…")
        currentJob = await jobs.enqueue(job)
    }

    func pauseAnalysis() async {
        guard let id = currentJob else { return }
        await jobs.pause(id)
        status.paused = true
    }

    func resumeAnalysis() async {
        guard let id = currentJob else { return }
        await jobs.resume(id)
        status.paused = false
    }

    func cancelAnalysis() async {
        guard let id = currentJob else { return }
        await jobs.cancel(id)
    }

    private func consumeJobEvents() async {
        for await event in jobs.events {
            switch event {
            case .progress(let id, let p) where id == currentJob:
                status.message = p.message
                status.fraction = p.fraction
            case .finished(let id, let result, let error) where id == currentJob:
                currentJob = nil
                status = IndexStatus()
                switch result {
                case .succeeded: db?.log("scan", "Analysis complete")
                case .cancelled: banner = "Analysis stopped. It will resume where it left off next time."
                case .failed: banner = "Analysis stopped with an error: \(error ?? "unknown")"
                default: break
                }
                await reloadFromDatabase(full: true)
            case .throttled(let reason):
                status.throttle = reason
            default:
                break
            }
        }
    }

    // MARK: Duplicates

    func rebuildDuplicates() async {
        guard let db, let cipher else { return }
        let rows = assets.filter { $0.mediaType == "image" && $0.pHash != nil }
        let strict = duplicateStrictness
        let groups: [DuplicateGroupVM] = await Offload.run {
            let embeddings = (try? db.sceneEmbeddings(cipher: cipher)) ?? [:]
            let (excluded, pairs) = (try? db.exclusions()) ?? ([], [])
            var ex = SimilarityExclusions()
            ex.excludedAssets = Set(excluded.map(AssetID.init))
            ex.notSimilarPairs = Set(pairs.map { SimilarityExclusions.Pair(AssetID($0[0]), AssetID($0[1])) })

            var grouper = DuplicateGrouper()
            // Strictness 0…1 moves thresholds between permissive and strict.
            grouper.thresholds.nearMaxPHash = Int((8 - 4 * strict).rounded())
            grouper.thresholds.nearLoosePHash = Int((14 - 6 * strict).rounded())
            // Feature-print cosines are high even for different scenes (~0.94 in the self-test),
            // so "similar" needs a high bar; the time windows do the rest.
            grouper.thresholds.nearEmbeddingMin = Float(0.95 + 0.04 * strict)
            grouper.thresholds.burstEmbeddingMin = Float(0.88 + 0.08 * strict)
            grouper.thresholds.similarEmbeddingMin = Float(0.93 + 0.05 * strict)

            let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            let features: [AssetFeatures] = rows.map { r in
                var f = AssetFeatures(id: AssetID(r.id), pixelWidth: r.pixelWidth, pixelHeight: r.pixelHeight)
                f.fileHash = r.fileHash
                f.pHash = r.pHash; f.dHash = r.dHash
                f.embedding = embeddings[r.id]
                f.captureDate = r.creationDate
                f.burstIdentifier = r.burstIdentifier
                if let lap = r.laplacianVariance, let sigma = r.noiseSigma, let luma = r.meanLuma {
                    f.quality = QualityMetrics(laplacianVariance: lap, noiseSigma: sigma, meanLuma: luma, clippedFraction: 0)
                }
                f.isFavorite = r.favorite
                return f
            }
            return grouper.groups(for: features, exclusions: ex).map { g in
                let members = g.ranking.compactMap { byID[$0.id.rawValue] }
                let key = "\(g.type.rawValue)-" + g.members.map { String($0.rawValue) }.joined(separator: ",")
                return DuplicateGroupVM(id: key, type: g.type, members: members,
                                        scores: Dictionary(uniqueKeysWithValues: g.ranking.map { ($0.id.rawValue, $0.score) }),
                                        recommended: g.recommended?.rawValue, explanation: g.explanation,
                                        similarity: g.similarity)
            }
            .sorted { ($0.type.order, -$0.members.count) < ($1.type.order, -$1.members.count) }
        }
        allDuplicateGroups = groups
        applyQueueFilter()
    }

    /// "Keep best": everything else in the group goes to the removal queue (not deleted).
    func keep(_ keepIDs: Set<Int64>, in group: DuplicateGroupVM) async {
        guard let db else { return }
        let others = group.members.map(\.id).filter { !keepIDs.contains($0) }
        try? db.queueForRemoval(others, reason: "\(group.type.label) of a photo you kept", groupID: group.id)
        for k in keepIDs { try? db.recordDecision("keep", subjectType: "asset", subjectID: k, detail: group.id) }
        db.log("delete", "Queued \(others.count) photo(s) for review before removal", assetCount: others.count)
        await reloadQueue()
    }

    func markNotSimilar(_ group: DuplicateGroupVM) async {
        let ids = group.members.map(\.id)
        let db = db
        await Offload.run { try? db?.addNotSimilar(ids) }
        allDuplicateGroups.removeAll { $0.id == group.id }
        applyQueueFilter()
    }

    func excludeFromScans(_ ids: [Int64]) async {
        let db = db
        await Offload.run { try? db?.excludeFromScans(ids) }
        let gone = Set(ids)
        allDuplicateGroups = allDuplicateGroups.compactMap { g in
            let m = g.members.filter { !gone.contains($0.id) }
            return m.count > 1 ? DuplicateGroupVM(id: g.id, type: g.type, members: m, scores: g.scores,
                                                  recommended: g.recommended, explanation: g.explanation, similarity: g.similarity) : nil
        }
        applyQueueFilter()
    }

    func restoreFromQueue(_ ids: [Int64]) async {
        try? db?.unqueue(ids)
        await reloadQueue()
    }

    /// Only the Removal Queue changed: re-read it and re-filter the groups (no rescan).
    func reloadQueue() async {
        guard let db else { return }
        let sid = activeLibraryID
        if let q = try? await Offload.run { try db.removalQueue(sourceID: sid) } { removalQueue = q }
        applyQueueFilter()
    }

    /// Deletes through PhotoKit (moves to Photos' Recently Deleted). Callers must have shown
    /// the in-app confirmation with the exact count; PhotoKit then asks once more.
    func delete(assetIDs: [Int64]) async -> Bool {
        guard let db else { return false }
        guard canDelete else {
            banner = "This library is opened read-only. Open it in Photos to delete photos."
            return false
        }
        let ids = assetIDs.compactMap { assetsByID[$0]?.localIdentifier }
        guard !ids.isEmpty else { return false }
        if let managed = managedSource {
            let pairs = assetIDs.compactMap { id in assetsByID[id].map { (id, $0.localIdentifier) } }
            let moved: [Int64] = await Offload.run {
                var moved: [Int64] = []
                for (id, key) in pairs where (try? managed.moveToTrash(key)) != nil { moved.append(id) }
                try? db.markDeleted(assetIDs: moved)
                try? db.unqueue(moved)
                return moved
            }
            db.log("delete", "Moved \(moved.count) item(s) to the library's Trash", assetCount: moved.count)
            await reloadFromDatabase()
            return !moved.isEmpty
        }
        do {
            try await photos.delete(DeletionConfirmation(localIdentifiers: ids, userAcceptedCount: ids.count))
            try await Offload.run {
                try db.markDeleted(localIdentifiers: ids)
                try db.unqueue(assetIDs)
            }
            db.log("delete", "Moved \(ids.count) photo(s) to Recently Deleted in Photos", assetCount: ids.count)
            await reloadFromDatabase()
            return true
        } catch {
            // The user cancelling Photos' own prompt lands here too: nothing was deleted.
            banner = "Nothing was deleted. \(error.localizedDescription)"
            return false
        }
    }

    // MARK: People

    /// Regroups faces into people. `reloadFaces` re-reads (and decrypts) every face from the
    /// database — needed only when faces were added or removed. Naming, merging and "not this
    /// person" reuse the faces already in memory and the cached nearest-neighbour lists, so a
    /// regroup after naming takes moments instead of minutes.
    func rebuildPeople(reloadFaces: Bool = true) async {
        guard let db, let cipher else { return }
        regroupTask?.cancel()
        let base = Float(faceModel.threshold(strictness: faceStrictness))
        let sid = activeLibraryID
        let cached: [StoredFace]? = reloadFaces || storedFaces.isEmpty ? nil : storedFaces
        let graph = faceGraph
        peopleBusy = true
        defer { peopleBusy = false }
        let result = await Offload.run { () -> ([StoredFace], [PersonRow], ClusteringResult)? in
            guard let faces = cached ?? (try? db.storedFaces(cipher: cipher, sourceID: sid)), let persons = try? db.persons(sourceID: sid),
                  let (must, cannot) = try? db.faceConstraints() else { return nil }
            var constraints = ClusteringConstraints()
            constraints.mustLink = must.map { (FaceID($0.0), FaceID($0.1)) }
            constraints.cannotLink = cannot.map { (FaceID($0.0), FaceID($0.1)) }
            for p in persons { for f in p.confirmedFaceIDs { constraints.confirmed[FaceID(f)] = PersonID(p.id) } }
            let samples = faces.map {
                FaceSample(id: FaceID($0.id), embedding: $0.embedding, quality: $0.quality,
                           pixelSize: $0.pixelSize, yaw: $0.yaw, captureDate: $0.captureDate)
            }
            var clusterer = FaceClusterer()
            // Strictness maps onto the calibrated cosine threshold range of the active face model.
            clusterer.config.baseThreshold = base
            clusterer.config.minClusterSize = 2
            graph.update(samples)
            let r = clusterer.cluster(samples, index: graph, constraints: constraints)
            return (faces, persons, r)
        }
        guard let (faces, persons, r) = result else { return }
        storedFaces = faces
        let byFace = Dictionary(uniqueKeysWithValues: faces.map { ($0.id, $0) })
        let personByID = Dictionary(uniqueKeysWithValues: persons.map { ($0.id, $0) })

        var vms: [PersonVM] = []
        var seenPersons = Set<Int64>()
        for (i, c) in r.clusters.enumerated() {
            let fs = c.faces.compactMap { byFace[$0.rawValue] }
                .sorted { $0.quality > $1.quality }
            if let pid = c.existingPerson?.rawValue, let p = personByID[pid] {
                seenPersons.insert(pid)
                vms.append(PersonVM(id: "p\(pid)", personID: pid, name: p.displayName, confidence: .confirmed,
                                    faces: fs, isHidden: p.isHidden))
            } else {
                vms.append(PersonVM(id: "c\(i)-\(c.faces.first?.rawValue ?? 0)", personID: nil, name: nil,
                                    confidence: c.confidence, faces: fs, isHidden: false))
            }
        }
        // Named people whose faces all went to review still appear.
        for p in persons where !seenPersons.contains(p.id) {
            vms.append(PersonVM(id: "p\(p.id)", personID: p.id, name: p.displayName, confidence: .confirmed,
                                faces: p.confirmedFaceIDs.compactMap { byFace[$0] }, isHidden: p.isHidden))
        }
        people = vms.sorted {
            if ($0.name != nil) != ($1.name != nil) { return $0.name != nil }
            return $0.faces.count > $1.faces.count
        }
        reviewFaces = r.review.compactMap { item in byFace[item.face.rawValue].map { ReviewFaceVM(face: $0, reason: item.reason) } }
        var owners: [Int64: String] = [:]
        for p in people { for f in p.faces { owners[f.id] = p.id } }
        faceOwnerIndex = owners
        if albums.contains(where: \.isSmart) { reloadAlbums() }
    }

    func name(_ person: PersonVM, _ newName: String) async {
        guard let db else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let faceIDs = person.faces.map(\.id)
        let pid: Int64?
        if let existing = person.personID {
            try? db.renamePerson(existing, to: trimmed)
            try? db.addFaces(faceIDs, toPerson: existing)
            pid = existing
        } else {
            pid = try? db.createPerson(named: trimmed, faceIDs: faceIDs, sourceID: activeLibraryID)
        }
        db.log("edit", "Named a person (\(person.faces.count) faces confirmed)")
        if let pid { assignLocally(faceIDs, to: pid, name: trimmed, replacing: person.id) }
        scheduleRegroup()
    }

    func merge(_ source: PersonVM, into target: PersonVM) async {
        guard let db else { return }
        let targetID: Int64
        if let t = target.personID { targetID = t }
        else if let created = try? db.createPerson(named: target.name ?? source.name ?? "Unnamed", faceIDs: target.faces.map(\.id), sourceID: activeLibraryID) {
            targetID = created
        } else { return }
        if let s = source.personID { try? db.mergePerson(s, into: targetID) }
        else { try? db.addFaces(source.faces.map(\.id), toPerson: targetID) }
        assignLocally(target.faces.map(\.id), to: targetID, name: target.name ?? source.name ?? "Unnamed", replacing: target.id)
        assignLocally(source.faces.map(\.id), to: targetID, name: target.name ?? source.name ?? "Unnamed")
        people.removeAll { $0.id == source.id }
        scheduleRegroup()
    }

    /// "This is not [Person]" — becomes cannot-link constraints for future grouping.
    func notThisPerson(_ face: StoredFace, in person: PersonVM) async {
        let others = person.faces.map(\.id).filter { $0 != face.id }
        try? db?.rejectFace(face.id, fromPerson: person.personID, againstFaces: others)
        removeLocally([face.id])
        scheduleRegroup()
    }

    func assign(_ face: StoredFace, to person: PersonVM) async {
        if let pid = person.personID {
            try? db?.addFaces([face.id], toPerson: pid)
            assignLocally([face.id], to: pid, name: person.name ?? "")
        } else if let name = person.name,
                  let pid = try? db?.createPerson(named: name, faceIDs: person.faces.map(\.id) + [face.id], sourceID: activeLibraryID) {
            assignLocally(person.faces.map(\.id) + [face.id], to: pid, name: name, replacing: person.id)
        }
        scheduleRegroup()
    }

    func ignore(_ face: StoredFace) async {
        try? db?.ignoreFace(face.id)
        removeLocally([face.id])
        storedFaces.removeAll { $0.id == face.id }
        scheduleRegroup()
    }

    func setHidden(_ person: PersonVM, _ hidden: Bool) async {
        guard let pid = person.personID else { return }
        try? db?.setPersonHidden(pid, hidden)
        if let i = people.firstIndex(where: { $0.id == person.id }) { people[i].isHidden = hidden }
    }

    // MARK: Instant feedback, then a quiet regroup

    /// Shows a naming decision straight away, before the background regroup finishes.
    func assignLocally(_ faceIDs: [Int64], to pid: Int64, name: String, replacing oldKey: String? = nil) {
        let key = "p\(pid)"
        let byID = Dictionary(storedFaces.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let moving = Set(faceIDs)
        for i in people.indices where people[i].id != key && people[i].id != oldKey {
            if people[i].faces.contains(where: { moving.contains($0.id) }) { people[i].faces.removeAll { moving.contains($0.id) } }
        }
        let faces = faceIDs.compactMap { byID[$0] }
        if let i = people.firstIndex(where: { $0.id == key }) {
            let have = Set(people[i].faces.map(\.id))
            people[i].faces += faces.filter { !have.contains($0.id) }
            if !name.isEmpty { people[i].name = name }
            if let old = oldKey, old != key { people.removeAll { $0.id == old } }
        } else if let old = oldKey, let i = people.firstIndex(where: { $0.id == old }) {
            people[i] = PersonVM(id: key, personID: pid, name: name, confidence: .confirmed,
                                 faces: people[i].faces, isHidden: false)
            let have = Set(people[i].faces.map(\.id))
            people[i].faces += faces.filter { !have.contains($0.id) }
        } else {
            people.insert(PersonVM(id: key, personID: pid, name: name, confidence: .confirmed, faces: faces, isHidden: false), at: 0)
        }
        people.removeAll { $0.personID == nil && $0.faces.isEmpty }
        for f in faceIDs { faceOwnerIndex[f] = key }
        lastNamedPersonKey = key
    }

    func removeLocally(_ faceIDs: [Int64]) {
        let gone = Set(faceIDs)
        for i in people.indices { people[i].faces.removeAll { gone.contains($0.id) } }
        people.removeAll { $0.personID == nil && $0.faces.isEmpty }
        for f in faceIDs { faceOwnerIndex[f] = nil }
    }

    /// Regroups shortly after the last naming decision (several quick decisions → one regroup).
    func scheduleRegroup() {
        regroupTask?.cancel()
        regroupTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await self?.rebuildPeople(reloadFaces: false)
        }
    }

    // MARK: Privacy controls

    func deleteAllFaceData() async {
        guard let db else { return }
        _ = try? await db.deleteAllFaceData(faceCropDirectory: faceCropDir)
        faceAnalysisEnabled = false
        await reloadFromDatabase(full: true)
        banner = "All face data was deleted and face analysis is off. Turn it back on in Settings to rebuild."
    }

    func deleteAllAppData() async {
        guard let db else { return }
        await cancelAnalysis()
        try? db.deleteAllAppData()
        try? FileManager.default.removeItem(at: faceCropDir)
        await reloadFromDatabase(full: true)
        banner = "All PhotoForge data was deleted. Your photos in Apple Photos were not touched."
        await syncLibrary(full: true)
    }

    func refreshActivity() async {
        activity = (try? db?.activity()) ?? []
    }

    func clearActivity() async {
        try? db?.clearActivity()
        await refreshActivity()
    }

    // MARK: Settings persistence

    private func loadSettings() {
        guard let db else { return }
        loadingSettings = true
        defer { loadingSettings = false }
        func bool(_ k: String, _ d: Bool) -> Bool { db.setting(k).map { $0 == "true" } ?? d }
        func dbl(_ k: String, _ d: Double) -> Double { db.setting(k).flatMap(Double.init) ?? d }
        faceAnalysisEnabled = bool("faceAnalysisEnabled", true)
        storeFaceCrops = bool("storeFaceCrops", true)
        sceneSimilarityEnabled = bool("semanticIndexEnabled", true)
        allowICloudDownloads = bool("allowICloudDownloads", false)
        activityLogEnabled = bool("activityLogEnabled", true)
        duplicateStrictness = dbl("duplicateStrictness", 0.5)
        faceStrictness = dbl("faceStrictness", 0.5)
        classifyEnabled = bool("classifyEnabled", true)
    }

    private func save(_ key: String, _ value: Bool) {
        guard !loadingSettings else { return }
        db?.setSetting(key, value ? "true" : "false")
        db?.log("privacy", "Setting '\(key)' turned \(value ? "on" : "off")")
    }

    private func save(_ key: String, _ value: Double) {
        guard !loadingSettings else { return }
        db?.setSetting(key, String(value))
    }
}

extension DuplicateGroupType {
    var label: String {
        switch self {
        case .exact: "Exact duplicate"
        case .near: "Near duplicate"
        case .burst: "Burst shot"
        case .similar: "Similar photo"
        }
    }
    var pluralLabel: String {
        switch self {
        case .exact: "Exact duplicates"
        case .near: "Near duplicates"
        case .burst: "Burst shots"
        case .similar: "Similar photos"
        }
    }
    var order: Int {
        switch self { case .exact: 0; case .near: 1; case .burst: 2; case .similar: 3 }
    }
}


struct SlideshowRequest: Identifiable, Hashable, Codable {
    var id = UUID()
    let title: String
    let keys: [String]
    let startIndex: Int
}
