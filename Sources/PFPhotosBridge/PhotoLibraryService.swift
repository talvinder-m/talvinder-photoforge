import Foundation
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
            let task = Task.detached(priority: .utility) {
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
                    if Task.isCancelled { continuation.finish(throwing: PhotoForgeError.cancelled); return }
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
            continuation.onTermination = { _ in task.cancel() }
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

    public func photoLibraryDidChange(_ changeInstance: PHChange) {
        changeContinuation.yield(())
    }

    // MARK: Pixels

    /// Small image for hashing, quality metrics and Vision passes. Never triggers an
    /// iCloud download unless `allowNetwork` is true (set only for user-initiated work).
    public func analysisImage(for localIdentifier: String, maxDimension: CGFloat = 512,
                              allowNetwork: Bool = false) async throws -> CGImage {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            throw PhotoForgeError.assetUnavailable(localIdentifier: localIdentifier)
        }
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat     // exactly one callback
        opts.resizeMode = .fast
        opts.version = .current                    // what the user sees, incl. Photos edits
        opts.isNetworkAccessAllowed = allowNetwork
        opts.isSynchronous = false

        return try await withCheckedThrowingContinuation { cont in
            imageManager.requestImage(for: asset,
                                      targetSize: CGSize(width: maxDimension, height: maxDimension),
                                      contentMode: .aspectFit, options: opts) { image, info in
                if let err = info?[PHImageErrorKey] as? Error { cont.resume(throwing: err); return }
                if (info?[PHImageCancelledKey] as? Bool) == true { cont.resume(throwing: PhotoForgeError.cancelled); return }
                if image == nil, (info?[PHImageResultIsInCloudKey] as? Bool) == true {
                    cont.resume(throwing: PhotoForgeError.iCloudDownloadRequired(localIdentifier: localIdentifier)); return
                }
                guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    cont.resume(throwing: PhotoForgeError.corruptImage); return
                }
                cont.resume(returning: cg)
            }
        }
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
