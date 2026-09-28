import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PFCore
import PFDatabase
import PFPhotosBridge
import PFVision
import PFSimilarity
import PFJobs

/// Options captured when the scan starts (from Settings).
struct AnalysisOptions: Sendable {
    var faceAnalysis: Bool
    var storeFaceCrops: Bool
    var sceneSimilarity: Bool
    var allowICloudDownloads: Bool
    var faceCropDirectory: URL
}

/// The whole local analysis pipeline as one resumable background job.
/// Each stage only processes assets whose stage bit is still clear, so a quit,
/// crash, pause or cancel resumes exactly where it stopped.
struct AnalysisJob: BackgroundJob {
    let kind = "analysis"
    let priority: JobPriority = .utility
    var maxRetries: Int { 0 }

    let db: AppDatabase
    let photos: PhotoLibraryService
    let cipher: VectorCipher
    let options: AnalysisOptions

    func run(_ ctx: JobContext) async throws {
        try await hashStage(ctx)
        try await exactDuplicateStage(ctx)
        if options.faceAnalysis { try await faceStage(ctx) }
        await ctx.report(message: "Finishing up")
    }

    // MARK: Stage 2 — thumbnails, hashes, quality, scene embedding

    private func hashStage(_ ctx: JobContext) async throws {
        let todo = try db.pending(stage: .thumbnailHashes, includeCloudOnly: options.allowICloudDownloads)
        guard !todo.isEmpty else { return }
        db.log("scan", "Analyzing \(todo.count) photos (hashes, quality, similarity)", assetCount: todo.count,
               model: options.sceneSimilarity ? "vision-featureprint" : nil)
        try await forEach(todo, ctx: ctx, verb: "Analyzing") { item in
            do {
                let img = try await photos.analysisImage(for: item.localIdentifier, maxDimension: 512,
                                                         allowNetwork: options.allowICloudDownloads)
                guard let (p, d) = PerceptualHash.hashes(for: img) else { return }
                let (w, h) = Self.fit(img, maxSide: 512)
                guard let luma = LumaImage.from(img, width: w, height: h) else { return }
                let q = QualityMetrics.measure(luma)
                let scene: [Float]? = options.sceneSimilarity ? (try? VisionFeaturePrintEmbedder.featurePrint(img)) : nil
                try db.saveAnalysis(assetID: item.id, pHash: p, dHash: d, laplacianVariance: q.laplacianVariance,
                                    noiseSigma: q.noiseSigma, meanLuma: q.meanLuma, clipped: q.clippedFraction,
                                    sharpness: q.sharpnessScore, noise: q.noiseScore, exposure: q.exposureScore,
                                    sceneEmbedding: scene, cipher: cipher)
            } catch PhotoForgeError.iCloudDownloadRequired {
                try? db.setAvailability(assetID: item.id, .cloudOnly)
            }
        }
    }

    // MARK: Stage 6 — SHA-256 only where it matters

    /// Hashing every original would read the whole library. Exact duplicates must share
    /// a perceptual hash and pixel size, so only those candidates are read.
    private func exactDuplicateStage(_ ctx: JobContext) async throws {
        let rows = try db.assets().filter { $0.mediaType == "image" && $0.fileHash == nil && $0.pHash != nil }
        let groups = Dictionary(grouping: rows) { "\($0.pHash!)-\($0.pixelWidth)x\($0.pixelHeight)" }
        let candidates = groups.values.filter { $0.count > 1 }.flatMap { $0 }
        guard !candidates.isEmpty else { return }
        let todo = candidates.map { (id: $0.id, localIdentifier: $0.localIdentifier) }
        try await forEach(todo, ctx: ctx, verb: "Checking exact duplicates for") { item in
            if let sha = try? await photos.sha256OfOriginal(item.localIdentifier, allowNetwork: options.allowICloudDownloads) {
                try db.setFileHash(assetID: item.id, sha256: sha, fileSize: photos.originalFileSize(item.localIdentifier))
            }
        }
    }

    // MARK: Stages 3–4 — faces

    private func faceStage(_ ctx: JobContext) async throws {
        let todo = try db.pending(stage: .faces, includeCloudOnly: options.allowICloudDownloads)
        guard !todo.isEmpty else { return }
        db.log("model", "Detecting faces in \(todo.count) photos", assetCount: todo.count, model: "Apple Vision")
        if options.storeFaceCrops {
            try? FileManager.default.createDirectory(at: options.faceCropDirectory, withIntermediateDirectories: true)
        }
        let detector = FaceDetector()
        try await forEach(todo, ctx: ctx, verb: "Finding faces in") { item in
            do {
                let img = try await photos.analysisImage(for: item.localIdentifier, maxDimension: 1600,
                                                         allowNetwork: options.allowICloudDownloads)
                let found = (try? detector.detect(in: img)) ?? []
                var faces: [NewFace] = []
                for (i, f) in found.enumerated() {
                    var embedding: [Float]? = nil
                    var cropPath: String? = nil
                    if let crop = f.alignedCrop {
                        embedding = try? VisionFeaturePrintEmbedder.featurePrint(crop)
                        if options.storeFaceCrops {
                            let url = options.faceCropDirectory.appendingPathComponent("\(item.id)-\(i).jpg")
                            if Self.writeJPEG(crop, to: url) { cropPath = url.lastPathComponent }
                        }
                    }
                    faces.append(NewFace(box: f.boundingBox, quality: Double(f.captureQuality ?? 0.5),
                                         yaw: f.yaw, pitch: f.pitch, roll: f.roll, pixelSize: Double(f.pixelSize),
                                         cropPath: cropPath, embedding: embedding))
                }
                try db.replaceFaces(assetID: item.id, faces: faces, modelName: "vision-featureprint",
                                    modelVersion: "2-face", cipher: cipher)
            } catch PhotoForgeError.iCloudDownloadRequired {
                try? db.setAvailability(assetID: item.id, .cloudOnly)
            }
        }
    }

    // MARK: Helpers

    /// Bounded-parallel loop with pause/cancel checkpoints and "N of M" progress.
    private func forEach(_ items: [(id: Int64, localIdentifier: String)], ctx: JobContext, verb: String,
                         _ body: @escaping @Sendable ((id: Int64, localIdentifier: String)) async throws -> Void) async throws {
        var done = 0
        var cursor = 0
        await ctx.report(0, of: items.count, verb, noun: "photos")
        while cursor < items.count {
            try await ctx.checkpoint()
            let width = max(1, min(6, await ctx.concurrencyBudget()))
            let batch = Array(items[cursor..<min(cursor + width * 4, items.count)])
            try await withThrowingTaskGroup(of: Void.self) { group in
                var it = batch.makeIterator()
                func next() -> Bool {
                    guard let item = it.next() else { return false }
                    group.addTask {
                        do { try await body(item) }
                        catch is CancellationError { throw CancellationError() }
                        catch { /* per-photo failure: skip it, keep scanning */ }
                    }
                    return true
                }
                for _ in 0..<width { _ = next() }
                while try await group.next() != nil { _ = next() }
            }
            cursor += batch.count
            done += batch.count
            await ctx.report(done, of: items.count, verb, noun: "photos")
        }
    }

    static func fit(_ img: CGImage, maxSide: Int) -> (Int, Int) {
        let s = min(1, Double(maxSide) / Double(max(img.width, img.height)))
        return (max(3, Int(Double(img.width) * s)), max(3, Int(Double(img.height) * s)))
    }

    static func writeJPEG(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }
}
