import Foundation
import AppKit
import AVFoundation
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers
import PFCore

/// What a player needs to play a video.
public enum PlaybackSource: @unchecked Sendable {
    case asset(AVAsset)       // from Photos (may have been downloaded from iCloud)
    case url(URL)             // a file on disk
}

/// File-type knowledge and lightweight probing shared by every on-disk source.
public enum MediaFiles {
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "gif", "bmp", "webp",
                                                      "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "avif"]
    /// Everything we list as a video. AVFoundation plays the first group; the rest need the VLC engine.
    public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "3gp", "3g2",
                                                      "mkv", "avi", "wmv", "flv", "webm", "mts", "m2ts", "ts", "mpg", "mpeg",
                                                      "vob", "ogv", "divx", "asf", "rm", "rmvb", "f4v"]
    public static let nativeVideoExtensions: Set<String> = ["mov", "mp4", "m4v", "3gp", "3g2"]

    public static func isImage(_ url: URL) -> Bool { imageExtensions.contains(url.pathExtension.lowercased()) }
    public static func isVideo(_ url: URL) -> Bool { videoExtensions.contains(url.pathExtension.lowercased()) }
    public static func isMedia(_ url: URL) -> Bool { isImage(url) || isVideo(url) }

    public struct Probe: Sendable {
        public var mediaType: String          // image | video
        public var width: Int
        public var height: Int
        public var captureDate: Date?
        public var duration: Double
        public var isScreenshot: Bool
    }

    static let exifDate: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy:MM:dd HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    /// Size, capture date and (for videos) duration, without decoding pixels.
    public static func probe(_ url: URL) -> Probe {
        if isVideo(url) {
            var w = 0, h = 0, d = 0.0
            var date: Date? = nil
            if nativeVideoExtensions.contains(url.pathExtension.lowercased()) {
                let a = AVURLAsset(url: url)
                d = CMTimeGetSeconds(a.duration)
                if let t = a.tracks(withMediaType: .video).first {
                    let s = t.naturalSize.applying(t.preferredTransform)
                    w = Int(abs(s.width)); h = Int(abs(s.height))
                }
                date = a.creationDate?.dateValue
            }
            return Probe(mediaType: "video", width: w, height: h, captureDate: date, duration: d.isFinite ? d : 0, isScreenshot: false)
        }
        var w = 0, h = 0
        var taken: Date? = nil
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            if let o = props[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&w, &h) }
            if let ex = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
               let s = ex[kCGImagePropertyExifDateTimeOriginal] as? String { taken = exifDate.date(from: s) }
        }
        let name = url.lastPathComponent.lowercased()
        return Probe(mediaType: "image", width: w, height: h, captureDate: taken, duration: 0,
                     isScreenshot: name.hasPrefix("screenshot") || name.hasPrefix("screen shot"))
    }

    /// Poster frame for a video: AVFoundation first, then Quick Look (covers more formats).
    public static func videoThumbnail(_ url: URL, maxPixel: CGFloat) async -> CGImage? {
        if nativeVideoExtensions.contains(url.pathExtension.lowercased()) {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            let t = CMTime(seconds: 1, preferredTimescale: 600)
            if let img = try? await gen.image(at: t).image { return img }
            if let img = try? await gen.image(at: .zero).image { return img }
        }
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: maxPixel, height: maxPixel),
                                               scale: 1, representationTypes: .thumbnail)
        return await withCheckedContinuation { cont in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
                cont.resume(returning: rep?.cgImage)
            }
        }
    }

    /// Whether Apple's player can play this file (otherwise the VLC engine is used).
    public static func isNativelyPlayable(_ url: URL) async -> Bool {
        guard nativeVideoExtensions.contains(url.pathExtension.lowercased()) else { return false }
        return (try? await AVURLAsset(url: url).load(.isPlayable)) ?? false
    }

    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - PhotoForge Library source (photos stored in a .pflibrary package)

/// Reads and manages the files of a PhotoForge Library. Keys are stable ("pf:<uuid>") and map
/// to a path relative to the package, so renaming a file or moving the library to another
/// drive never breaks the database.
public final class ManagedLibrarySource: MediaSource, @unchecked Sendable {
    public let root: URL
    private var map: [String: String] = [:]
    private let lock = NSLock()

    public var capabilities: MediaSourceCapabilities { .init(canDelete: true, canAddToLibrary: true, isReadOnly: false) }

    public init(root: URL) { self.root = root }

    public func register(_ m: [String: String]) { lock.lock(); map.merge(m) { $1 }; lock.unlock() }
    public func set(_ key: String, relativePath: String) { lock.lock(); map[key] = relativePath; lock.unlock() }
    public func remove(_ key: String) { lock.lock(); map[key] = nil; lock.unlock() }
    public var knownRelativePaths: Set<String> { lock.lock(); defer { lock.unlock() }; return Set(map.values) }

    public func url(for key: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return map[key].map { root.appendingPathComponent($0) }
    }

    public static func newKey() -> String { "pf:\(UUID().uuidString)" }

    // MARK: File operations

    /// Copies a file into Originals/YYYY/MM/, keeping its name (made unique if needed).
    public func importFile(_ src: URL, date: Date?) throws -> String {
        let cal = Calendar.current
        let d = date ?? (try? src.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now
        let folder = String(format: "Originals/%04d/%02d", cal.component(.year, from: d), cal.component(.month, from: d))
        let dir = root.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = Self.unique(dir.appendingPathComponent(src.lastPathComponent))
        try FileManager.default.copyItem(at: src, to: dest)
        return folder + "/" + dest.lastPathComponent
    }

    /// Adds an already-written file (an edit or upscale) to Edits/.
    public func addEdited(_ file: URL, name: String) throws -> String {
        let dir = root.appendingPathComponent("Edits")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = Self.unique(dir.appendingPathComponent(name))
        try FileManager.default.moveItem(at: file, to: dest)
        return "Edits/" + dest.lastPathComponent
    }

    /// Renames the file on disk (keeping its extension and folder). Returns the new relative path.
    public func renameFile(_ key: String, to baseName: String) throws -> String {
        guard let old = url(for: key) else { throw CocoaError(.fileNoSuchFile) }
        let clean = baseName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        let ext = old.pathExtension
        let target = old.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? clean : "\(clean).\(ext)")
        guard target.path != old.path else { return relative(old) }
        let dest = Self.unique(target)
        try FileManager.default.moveItem(at: old, to: dest)
        let rel = relative(dest)
        set(key, relativePath: rel)
        return rel
    }

    /// Moves the file to the library's Trash (recoverable until emptied).
    public func moveToTrash(_ key: String) throws {
        guard let u = url(for: key) else { return }
        let rel = relative(u)
        let dest = Self.unique(root.appendingPathComponent("Trash").appendingPathComponent(rel))
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: u, to: dest)
        remove(key)
    }

    /// Media files in Originals/ and Edits/ that the database doesn't know about yet.
    public func untrackedFiles() -> [URL] {
        let known = knownRelativePaths
        var out: [URL] = []
        for sub in ["Originals", "Edits"] {
            guard let e = FileManager.default.enumerator(at: root.appendingPathComponent(sub), includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let f as URL in e where MediaFiles.isMedia(f) && !known.contains(relative(f)) { out.append(f) }
        }
        return out
    }

    public func relative(_ u: URL) -> String { FileLibrarySource.relativePath(u, to: root) }

    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension, dir = url.deletingLastPathComponent()
        var n = 2
        while true {
            let c = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            if !fm.fileExists(atPath: c.path) { return c }
            n += 1
        }
    }

    // MARK: MediaSource

    public func thumbnail(for key: String, side: CGFloat) async -> NSImage? {
        guard let u = url(for: key) else { return nil }
        return await FileLibrarySource.thumbnail(at: u, side: side)
    }

    public func analysisImage(for key: String, maxDimension: CGFloat, allowNetwork: Bool) async throws -> CGImage {
        guard let u = url(for: key) else { throw PhotoForgeError.assetUnavailable(localIdentifier: key) }
        guard let img = FileLibrarySource.downsample(u, maxPixel: maxDimension) else { throw PhotoForgeError.corruptImage }
        return img
    }

    public func fullImageData(for key: String) async throws -> Data {
        guard let u = url(for: key) else { throw FileLibraryError.missing(key) }
        return try Data(contentsOf: u, options: .mappedIfSafe)
    }

    public func sha256OfOriginal(_ key: String, allowNetwork: Bool) async throws -> Data {
        guard let u = url(for: key) else { throw FileLibraryError.missing(key) }
        return try FileLibrarySource.sha256(of: u)
    }

    public func originalFileSize(_ key: String) -> Int? {
        url(for: key).flatMap { (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize }
    }

    public func metadata(for key: String) async -> PhotoMetadata {
        guard let u = url(for: key), let src = CGImageSourceCreateWithURL(u as CFURL, nil) else { return PhotoMetadata() }
        return MetadataReader.read(src, filename: u.lastPathComponent, uti: nil)
    }

    public func playback(for key: String) async throws -> PlaybackSource {
        guard let u = url(for: key) else { throw FileLibraryError.missing(key) }
        return .url(u)
    }
}
