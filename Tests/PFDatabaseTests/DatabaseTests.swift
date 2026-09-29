import Testing
import Foundation
import GRDB
@testable import PFDatabase
import PFCore

@Suite("App database")
struct DatabaseTests {
    func freshDB() throws -> AppDatabase {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pf-\(UUID().uuidString).sqlite")
        return try AppDatabase.open(at: url)
    }

    @Test func migrationCreatesSchema() throws {
        let db = try freshDB()
        let tables = try db.writer.read { try String.fetchAll($0, sql:
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'ocr_text_%' AND name != 'grdb_migrations'") }
        #expect(Set(tables) == ["source_libraries", "assets", "asset_metadata", "ocr_text", "tags", "embeddings",
                                "embedding_vectors", "faces", "persons", "person_face_membership", "face_constraints",
                                "duplicate_groups", "duplicate_group_members", "similarity_exclusions", "edit_projects",
                                "jobs", "user_decisions", "activity_log", "settings", "removal_queue", "asset_categories", "pf_albums", "pf_album_members"])
    }

    @Test func constraintsRejectBadData() throws {
        let db = try freshDB()
        try db.writer.write { d in
            try d.execute(sql: "INSERT INTO source_libraries(kind, displayName, createdAt) VALUES ('photokit_system','Photos',0)")
            #expect(throws: DatabaseError.self) {
                try d.execute(sql: "INSERT INTO assets(sourceLibraryID, mediaType, updatedAt) VALUES (1, 'gif', 0)")
            }
            try d.execute(sql: "INSERT INTO assets(sourceLibraryID, mediaType, updatedAt) VALUES (1, 'image', 0)")
            try d.execute(sql: "INSERT INTO faces(assetID,bboxX,bboxY,bboxW,bboxH,createdAt) VALUES (1,0,0,.1,.1,0),(1,.5,0,.1,.1,0)")
            #expect(throws: DatabaseError.self) {   // pairs must be stored ordered (faceA < faceB)
                try d.execute(sql: "INSERT INTO face_constraints VALUES (2, 1, 'cannot_link', 0)")
            }
        }
    }

    @Test func deleteAllFaceDataRemovesEverythingFaceRelated() async throws {
        let db = try freshDB()
        try await db.writer.write { d in
            try d.execute(sql: """
                INSERT INTO source_libraries(kind, displayName, createdAt) VALUES ('photokit_system','Photos',0);
                INSERT INTO assets(sourceLibraryID, mediaType, analysisStage, updatedAt) VALUES (1,'image', \(IndexStage.all.rawValue), 0);
                INSERT INTO faces(assetID,bboxX,bboxY,bboxW,bboxH,createdAt) VALUES (1,0,0,.1,.1,0),(1,.5,0,.1,.1,0);
                INSERT INTO embeddings(entityType,entityID,modelName,modelVersion,dimension,vectorIndexName,createdAt)
                    VALUES ('face',1,'arcface','1',512,'faces',0), ('asset',1,'scene','1',512,'scenes',0);
                INSERT INTO persons(displayName, createdAt, updatedAt) VALUES ('Rahul',0,0);
                INSERT INTO person_face_membership(personID, faceID, addedAt) VALUES (1,1,0);
                INSERT INTO face_constraints VALUES (1,2,'cannot_link',0);
                """)
        }
        let crops = FileManager.default.temporaryDirectory.appendingPathComponent("crops-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: crops, withIntermediateDirectories: true)

        #expect(try await db.deleteAllFaceData(faceCropDirectory: crops) == 2)

        try await db.writer.read { d in
            for t in ["faces", "persons", "person_face_membership", "face_constraints"] {
                #expect(try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM \(t)") == 0)
            }
            #expect(try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM embeddings WHERE entityType='face'") == 0)
            #expect(try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM embeddings WHERE entityType='asset'") == 1)   // scene index untouched
            let stage = IndexStage(rawValue: try Int.fetchOne(d, sql: "SELECT analysisStage FROM assets") ?? 0)
            #expect(!stage.contains(.faces) && !stage.contains(.faceEmbeddings) && stage.contains(.thumbnailHashes))
            #expect(try String.fetchOne(d, sql: "SELECT value FROM settings WHERE key='faceAnalysisEnabled'") == "false")
        }
        #expect(!FileManager.default.fileExists(atPath: crops.path))
    }
}
