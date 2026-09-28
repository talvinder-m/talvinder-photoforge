import Foundation
import GRDB
import CryptoKit
import Security
import PFCore

/// The app's own database, in the sandboxed Application Support container.
/// Apple's Photos.sqlite is never opened for writing anywhere in this codebase.
public final class AppDatabase: Sendable {
    public let writer: DatabasePool

    public static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var cfg = Configuration()
        cfg.foreignKeysEnabled = true
        cfg.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA secure_delete = ON;")
        }
        let pool = try DatabasePool(path: url.path, configuration: cfg)
        // Protect the file at rest when the Mac is locked (FileVault is the primary layer).
        try? (url as NSURL).setResourceValue(URLFileProtection.completeUntilFirstUserAuthentication, forKey: .fileProtectionKey)
        let db = AppDatabase(writer: pool)
        try db.migrator.migrate(pool)
        return db
    }

    init(writer: DatabasePool) { self.writer = writer }

    /// Append-only list of migrations. Never edit a shipped migration; add a new one.
    var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        #if DEBUG
        m.eraseDatabaseOnSchemaChange = false   // keep dev data; migrations must be additive
        #endif
        m.registerMigration("0001_initial") { db in
            try db.execute(sql: try Self.sql(named: "0001_initial"))
        }
        // m.registerMigration("0002_…") { db in … }
        return m
    }

    static func sql(named name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "sql", subdirectory: "Migrations") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: Privacy controls

    /// Settings › Privacy › "Delete all face data". Removes embeddings, clusters,
    /// crops, labels and constraints. Does NOT re-run analysis unless asked.
    public func deleteAllFaceData(faceCropDirectory: URL) async throws -> Int {
        let removed = try await writer.write { db -> Int in
            let n = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM faces") ?? 0
            try db.execute(sql: """
                DELETE FROM embeddings WHERE entityType = 'face';
                DELETE FROM face_constraints;
                DELETE FROM person_face_membership;
                DELETE FROM persons;
                DELETE FROM faces;
                DELETE FROM user_decisions WHERE subjectType IN ('face','person');
                UPDATE assets SET analysisStage = analysisStage & ~(\(IndexStage.faces.rawValue) | \(IndexStage.faceEmbeddings.rawValue));
                UPDATE settings SET value = 'false' WHERE key = 'faceAnalysisEnabled';
                INSERT INTO activity_log(category, message, execution, createdAt)
                    VALUES ('privacy', 'All face data deleted by user', 'local', \(Date().timeIntervalSince1970));
                """)
            return n
        }
        try? FileManager.default.removeItem(at: faceCropDirectory)
        // Don't leave deleted biometric rows recoverable from free pages.
        try await writer.writeWithoutTransaction { db in try db.execute(sql: "VACUUM") }
        return removed
    }
}

/// Seals embedding vectors with AES-GCM. The 256-bit key lives in the Keychain,
/// is created on first use, and never leaves the device (ThisDeviceOnly).
public struct VectorCipher: Sendable {
    private let key: SymmetricKey

    public init(service: String = "ai.photoforge.vectors") throws {
        key = try Self.loadOrCreateKey(service: service)
    }

    public func seal(_ v: [Float]) throws -> Data {
        let raw = v.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let combined = try AES.GCM.seal(raw, using: key).combined else { throw CocoaError(.coderInvalidValue) }
        return combined
    }

    public func open(_ blob: Data) throws -> [Float] {
        let raw = try AES.GCM.open(AES.GCM.SealedBox(combined: blob), using: key)
        return raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    static func loadOrCreateKey(service: String) throws -> SymmetricKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: "vector-key",
                                    kSecReturnData as String: true]
        var out: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let d = out as? Data {
            return SymmetricKey(data: d)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service,
                                  kSecAttrAccount as String: "vector-key",
                                  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                  kSecValueData as String: data]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return key
    }
}
