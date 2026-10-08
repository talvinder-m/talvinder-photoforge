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
    /// File name, type and camera metadata, read without decoding the image or downloading.
    func metadata(for key: String) async -> PhotoMetadata
    /// What to hand a video player.
    func playback(for key: String) async throws -> PlaybackSource
}

/// Shared EXIF/TIFF reading for both kinds of source.
public enum MetadataReader {
    public static func read(_ src: CGImageSource, filename: String?, uti: String?) -> PhotoMetadata {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return PhotoMetadata(filename: filename, uti: uti)
        }
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let software = tiff[kCGImagePropertyTIFFSoftware] as? String
        let exposure = exif[kCGImagePropertyExifExposureTime] != nil || exif[kCGImagePropertyExifFNumber] != nil
            || exif[kCGImagePropertyExifISOSpeedRatings] != nil
        return PhotoMetadata(filename: filename, uti: uti ?? (CGImageSourceGetType(src) as String?),
                             cameraMake: make?.isEmpty == false ? make : nil, cameraModel: model?.isEmpty == false ? model : nil,
                             software: software, hasCameraData: make != nil || model != nil || exposure,
                             hasAnyExif: !exif.isEmpty || !tiff.isEmpty)
    }
}

extension PhotoLibraryService: MediaSource {
    public var capabilities: MediaSourceCapabilities {
        MediaSourceCapabilities(canDelete: true, canAddToLibrary: true, isReadOnly: false)
    }
}

// MARK: - Libraries on disk

/// A folder, album or directory in the sidebar tree. `assetKeys` holds the photos shown when
/// it's selected (for folders: everything inside, recursively).
public struct AlbumNode: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable { case folder, album, smartAlbum, directory, date }
    public let id: String
    public let title: String
    public let kind: Kind
    public var children: [AlbumNode]
    public var assetKeys: [String]
    public init(id: String, title: String, kind: Kind, children: [AlbumNode] = [], assetKeys: [String] = []) {
        self.id = id; self.title = title; self.kind = kind; self.children = children; self.assetKeys = assetKeys
    }
    public static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.assetKeys.count == b.assetKeys.count && a.children.count == b.children.count }
    public func hash(into h: inout Hasher) { h.combine(id) }

    /// Fills folders' asset lists from their children and drops empty branches.
    public func rolledUp() -> AlbumNode? {
        let kids = children.compactMap { $0.rolledUp() }
        var keys = assetKeys
        if kind == .folder || kind == .directory || kind == .date {
            var seen = Set(keys)
            for k in kids { for a in k.assetKeys where seen.insert(a).inserted { keys.append(a) } }
        }
        if keys.isEmpty && kids.isEmpty && kind != .album { return nil }
        return AlbumNode(id: id, title: title, kind: kind, children: kids, assetKeys: keys)
    }
}

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
    /// Albums/folders (Photos libraries) or the directory tree (iPhoto libraries, folders), after `scan()`.
    public private(set) var albums: [AlbumNode] = []

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
        if inspection.kind != .photosLibrary || albums.isEmpty {
            albums = Self.directoryTree(assets, root: root)
        }
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
        albums = (try? Self.readAlbums(db, assetTable: table)) ?? []
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

    /// Albums and folders from a Photos database (undocumented schema: detected, never assumed).
    static func readAlbums(_ db: OpaquePointer?, assetTable: String) throws -> [AlbumNode] {
        func query(_ sql: String) -> [[String?]] {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(st) }
            var rows: [[String?]] = []
            while sqlite3_step(st) == SQLITE_ROW {
                rows.append((0..<sqlite3_column_count(st)).map { i in sqlite3_column_text(st, i).map { String(cString: $0) } })
            }
            return rows
        }
        let tables = query("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0[0] }
        guard tables.contains("ZGENERICALBUM") else { return [] }
        let albumCols = Set(query("PRAGMA table_info(ZGENERICALBUM)").compactMap { $0[1] })
        guard albumCols.isSuperset(of: ["Z_PK", "ZKIND", "ZTITLE"]) else { return [] }

        // Join table: named Z_<n>ASSETS with one *ALBUMS column and one *ASSETS column.
        var join: (table: String, albumCol: String, assetCol: String)?
        for t in tables where t.range(of: #"^Z_\d+ASSETS$"#, options: .regularExpression) != nil {
            let cols = query("PRAGMA table_info(\(t))").compactMap { $0[1] }
            if let a = cols.first(where: { $0.hasSuffix("ALBUMS") }), let b = cols.first(where: { $0.hasSuffix("ASSETS") && $0 != a }) {
                join = (t, a, b); break
            }
        }
        guard let join else { return [] }

        let trash = albumCols.contains("ZTRASHEDSTATE") ? " AND COALESCE(ZTRASHEDSTATE,0) = 0" : ""
        let parentCol = albumCols.contains("ZPARENTFOLDER") ? "ZPARENTFOLDER" : "NULL"
        // ZKIND: 2 = user album, 4000 = folder, 3999 = top-level folder (Photos 5+).
        let rows = query("SELECT Z_PK, ZKIND, ZTITLE, \(parentCol) FROM ZGENERICALBUM WHERE ZKIND IN (2, 4000, 3999)\(trash)")
        var members: [String: [String]] = [:]
        for r in query("""
            SELECT j.\(join.albumCol), a.ZUUID FROM \(join.table) j JOIN \(assetTable) a ON a.Z_PK = j.\(join.assetCol)
            """ + (tables.contains(assetTable) ? " WHERE COALESCE(a.ZTRASHEDSTATE,0) = 0" : "")) {
            if let al = r[0], let u = r[1] { members[al, default: []].append("pkg:\(u)") }
        }
        struct Item { let pk: String; let kind: Int; let title: String; let parent: String? }
        let items = rows.compactMap { r -> Item? in
            guard let pk = r[0], let k = r[1].flatMap(Int.init) else { return nil }
            return Item(pk: pk, kind: k, title: r[2] ?? "Untitled", parent: r[3])
        }
        let rootPKs = Set(items.filter { $0.kind == 3999 }.map(\.pk))
        let byParent = Dictionary(grouping: items.filter { $0.kind != 3999 }) { $0.parent ?? "" }
        func build(_ parent: String, depth: Int) -> [AlbumNode] {
            guard depth < 12 else { return [] }
            return (byParent[parent] ?? []).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }.map { i in
                i.kind == 4000
                    ? AlbumNode(id: "pkgalbum:\(i.pk)", title: i.title, kind: .folder, children: build(i.pk, depth: depth + 1))
                    : AlbumNode(id: "pkgalbum:\(i.pk)", title: i.title, kind: .album, assetKeys: members[i.pk] ?? [])
            }
        }
        var top: [AlbumNode] = []
        for r in rootPKs { top += build(r, depth: 0) }
        top += build("", depth: 0)
        return top.compactMap { $0.rolledUp() }
    }

    /// Directory hierarchy of the photos' files (below the library's Masters/originals folder).
    static func directoryTree(_ assets: [FileAsset], root: URL) -> [AlbumNode] {
        final class Dir { var children: [String: Dir] = [:]; var keys: [String] = [] }
        let top = Dir()
        for a in assets {
            guard let u = a.url else { continue }
            var rel = "/" + Self.relativePath(u.deletingLastPathComponent(), to: root)
            if rel == "/" { rel = "" }
            for prefix in ["/Masters", "/originals", "/resources/derivatives/masters", "/resources/derivatives"] where rel.hasPrefix(prefix) {
                rel = String(rel.dropFirst(prefix.count)); break
            }
            let parts = rel.split(separator: "/").map(String.init)
            var d = top
            for p in parts {
                if d.children[p] == nil { d.children[p] = Dir() }
                d = d.children[p]!
            }
            d.keys.append(a.key)
        }
        func convert(_ name: String, _ d: Dir, _ path: String) -> AlbumNode {
            let kids = d.children.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { convert($0, d.children[$0]!, path + "/" + $0) }
            return AlbumNode(id: "dir:\(path)", title: name, kind: .directory, children: kids, assetKeys: d.keys)
        }
        let nodes = top.children.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { convert($0, top.children[$0]!, "/" + $0) }
        // A single wrapper directory (e.g. only "2014") is shown expanded one level.
        return nodes.compactMap { $0.rolledUp() }
    }

    /// Path of `url` inside `root`, with symlinks resolved on both sides.
    static func relativePath(_ url: URL, to root: URL) -> String {
        let r = root.resolvingSymlinksInPath().standardizedFileURL.path
        let p = url.resolvingSymlinksInPath().standardizedFileURL.path
        if p == r { return "" }
        return p.hasPrefix(r + "/") ? String(p.dropFirst(r.count + 1)) : p
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
        _ = exif
        for case let f as URL in e where MediaFiles.isMedia(f) {
            // Compare resolved paths: /var → /private/var style symlinks must not change the key.
            let rel = Self.relativePath(f, to: root)
            let values = try? f.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            let p = MediaFiles.probe(f)
            out.append(FileAsset(key: "file:\(rel)", url: f, isOriginalLocal: true, mediaType: p.mediaType,
                                 subtypeMask: p.isScreenshot ? 4 : 0,
                                 creationDate: p.captureDate ?? values?.creationDate, modificationDate: values?.contentModificationDate,
                                 pixelWidth: p.width, pixelHeight: p.height, duration: p.duration, favorite: false, hidden: false,
                                 burstIdentifier: nil))
        }
        return out
    }

    // MARK: Pixels

    public func thumbnail(for key: String, side: CGFloat) async -> NSImage? {
        guard let u = url(for: key) else { return nil }
        return await Self.thumbnail(at: u, side: side)
    }

    static func thumbnail(at u: URL, side: CGFloat) async -> NSImage? {
        let cg: CGImage?
        if MediaFiles.isVideo(u) {
            cg = await MediaFiles.videoThumbnail(u, maxPixel: side)
        } else {
            cg = await Offload.run { Self.downsample(u, maxPixel: side) }
        }
        return cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
    }

    public func playback(for key: String) async throws -> PlaybackSource {
        guard let u = url(for: key) else { throw FileLibraryError.missing(key) }
        return .url(u)
    }

    public static func sha256(of u: URL) throws -> Data {
        let h = try FileHandle(forReadingFrom: u)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return Data(hasher.finalize())
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

    public func metadata(for key: String) async -> PhotoMetadata {
        guard let u = url(for: key), let src = CGImageSourceCreateWithURL(u as CFURL, nil) else { return PhotoMetadata() }
        // For iCloud-only Photos originals we only have a preview, whose metadata isn't the original's.
        if key.hasPrefix("pkg:"), u.path.contains("/resources/derivatives/") {
            return PhotoMetadata(filename: u.lastPathComponent)
        }
        return MetadataReader.read(src, filename: u.lastPathComponent, uti: nil)
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
