import Foundation
import ImageIO
import Photos
import AppKit
import CryptoKit
import PFCore

/// Sendable snapshot of a PHAsset. PHAsset itself is not Sendable, so it never
/// crosses an actor boundary; only this value type does.
public struct AssetSnapshot: Sendable, Hashable {
    public let localIdentifier: String
    public let mediaType: MediaKind
    public let subtypeMask: UInt
    public let creationDate: Date?
    public let modificationDate: Date?
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let duration: TimeInterval
    public let isFavorite: Bool
    public let isHidden: Bool
    public let burstIdentifier: String?
    public let latitude: Double?
    public let longitude: Double?
    /// From an iCloud Shared Album rather than the user's own library.
    public let isShared: Bool
    /// Whether the full-size original is stored on this Mac. nil = PhotoKit didn't say.
    public let locallyAvailable: Bool?

    public enum MediaKind: String, Sendable { case image, video, audio, unknown }

    public var isScreenshot: Bool { subtypeMask & PHAssetMediaSubtype.photoScreenshot.rawValue != 0 }
    public var isLivePhoto: Bool  { subtypeMask & PHAssetMediaSubtype.photoLive.rawValue != 0 }
    public var isHDR: Bool        { subtypeMask & PHAssetMediaSubtype.photoHDR.rawValue != 0 }

    init(_ a: PHAsset, includeLocation: Bool) {
        localIdentifier = a.localIdentifier
        mediaType = switch a.mediaType {
            case .image: .image
            case .video: .video
            case .audio: .audio
            default: .unknown
        }
        subtypeMask = a.mediaSubtypes.rawValue
        creationDate = a.creationDate
        modificationDate = a.modificationDate
        pixelWidth = a.pixelWidth
        pixelHeight = a.pixelHeight
        duration = a.duration
        isFavorite = a.isFavorite
        isHidden = a.isHidden
        burstIdentifier = a.burstIdentifier
        // Location is only read when the user has enabled location indexing.
        latitude = includeLocation ? a.location?.coordinate.latitude : nil
        longitude = includeLocation ? a.location?.coordinate.longitude : nil
        isShared = a.sourceType.contains(.typeCloudShared)
        // PHAssetResource exposes this through key-value coding (not a documented property);
        // if it ever disappears we simply report "unknown".
        let resources = PHAssetResource.assetResources(for: a)
        let original = resources.first { $0.type == .photo || $0.type == .video || $0.type == .fullSizePhoto }
        locallyAvailable = original.flatMap { PhotoLibraryService.safeKVC($0, "locallyAvailable")?.boolValue }
    }
}

/// Incremental change set derived from PhotoKit persistent change history.
public struct LibraryDelta: Sendable {
    public var inserted: Set<String> = []
    public var updated: Set<String> = []
    public var deleted: Set<String> = []
    public var newTokenArchive: Data?
    /// True when the stored token expired or was invalid; caller must run a full reconcile.
    public var requiresFullReconcile = false
}

/// Proof object that a destructive confirmation sheet was shown and accepted.
/// Only the confirmation UI constructs one; the exact identifiers and count are
/// bound into it so a stale or widened selection cannot be deleted.
public struct DeletionConfirmation: Sendable {
    public let localIdentifiers: [String]
    public let confirmedCount: Int
    public let confirmedAt: Date
    public init(localIdentifiers: [String], userAcceptedCount: Int) {
        self.localIdentifiers = localIdentifiers
        self.confirmedCount = userAcceptedCount
        self.confirmedAt = .now
    }
    var isConsistent: Bool { confirmedCount == localIdentifiers.count && !localIdentifiers.isEmpty }
}

/// All Apple Photos access goes through here, using PhotoKit only.
/// This type never touches the .photoslibrary package on disk.
public final class PhotoLibraryService: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {

    private let library = PHPhotoLibrary.shared()
    private let imageManager = PHCachingImageManager()
    private let changeContinuation: AsyncStream<Void>.Continuation
    /// Coalesced "something changed" pings. Consumers call `fetchDelta(since:)`
    /// to learn what changed, which also covers changes made while the app was closed.
    public let changes: AsyncStream<Void>

    public override init() {
        (changes, changeContinuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        super.init()
    }

    deinit {
        library.unregisterChangeObserver(self)
        changeContinuation.finish()
    }

    // MARK: Authorization

    public enum AccessState: Sendable, Equatable { case notDetermined, authorized, limited, denied, restricted }

    public var accessState: AccessState {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    /// Call only from a user action ("Connect Apple Photos"). Never at launch.
    public func requestAccess() async -> AccessState {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        let state = Self.map(status)
        if state == .authorized || state == .limited {
            library.register(self)
        }
        return state
    }

    private static func map(_ s: PHAuthorizationStatus) -> AccessState {
        switch s {
        case .authorized: .authorized
        case .limited: .limited
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    // MARK: Fetching

    /// Streams every asset as snapshots in batches, oldest first. The fetch result
    /// is lazy, so memory stays flat even for 100k+ assets.
    public func allAssets(batchSize: Int = 500, includeLocation: Bool) -> AsyncThrowingStream<[AssetSnapshot], Error> {
        AsyncThrowingStream { continuation in
            // A plain background queue, not the shared Swift thread pool: enumerating a big
            // library is long, blocking work.
            let cancelled = CancelFlag()
            DispatchQueue.global(qos: .utility).async {
                guard self.accessState == .authorized || self.accessState == .limited else {
                    continuation.finish(throwing: PhotoForgeError.photosAccessDenied); return
                }
                let opts = PHFetchOptions()
                opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
                opts.includeHiddenAssets = true
                opts.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
                let result = PHAsset.fetchAssets(with: opts)

                var start = 0
                while start < result.count {
                    if cancelled.isSet { continuation.finish(throwing: PhotoForgeError.cancelled); return }
                    let end = min(start + batchSize, result.count)
                    let batch: [AssetSnapshot] = autoreleasepool {
                        result.objects(at: IndexSet(integersIn: start..<end))
                              .map { AssetSnapshot($0, includeLocation: includeLocation) }
                    }
                    continuation.yield(batch)
                    start = end
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in cancelled.set() }
        }
    }

    public func snapshots(for identifiers: [String], includeLocation: Bool) -> [AssetSnapshot] {
        guard !identifiers.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var out: [AssetSnapshot] = []
        out.reserveCapacity(result.count)
        result.enumerateObjects { a, _, _ in out.append(AssetSnapshot(a, includeLocation: includeLocation)) }
        return out
    }

    public func originalFilename(for localIdentifier: String) -> String? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        return (resources.first { $0.type == .photo || $0.type == .video } ?? resources.first)?.originalFilename
    }

    // MARK: Incremental change tracking

    /// Uses PhotoKit's persistent change history (macOS 13+) so changes made while
    /// the app was not running are picked up without a full rescan.
    public func fetchDelta(sinceArchivedToken archived: Data?) -> LibraryDelta {
        var delta = LibraryDelta()
        delta.newTokenArchive = try? NSKeyedArchiver.archivedData(
            withRootObject: library.currentChangeToken, requiringSecureCoding: true)

        guard let archived,
              let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: archived)
        else { delta.requiresFullReconcile = true; return delta }

        do {
            let changes = try library.fetchPersistentChanges(since: token)
            for change in changes {
                let details = try change.changeDetails(for: .asset)
                delta.inserted.formUnion(details.insertedLocalIdentifiers)
                delta.updated.formUnion(details.updatedLocalIdentifiers)
                delta.deleted.formUnion(details.deletedLocalIdentifiers)
            }
            // An insert followed by a delete in the same window nets to nothing.
            let transient = delta.inserted.intersection(delta.deleted)
            delta.inserted.subtract(transient)
            delta.updated.subtract(delta.deleted)
            delta.deleted.subtract(transient)
        } catch {
            // PHPhotosError.persistentChangeTokenExpired, persistentChangeDetailsUnavailable, …
            delta = LibraryDelta(newTokenArchive: delta.newTokenArchive, requiresFullReconcile: true)
        }
        return delta
    }

    /// Reads an undocumented property only if the object actually has it, so a future
    /// macOS that removes it degrades to "unknown" instead of raising NSUnknownKeyException.
    static func safeKVC(_ obj: NSObject, _ key: String) -> NSNumber? {
        guard obj.responds(to: NSSelectorFromString(key)) else { return nil }
        return obj.value(forKey: key) as? NSNumber
    }

    public func photoLibraryDidChange(_ changeInstance: PHChange) {
        changeContinuation.yield(())
    }

    // MARK: Pixels

    /// Small image for hashing, quality metrics and Vision passes. Never triggers an
    /// iCloud download unless `allowNetwork` is true (set only for user-initiated work).
    /// Background queues for PhotoKit image requests. Requests are made synchronously *on these
    /// queues*, so decoding happens there and never on the main thread (PhotoKit delivers
    /// asynchronous results on the main thread, which made the window stutter during analysis).
    private static let analysisQueue = DispatchQueue(label: "photoforge.photokit.analysis", qos: .utility, attributes: .concurrent)
    private static let thumbnailQueue = DispatchQueue(label: "photoforge.photokit.thumbnails", qos: .userInitiated, attributes: .concurrent)

    public func analysisImage(for localIdentifier: String, maxDimension: CGFloat = 512,
                              allowNetwork: Bool = false) async throws -> CGImage {
        let manager = imageManager
        return try await withCheckedThrowingContinuation { cont in
            Self.analysisQueue.async {
                guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
                    cont.resume(throwing: PhotoForgeError.assetUnavailable(localIdentifier: localIdentifier)); return
                }
                let opts = PHImageRequestOptions()
                opts.deliveryMode = .highQualityFormat     // exactly one callback
                opts.resizeMode = .fast
                opts.version = .current                    // what the user sees, incl. Photos edits
                opts.isNetworkAccessAllowed = allowNetwork
                opts.isSynchronous = true                  // on this background queue
                var result: Result<CGImage, Error> = .failure(PhotoForgeError.corruptImage)
                manager.requestImage(for: asset, targetSize: CGSize(width: maxDimension, height: maxDimension),
                                     contentMode: .aspectFit, options: opts) { image, info in
                    if let err = info?[PHImageErrorKey] as? Error { result = .failure(err); return }
                    if (info?[PHImageCancelledKey] as? Bool) == true { result = .failure(PhotoForgeError.cancelled); return }
                    if image == nil, (info?[PHImageResultIsInCloudKey] as? Bool) == true {
                        result = .failure(PhotoForgeError.iCloudDownloadRequired(localIdentifier: localIdentifier)); return
                    }
                    if let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) { result = .success(cg) }
                }
                cont.resume(with: result)
            }
        }
    }

    /// Grid thumbnail. Uses PhotoKit's local derivatives; never downloads. Decoded off the main thread.
    public func thumbnail(for localIdentifier: String, side: CGFloat) async -> NSImage? {
        let manager = imageManager
        return await withCheckedContinuation { cont in
            Self.thumbnailQueue.async {
                guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
                    cont.resume(returning: nil); return
                }
                let opts = PHImageRequestOptions()
                opts.deliveryMode = .highQualityFormat
                opts.resizeMode = .fast
                opts.isNetworkAccessAllowed = false
                opts.isSynchronous = true
                var out: NSImage?
                manager.requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                     contentMode: .aspectFill, options: opts) { image, _ in
                    // Render to a bitmap here so drawing it later costs nothing.
                    if let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        out = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    }
                }
                cont.resume(returning: out)
            }
        }
    }

    /// Full-resolution image data (current version, incl. Photos edits) for the editor.
    /// Downloads from iCloud if needed because the user explicitly opened the photo.
    public func fullImageData(for localIdentifier: String) async throws -> Data {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            throw PhotoForgeError.assetUnavailable(localIdentifier: localIdentifier)
        }
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.version = .current
        opts.isNetworkAccessAllowed = true
        return try await withCheckedThrowingContinuation { cont in
            imageManager.requestImageDataAndOrientation(for: asset, options: opts) { data, _, _, info in
                if let data { cont.resume(returning: data) }
                else if let err = info?[PHImageErrorKey] as? Error { cont.resume(throwing: err) }
                else { cont.resume(throwing: PhotoForgeError.assetUnavailable(localIdentifier: localIdentifier)) }
            }
        }
    }

    // MARK: Video

    /// The video for playback (downloads from iCloud if needed — the user asked to play it).
    public func playback(for localIdentifier: String) async throws -> PlaybackSource {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            throw PhotoForgeError.assetUnavailable(localIdentifier: localIdentifier)
        }
        let opts = PHVideoRequestOptions()
        opts.isNetworkAccessAllowed = true
        opts.deliveryMode = .highQualityFormat
        opts.version = .current
        final class Box: @unchecked Sendable { var done = false }
        let box = Box()
        return try await withCheckedThrowingContinuation { cont in
            imageManager.requestAVAsset(forVideo: asset, options: opts) { av, _, info in
                guard !box.done else { return }
                box.done = true
                if let av { cont.resume(returning: .asset(av)) }
                else if let e = info?[PHImageErrorKey] as? Error { cont.resume(throwing: e) }
                else { cont.resume(throwing: PhotoForgeError.assetUnavailable(localIdentifier: localIdentifier)) }
            }
        }
    }

    // MARK: Copying out (used when building a PhotoForge Library from Apple Photos)

    public struct ExportedOriginal: Sendable {
        public let url: URL
        public let originalFilename: String
    }

    /// Writes the photo or video as currently shown in Photos (with edits) to `directory`.
    public func exportOriginal(_ localIdentifier: String, to directory: URL, allowNetwork: Bool) async throws -> ExportedOriginal {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            throw PhotoForgeError.assetUnavailable(localIdentifier: localIdentifier)
        }
        let resources = PHAssetResource.assetResources(for: asset)
        let preferred: [PHAssetResourceType] = asset.mediaType == .video ? [.fullSizeVideo, .video] : [.fullSizePhoto, .photo]
        guard let res = preferred.lazy.compactMap({ t in resources.first { $0.type == t } }).first ?? resources.first else {
            throw PhotoForgeError.assetUnavailable(localIdentifier: localIdentifier)
        }
        let original = resources.first { $0.type == .photo || $0.type == .video }?.originalFilename ?? res.originalFilename
        var name = res.originalFilename
        // Edited renditions are called FullSizeRender.*; keep the original's name with the rendition's extension.
        if name.lowercased().hasPrefix("fullsizerender") {
            name = (original as NSString).deletingPathExtension + "." + (name as NSString).pathExtension
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var dest = directory.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = directory.appendingPathComponent("\((name as NSString).deletingPathExtension) \(n).\((name as NSString).pathExtension)"); n += 1
        }
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = allowNetwork
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: res, toFile: dest, options: opts) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
        return ExportedOriginal(url: dest, originalFilename: original)
    }

    /// Album membership as (album path, asset ids), for recreating albums in a copy.
    public func albumMemberships() -> [(path: [String], localIdentifiers: [String])] {
        var out: [(path: [String], localIdentifiers: [String])] = []
        func walk(_ nodes: [AlbumNode], _ path: [String]) {
            for n in nodes {
                if n.kind == .album { out.append((path + [n.title], n.assetKeys)) }
                walk(n.children, path + [n.title])
            }
        }
        walk(albumTree().filter { $0.id != "pk:smart" }, [])
        return out
    }

    // MARK: Names in Apple Photos (via Photos' own scripting, since PhotoKit can't set titles)

    public struct TitleWriteResult: Sendable { public let written: Int; public let failed: Int; public let error: String? }

    /// Sets the Title field in Apple Photos. macOS asks the user once to allow PhotoForge to control Photos.
    public static func writeTitlesToPhotos(_ items: [(localIdentifier: String, title: String)]) async -> TitleWriteResult {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        var written = 0, failed = 0
        var lastError: String?
        // Pre-flight: triggers the one-time "allow PhotoForge to control Photos" prompt and
        // surfaces a refusal clearly (inside the per-item try blocks it would be swallowed).
        let (_, preErr, preStatus) = await runOsascript("tell application \"Photos\" to return (count of albums)")
        if preStatus != 0 {
            let denied = preErr.contains("-1743") || preErr.lowercased().contains("not allowed")
            return TitleWriteResult(written: 0, failed: items.count,
                                    error: denied ? "PhotoForge isn't allowed to control Photos. Allow it in System Settings › Privacy & Security › Automation."
                                                  : preErr)
        }
        for chunk in stride(from: 0, to: items.count, by: 150) {
            let part = items[chunk..<min(chunk + 150, items.count)]
            var script = "tell application \"Photos\"\nset ok to 0\n"
            for (id, t) in part {
                script += "try\nset name of media item id \"\(esc(id))\" to \"\(esc(t))\"\nset ok to ok + 1\nend try\n"
            }
            script += "return ok\nend tell\n"
            let (out, err, status) = await runOsascript(script)
            if status == 0, let n = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) {
                written += n; failed += part.count - n
            } else {
                failed += part.count
                lastError = err.isEmpty ? "osascript exited with \(status)" : err
                if err.contains("-1743") || err.lowercased().contains("not allowed") { break }   // permission denied: stop
            }
        }
        return TitleWriteResult(written: written, failed: failed, error: lastError)
    }

    static func runOsascript(_ script: String) async -> (String, String, Int32) {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-"]
            let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
            p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe
            p.terminationHandler = { proc in
                let o = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let e = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                cont.resume(returning: (o, e, proc.terminationStatus))
            }
            do {
                try p.run()
                inPipe.fileHandleForWriting.write(Data(script.utf8))
                try? inPipe.fileHandleForWriting.close()
            } catch {
                cont.resume(returning: ("", error.localizedDescription, -1))
            }
        }
    }

    /// Albums, folders and non-empty smart albums from the System Photo Library.
    public func albumTree() -> [AlbumNode] {
        func keys(_ c: PHAssetCollection) -> [String] {
            let opts = PHFetchOptions()
            opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            let r = PHAsset.fetchAssets(in: c, options: opts)
            var out: [String] = []
            out.reserveCapacity(r.count)
            r.enumerateObjects { a, _, _ in out.append(a.localIdentifier) }
            return out
        }
        func node(_ c: PHCollection, depth: Int) -> AlbumNode? {
            if let list = c as? PHCollectionList {
                guard depth < 12 else { return nil }
                var kids: [AlbumNode] = []
                PHCollection.fetchCollections(in: list, options: nil).enumerateObjects { k, _, _ in
                    if let n = node(k, depth: depth + 1) { kids.append(n) }
                }
                return AlbumNode(id: "pk:\(list.localIdentifier)", title: list.localizedTitle ?? "Folder", kind: .folder, children: kids)
            }
            if let a = c as? PHAssetCollection {
                return AlbumNode(id: "pk:\(a.localIdentifier)", title: a.localizedTitle ?? "Album", kind: .album, assetKeys: keys(a))
            }
            return nil
        }
        var top: [AlbumNode] = []
        PHCollectionList.fetchTopLevelUserCollections(with: nil).enumerateObjects { c, _, _ in
            if let n = node(c, depth: 0) { top.append(n) }
        }
        var smart: [AlbumNode] = []
        PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: nil).enumerateObjects { c, _, _ in
            guard c.assetCollectionSubtype != .smartAlbumAllHidden, c.assetCollectionSubtype != .smartAlbumUserLibrary else { return }
            let k = keys(c)
            if !k.isEmpty {
                smart.append(AlbumNode(id: "pk:\(c.localIdentifier)", title: c.localizedTitle ?? "Smart Album", kind: .smartAlbum, assetKeys: k))
            }
        }
        var out = top.compactMap { $0.rolledUp() }
        if !smart.isEmpty {
            out.append(AlbumNode(id: "pk:smart", title: "Smart Albums", kind: .folder,
                                 children: smart.sorted { $0.title < $1.title }).rolledUp()!)
        }
        return out
    }

    /// File name and camera metadata from the start of the original file. Local originals only:
    /// never downloads from iCloud (camera data is then reported as unknown, not absent).
    public func metadata(for localIdentifier: String) async -> PhotoMetadata {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            return PhotoMetadata()
        }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let res = resources.first(where: { $0.type == .photo }) ?? resources.first else { return PhotoMetadata() }
        let name = res.originalFilename, uti = res.uniformTypeIdentifier
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = false
        final class Box: @unchecked Sendable { var data = Data(); var id: PHAssetResourceDataRequestID = 0; var done = false }
        let box = Box()
        let limit = 1 << 20      // EXIF lives in the first bytes of JPEG/HEIC files
        let data: Data? = await withCheckedContinuation { cont in
            box.id = PHAssetResourceManager.default().requestData(for: res, options: opts, dataReceivedHandler: { chunk in
                box.data.append(chunk)
                if box.data.count >= limit { PHAssetResourceManager.default().cancelDataRequest(box.id) }
            }, completionHandler: { error in
                guard !box.done else { return }
                box.done = true
                // A cancel after enough bytes is success; any other error means "not available locally".
                cont.resume(returning: (error == nil || box.data.count >= limit) ? box.data : (box.data.isEmpty ? nil : box.data))
            })
        }
        guard let data, !data.isEmpty, let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            return PhotoMetadata(filename: name, uti: uti)
        }
        let md = MetadataReader.read(src, filename: name, uti: uti)
        // A truncated read that found nothing is "unknown", not "no camera data".
        if data.count >= limit && md.hasAnyExif == false {
            return PhotoMetadata(filename: name, uti: uti)
        }
        return md
    }

    /// Size in bytes of the original resource, when PhotoKit reports it.
    public func originalFileSize(_ localIdentifier: String) -> Int? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject,
              let res = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .photo }) else { return nil }
        return Self.safeKVC(res, "fileSize")?.intValue   // not formally documented
    }

    /// Thumbnail warm-up for the visible grid window.
    public func startCaching(_ ids: [String], size: CGSize) {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        guard result.count > 0 else { return }
        imageManager.startCachingImages(for: result.objects(at: IndexSet(integersIn: 0..<result.count)),
                                        targetSize: size, contentMode: .aspectFill, options: nil)
    }

    /// Streams the original resource through SHA-256 without holding the file in memory.
    public func sha256OfOriginal(_ localIdentifier: String, allowNetwork: Bool) async throws -> Data {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            throw PhotoForgeError.assetUnavailable(localIdentifier: localIdentifier)
        }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let original = resources.first(where: { $0.type == .photo || $0.type == .video }) ?? resources.first else {
            throw PhotoForgeError.assetUnavailable(localIdentifier: localIdentifier)
        }
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = allowNetwork

        final class HashBox: @unchecked Sendable { var hasher = SHA256() }
        let box = HashBox()
        return try await withCheckedThrowingContinuation { cont in
            PHAssetResourceManager.default().requestData(for: original, options: opts,
                dataReceivedHandler: { chunk in box.hasher.update(data: chunk) },
                completionHandler: { error in
                    if let error { cont.resume(throwing: error) }
                    else { cont.resume(returning: Data(box.hasher.finalize())) }
                })
        }
    }

    // MARK: Writing back (supported APIs only)

    /// Exports an edit as a NEW asset (default policy). Never replaces the original.
    public func addDerivative(fileURL: URL, toAlbumNamed album: String?) async throws -> String {
        final class IDBox: @unchecked Sendable { var id: String? }
        let box = IDBox()
        try await library.performChanges {
            let req = PHAssetCreationRequest.forAsset()
            let o = PHAssetResourceCreationOptions()
            o.shouldMoveFile = false
            req.addResource(with: .photo, fileURL: fileURL, options: o)
            box.id = req.placeholderForCreatedAsset?.localIdentifier
            if let album, let placeholder = req.placeholderForCreatedAsset {
                let albumReq = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: album)
                albumReq.addAssets([placeholder] as NSArray)
            }
        }
        guard let newID = box.id else { throw PhotoForgeError.assetUnavailable(localIdentifier: "<new>") }
        return newID
    }

    /// Deletes through PhotoKit, which also shows the system's own confirmation and
    /// moves items to Recently Deleted. Requires our in-app confirmation proof first.
    public func delete(_ confirmation: DeletionConfirmation) async throws {
        guard confirmation.isConsistent else { throw PhotoForgeError.policyBlocked(reason: "Confirmation does not match selection") }
        let ids = confirmation.localIdentifiers
        let expected = confirmation.confirmedCount
        guard PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).count == expected else {
            throw PhotoForgeError.policyBlocked(reason: "Library changed since confirmation; please review again")
        }
        try await library.performChanges {
            // Re-fetch inside the change block (PHFetchResult is not Sendable).
            PHAssetChangeRequest.deleteAssets(PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil))
        }
    }
}

/// Thread-safe one-way flag.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
