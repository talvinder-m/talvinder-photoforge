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
            try db.execute(sql: Migrations.v0001_initial)
        }
        // m.registerMigration("0002_…") { db in … }
        return m
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

/// Seals embedding vectors with AES-GCM.
///
/// Key storage: builds signed with a Developer ID keep the key in the Keychain
/// (`.keychain`). Ad-hoc-signed builds (what CI produces) would trigger a Keychain
/// prompt after every update, because each build has a new code signature, so they
/// use `.file`: a 0600 key file inside the app's Application Support folder,
/// protected at rest by FileVault. Either way the key never leaves the Mac.
public struct VectorCipher: Sendable {
    public enum KeyStore: Sendable { case keychain(service: String), file(URL) }
    private let key: SymmetricKey

    public init(store: KeyStore) throws {
        switch store {
        case .keychain(let service): key = try Self.keychainKey(service: service)
        case .file(let url): key = try Self.fileKey(at: url)
        }
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

    static func fileKey(at url: URL) throws -> SymmetricKey {
        let fm = FileManager.default
        if let d = try? Data(contentsOf: url), d.count == 32 { return SymmetricKey(data: d) }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        guard fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return key
    }

    static func keychainKey(service: String) throws -> SymmetricKey {
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
