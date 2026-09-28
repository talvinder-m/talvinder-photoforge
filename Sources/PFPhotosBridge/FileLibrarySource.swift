import Foundation
import AppKit
import ImageIO
import CryptoKit
import SQLite3
import UniformTypeIdentifiers
import PFCore

// MARK: - Common interface for where photos come from

public struct MediaSourceCapabilities: Sendable {
    public var canDelete: Bool          // delete through the owning app (PhotoKit)
    public var canAddToLibrary: Bool    // save edits back as new photos
    public var isReadOnly: Bool
}

/// Anything PhotoForge can read photos from: the System Photo Library (via PhotoKit)
/// or another library/folder on disk (read directly, read-only).
public protocol MediaSource: AnyObject, Sendable {
    var capabilities: MediaSourceCapabilities { get }
    func thumbnail(for key: String, side: CGFloat) async -> NSImage?
    func analysisImage(for key: String, maxDimension: CGFloat, allowNetwork: Bool) async throws -> CGImage
    func fullImageData(for key: String) async throws -> Data
    func sha256OfOriginal(_ key: String, allowNetwork: Bool) async throws -> Data
    func originalFileSize(_ key: String) -> Int?
}

extension PhotoLibraryService: MediaSource {
    public var capabilities: MediaSourceCapabilities {
        MediaSourceCapabilities(canDelete: true, canAddToLibrary: true, isReadOnly: false)
    }
}

// MARK: - Libraries on disk

/// One photo found in an on-disk library.
public struct FileAsset: Sendable {
    public let key: String              // stable id: "pkg:<UUID>" or "file:<relative path>"
    public let url: URL?                // best readable file (original, else largest derivative)
    public let isOriginalLocal: Bool    // false → original is only in iCloud (a preview may still exist)
    public let mediaType: String
    public let subtypeMask: Int
    public let creationDate: Date?
    public let modificationDate: Date?
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let duration: Double
    public let favorite: Bool
    public let hidden: Bool
    public let burstIdentifier: String?
}

public struct LibraryInspection: Sendable {
    public enum Kind: String, Sendable {
        case photosLibrary      // Photos 5+ (macOS 10.15 and later): database/Photos.sqlite
        case legacyLibrary      // older Photos or iPhoto: read as a folder of image files
        case folder             // any other folder
    }
    public let kind: Kind
    public let name: String
    public let url: URL
    public let detail: String
}

public enum FileLibraryError: LocalizedError {
    case permissionDenied(URL)
    case notALibrary(URL)
    case unsupportedSchema(String)
    case missing(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let u):
            return "macOS blocked PhotoForge from reading “\(u.lastPathComponent)”. Give PhotoForge Full Disk Access in System Settings › Privacy & Security, then try again."
        case .notALibrary(let u): return "“\(u.lastPathComponent)” isn't a photo library or folder PhotoForge can read."
        case .unsupportedSchema(let s): return "This library's database format isn't recognised (\(s)). It will be read as a folder of photos instead."
        case .missing(let k): return "The photo file for \(k) couldn't be found."
        }
    }
}

/// Reads a Photos/iPhoto library or plain folder directly from disk, strictly read-only.
///
/// For Photos 5+ libraries it reads a *copy* of `database/Photos.sqlite` (plus its WAL),
/// never the live file, and maps assets to `originals/…`. Apple's schema is undocumented;
/// only columns that exist are queried, and any failure falls back to scanning image files.
/// Nothing inside the library is ever written.
public final class FileLibrarySource: MediaSource, @unchecked Sendable {
    public let root: URL
    public let inspection: LibraryInspection
    private var paths: [String: URL] = [:]
    private let lock = NSLock()

    public var capabilities: MediaSourceCapabilities {
        MediaSourceCapabilities(canDelete: false, canAddToLibrary: false, isReadOnly: true)
    }

    public init(url: URL) throws {
        root = url
        inspection = try Self.inspect(url)
    }

    /// Lets the app restore key → file mappings saved in its database before a rescan.
    public func register(_ map: [String: URL]) {
        lock.lock(); defer { lock.unlock() }
        for (k, v) in map where paths[k] == nil { paths[k] = v }
    }

    private func url(for key: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return paths[key]
    }

    // MARK: Discovery

    public static func inspect(_ url: URL) throws -> LibraryInspection {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { throw FileLibraryError.notALibrary(url) }
        let name = url.deletingPathExtension().lastPathComponent
        let db = url.appendingPathComponent("database/Photos.sqlite")
        if fm.fileExists(atPath: db.path) {
            guard fm.isReadableFile(atPath: db.path) else { throw FileLibraryError.permissionDenied(url) }
            return LibraryInspection(kind: .photosLibrary, name: name, url: url, detail: "Photos library")
        }
        for sub in ["Masters", "originals"] where fm.fileExists(atPath: url.appendingPathComponent(sub).path) {
            let what = url.pathExtension == "photolibrary" ? "iPhoto library" : "Older Photos library"
            return LibraryInspection(kind: .legacyLibrary, name: name, url: url, detail: "\(what) (read as files)")
        }
        guard fm.isReadableFile(atPath: url.path) else { throw FileLibraryError.permissionDenied(url) }
        return LibraryInspection(kind: .folder, name: url.lastPathComponent, url: url, detail: "Folder")
    }

    /// Finds photo libraries in the usual places: ~/Pictures, home, Desktop, Documents, and external drives.
    public static func discoverLibraries() -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var dirs = ["Pictures", "", "Desktop", "Documents", "Movies"].map { home.appendingPathComponent($0) }
        if let vols = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: nil) {
            for v in vols { dirs.append(v); dirs.append(v.appendingPathComponent("Pictures")) }
        }
        var found = Set<URL>()
        for d in dirs {
            guard let items = try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for i in items where ["photoslibrary", "photolibrary"].contains(i.pathExtension.lowercased()) {
                found.insert(i.standardizedFileURL)
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    // MARK: Scanning

    public func scan() throws -> [FileAsset] {
        let assets: [FileAsset]
        switch inspection.kind {
        case .photosLibrary:
            do { assets = try scanPhotosDatabase() }
            catch { assets = try scanFolder(preferring: ["originals"]) }
        case .legacyLibrary:
            assets = try scanFolder(preferring: ["Masters", "originals"])
        case .folder:
            assets = try scanFolder(preferring: [])
        }
        lock.lock()
        for a in assets { if let u = a.url { paths[a.key] = u } }
        lock.unlock()
        return assets
    }

    private func scanPhotosDatabase() throws -> [FileAsset] {
        let fm = FileManager.default
        let dbDir = root.appendingPathComponent("database")
        let tmp = fm.temporaryDirectory.appendingPathComponent("pf-lib-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        // Work on a copy (with its WAL) so the live database is never opened.
        for f in ["Photos.sqlite", "Photos.sqlite-wal", "Photos.sqlite-shm"] {
            let src = dbDir.appendingPathComponent(f)
            guard fm.fileExists(atPath: src.path) else { continue }
            do { try fm.copyItem(at: src, to: tmp.appendingPathComponent(f)) }
            catch let e as NSError where e.code == NSFileReadNoPermissionError || e.code == 257 {
                throw FileLibraryError.permissionDenied(root)
            }
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(tmp.appendingPathComponent("Photos.sqlite").path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw FileLibraryError.unsupportedSchema("cannot open database")
        }
        defer { sqlite3_close(db) }

        func tableExists(_ t: String) -> Bool {
            var st: OpaquePointer?
            defer { sqlite3_finalize(st) }
            guard sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", -1, &st, nil) == SQLITE_OK else { return false }
            sqlite3_bind_text(st, 1, t, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            return sqlite3_step(st) == SQLITE_ROW
        }
        let table = tableExists("ZASSET") ? "ZASSET" : tableExists("ZGENERICASSET") ? "ZGENERICASSET" : nil
        guard let table else { throw FileLibraryError.unsupportedSchema("no asset table") }

        var cols = Set<String>()
        var st: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &st, nil) == SQLITE_OK {
            while sqlite3_step(st) == SQLITE_ROW { if let c = sqlite3_column_text(st, 1) { cols.insert(String(cString: c)) } }
        }
        sqlite3_finalize(st)
        for required in ["ZUUID", "ZDIRECTORY", "ZFILENAME"] where !cols.contains(required) {
            throw FileLibraryError.unsupportedSchema("missing \(required)")
        }
        let wanted = ["ZUUID", "ZDIRECTORY", "ZFILENAME", "ZDATECREATED", "ZMODIFICATIONDATE", "ZWIDTH", "ZHEIGHT",
                      "ZKIND", "ZKINDSUBTYPE", "ZFAVORITE", "ZHIDDEN", "ZDURATION", "ZAVALANCHEUUID"]
        let select = wanted.map { cols.contains($0) ? $0 : "NULL AS \($0)" }.joined(separator: ", ")
        var sql = "SELECT \(select) FROM \(table)"
        if cols.contains("ZTRASHEDSTATE") { sql += " WHERE ZTRASHEDSTATE = 0" }

        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            throw FileLibraryError.unsupportedSchema(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(st) }

        func text(_ i: Int32) -> String? { sqlite3_column_text(st, i).map { String(cString: $0) } }
        func dbl(_ i: Int32) -> Double? { sqlite3_column_type(st, i) == SQLITE_NULL ? nil : sqlite3_column_double(st, i) }
        func int(_ i: Int32) -> Int? { sqlite3_column_type(st, i) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(st, i)) }

        let originals = root.appendingPathComponent("originals")
        var derivativeIndex: [String: [URL]] = [:]   // directory → files, filled lazily
        func derivative(uuid: String, dir: String) -> URL? {
            var best: (URL, Int)?
            for base in ["resources/derivatives/masters", "resources/derivatives"] {
                let d = root.appendingPathComponent(base).appendingPathComponent(dir)
                let files: [URL]
                if let cached = derivativeIndex[d.path] { files = cached }
                else {
                    files = (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.fileSizeKey])) ?? []
                    derivativeIndex[d.path] = files
                }
                for f in files where f.lastPathComponent.hasPrefix(uuid) {
                    let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    if best == nil || size > best!.1 { best = (f, size) }
                }
            }
            return best?.0
        }

        var out: [FileAsset] = []
        while sqlite3_step(st) == SQLITE_ROW {
            guard let uuid = text(0), let dir = text(1), let file = text(2) else { continue }
            let kind = int(7) ?? 0
            guard kind == 0 || kind == 1 else { continue }
            let original = originals.appendingPathComponent(dir).appendingPathComponent(file)
            let local = fm.fileExists(atPath: original.path)
            let readable = local ? original : derivative(uuid: uuid, dir: dir)
            var subtype = 0
            switch int(8) ?? 0 {
            case 10: subtype |= 4      // screenshot (PHAssetMediaSubtype.photoScreenshot)
            case 2: subtype |= 8       // Live Photo (PHAssetMediaSubtype.photoLive)
            default: break
            }
            out.append(FileAsset(
                key: "pkg:\(uuid)", url: readable, isOriginalLocal: local,
                mediaType: kind == 1 ? "video" : "image", subtypeMask: subtype,
                creationDate: dbl(3).map(Date.init(timeIntervalSinceReferenceDate:)),
                modificationDate: dbl(4).map(Date.init(timeIntervalSinceReferenceDate:)),
                pixelWidth: int(5) ?? 0, pixelHeight: int(6) ?? 0, duration: dbl(11) ?? 0,
                favorite: (int(9) ?? 0) != 0, hidden: (int(10) ?? 0) != 0, burstIdentifier: text(12)))
        }
        return out
    }

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "gif", "bmp", "webp",
                                               "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2"]

    private func scanFolder(preferring subfolders: [String]) throws -> [FileAsset] {
        let fm = FileManager.default
        let base = subfolders.map { root.appendingPathComponent($0) }.first { fm.fileExists(atPath: $0.path) } ?? root
        guard let e = fm.enumerator(at: base, includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
                                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw FileLibraryError.permissionDenied(root)
        }
        var out: [FileAsset] = []
        let exif = DateFormatter()
        exif.dateFormat = "yyyy:MM:dd HH:mm:ss"
        exif.locale = Locale(identifier: "en_US_POSIX")
        for case let f as URL in e where Self.imageExtensions.contains(f.pathExtension.lowercased()) {
            let rel = f.path.replacingOccurrences(of: root.path + "/", with: "")
            let values = try? f.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            var w = 0, h = 0
            var taken: Date? = nil
            if let src = CGImageSourceCreateWithURL(f as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
                h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
                if let o = props[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&w, &h) }
                if let ex = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
                   let s = ex[kCGImagePropertyExifDateTimeOriginal] as? String { taken = exif.date(from: s) }
            }
            out.append(FileAsset(key: "file:\(rel)", url: f, isOriginalLocal: true, mediaType: "image",
                                 subtypeMask: f.lastPathComponent.lowercased().hasPrefix("screenshot") ? 4 : 0,
                                 creationDate: taken ?? values?.creationDate, modificationDate: values?.contentModificationDate,
                                 pixelWidth: w, pixelHeight: h, duration: 0, favorite: false, hidden: false, burstIdentifier: nil))
        }
        return out
    }

    // MARK: Pixels

    public func thumbnail(for key: String, side: CGFloat) async -> NSImage? {
        guard let u = url(for: key) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            Self.downsample(u, maxPixel: side).map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        }.value
    }

    public func analysisImage(for key: String, maxDimension: CGFloat, allowNetwork: Bool) async throws -> CGImage {
        guard let u = url(for: key) else { throw PhotoForgeError.assetUnavailable(localIdentifier: key) }
        guard let img = Self.downsample(u, maxPixel: maxDimension) else { throw PhotoForgeError.corruptImage }
        return img
    }

    public func fullImageData(for key: String) async throws -> Data {
        guard let u = url(for: key) else { throw FileLibraryError.missing(key) }
        return try Data(contentsOf: u, options: .mappedIfSafe)
    }

    public func sha256OfOriginal(_ key: String, allowNetwork: Bool) async throws -> Data {
        guard let u = url(for: key) else { throw FileLibraryError.missing(key) }
        let h = try FileHandle(forReadingFrom: u)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return Data(hasher.finalize())
    }

    public func originalFileSize(_ key: String) -> Int? {
        guard let u = url(for: key) else { return nil }
        return (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    /// ImageIO thumbnail: decodes only what's needed and applies EXIF orientation.
    static func downsample(_ url: URL, maxPixel: CGFloat) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(16, Int(maxPixel)),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
