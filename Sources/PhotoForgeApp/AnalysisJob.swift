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
import PFClassify

/// Options captured when the scan starts (from Settings).
struct AnalysisOptions: Sendable {
    var faceAnalysis: Bool
    var storeFaceCrops: Bool
    var sceneSimilarity: Bool
    var allowICloudDownloads: Bool
    var faceCropDirectory: URL
    var face: FaceEmbedding
    var classify: Bool = true
    var maxConcurrency: Int = 4
    var ocrAccurate: Bool = false
    var classifyImageSize: Int = 1280
    var faceImageSize: Int = 1600
}

/// The whole local analysis pipeline as one resumable background job.
/// Each stage only processes assets whose stage bit is still clear, so a quit,
/// crash, pause or cancel resumes exactly where it stopped.
struct AnalysisJob: BackgroundJob {
    let kind = "analysis"
    let priority: JobPriority = .utility
    var maxRetries: Int { 0 }

    let db: AppDatabase
    let source: any MediaSource       // PhotoKit, or a library/folder read from disk
    let sourceID: Int64
    let cipher: VectorCipher
    let options: AnalysisOptions

    func run(_ ctx: JobContext) async throws {
        try await hashStage(ctx)
        try await exactDuplicateStage(ctx)
        if options.classify { try await classificationStage(ctx) }
        if options.faceAnalysis { try await faceStage(ctx) }
        await ctx.report(message: "Finishing up")
    }

    // MARK: Stage 2 — thumbnails, hashes, quality, scene embedding

    private func hashStage(_ ctx: JobContext) async throws {
        let todo = try db.pending(stage: .thumbnailHashes, sourceID: sourceID, includeCloudOnly: options.allowICloudDownloads)
        guard !todo.isEmpty else { return }
        db.log("scan", "Analyzing \(todo.count) photos (hashes, quality, similarity)", assetCount: todo.count,
               model: options.sceneSimilarity ? "vision-featureprint" : nil)
        try await forEach(todo, ctx: ctx, verb: "Analyzing") { item in
            do {
                let img = try await source.analysisImage(for: item.localIdentifier, maxDimension: 512,
                                                         allowNetwork: options.allowICloudDownloads)
                // The calculations block, so they run off the shared Swift thread pool.
                let (db, cipher, sceneOn) = (db, cipher, options.sceneSimilarity)
                try await Offload.run(.utility) {
                    guard let (p, d) = PerceptualHash.hashes(for: img) else { return }
                    let (w, h) = Self.fit(img, maxSide: 512)
                    guard let luma = LumaImage.from(img, width: w, height: h) else { return }
                    let q = QualityMetrics.measure(luma)
                    let scene: [Float]? = sceneOn ? (try? VisionFeaturePrintEmbedder.featurePrint(img)) : nil
                    try db.saveAnalysis(assetID: item.id, pHash: p, dHash: d, laplacianVariance: q.laplacianVariance,
                                        noiseSigma: q.noiseSigma, meanLuma: q.meanLuma, clipped: q.clippedFraction,
                                        sharpness: q.sharpnessScore, noise: q.noiseScore, exposure: q.exposureScore,
                                        sceneEmbedding: scene, cipher: cipher)
                }
            } catch PhotoForgeError.iCloudDownloadRequired {
                try? db.setAvailability(assetID: item.id, .cloudOnly)
            }
        }
    }

    // MARK: Stage 6 — SHA-256 only where it matters

    /// Hashing every original would read the whole library. Exact duplicates must share
    /// a perceptual hash and pixel size, so only those candidates are read.
    private func exactDuplicateStage(_ ctx: JobContext) async throws {
        let rows = try db.assets(sourceID: sourceID).filter { $0.mediaType == "image" && $0.fileHash == nil && $0.pHash != nil }
        let groups = Dictionary(grouping: rows) { "\($0.pHash!)-\($0.pixelWidth)x\($0.pixelHeight)" }
        let candidates = groups.values.filter { $0.count > 1 }.flatMap { $0 }
        guard !candidates.isEmpty else { return }
        let todo = candidates.map { (id: $0.id, localIdentifier: $0.localIdentifier) }
        try await forEach(todo, ctx: ctx, verb: "Checking exact duplicates for") { item in
            if let sha = try? await source.sha256OfOriginal(item.localIdentifier, allowNetwork: options.allowICloudDownloads) {
                try db.setFileHash(assetID: item.id, sha256: sha, fileSize: source.originalFileSize(item.localIdentifier))
            }
        }
    }

    // MARK: Stage 5 — categories (documents, receipts, screenshots, WhatsApp, social, QR, camera)

    private func classificationStage(_ ctx: JobContext) async throws {
        let todo = try db.pending(stage: .classification, sourceID: sourceID, includeCloudOnly: options.allowICloudDownloads)
        guard !todo.isEmpty else { return }
        let rows = Dictionary(uniqueKeysWithValues: try db.assets(sourceID: sourceID).map { ($0.id, $0) })
        db.log("model", "Sorting \(todo.count) photos into categories", assetCount: todo.count, model: "Apple Vision (classify, text, barcodes)")
        let analyzer = PhotoAnalyzer(accurateText: options.ocrAccurate)
        try await forEach(todo, ctx: ctx, verb: "Sorting") { item in
            guard let row = rows[item.id] else { return }
            do {
                let md = await source.metadata(for: item.localIdentifier)
                let img = try await source.analysisImage(for: item.localIdentifier, maxDimension: CGFloat(options.classifyImageSize),
                                                         allowNetwork: options.allowICloudDownloads)
                let db = db
                let out = try await Offload.run(.utility) {
                    try analyzer.analyze(img, width: row.pixelWidth, height: row.pixelHeight, metadata: md,
                                         isScreenshotSubtype: row.subtypeMask & 4 != 0)
                }
                try db.saveClassification(
                    assetID: item.id,
                    categories: out.decisions.map { .init(category: $0.category.rawValue, confidence: $0.confidence, reason: $0.reason) },
                    ocrText: out.ocrText, labels: out.sceneLabels, filename: md.filename,
                    cameraMake: md.cameraMake, cameraModel: md.cameraModel)
            } catch PhotoForgeError.iCloudDownloadRequired {
                try? db.setAvailability(assetID: item.id, .cloudOnly)
            }
        }
    }

    // MARK: Stages 3–4 — faces

    private func faceStage(_ ctx: JobContext) async throws {
        let todo = try db.pending(stage: .faces, sourceID: sourceID, includeCloudOnly: options.allowICloudDownloads)
        guard !todo.isEmpty else { return }
        db.log("model", "Detecting faces in \(todo.count) photos", assetCount: todo.count,
               model: "Apple Vision + \(options.face.name)")
        if options.storeFaceCrops {
            try? FileManager.default.createDirectory(at: options.faceCropDirectory, withIntermediateDirectories: true)
        }
        let detector = FaceDetector()
        try await forEach(todo, ctx: ctx, verb: "Finding faces in") { item in
            do {
                let img = try await source.analysisImage(for: item.localIdentifier, maxDimension: CGFloat(options.faceImageSize),
                                                         allowNetwork: options.allowICloudDownloads)
                let found = await Offload.run(.utility) { (try? detector.detect(in: img)) ?? [] }
                var faces: [NewFace] = []
                for (i, f) in found.enumerated() {
                    var embedding: [Float]? = nil
                    var cropPath: String? = nil
                    if let crop = f.alignedCrop {
                        embedding = try? await options.face.model.embed([crop]).first
                        if options.storeFaceCrops {
                            let url = options.faceCropDirectory.appendingPathComponent("\(item.id)-\(i).jpg")
                            if Self.writeJPEG(crop, to: url) { cropPath = url.lastPathComponent }
                        }
                    }
                    faces.append(NewFace(box: f.boundingBox, quality: Double(f.captureQuality ?? 0.5),
                                         yaw: f.yaw, pitch: f.pitch, roll: f.roll, pixelSize: Double(f.pixelSize),
                                         cropPath: cropPath, embedding: embedding))
                }
                try db.replaceFaces(assetID: item.id, faces: faces, modelName: options.face.name,
                                    modelVersion: options.face.version, cipher: cipher)
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
            let width = max(1, min(options.maxConcurrency, await ctx.concurrencyBudget()))
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
