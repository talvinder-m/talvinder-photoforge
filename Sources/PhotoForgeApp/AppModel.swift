import Foundation
import SwiftUI
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

enum SidebarItem: Hashable {
    case dashboard, allPhotos, favorites, screenshots, blurry
    case duplicates, removalQueue, people
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
    private(set) var db: AppDatabase?
    private(set) var cipher: VectorCipher?
    let photos = PhotoLibraryService()
    let jobs = JobManager(maxConcurrentJobs: 1)
    let renderer = EditRenderer()
    let policy = GenerativeEditPolicy()
    let faceModel = FaceEmbedding.load()

    // State
    var startupError: String?
    var access: PhotoLibraryService.AccessState = .notDetermined
    var selection: SidebarItem? = .dashboard
    var assets: [AssetRow] = []
    var assetsByID: [Int64: AssetRow] = [:]
    var stats = LibraryStats()
    var status = IndexStatus()
    var syncing = false
    var duplicateGroups: [DuplicateGroupVM] = []
    var removalQueue: [(assetID: Int64, reason: String)] = []
    var people: [PersonVM] = []
    var reviewFaces: [ReviewFaceVM] = []
    var activity: [ActivityEntry] = []
    var editingAsset: AssetRow?
    var banner: String?

    // Settings (persisted in the settings table)
    var faceAnalysisEnabled = true { didSet { save("faceAnalysisEnabled", faceAnalysisEnabled) } }
    var storeFaceCrops = true { didSet { save("storeFaceCrops", storeFaceCrops) } }
    var sceneSimilarityEnabled = true { didSet { save("semanticIndexEnabled", sceneSimilarityEnabled) } }
    var allowICloudDownloads = false { didSet { save("allowICloudDownloads", allowICloudDownloads) } }
    var activityLogEnabled = true { didSet { save("activityLogEnabled", activityLogEnabled) } }
    var duplicateStrictness = 0.5 { didSet { save("duplicateStrictness", duplicateStrictness) } }
    var faceStrictness = 0.5 { didSet { save("faceStrictness", faceStrictness) } }

    private var currentJob: UUID?
    private var loadingSettings = false
    private var storedFaces: [StoredFace] = []

    static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PhotoForge", isDirectory: true)
    }()
    static var faceCropDir: URL { supportDir.appendingPathComponent("FaceCrops", isDirectory: true) }

    // MARK: Startup

    func bootstrap() async {
        do {
            let db = try AppDatabase.open(at: Self.supportDir.appendingPathComponent("photoforge.sqlite"))
            self.db = db
            cipher = try VectorCipher(store: .file(Self.supportDir.appendingPathComponent("vector.key")))
            loadSettings()
            // Embeddings from different models can't be compared: rebuild face data if the model changed.
            if let inUse = try? db.faceEmbeddingModels(), !inUse.isEmpty, inUse != [faceModel.name] {
                _ = try? await db.deleteAllFaceData(faceCropDirectory: Self.faceCropDir, keepAnalysisEnabled: true)
                banner = "Face grouping was upgraded to a more accurate model. Run Analyze Photos to rebuild People."
            }
            await jobs.startMonitoringSystem()
            Task { await self.consumeJobEvents() }
        } catch {
            startupError = "Couldn't open PhotoForge's database: \(error.localizedDescription)"
            return
        }
        access = photos.accessState
        if access == .authorized || access == .limited {
            _ = await photos.requestAccess()          // registers the change observer; no prompt when already decided
            await reloadFromDatabase()
            await syncLibrary()
            watchLibraryChanges()
        }
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

    func syncLibrary() async {
        guard let db, !syncing else { return }
        syncing = true
        defer { syncing = false }
        let stamp = Date()
        do {
            let source = try db.systemSourceID()
            var count = 0
            for try await batch in photos.allAssets(batchSize: 500, includeLocation: false) {
                let rows = batch.map { a in
                    AssetUpsert(localIdentifier: a.localIdentifier, mediaType: a.mediaType.rawValue,
                                subtypeMask: Int(a.subtypeMask), creationDate: a.creationDate,
                                modificationDate: a.modificationDate, pixelWidth: a.pixelWidth,
                                pixelHeight: a.pixelHeight, duration: a.duration, favorite: a.isFavorite,
                                hidden: a.isHidden, burstIdentifier: a.burstIdentifier)
                }
                try await Task.detached { try db.upsert(rows, sourceID: source, scanStamp: stamp) }.value
                count += rows.count
                status.message = "Reading library… \(count.formatted()) items"
            }
            let removed = try db.markUnseenDeleted(sourceID: source, scanStamp: stamp)
            db.log("scan", "Library synced: \(count) items\(removed > 0 ? ", \(removed) removed from Photos" : "")", assetCount: count)
            if !status.running { status.message = "" }
            await reloadFromDatabase()
        } catch {
            banner = "Couldn't read the Photos library: \(error.localizedDescription)"
        }
    }

    func reloadFromDatabase() async {
        guard let db else { return }
        let loaded = try? await Task.detached { () -> ([AssetRow], LibraryStats, [(assetID: Int64, reason: String)], [ActivityEntry]) in
            (try db.assets(), try db.stats(), try db.removalQueue(), try db.activity())
        }.value
        if let (a, s, q, act) = loaded {
            assets = a
            assetsByID = Dictionary(uniqueKeysWithValues: a.map { ($0.id, $0) })
            stats = s
            removalQueue = q
            activity = act
        }
        await rebuildDuplicates()
        await rebuildPeople()
    }

    // MARK: Analysis

    func startAnalysis() async {
        guard let db, let cipher, currentJob == nil else { return }
        let options = AnalysisOptions(faceAnalysis: faceAnalysisEnabled, storeFaceCrops: storeFaceCrops,
                                      sceneSimilarity: sceneSimilarityEnabled, allowICloudDownloads: allowICloudDownloads,
                                      faceCropDirectory: Self.faceCropDir, face: faceModel)
        let job = AnalysisJob(db: db, photos: photos, cipher: cipher, options: options)
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
                await reloadFromDatabase()
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
        let groups: [DuplicateGroupVM] = await Task.detached(priority: .userInitiated) {
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
        }.value
        // Hide groups whose extra members are all already queued for removal.
        let queued = Set(removalQueue.map(\.assetID))
        duplicateGroups = groups.filter { g in g.members.filter { !queued.contains($0.id) }.count > 1 }
    }

    /// "Keep best": everything else in the group goes to the removal queue (not deleted).
    func keep(_ keepIDs: Set<Int64>, in group: DuplicateGroupVM) async {
        guard let db else { return }
        let others = group.members.map(\.id).filter { !keepIDs.contains($0) }
        try? db.queueForRemoval(others, reason: "\(group.type.label) of a photo you kept", groupID: group.id)
        for k in keepIDs { try? db.recordDecision("keep", subjectType: "asset", subjectID: k, detail: group.id) }
        db.log("delete", "Queued \(others.count) photo(s) for review before removal", assetCount: others.count)
        await reloadFromDatabase()
    }

    func markNotSimilar(_ group: DuplicateGroupVM) async {
        try? db?.addNotSimilar(group.members.map(\.id))
        await reloadFromDatabase()
    }

    func excludeFromScans(_ ids: [Int64]) async {
        try? db?.excludeFromScans(ids)
        await reloadFromDatabase()
    }

    func restoreFromQueue(_ ids: [Int64]) async {
        try? db?.unqueue(ids)
        await reloadFromDatabase()
    }

    /// Deletes through PhotoKit (moves to Photos' Recently Deleted). Callers must have shown
    /// the in-app confirmation with the exact count; PhotoKit then asks once more.
    func delete(assetIDs: [Int64]) async -> Bool {
        guard let db else { return false }
        let ids = assetIDs.compactMap { assetsByID[$0]?.localIdentifier }
        guard !ids.isEmpty else { return false }
        do {
            try await photos.delete(DeletionConfirmation(localIdentifiers: ids, userAcceptedCount: ids.count))
            try db.markDeleted(localIdentifiers: ids)
            try db.unqueue(assetIDs)
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

    func rebuildPeople() async {
        guard let db, let cipher else { return }
        let base = Float(faceModel.threshold(strictness: faceStrictness))
        let result = await Task.detached(priority: .userInitiated) { () -> ([StoredFace], [PersonRow], ClusteringResult)? in
            guard let faces = try? db.storedFaces(cipher: cipher), let persons = try? db.persons(),
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
            let r = clusterer.cluster(samples, index: BruteForceIndex(samples), constraints: constraints)
            return (faces, persons, r)
        }.value
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
    }

    func name(_ person: PersonVM, _ newName: String) async {
        guard let db else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let pid = person.personID {
            try? db.renamePerson(pid, to: trimmed)
            try? db.addFaces(person.faces.map(\.id), toPerson: pid)
        } else {
            try? db.createPerson(named: trimmed, faceIDs: person.faces.map(\.id))
        }
        db.log("edit", "Named a person (\(person.faces.count) faces confirmed)")
        await rebuildPeople()
    }

    func merge(_ source: PersonVM, into target: PersonVM) async {
        guard let db else { return }
        let targetID: Int64
        if let t = target.personID { targetID = t }
        else if let created = try? db.createPerson(named: target.name ?? source.name ?? "Unnamed", faceIDs: target.faces.map(\.id)) {
            targetID = created
        } else { return }
        if let s = source.personID { try? db.mergePerson(s, into: targetID) }
        else { try? db.addFaces(source.faces.map(\.id), toPerson: targetID) }
        await rebuildPeople()
    }

    /// "This is not [Person]" — becomes cannot-link constraints for future grouping.
    func notThisPerson(_ face: StoredFace, in person: PersonVM) async {
        let others = person.faces.map(\.id).filter { $0 != face.id }
        try? db?.rejectFace(face.id, fromPerson: person.personID, againstFaces: others)
        await rebuildPeople()
    }

    func assign(_ face: StoredFace, to person: PersonVM) async {
        if let pid = person.personID { try? db?.addFaces([face.id], toPerson: pid) }
        else if let name = person.name { try? db?.createPerson(named: name, faceIDs: person.faces.map(\.id) + [face.id]) }
        await rebuildPeople()
    }

    func ignore(_ face: StoredFace) async {
        try? db?.ignoreFace(face.id)
        await rebuildPeople()
    }

    func setHidden(_ person: PersonVM, _ hidden: Bool) async {
        guard let pid = person.personID else { return }
        try? db?.setPersonHidden(pid, hidden)
        await rebuildPeople()
    }

    // MARK: Privacy controls

    func deleteAllFaceData() async {
        guard let db else { return }
        _ = try? await db.deleteAllFaceData(faceCropDirectory: Self.faceCropDir)
        faceAnalysisEnabled = false
        await reloadFromDatabase()
        banner = "All face data was deleted and face analysis is off. Turn it back on in Settings to rebuild."
    }

    func deleteAllAppData() async {
        guard let db else { return }
        await cancelAnalysis()
        try? db.deleteAllAppData()
        try? FileManager.default.removeItem(at: Self.faceCropDir)
        await reloadFromDatabase()
        banner = "All PhotoForge data was deleted. Your photos in Apple Photos were not touched."
        await syncLibrary()
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
