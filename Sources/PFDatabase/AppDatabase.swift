import Foundation
import GRDB
import CryptoKit
import Security
import PFCore

/// The app's own database, in the sandboxed Application Support container.
/// Apple's Photos.sqlite is never opened for writing anywhere in this codebase.
public final class AppDatabase: Sendable {
    public let writer: DatabasePool
    public let url: URL

    /// Opens (creating if needed) and migrates a library database. When an upgrade brings
    /// new migrations, the database is first copied to `Backups/` next to it (last 3 kept),
    /// so an app update can never cost the user their analysis or names.
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
        let db = AppDatabase(writer: pool, url: url)
        let migrator = db.migrator
        let (applied, complete) = try pool.read { d in (try migrator.appliedMigrations(d), try migrator.hasCompletedMigrations(d)) }
        if !applied.isEmpty && !complete {
            try? db.backup(reason: "before-upgrade")
        }
        try migrator.migrate(pool)
        return db
    }

    /// Opens a library database for reading only (no migrations, no writes) — used to serve
    /// other apps through the local API, and to read a library that isn't the open one.
    public static func openReadOnly(at url: URL) throws -> AppDatabase {
        var cfg = Configuration()
        cfg.readonly = true
        cfg.foreignKeysEnabled = true
        return AppDatabase(writer: try DatabasePool(path: url.path, configuration: cfg), url: url)
    }

    init(writer: DatabasePool, url: URL) { self.writer = writer; self.url = url }

    public var backupsDirectory: URL { url.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true) }

    /// Consistent single-file copy of the live database (safe while in use).
    public func copy(to dest: URL) throws {
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try writer.writeWithoutTransaction { db in try db.execute(sql: "VACUUM INTO ?", arguments: [dest.path]) }
    }

    /// Timestamped backup in `Backups/`; keeps the newest `keep`.
    @discardableResult
    public func backup(reason: String, keep: Int = 3) throws -> URL {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        let dest = backupsDirectory.appendingPathComponent("photoforge-\(f.string(from: .now))-\(reason).sqlite")
        try copy(to: dest)
        let fm = FileManager.default
        let all = ((try? fm.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.pathExtension == "sqlite" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in all.dropFirst(keep) { try? fm.removeItem(at: old) }
        return dest
    }

    /// Append-only list of migrations. Never edit a shipped migration; add a new one.
    var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        #if DEBUG
        m.eraseDatabaseOnSchemaChange = false   // keep dev data; migrations must be additive
        #endif
        m.registerMigration("0001_initial") { db in
            try db.execute(sql: Migrations.v0001_initial)
        }
        m.registerMigration("0002_metrics") { db in
            try db.execute(sql: Migrations.v0002_metrics)
        }
        m.registerMigration("0003_removal_queue") { db in
            try db.execute(sql: Migrations.v0003_removal_queue)
        }
        m.registerMigration("0004_libraries") { db in
            try db.execute(sql: Migrations.v0004_libraries)
        }
        m.registerMigration("0005_categories") { db in
            try db.execute(sql: Migrations.v0005_categories)
        }
        m.registerMigration("0006_names_albums_manual_faces") { db in
            try db.execute(sql: Migrations.v0006_names_albums)
        }
        m.registerMigration("0007_smart_albums_tags") { db in
            try db.execute(sql: Migrations.v0007_smart_albums_tags)
        }
        return m
    }

    // MARK: Privacy controls

    /// Settings › Privacy › "Delete all face data". Removes embeddings, clusters,
    /// crops, labels and constraints. Does NOT re-run analysis unless asked.
    public func deleteAllFaceData(faceCropDirectory: URL, keepAnalysisEnabled: Bool = false) async throws -> Int {
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
                \(keepAnalysisEnabled ? "" : "UPDATE settings SET value = 'false' WHERE key = 'faceAnalysisEnabled';")
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
