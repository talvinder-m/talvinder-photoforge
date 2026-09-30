import Foundation
import GRDB
import PFCore

public struct PFAlbum: Sendable, Identifiable, Hashable {
    public let id: Int64
    public let parentID: Int64?
    public let title: String
    public let isFolder: Bool
    public let assetIDs: [Int64]
    /// Set for smart albums: membership comes from the rule, not from `assetIDs`.
    public let rule: AlbumRule?
    public var isSmart: Bool { rule != nil }
    public init(id: Int64, parentID: Int64?, title: String, isFolder: Bool, assetIDs: [Int64], rule: AlbumRule? = nil) {
        self.id = id; self.parentID = parentID; self.title = title; self.isFolder = isFolder
        self.assetIDs = assetIDs; self.rule = rule
    }
}

public struct PersonSummary: Sendable, Identifiable, Hashable {
    public let id: Int64
    public let name: String?
    public let faceCount: Int
    public let photoCount: Int
    public let isHidden: Bool
}

public extension AppDatabase {

    // MARK: Names

    /// Sets PhotoForge names. `nil` or empty clears the name (the file name shows again).
    func setTitles(_ titles: [(assetID: Int64, title: String?)]) throws {
        try writer.write { db in
            for (id, t) in titles {
                let v = t?.trimmingCharacters(in: .whitespacesAndNewlines)
                try db.execute(sql: "UPDATE assets SET title = ?, updatedAt = ? WHERE id = ?",
                               arguments: [(v?.isEmpty ?? true) ? nil : v, Date().timeIntervalSince1970, id])
            }
        }
    }

    /// After a file rename inside a PhotoForge library.
    func updateFileLocation(assetID: Int64, filePath: String, originalFilename: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE assets SET filePath = ?, originalFilename = ?, updatedAt = ? WHERE id = ?",
                           arguments: [filePath, originalFilename, Date().timeIntervalSince1970, assetID])
        }
    }

    // MARK: PhotoForge albums (custom groups, any library)

    func albums(sourceID: Int64?) throws -> [PFAlbum] {
        try writer.read { db in
            var members: [Int64: [Int64]] = [:]
            for r in try Row.fetchAll(db, sql: """
                SELECT m.albumID, m.assetID FROM pf_album_members m JOIN assets a ON a.id = m.assetID
                WHERE a.isDeletedInSource = 0 ORDER BY m.addedAt
                """) { members[r["albumID"], default: []].append(r["assetID"]) }
            return try Row.fetchAll(db, sql: """
                SELECT id, parentID, title, isFolder, rule FROM pf_albums WHERE (? IS NULL OR sourceLibraryID = ?)
                ORDER BY isFolder DESC, title COLLATE NOCASE
                """, arguments: [sourceID, sourceID]).map {
                PFAlbum(id: $0["id"], parentID: $0["parentID"], title: $0["title"], isFolder: $0["isFolder"],
                        assetIDs: members[$0["id"]] ?? [], rule: AlbumRule.decode($0["rule"] as String?))
            }
        }
    }

    @discardableResult
    func createAlbum(title: String, parentID: Int64?, isFolder: Bool, sourceID: Int64?, assetIDs: [Int64] = [],
                     rule: AlbumRule? = nil) throws -> Int64 {
        try writer.write { db in
            try db.execute(sql: "INSERT INTO pf_albums(sourceLibraryID, parentID, title, isFolder, createdAt, rule) VALUES (?,?,?,?,?,?)",
                           arguments: [sourceID, parentID, title, isFolder, Date().timeIntervalSince1970, rule?.encoded()])
            let id = db.lastInsertedRowID
            try Self.addMembers(db, album: id, assets: assetIDs)
            return id
        }
    }

    /// Changes a smart album's rule, or (nil) turns it into an ordinary album holding `freeze` items.
    func setAlbumRule(_ id: Int64, _ rule: AlbumRule?, freeze: [Int64] = []) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE pf_albums SET rule = ? WHERE id = ?", arguments: [rule?.encoded(), id])
            if rule == nil { try Self.addMembers(db, album: id, assets: freeze) }
        }
    }

    // MARK: Tags you add (stored in `tags` with source 'user')

    /// Tag → items, for the given library.
    func userTags(sourceID: Int64?) throws -> [String: Set<Int64>] {
        try writer.read { db in
            var out: [String: Set<Int64>] = [:]
            for r in try Row.fetchAll(db, sql: """
                SELECT t.label, t.assetID FROM tags t JOIN assets a ON a.id = t.assetID
                WHERE t.source = 'user' AND a.isDeletedInSource = 0 AND (? IS NULL OR a.sourceLibraryID = ?)
                """, arguments: [sourceID, sourceID]) {
                out[r["label"] as String, default: []].insert(r["assetID"] as Int64)
            }
            return out
        }
    }

    func addTag(_ label: String, to assetIDs: [Int64]) throws {
        let l = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty else { return }
        try writer.write { db in
            // Reuse the existing spelling if the tag exists in another case.
            let existing = try String.fetchOne(db, sql: "SELECT label FROM tags WHERE source = 'user' AND label = ? COLLATE NOCASE LIMIT 1", arguments: [l]) ?? l
            for a in assetIDs {
                try db.execute(sql: "INSERT OR IGNORE INTO tags(assetID, label, confidence, source) VALUES (?,?,1,'user')", arguments: [a, existing])
            }
        }
    }

    func removeTag(_ label: String, from assetIDs: [Int64]) throws {
        try writer.write { db in
            for a in assetIDs {
                try db.execute(sql: "DELETE FROM tags WHERE source = 'user' AND assetID = ? AND label = ?", arguments: [a, label])
            }
        }
    }

    func renameTag(_ old: String, to new: String) throws {
        let n = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n != old else { return }
        try writer.write { db in
            try db.execute(sql: "UPDATE OR IGNORE tags SET label = ? WHERE source = 'user' AND label = ?", arguments: [n, old])
            try db.execute(sql: "DELETE FROM tags WHERE source = 'user' AND label = ?", arguments: [old])
        }
    }

    func deleteTag(_ label: String) throws {
        try writer.write { db in try db.execute(sql: "DELETE FROM tags WHERE source = 'user' AND label = ?", arguments: [label]) }
    }

    func renameAlbum(_ id: Int64, to title: String) throws {
        try writer.write { db in try db.execute(sql: "UPDATE pf_albums SET title = ? WHERE id = ?", arguments: [title, id]) }
    }

    /// Deleting an album never deletes photos.
    func deleteAlbum(_ id: Int64) throws {
        try writer.write { db in try db.execute(sql: "DELETE FROM pf_albums WHERE id = ?", arguments: [id]) }
    }

    func moveAlbum(_ id: Int64, toParent parent: Int64?) throws {
        guard parent != id else { return }
        try writer.write { db in try db.execute(sql: "UPDATE pf_albums SET parentID = ? WHERE id = ?", arguments: [parent, id]) }
    }

    func addToAlbum(_ albumID: Int64, assetIDs: [Int64]) throws {
        try writer.write { db in try Self.addMembers(db, album: albumID, assets: assetIDs) }
    }

    func removeFromAlbum(_ albumID: Int64, assetIDs: [Int64]) throws {
        try writer.write { db in
            for a in assetIDs {
                try db.execute(sql: "DELETE FROM pf_album_members WHERE albumID = ? AND assetID = ?", arguments: [albumID, a])
            }
        }
    }

    static func addMembers(_ db: Database, album: Int64, assets: [Int64]) throws {
        let now = Date().timeIntervalSince1970
        for a in assets {
            try db.execute(sql: "INSERT OR IGNORE INTO pf_album_members(albumID, assetID, addedAt) VALUES (?,?,?)", arguments: [album, a, now])
        }
    }

    // MARK: People management (Settings › Face Data)

    func personSummaries(sourceID: Int64?) throws -> [PersonSummary] {
        try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT p.id, p.displayName, p.isHidden,
                       (SELECT COUNT(*) FROM person_face_membership m WHERE m.personID = p.id) AS faces,
                       (SELECT COUNT(DISTINCT f.assetID) FROM person_face_membership m JOIN faces f ON f.id = m.faceID
                         WHERE m.personID = p.id) AS photos
                FROM persons p WHERE (? IS NULL OR p.sourceLibraryID = ?)
                ORDER BY p.displayName COLLATE NOCASE
                """, arguments: [sourceID, sourceID]).map {
                PersonSummary(id: $0["id"], name: $0["displayName"], faceCount: $0["faces"], photoCount: $0["photos"], isHidden: $0["isHidden"])
            }
        }
    }

    /// Forgets a person: their name and confirmations go; the detected faces stay (unassigned),
    /// unless `deleteFaces` is set, which also removes those faces' data.
    func deletePerson(_ id: Int64, deleteFaces: Bool) throws {
        try writer.write { db in
            let faces = try Int64.fetchAll(db, sql: "SELECT faceID FROM person_face_membership WHERE personID = ?", arguments: [id])
            for f in faces {
                try db.execute(sql: "DELETE FROM face_constraints WHERE faceA = ?1 OR faceB = ?1", arguments: [f])
            }
            try db.execute(sql: "DELETE FROM persons WHERE id = ?", arguments: [id])
            if deleteFaces {
                for f in faces {
                    try db.execute(sql: "DELETE FROM embeddings WHERE entityType = 'face' AND entityID = ?", arguments: [f])
                    try db.execute(sql: "UPDATE faces SET isIgnored = 1, embeddingID = NULL WHERE id = ?", arguments: [f])
                }
            }
        }
    }

    /// A face the user marked by hand (Vision missed it, or drew a better box).
    @discardableResult
    func addManualFace(assetID: Int64, box: CGRect, quality: Double, pixelSize: Double, embedding: [Float]?,
                       cropPath: String?, modelName: String, modelVersion: String, cipher: VectorCipher) throws -> Int64 {
        let sealed = try embedding.map { try cipher.seal($0) }
        return try writer.write { db in
            try db.execute(sql: """
                INSERT INTO faces(assetID, bboxX, bboxY, bboxW, bboxH, faceQualityScore, pixelSize, faceCropPath, isManual, createdAt)
                VALUES (?,?,?,?,?,?,?,?,1,?)
                """, arguments: [assetID, box.minX, box.minY, box.width, box.height, quality, pixelSize, cropPath,
                                 Date().timeIntervalSince1970])
            let fid = db.lastInsertedRowID
            if let sealed, let dim = embedding?.count {
                try Self.storeVector(db, entityType: "face", entityID: fid, model: (modelName, modelVersion),
                                     dimension: dim, index: "faces", sealed: sealed)
                try db.execute(sql: "UPDATE faces SET embeddingID = (SELECT id FROM embeddings WHERE entityType='face' AND entityID=?) WHERE id = ?",
                               arguments: [fid, fid])
            }
            return fid
        }
    }

    /// Clears face detection for photos so it runs again (confirmed names are kept where boxes match).
    func resetFaceDetection(sourceID: Int64?) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE assets SET analysisStage = analysisStage & ~? WHERE (? IS NULL OR sourceLibraryID = ?)",
                           arguments: [IndexStage.faces.rawValue | IndexStage.faceEmbeddings.rawValue, sourceID, sourceID])
        }
    }

    // MARK: Splitting a combined database (one-time upgrade to one database per library)

    /// Removes every library except `keep` from this database, with everything that belonged to them.
    func pruneToSource(keep: Int64) throws {
        try writer.write { db in
            let drop = try Int64.fetchAll(db, sql: "SELECT id FROM source_libraries WHERE id != ?", arguments: [keep])
            for sid in drop {
                // edit_projects restricts deletes of their source assets; they belong to the dropped library.
                try db.execute(sql: "DELETE FROM edit_projects WHERE sourceAssetID IN (SELECT id FROM assets WHERE sourceLibraryID = ?)", arguments: [sid])
                try db.execute(sql: "DELETE FROM source_libraries WHERE id = ?", arguments: [sid])      // cascades
            }
            try Self.deleteOrphans(db)
        }
        try writer.writeWithoutTransaction { db in try db.execute(sql: "VACUUM") }
    }

    static func deleteOrphans(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM embeddings WHERE entityType = 'asset' AND entityID NOT IN (SELECT id FROM assets)")
        try db.execute(sql: "DELETE FROM embeddings WHERE entityType = 'face' AND entityID NOT IN (SELECT id FROM faces)")
        try db.execute(sql: "DELETE FROM ocr_text WHERE rowid NOT IN (SELECT id FROM assets)")
        try db.execute(sql: "DELETE FROM persons WHERE sourceLibraryID IS NOT NULL AND sourceLibraryID NOT IN (SELECT id FROM source_libraries)")
        try db.execute(sql: "DELETE FROM similarity_exclusions WHERE assetB IS NOT NULL AND assetB NOT IN (SELECT id FROM assets)")
        try db.execute(sql: "DELETE FROM user_decisions WHERE subjectType = 'asset' AND subjectID NOT IN (SELECT id FROM assets)")
    }

    func sourceIDs() throws -> [(id: Int64, kind: String, name: String, path: String?)] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT id, kind, displayName, path FROM source_libraries ORDER BY id").map {
                ($0["id"], $0["kind"], $0["displayName"], $0["path"])
            }
        }
    }

    func faceCropPaths() throws -> [String] {
        try writer.read { db in try String.fetchAll(db, sql: "SELECT faceCropPath FROM faces WHERE faceCropPath IS NOT NULL") }
    }

    // MARK: Library lookups used by PhotoForge libraries and importers

    func fileHashes(sourceID: Int64) throws -> Set<Data> {
        try writer.read { db in
            Set(try Data.fetchAll(db, sql: "SELECT fileHash FROM assets WHERE sourceLibraryID = ? AND fileHash IS NOT NULL AND isDeletedInSource = 0",
                                  arguments: [sourceID]))
        }
    }

    func assetIDs(forKeys keys: [String], sourceID: Int64) throws -> [String: Int64] {
        try writer.read { db in
            var out: [String: Int64] = [:]
            for k in keys {
                if let id = try Int64.fetchOne(db, sql: "SELECT id FROM assets WHERE sourceLibraryID = ? AND photoKitLocalIdentifier = ?",
                                               arguments: [sourceID, k]) { out[k] = id }
            }
            return out
        }
    }

    /// Apple Photos identifiers already copied into this (PhotoForge) library.
    func importedFromPhotos() throws -> [String] {
        try writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT d.detailJSON FROM user_decisions d JOIN assets a ON a.id = d.subjectID
                WHERE d.decisionType = 'imported_from_photos' AND a.isDeletedInSource = 0 AND d.detailJSON IS NOT NULL
                """)
        }
    }

    func markDeleted(assetIDs: [Int64]) throws {
        try writer.write { db in
            for id in assetIDs { try db.execute(sql: "UPDATE assets SET isDeletedInSource = 1 WHERE id = ?", arguments: [id]) }
        }
    }

    // MARK: Carrying analysis to another library (so a copied library needn't be rescanned)

    /// Copies everything PhotoForge learned about photos in `from` to their copies in this database:
    /// hashes, quality, categories, text, scene embeddings, faces (with embeddings and crops),
    /// people, confirmations and constraints. `mapping` is old asset id → new asset id.
    /// Vectors are re-sealed with this library's key. Returns the number of faces copied.
    @discardableResult
    func copyAnalysis(from src: AppDatabase, sourceCipher: VectorCipher, cipher: VectorCipher,
                      mapping: [Int64: Int64], sourceCropDir: URL, cropDir: URL, newSourceID: Int64) throws -> Int {
        guard !mapping.isEmpty else { return 0 }
        let oldIDs = Array(mapping.keys)
        let copyCols = ["perceptualHash", "differenceHash", "sharpnessScore", "noiseScore", "exposureScore", "qualityScore",
                        "laplacianVariance", "noiseSigma", "meanLuma", "clippedFraction", "title", "burstIdentifier"]
        let stageMask = IndexStage.thumbnailHashes.rawValue | IndexStage.sceneEmbedding.rawValue | IndexStage.ocr.rawValue
            | IndexStage.classification.rawValue | IndexStage.faces.rawValue | IndexStage.faceEmbeddings.rawValue

        // Read everything from the source first.
        typealias FaceRow = (id: Int64, asset: Int64, box: [Double], quality: Double?, pixel: Double?, yaw: Double?, pitch: Double?,
                             roll: Double?, crop: String?, ignored: Bool, manual: Bool, vector: Data?, model: String?, version: String?, dim: Int?)
        let (assets, cats, texts, tags, scene, faces, persons, members, constraints) = try src.writer.read { db -> (
            [Int64: (cols: [String: DatabaseValue], stage: Int)], [Row], [(Int64, String)], [Row], [(Int64, Data, String, String, Int)],
            [FaceRow], [Row], [Row], [Row]) in
            var a: [Int64: (cols: [String: DatabaseValue], stage: Int)] = [:]
            var cats: [Row] = [], texts: [(Int64, String)] = [], tags: [Row] = [], scene: [(Int64, Data, String, String, Int)] = []
            var faces: [FaceRow] = []
            for chunk in stride(from: 0, to: oldIDs.count, by: 500) {
                let ids = oldIDs[chunk..<min(chunk + 500, oldIDs.count)].map(String.init).joined(separator: ",")
                for r in try Row.fetchAll(db, sql: "SELECT * FROM assets WHERE id IN (\(ids))") {
                    var cols: [String: DatabaseValue] = [:]
                    for c in copyCols { cols[c] = r.hasColumn(c) ? (r[c] as DatabaseValue) : .null }
                    a[r["id"] as Int64] = (cols, r["analysisStage"] as Int)
                }
                cats += try Row.fetchAll(db, sql: "SELECT * FROM asset_categories WHERE assetID IN (\(ids))")
                texts += try Row.fetchAll(db, sql: "SELECT rowid AS id, text FROM ocr_text WHERE rowid IN (\(ids))").map { ($0["id"] as Int64, $0["text"] as String) }
                tags += try Row.fetchAll(db, sql: "SELECT * FROM tags WHERE assetID IN (\(ids))")
                scene += try Row.fetchAll(db, sql: """
                    SELECT e.entityID, v.vector, e.modelName, e.modelVersion, e.dimension FROM embeddings e
                    JOIN embedding_vectors v ON v.embeddingID = e.id WHERE e.entityType = 'asset' AND e.entityID IN (\(ids))
                    """).map { ($0["entityID"] as Int64, $0["vector"] as Data, $0["modelName"] as String, $0["modelVersion"] as String, $0["dimension"] as Int) }
                faces += try Row.fetchAll(db, sql: """
                    SELECT f.*, v.vector, e.modelName, e.modelVersion, e.dimension FROM faces f
                    LEFT JOIN embeddings e ON e.id = f.embeddingID LEFT JOIN embedding_vectors v ON v.embeddingID = e.id
                    WHERE f.assetID IN (\(ids))
                    """).map { r -> FaceRow in
                    let box: [Double] = [r["bboxX"], r["bboxY"], r["bboxW"], r["bboxH"]]
                    return (id: r["id"] as Int64, asset: r["assetID"] as Int64, box: box,
                            quality: r["faceQualityScore"] as Double?, pixel: r["pixelSize"] as Double?,
                            yaw: r["yaw"] as Double?, pitch: r["pitch"] as Double?, roll: r["roll"] as Double?,
                            crop: r["faceCropPath"] as String?, ignored: r["isIgnored"] as Bool, manual: (r["isManual"] as Bool?) ?? false,
                            vector: r["vector"] as Data?, model: r["modelName"] as String?, version: r["modelVersion"] as String?,
                            dim: r["dimension"] as Int?)
                }
            }
            let persons = try Row.fetchAll(db, sql: "SELECT * FROM persons")
            let members = try Row.fetchAll(db, sql: "SELECT * FROM person_face_membership")
            let constraints = try Row.fetchAll(db, sql: "SELECT * FROM face_constraints")
            return (a, cats, texts, tags, scene, faces, persons, members, constraints)
        }

        // Re-seal vectors outside the write transaction.
        func reseal(_ blob: Data?) -> Data? {
            guard let blob, let v = try? sourceCipher.open(blob) else { return nil }
            return try? cipher.seal(v)
        }
        let sceneSealed = scene.compactMap { s in reseal(s.1).map { (s.0, $0, s.2, s.3, s.4) } }
        let faceSealed = faces.map { f in (f, reseal(f.vector)) }
        try? FileManager.default.createDirectory(at: cropDir, withIntermediateDirectories: true)

        return try writer.write { db in
            for (old, info) in assets {
                guard let new = mapping[old] else { continue }
                let sets = copyCols.map { "\($0) = ?" }.joined(separator: ", ")
                var args: [DatabaseValueConvertible?] = copyCols.map { info.cols[$0] ?? .null }
                args.append(info.stage & stageMask)
                args.append(new)
                try db.execute(sql: "UPDATE assets SET \(sets), analysisStage = analysisStage | ? WHERE id = ?",
                               arguments: StatementArguments(args))
            }
            for r in cats {
                guard let new = mapping[r["assetID"] as Int64] else { continue }
                try db.execute(sql: "INSERT OR REPLACE INTO asset_categories(assetID, category, confidence, reason, source) VALUES (?,?,?,?,?)",
                               arguments: [new, r["category"] as String, r["confidence"] as Double, r["reason"] as String?, r["source"] as String])
            }
            for (old, text) in texts {
                guard let new = mapping[old] else { continue }
                try db.execute(sql: "INSERT OR REPLACE INTO ocr_text(rowid, text) VALUES (?, ?)", arguments: [new, text])
            }
            for r in tags {
                guard let new = mapping[r["assetID"] as Int64] else { continue }
                try db.execute(sql: "INSERT OR REPLACE INTO tags(assetID, label, confidence, source) VALUES (?,?,?,?)",
                               arguments: [new, r["label"] as String, r["confidence"] as Double, r["source"] as String])
            }
            for (old, blob, model, version, dim) in sceneSealed {
                guard let new = mapping[old] else { continue }
                try Self.storeVector(db, entityType: "asset", entityID: new, model: (model, version), dimension: dim, index: "scenes", sealed: blob)
            }
            var faceMap: [Int64: Int64] = [:]
            for (f, sealed) in faceSealed {
                guard let newAsset = mapping[f.asset] else { continue }
                var newCrop: String? = nil
                if let c = f.crop {
                    let name = "\(newAsset)-\(f.id).jpg"
                    if (try? FileManager.default.copyItem(at: sourceCropDir.appendingPathComponent(c), to: cropDir.appendingPathComponent(name))) != nil {
                        newCrop = name
                    }
                }
                try db.execute(sql: """
                    INSERT INTO faces(assetID, bboxX, bboxY, bboxW, bboxH, faceQualityScore, pixelSize, yaw, pitch, roll,
                                      faceCropPath, isIgnored, isManual, createdAt)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, arguments: [newAsset, f.box[0], f.box[1], f.box[2], f.box[3], f.quality, f.pixel, f.yaw, f.pitch, f.roll,
                                     newCrop, f.ignored, f.manual, Date().timeIntervalSince1970])
                let nf = db.lastInsertedRowID
                faceMap[f.id] = nf
                if let sealed, let model = f.model, let version = f.version, let dim = f.dim {
                    try Self.storeVector(db, entityType: "face", entityID: nf, model: (model, version), dimension: dim, index: "faces", sealed: sealed)
                    try db.execute(sql: "UPDATE faces SET embeddingID = (SELECT id FROM embeddings WHERE entityType='face' AND entityID=?) WHERE id = ?",
                                   arguments: [nf, nf])
                }
            }
            var personMap: [Int64: Int64] = [:]
            for p in persons {
                let oldP: Int64 = p["id"]
                // Only people who have at least one copied face.
                let hasFace = members.contains { ($0["personID"] as Int64) == oldP && faceMap[$0["faceID"] as Int64] != nil }
                guard hasFace else { continue }
                try db.execute(sql: """
                    INSERT INTO persons(displayName, coverFaceID, confidenceState, isHidden, createdAt, updatedAt, sourceLibraryID)
                    VALUES (?, NULL, ?, ?, ?, ?, ?)
                    """, arguments: [p["displayName"] as String?, p["confidenceState"] as String, p["isHidden"] as Bool,
                                     p["createdAt"] as Double, Date().timeIntervalSince1970, newSourceID])
                personMap[oldP] = db.lastInsertedRowID
            }
            for m in members {
                guard let np = personMap[m["personID"] as Int64], let nf = faceMap[m["faceID"] as Int64] else { continue }
                try db.execute(sql: """
                    INSERT OR REPLACE INTO person_face_membership(personID, faceID, clusterSimilarity, userConfirmed, isReference, addedAt)
                    VALUES (?,?,?,?,?,?)
                    """, arguments: [np, nf, m["clusterSimilarity"] as Double?, m["userConfirmed"] as Bool, m["isReference"] as Bool, m["addedAt"] as Double])
            }
            for c in constraints {
                guard let a = faceMap[c["faceA"] as Int64], let b = faceMap[c["faceB"] as Int64] else { continue }
                try db.execute(sql: "INSERT OR REPLACE INTO face_constraints(faceA, faceB, kind, createdAt) VALUES (?,?,?,?)",
                               arguments: [min(a, b), max(a, b), c["kind"] as String, c["createdAt"] as Double])
            }
            return faceMap.count
        }
    }
}
