import Foundation
import GRDB
import PFCore

// MARK: - Plain value types exchanged with the app layer

public struct AssetUpsert: Sendable {
    public var localIdentifier: String
    public var mediaType: String            // image | video | audio | unknown
    public var subtypeMask: Int
    public var creationDate: Date?
    public var modificationDate: Date?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var duration: Double
    public var favorite: Bool
    public var hidden: Bool
    public var burstIdentifier: String?
    public init(localIdentifier: String, mediaType: String, subtypeMask: Int, creationDate: Date?,
                modificationDate: Date?, pixelWidth: Int, pixelHeight: Int, duration: Double,
                favorite: Bool, hidden: Bool, burstIdentifier: String?) {
        self.localIdentifier = localIdentifier; self.mediaType = mediaType; self.subtypeMask = subtypeMask
        self.creationDate = creationDate; self.modificationDate = modificationDate
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.duration = duration
        self.favorite = favorite; self.hidden = hidden; self.burstIdentifier = burstIdentifier
    }
}

public struct AssetRow: Sendable, Hashable, Identifiable {
    public let id: Int64
    public let localIdentifier: String
    public let mediaType: String
    public let subtypeMask: Int
    public let creationDate: Date?
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let favorite: Bool
    public let burstIdentifier: String?
    public let pHash: UInt64?
    public let dHash: UInt64?
    public let fileHash: Data?
    public let sharpness: Double?
    public let noise: Double?
    public let exposure: Double?
    public let laplacianVariance: Double?
    public let noiseSigma: Double?
    public let meanLuma: Double?
    public let availability: String
}

public struct StoredFace: Sendable, Identifiable {
    public let id: Int64
    public let assetID: Int64
    public let localIdentifier: String
    public let box: CGRect
    public let quality: Double
    public let pixelSize: Double
    public let yaw: Double?
    public let cropPath: String?
    public let embedding: [Float]
    public let captureDate: Date?
}

public struct NewFace: Sendable {
    public var box: CGRect
    public var quality: Double
    public var yaw: Double?, pitch: Double?, roll: Double?
    public var pixelSize: Double
    public var cropPath: String?
    public var embedding: [Float]?
    public init(box: CGRect, quality: Double, yaw: Double?, pitch: Double?, roll: Double?,
                pixelSize: Double, cropPath: String?, embedding: [Float]?) {
        self.box = box; self.quality = quality; self.yaw = yaw; self.pitch = pitch; self.roll = roll
        self.pixelSize = pixelSize; self.cropPath = cropPath; self.embedding = embedding
    }
}

public struct PersonRow: Sendable, Identifiable, Hashable {
    public let id: Int64
    public var displayName: String?
    public var confidence: String
    public var isHidden: Bool
    public var confirmedFaceIDs: [Int64]
}

public struct LibraryStats: Sendable {
    public var photos = 0, videos = 0, screenshots = 0, livePhotos = 0, favorites = 0
    public var hashed = 0, facesScanned = 0, faces = 0, cloudOnly = 0, namedPeople = 0
    public init() {}
}

public struct ActivityEntry: Sendable, Identifiable {
    public let id: Int64
    public let category: String
    public let message: String
    public let date: Date
}

// MARK: - Repository

public extension AppDatabase {
    static let sceneModel = (name: "vision-featureprint", version: "2")

    // --- sources & assets -----------------------------------------------------

    func systemSourceID() throws -> Int64 {
        try writer.write { db in
            if let id = try Int64.fetchOne(db, sql: "SELECT id FROM source_libraries WHERE kind = 'photokit_system'") {
                return id
            }
            try db.execute(sql: "INSERT INTO source_libraries(kind, displayName, createdAt) VALUES ('photokit_system', 'Apple Photos', ?)",
                           arguments: [Date().timeIntervalSince1970])
            return db.lastInsertedRowID
        }
    }

    /// Insert-or-update from PhotoKit. A changed modification date clears every
    /// analysis bit except metadata, so edited photos are re-analysed.
    func upsert(_ items: [AssetUpsert], sourceID: Int64, scanStamp: Date) throws {
        let stamp = scanStamp.timeIntervalSince1970
        try writer.write { db in
            let stmt = try db.cachedStatement(sql: """
                INSERT INTO assets(photoKitLocalIdentifier, sourceLibraryID, mediaType, mediaSubtypeMask, creationDate,
                    modificationDate, pixelWidth, pixelHeight, duration, favorite, hidden, burstIdentifier,
                    analysisStage, isDeletedInSource, indexedAt, updatedAt)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?, 1, 0, ?, ?)
                ON CONFLICT(sourceLibraryID, photoKitLocalIdentifier) DO UPDATE SET
                    mediaType = excluded.mediaType, mediaSubtypeMask = excluded.mediaSubtypeMask,
                    creationDate = excluded.creationDate, pixelWidth = excluded.pixelWidth,
                    pixelHeight = excluded.pixelHeight, duration = excluded.duration,
                    favorite = excluded.favorite, hidden = excluded.hidden, burstIdentifier = excluded.burstIdentifier,
                    analysisStage = CASE WHEN assets.modificationDate IS NOT excluded.modificationDate THEN 1
                                         ELSE assets.analysisStage END,
                    modificationDate = excluded.modificationDate,
                    isDeletedInSource = 0, indexedAt = excluded.indexedAt, updatedAt = excluded.updatedAt
                """)
            for a in items {
                try stmt.execute(arguments: [a.localIdentifier, sourceID, a.mediaType, a.subtypeMask,
                                             a.creationDate?.timeIntervalSince1970, a.modificationDate?.timeIntervalSince1970,
                                             a.pixelWidth, a.pixelHeight, a.duration, a.favorite, a.hidden,
                                             a.burstIdentifier, stamp, stamp])
            }
        }
    }

    /// After a full scan, anything not seen in this scan is gone from Photos.
    func markUnseenDeleted(sourceID: Int64, scanStamp: Date) throws -> Int {
        try writer.write { db in
            try db.execute(sql: "UPDATE assets SET isDeletedInSource = 1 WHERE sourceLibraryID = ? AND indexedAt < ? AND isDeletedInSource = 0",
                           arguments: [sourceID, scanStamp.timeIntervalSince1970])
            return db.changesCount
        }
    }

    func markDeleted(localIdentifiers: [String]) throws {
        guard !localIdentifiers.isEmpty else { return }
        try writer.write { db in
            for id in localIdentifiers {
                try db.execute(sql: "UPDATE assets SET isDeletedInSource = 1 WHERE photoKitLocalIdentifier = ?", arguments: [id])
            }
        }
    }

    /// Image assets still missing `stage`, newest first (what users look at first).
    func pending(stage: IndexStage, includeCloudOnly: Bool, limit: Int = 1_000_000) throws -> [(id: Int64, localIdentifier: String)] {
        try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, photoKitLocalIdentifier FROM assets
                WHERE isDeletedInSource = 0 AND mediaType = 'image' AND (analysisStage & ?) = 0
                  AND (? OR localAvailabilityState != 'cloud_only')
                ORDER BY creationDate DESC LIMIT ?
                """, arguments: [stage.rawValue, includeCloudOnly, limit])
            .map { ($0["id"], $0["photoKitLocalIdentifier"]) }
        }
    }

    func setAvailability(assetID: Int64, _ state: LocalAvailability) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE assets SET localAvailabilityState = ? WHERE id = ?", arguments: [state.rawValue, assetID])
        }
    }

    func saveAnalysis(assetID: Int64, pHash: UInt64, dHash: UInt64, laplacianVariance: Double, noiseSigma: Double,
                      meanLuma: Double, clipped: Double, sharpness: Double, noise: Double, exposure: Double,
                      sceneEmbedding: [Float]?, cipher: VectorCipher) throws {
        let sealed = try sceneEmbedding.map { try cipher.seal($0) }
        try writer.write { db in
            try db.execute(sql: """
                UPDATE assets SET perceptualHash = ?, differenceHash = ?, sharpnessScore = ?, noiseScore = ?,
                    exposureScore = ?, qualityScore = ?, localAvailabilityState = 'local',
                    analysisStage = analysisStage | ?, updatedAt = ? WHERE id = ?
                """, arguments: [Int64(bitPattern: pHash), Int64(bitPattern: dHash), sharpness, noise, exposure,
                                 0.75 * sharpness + 0.25 * noise,
                                 IndexStage.thumbnailHashes.rawValue | IndexStage.sceneEmbedding.rawValue,
                                 Date().timeIntervalSince1970, assetID])
            try db.execute(sql: """
                UPDATE assets SET laplacianVariance = ?, noiseSigma = ?, meanLuma = ?, clippedFraction = ? WHERE id = ?
                """, arguments: [laplacianVariance, noiseSigma, meanLuma, clipped, assetID])
            if let sealed, let dim = sceneEmbedding?.count {
                try Self.storeVector(db, entityType: "asset", entityID: assetID, model: Self.sceneModel,
                                     dimension: dim, index: "scenes", sealed: sealed)
            }
        }
    }

    func setFileHash(assetID: Int64, sha256: Data, fileSize: Int?) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE assets SET fileHash = ?, fileSize = COALESCE(?, fileSize), analysisStage = analysisStage | ? WHERE id = ?",
                           arguments: [sha256, fileSize, IndexStage.fileHash.rawValue, assetID])
        }
    }

    func assets(includeHidden: Bool = true) throws -> [AssetRow] {
        try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM assets a
                WHERE a.isDeletedInSource = 0 AND (? OR a.hidden = 0)
                ORDER BY a.creationDate DESC
                """, arguments: [includeHidden]).map(Self.assetRow)
        }
    }

    static func assetRow(_ r: Row) -> AssetRow {
        let lap: Double? = r["laplacianVariance"], sigma: Double? = r["noiseSigma"], luma: Double? = r["meanLuma"]
        let p: Int64? = r["perceptualHash"], dh: Int64? = r["differenceHash"]
        let created: Double? = r["creationDate"]
        return AssetRow(id: r["id"], localIdentifier: r["photoKitLocalIdentifier"] ?? "", mediaType: r["mediaType"],
                        subtypeMask: r["mediaSubtypeMask"], creationDate: created.map(Date.init(timeIntervalSince1970:)),
                        pixelWidth: r["pixelWidth"] ?? 0, pixelHeight: r["pixelHeight"] ?? 0,
                        favorite: r["favorite"], burstIdentifier: r["burstIdentifier"],
                        pHash: p.map { UInt64(bitPattern: $0) }, dHash: dh.map { UInt64(bitPattern: $0) },
                        fileHash: r["fileHash"], sharpness: r["sharpnessScore"], noise: r["noiseScore"],
                        exposure: r["exposureScore"], laplacianVariance: lap, noiseSigma: sigma, meanLuma: luma,
                        availability: r["localAvailabilityState"])
    }

    /// Scene embeddings keyed by asset id.
    func sceneEmbeddings(cipher: VectorCipher) throws -> [Int64: [Float]] {
        try writer.read { db in
            var out: [Int64: [Float]] = [:]
            let rows = try Row.fetchCursor(db, sql: """
                SELECT e.entityID, v.vector FROM embeddings e JOIN embedding_vectors v ON v.embeddingID = e.id
                WHERE e.entityType = 'asset' AND e.modelName = ?
                """, arguments: [Self.sceneModel.name])
            while let r = try rows.next() {
                let blob: Data = r["vector"]
                if let v = try? cipher.open(blob) { out[r["entityID"]] = v }
            }
            return out
        }
    }

    static func storeVector(_ db: Database, entityType: String, entityID: Int64,
                            model: (name: String, version: String), dimension: Int, index: String, sealed: Data) throws {
        try db.execute(sql: """
            INSERT INTO embeddings(entityType, entityID, modelName, modelVersion, dimension, vectorIndexName, encrypted, createdAt)
            VALUES (?,?,?,?,?,?,1,?)
            ON CONFLICT(entityType, entityID, modelName, modelVersion) DO UPDATE SET createdAt = excluded.createdAt
            """, arguments: [entityType, entityID, model.name, model.version, dimension, index, Date().timeIntervalSince1970])
        let eid = try Int64.fetchOne(db, sql: """
            SELECT id FROM embeddings WHERE entityType = ? AND entityID = ? AND modelName = ? AND modelVersion = ?
            """, arguments: [entityType, entityID, model.name, model.version])!
        try db.execute(sql: "INSERT OR REPLACE INTO embedding_vectors(embeddingID, vector) VALUES (?, ?)", arguments: [eid, sealed])
    }

    // --- duplicate feedback -------------------------------------------------------

    func exclusions() throws -> (excluded: Set<Int64>, pairs: Set<[Int64]>) {
        try writer.read { db in
            var ex = Set<Int64>(), pairs = Set<[Int64]>()
            for r in try Row.fetchAll(db, sql: "SELECT assetA, assetB FROM similarity_exclusions") {
                let a: Int64 = r["assetA"]
                if let b: Int64 = r["assetB"] { pairs.insert([a, b]) } else { ex.insert(a) }
            }
            return (ex, pairs)
        }
    }

    func addNotSimilar(_ ids: [Int64]) throws {
        try writer.write { db in
            let sorted = ids.sorted()
            for i in sorted.indices { for j in sorted.indices where j > i {
                try db.execute(sql: "INSERT OR IGNORE INTO similarity_exclusions(assetA, assetB, createdAt) VALUES (?,?,?)",
                               arguments: [sorted[i], sorted[j], Date().timeIntervalSince1970])
            } }
        }
    }

    func excludeFromScans(_ ids: [Int64]) throws {
        try writer.write { db in
            for id in ids {
                try db.execute(sql: "INSERT OR IGNORE INTO similarity_exclusions(assetA, assetB, createdAt) VALUES (?, NULL, ?)",
                               arguments: [id, Date().timeIntervalSince1970])
                try db.execute(sql: "UPDATE assets SET duplicateStatus = 'excluded' WHERE id = ?", arguments: [id])
            }
        }
    }

    func recordDecision(_ type: String, subjectType: String, subjectID: Int64, related: Int64? = nil, detail: String? = nil) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO user_decisions(decisionType, subjectType, subjectID, relatedSubjectID, detailJSON, createdAt)
                VALUES (?,?,?,?,?,?)
                """, arguments: [type, subjectType, subjectID, related, detail, Date().timeIntervalSince1970])
        }
    }

    // --- removal queue & edit projects ---------------------------------------------

    func queueForRemoval(_ ids: [Int64], reason: String, groupID: String?) throws {
        try writer.write { db in
            for id in ids {
                try db.execute(sql: "INSERT OR REPLACE INTO removal_queue(assetID, reason, groupID, addedAt) VALUES (?,?,?,?)",
                               arguments: [id, reason, groupID, Date().timeIntervalSince1970])
            }
        }
    }

    func unqueue(_ ids: [Int64]) throws {
        try writer.write { db in
            for id in ids { try db.execute(sql: "DELETE FROM removal_queue WHERE assetID = ?", arguments: [id]) }
        }
    }

    func removalQueue() throws -> [(assetID: Int64, reason: String)] {
        try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT q.assetID, q.reason FROM removal_queue q JOIN assets a ON a.id = q.assetID
                WHERE a.isDeletedInSource = 0 ORDER BY q.addedAt DESC
                """).map { ($0["assetID"], $0["reason"]) }
        }
    }

    func saveEditProject(sourceAssetID: Int64, name: String, stackJSON: String, stackVersion: Int,
                         containsGenerative: Bool, outputAssetID: String?, outputPath: String?,
                         modelsJSON: String?, sourceChecksum: Data?) throws {
        try writer.write { db in
            let now = Date().timeIntervalSince1970
            try db.execute(sql: """
                INSERT INTO edit_projects(sourceAssetID, projectName, editStackJSON, editStackVersion, containsGenerative,
                    outputAssetID, outputPath, aiModelMetadataJSON, sourceChecksum, sourceAccessedAt, createdAt, updatedAt)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                """, arguments: [sourceAssetID, name, stackJSON, stackVersion, containsGenerative, outputAssetID,
                                 outputPath, modelsJSON, sourceChecksum, now, now, now])
        }
    }

    func lastEditStack(sourceAssetID: Int64) throws -> String? {
        try writer.read { db in
            try String.fetchOne(db, sql: "SELECT editStackJSON FROM edit_projects WHERE sourceAssetID = ? ORDER BY updatedAt DESC LIMIT 1",
                                arguments: [sourceAssetID])
        }
    }

    // --- faces & people -----------------------------------------------------------

    /// Replaces the faces of one asset (re-analysis) and sets the face stage bits.
    func replaceFaces(assetID: Int64, faces: [NewFace], modelName: String, modelVersion: String, cipher: VectorCipher) throws {
        let sealed = try faces.map { try $0.embedding.map { try cipher.seal($0) } }
        try writer.write { db in
            let old = try Int64.fetchAll(db, sql: "SELECT id FROM faces WHERE assetID = ?", arguments: [assetID])
            for f in old {
                try db.execute(sql: "DELETE FROM embeddings WHERE entityType = 'face' AND entityID = ?", arguments: [f])
            }
            // Keep user-confirmed memberships' faces if boxes are unchanged would be ideal; simplest safe path:
            // only re-detect assets that have no confirmed faces (enforced by the caller's pending query).
            try db.execute(sql: "DELETE FROM faces WHERE assetID = ?", arguments: [assetID])
            let now = Date().timeIntervalSince1970
            for (f, s) in zip(faces, sealed) {
                try db.execute(sql: """
                    INSERT INTO faces(assetID, bboxX, bboxY, bboxW, bboxH, faceQualityScore, yaw, pitch, roll, pixelSize,
                                      faceCropPath, createdAt)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                    """, arguments: [assetID, f.box.minX, f.box.minY, f.box.width, f.box.height, f.quality,
                                     f.yaw, f.pitch, f.roll, f.pixelSize, f.cropPath, now])
                let fid = db.lastInsertedRowID
                if let s, let dim = f.embedding?.count {
                    try Self.storeVector(db, entityType: "face", entityID: fid, model: (modelName, modelVersion),
                                         dimension: dim, index: "faces", sealed: s)
                    try db.execute(sql: "UPDATE faces SET embeddingID = (SELECT id FROM embeddings WHERE entityType='face' AND entityID=?) WHERE id = ?",
                                   arguments: [fid, fid])
                }
            }
            try db.execute(sql: "UPDATE assets SET analysisStage = analysisStage | ? WHERE id = ?",
                           arguments: [IndexStage.faces.rawValue | IndexStage.faceEmbeddings.rawValue, assetID])
        }
    }

    func storedFaces(cipher: VectorCipher) throws -> [StoredFace] {
        try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT f.id, f.assetID, a.photoKitLocalIdentifier, f.bboxX, f.bboxY, f.bboxW, f.bboxH,
                       f.faceQualityScore, f.pixelSize, f.yaw, f.faceCropPath, a.creationDate, v.vector
                FROM faces f
                JOIN assets a ON a.id = f.assetID AND a.isDeletedInSource = 0
                JOIN embeddings e ON e.id = f.embeddingID
                JOIN embedding_vectors v ON v.embeddingID = e.id
                WHERE f.isIgnored = 0
                """).compactMap { r in
                    let blob: Data = r["vector"]
                    guard let v = try? cipher.open(blob) else { return nil }
                    let created: Double? = r["creationDate"]
                    return StoredFace(id: r["id"], assetID: r["assetID"], localIdentifier: r["photoKitLocalIdentifier"] ?? "",
                                      box: CGRect(x: r["bboxX"] as Double, y: r["bboxY"] as Double,
                                                  width: r["bboxW"] as Double, height: r["bboxH"] as Double),
                                      quality: r["faceQualityScore"] ?? 0.5, pixelSize: r["pixelSize"] ?? 100,
                                      yaw: r["yaw"], cropPath: r["faceCropPath"], embedding: v,
                                      captureDate: created.map(Date.init(timeIntervalSince1970:)))
                }
        }
    }

    func persons() throws -> [PersonRow] {
        try writer.read { db in
            let members = try Row.fetchAll(db, sql: "SELECT personID, faceID FROM person_face_membership WHERE userConfirmed = 1")
            var byPerson: [Int64: [Int64]] = [:]
            for m in members { byPerson[m["personID"], default: []].append(m["faceID"]) }
            return try Row.fetchAll(db, sql: "SELECT * FROM persons ORDER BY displayName COLLATE NOCASE").map { r in
                PersonRow(id: r["id"], displayName: r["displayName"], confidence: r["confidenceState"],
                          isHidden: r["isHidden"], confirmedFaceIDs: byPerson[r["id"]] ?? [])
            }
        }
    }

    func faceConstraints() throws -> (must: [(Int64, Int64)], cannot: [(Int64, Int64)]) {
        try writer.read { db in
            var must: [(Int64, Int64)] = [], cannot: [(Int64, Int64)] = []
            for r in try Row.fetchAll(db, sql: "SELECT faceA, faceB, kind FROM face_constraints") {
                let pair: (Int64, Int64) = (r["faceA"], r["faceB"])
                if (r["kind"] as String) == "must_link" { must.append(pair) } else { cannot.append(pair) }
            }
            return (must, cannot)
        }
    }

    /// Naming a group confirms its current faces as that person.
    @discardableResult
    func createPerson(named name: String, faceIDs: [Int64]) throws -> Int64 {
        try writer.write { db in
            let now = Date().timeIntervalSince1970
            try db.execute(sql: "INSERT INTO persons(displayName, coverFaceID, confidenceState, createdAt, updatedAt) VALUES (?,?,'confirmed',?,?)",
                           arguments: [name, faceIDs.first, now, now])
            let pid = db.lastInsertedRowID
            try Self.confirm(db, person: pid, faces: faceIDs)
            return pid
        }
    }

    func addFaces(_ faceIDs: [Int64], toPerson pid: Int64) throws {
        try writer.write { db in try Self.confirm(db, person: pid, faces: faceIDs) }
    }

    static func confirm(_ db: Database, person pid: Int64, faces: [Int64]) throws {
        let now = Date().timeIntervalSince1970
        for f in faces {
            try db.execute(sql: """
                INSERT INTO person_face_membership(personID, faceID, userConfirmed, addedAt) VALUES (?,?,1,?)
                ON CONFLICT(faceID) DO UPDATE SET personID = excluded.personID, userConfirmed = 1
                """, arguments: [pid, f, now])
            // Must-link to the person's anchor face keeps the group together on re-clustering.
            if let anchor = try Int64.fetchOne(db, sql: "SELECT MIN(faceID) FROM person_face_membership WHERE personID = ?", arguments: [pid]),
               anchor != f {
                try db.execute(sql: "INSERT OR REPLACE INTO face_constraints(faceA, faceB, kind, createdAt) VALUES (?,?,'must_link',?)",
                               arguments: [min(anchor, f), max(anchor, f), now])
            }
        }
        try db.execute(sql: "UPDATE persons SET updatedAt = ? WHERE id = ?", arguments: [now, pid])
    }

    func renamePerson(_ pid: Int64, to name: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE persons SET displayName = ?, updatedAt = ? WHERE id = ?",
                           arguments: [name, Date().timeIntervalSince1970, pid])
        }
    }

    func setPersonHidden(_ pid: Int64, _ hidden: Bool) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE persons SET isHidden = ? WHERE id = ?", arguments: [hidden, pid])
        }
    }

    /// Merge `source` into `target`: memberships move, source row is removed.
    func mergePerson(_ source: Int64, into target: Int64) throws {
        guard source != target else { return }
        try writer.write { db in
            let faces = try Int64.fetchAll(db, sql: "SELECT faceID FROM person_face_membership WHERE personID = ?", arguments: [source])
            try Self.confirm(db, person: target, faces: faces)
            // Clear any cannot-links between the two people now that the user says they're the same.
            let targetFaces = try Int64.fetchAll(db, sql: "SELECT faceID FROM person_face_membership WHERE personID = ?", arguments: [target])
            let all = Set(targetFaces)
            for a in all { for b in all where a < b {
                try db.execute(sql: "DELETE FROM face_constraints WHERE faceA = ? AND faceB = ? AND kind = 'cannot_link'", arguments: [a, b])
            } }
            try db.execute(sql: "DELETE FROM persons WHERE id = ?", arguments: [source])
        }
    }

    /// "This is not [Person]": remove the face and add cannot-links against the person's confirmed faces.
    func rejectFace(_ faceID: Int64, fromPerson pid: Int64?, againstFaces others: [Int64]) throws {
        try writer.write { db in
            let now = Date().timeIntervalSince1970
            if let pid {
                try db.execute(sql: "DELETE FROM person_face_membership WHERE faceID = ? AND personID = ?", arguments: [faceID, pid])
            }
            for o in others where o != faceID {
                try db.execute(sql: "DELETE FROM face_constraints WHERE faceA = ? AND faceB = ?", arguments: [min(o, faceID), max(o, faceID)])
                try db.execute(sql: "INSERT INTO face_constraints(faceA, faceB, kind, createdAt) VALUES (?,?,'cannot_link',?)",
                               arguments: [min(o, faceID), max(o, faceID), now])
            }
        }
    }

    func ignoreFace(_ faceID: Int64) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE faces SET isIgnored = 1 WHERE id = ?", arguments: [faceID])
            try db.execute(sql: "DELETE FROM person_face_membership WHERE faceID = ?", arguments: [faceID])
        }
    }

    // --- settings, stats, activity ------------------------------------------------

    func setting(_ key: String) -> String? {
        try? writer.read { db in try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key]) }
    }

    func setSetting(_ key: String, _ value: String) {
        try? writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)", arguments: [key, value])
        }
    }

    func log(_ category: String, _ message: String, assetCount: Int? = nil, model: String? = nil) {
        guard setting("activityLogEnabled") != "false" else { return }
        try? writer.write { db in
            try db.execute(sql: "INSERT INTO activity_log(category, message, execution, modelName, assetCount, createdAt) VALUES (?,?,'local',?,?,?)",
                           arguments: [category, message, model, assetCount, Date().timeIntervalSince1970])
        }
    }

    func activity(limit: Int = 500) throws -> [ActivityEntry] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT id, category, message, createdAt FROM activity_log ORDER BY createdAt DESC LIMIT ?",
                             arguments: [limit]).map {
                ActivityEntry(id: $0["id"], category: $0["category"], message: $0["message"],
                              date: Date(timeIntervalSince1970: $0["createdAt"]))
            }
        }
    }

    func clearActivity() throws { try writer.write { try $0.execute(sql: "DELETE FROM activity_log") } }

    func stats() throws -> LibraryStats {
        try writer.read { db in
            var s = LibraryStats()
            let base = "FROM assets WHERE isDeletedInSource = 0"
            s.photos = try Int.fetchOne(db, sql: "SELECT COUNT(*) \(base) AND mediaType = 'image'") ?? 0
            s.videos = try Int.fetchOne(db, sql: "SELECT COUNT(*) \(base) AND mediaType = 'video'") ?? 0
            s.screenshots = try Int.fetchOne(db, sql: "SELECT COUNT(*) \(base) AND (mediaSubtypeMask & 4) != 0") ?? 0
            s.livePhotos = try Int.fetchOne(db, sql: "SELECT COUNT(*) \(base) AND (mediaSubtypeMask & 8) != 0") ?? 0
            s.favorites = try Int.fetchOne(db, sql: "SELECT COUNT(*) \(base) AND favorite = 1") ?? 0
            s.hashed = try Int.fetchOne(db, sql: "SELECT COUNT(*) \(base) AND (analysisStage & 2) != 0") ?? 0
            s.facesScanned = try Int.fetchOne(db, sql: "SELECT COUNT(*) \(base) AND (analysisStage & 8) != 0") ?? 0
            s.cloudOnly = try Int.fetchOne(db, sql: "SELECT COUNT(*) \(base) AND localAvailabilityState = 'cloud_only'") ?? 0
            s.faces = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM faces WHERE isIgnored = 0") ?? 0
            s.namedPeople = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM persons WHERE displayName IS NOT NULL") ?? 0
            return s
        }
    }

    /// Settings › Privacy › "Delete all app data": everything except settings.
    func deleteAllAppData() throws {
        try writer.write { db in
            for t in ["removal_queue", "embedding_vectors", "embeddings", "face_constraints", "person_face_membership", "persons", "faces",
                      "duplicate_group_members", "duplicate_groups", "similarity_exclusions", "edit_projects",
                      "user_decisions", "tags", "asset_metadata", "assets", "jobs", "activity_log"] {
                try db.execute(sql: "DELETE FROM \(t)")
            }
            try db.execute(sql: "DELETE FROM ocr_text")
        }
        try writer.writeWithoutTransaction { db in try db.execute(sql: "VACUUM") }
    }
}
