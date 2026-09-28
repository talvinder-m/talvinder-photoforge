import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import PFCore
import PFDatabase
import PFVision
import PFSimilarity
import PFPeople
import PFEditing

/// `PhotoForge --selftest` runs the app's real code paths (database, Vision, Core Image,
/// grouping, clustering, privacy wipes) against synthetic data, without touching the Photos
/// library, then exits 0 on success. CI runs it on the packaged app.
enum SelfTest {
    static func runAndExit() -> Never {
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            print((ok ? "PASS " : "FAIL ") + name)
            if !ok { failures += 1 }
        }
        func attempt(_ name: String, _ body: () throws -> Bool) {
            do { check(try body(), name) } catch { check(false, "\(name) — threw \(error)") }
        }

        print("PhotoForge self-test · \(ProcessInfo.processInfo.operatingSystemVersionString) · \(archName())")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pf-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1. Synthetic photos
        let scene = makeScene(seed: 1, size: 640)
        let brighter = makeScene(seed: 1, size: 640, gain: 1.08)
        let other = makeScene(seed: 7, size: 640)
        check(scene != nil && brighter != nil && other != nil, "render synthetic images")
        guard let scene, let brighter, let other else { exit(1) }

        // 2. Hashing & quality
        let h1 = PerceptualHash.hashes(for: scene), h2 = PerceptualHash.hashes(for: brighter), h3 = PerceptualHash.hashes(for: other)
        check(h1 != nil && h2 != nil && h3 != nil, "perceptual hashes computed")
        if let h1, let h2, let h3 {
            let near = PerceptualHash.hamming(h1.pHash, h2.pHash), far = PerceptualHash.hamming(h1.pHash, h3.pHash)
            check(near <= 6 && far >= 12, "pHash: exposure change \(near) bits, different scene \(far) bits")
        }
        let (w, h) = AnalysisJob.fit(scene, maxSide: 512)
        let q = LumaImage.from(scene, width: w, height: h).map(QualityMetrics.measure)
        check((q?.laplacianVariance ?? 0) > 0 && (q?.sharpnessScore ?? -1) >= 0, "quality metrics")

        // 3. Vision feature prints
        var e1: [Float] = [], e2: [Float] = [], e3: [Float] = []
        attempt("Vision feature print") {
            e1 = try VisionFeaturePrintEmbedder.featurePrint(scene)
            e2 = try VisionFeaturePrintEmbedder.featurePrint(brighter)
            e3 = try VisionFeaturePrintEmbedder.featurePrint(other)
            return e1.count > 100 && e1.count == e3.count
        }
        if !e1.isEmpty {
            let sSame = VectorMath.dot(e1, e2), sDiff = VectorMath.dot(e1, e3)
            print("     feature-print cosine: same scene \(String(format: "%.3f", sSame)), different \(String(format: "%.3f", sDiff))")
            check(sSame > sDiff, "feature prints rank the matching scene higher")
        }

        // 4. Face detection runs (synthetic image has no faces)
        attempt("Vision face detector runs") { try FaceDetector().detect(in: scene).isEmpty }

        // 5. Database: migrations + repository round-trips
        attempt("database end-to-end") {
            let db = try AppDatabase.open(at: dir.appendingPathComponent("t.sqlite"))
            let cipher = try VectorCipher(store: .file(dir.appendingPathComponent("k.key")))
            let src = try db.systemSourceID()
            let now = Date()
            let items = (1...3).map { i in
                AssetUpsert(localIdentifier: "ID-\(i)", mediaType: "image", subtypeMask: 0, creationDate: now.addingTimeInterval(Double(i)),
                            modificationDate: now, pixelWidth: 640, pixelHeight: 640, duration: 0, favorite: i == 2,
                            hidden: false, burstIdentifier: nil)
            }
            try db.upsert(items, sourceID: src, scanStamp: now)
            let pending = try db.pending(stage: .thumbnailHashes, includeCloudOnly: false)
            guard pending.count == 3 else { return false }
            let emb = [e1, e2, e3]
            let hs = [h1!, h2!, h3!]
            for (i, p) in pending.sorted(by: { $0.localIdentifier < $1.localIdentifier }).enumerated() {
                try db.saveAnalysis(assetID: p.id, pHash: hs[i].pHash, dHash: hs[i].dHash, laplacianVariance: 100,
                                    noiseSigma: 2, meanLuma: 120, clipped: 0, sharpness: 0.5, noise: 0.8, exposure: 0.9,
                                    sceneEmbedding: emb[i].isEmpty ? nil : emb[i], cipher: cipher)
            }
            guard try db.pending(stage: .thumbnailHashes, includeCloudOnly: false).isEmpty else { return false }
            let rows = try db.assets()
            let back = try db.sceneEmbeddings(cipher: cipher)
            guard rows.count == 3, back.count == (e1.isEmpty ? 0 : 3) else { return false }
            if let first = back.values.first, !e1.isEmpty { guard first.count == e1.count else { return false } }

            // Faces, people, constraints
            let f = NewFace(box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), quality: 0.9, yaw: 0, pitch: 0, roll: 0,
                            pixelSize: 120, cropPath: nil, embedding: e1.isEmpty ? [1, 0, 0] : e1)
            try db.replaceFaces(assetID: rows[0].id, faces: [f, f], modelName: "vision-featureprint", modelVersion: "2-face", cipher: cipher)
            let faces = try db.storedFaces(cipher: cipher)
            guard faces.count == 2 else { return false }
            let pid = try db.createPerson(named: "Test Person", faceIDs: [faces[0].id])
            try db.rejectFace(faces[1].id, fromPerson: pid, againstFaces: [faces[0].id])
            let (must, cannot) = try db.faceConstraints()
            guard try db.persons().first?.confirmedFaceIDs == [faces[0].id], cannot.count == 1, must.isEmpty else { return false }

            // Removal queue, edits, stats, activity
            try db.queueForRemoval([rows[1].id], reason: "test", groupID: nil)
            guard try db.removalQueue().count == 1 else { return false }
            try db.saveEditProject(sourceAssetID: rows[0].id, name: "t", stackJSON: "{}", stackVersion: 1, containsGenerative: false,
                                   outputAssetID: nil, outputPath: nil, modelsJSON: nil, sourceChecksum: nil)
            db.log("scan", "self-test")
            let st = try db.stats()
            let hasActivity = try !db.activity().isEmpty
            guard st.photos == 3, st.hashed == 3, st.faces == 2, st.namedPeople == 1, hasActivity else { return false }

            // Privacy wipes
            let semaphore = DispatchSemaphore(value: 0)
            var wiped = -1
            Task.detached { wiped = (try? await db.deleteAllFaceData(faceCropDirectory: dir.appendingPathComponent("crops"))) ?? -1; semaphore.signal() }
            semaphore.wait()
            guard wiped == 2, try db.storedFaces(cipher: cipher).isEmpty, try db.persons().isEmpty else { return false }
            try db.deleteAllAppData()
            let emptyAssets = try db.assets().isEmpty
            let zeroPhotos = try db.stats().photos == 0
            return emptyAssets && zeroPhotos
        }

        // 6. Duplicate grouping with real hashes + embeddings
        do {
            var fs: [AssetFeatures] = []
            for (i, (hh, e)) in zip([h1!, h2!, h3!], [e1, e2, e3]).enumerated() {
                var a = AssetFeatures(id: AssetID(Int64(i + 1)), pixelWidth: 640, pixelHeight: 640)
                a.pHash = hh.pHash; a.dHash = hh.dHash; a.embedding = e.isEmpty ? nil : e
                a.captureDate = Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 3600)
                a.quality = QualityMetrics(laplacianVariance: 100 + Double(i), noiseSigma: 2, meanLuma: 120, clippedFraction: 0)
                fs.append(a)
            }
            let groups = DuplicateGrouper().groups(for: fs)
            check(groups.contains { $0.type == .near && Set($0.members) == [AssetID(1), AssetID(2)] },
                  "near-duplicate group from real image hashes (\(groups.map { "\($0.type.rawValue):\($0.members.map(\.rawValue))" }))")
        }

        // 7. Editor rendering + export
        do {
            let r = EditRenderer()
            var adj = Adjustments()
            adj.exposure = 0.5; adj.contrast = 0.3; adj.highlights = -0.4; adj.shadows = 0.3; adj.whites = 0.2; adj.blacks = -0.2
            adj.temperature = 0.3; adj.tint = -0.2; adj.vibrance = 0.4; adj.saturation = 0.2; adj.clarity = 0.3; adj.dehaze = 0.2
            adj.sharpness = 0.5; adj.noiseReduction = 0.3; adj.vignette = 0.4; adj.grain = 0.3
            var stack = EditStack(source: SourceReference(accessedAt: .now))
            stack.push(EditLayer(operation: .adjust(adj)))
            let adjusted = r.render(CIImage(cgImage: scene), stack: stack)
            let a = r.cgImage(adjusted)
            check(a != nil && a!.width == 640 && a!.height == 640, "editor adjustments render (\(a.map { "\($0.width)x\($0.height)" } ?? "nil"), extent \(adjusted.extent))")

            stack.push(EditLayer(operation: .crop(CropSpec(rect: [0.1, 0.1, 0.5, 0.5], angle: 0.1, flipH: true, flipV: false))))
            let out = r.render(CIImage(cgImage: scene), stack: stack)
            let c = r.cgImage(out)
            check(c != nil && abs(c!.width - 320) <= 2 && abs(c!.height - 320) <= 2,
                  "editor crop + straighten + flip (\(c.map { "\($0.width)x\($0.height)" } ?? "nil"), extent \(out.extent))")

            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for type in [UTType.jpeg, .heic, .png, .tiff] {
                let url = dir.appendingPathComponent("out.\(type.preferredFilenameExtension!)")
                do {
                    try r.write(out, to: url, type: type)
                    let src = CGImageSourceCreateWithURL(url as CFURL, nil)
                    check(src.map { CGImageSourceGetCount($0) } == 1, "export \(type.preferredFilenameExtension!)")
                } catch {
                    // HEIC encoding depends on the Mac's media hardware; report but tolerate.
                    if type == .heic { print("INFO export heic unavailable on this machine: \(error)") }
                    else { check(false, "export \(type.preferredFilenameExtension!) — \(error)") }
                }
            }
            let decoded = try? EditStack.decode((try? stack.encoded()) ?? "")
            check(decoded == stack, "edit recipe round-trips")
        }

        // 8. Clustering with feature-print embeddings of the synthetic scenes
        if !e1.isEmpty {
            let samples = [e1, e2, e1, e3].enumerated().map {
                FaceSample(id: FaceID(Int64($0.offset + 1)), embedding: $0.element, quality: 0.9, pixelSize: 150)
            }
            var c = FaceClusterer(); c.config.minClusterSize = 2
            let r = c.cluster(samples, index: BruteForceIndex(samples))
            check(!r.clusters.isEmpty || !r.review.isEmpty, "clusterer runs on real embeddings")
        }

        print(failures == 0 ? "SELFTEST OK" : "SELFTEST FAILED (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }

    static func archName() -> String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    /// Deterministic textured test image: gradient background plus seeded shapes.
    static func makeScene(seed: UInt64, size: Int, gain: CGFloat = 1) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var rng = SplitMix64(seed: seed)
        func r() -> CGFloat { CGFloat(rng.next() % 10_000) / 10_000 }
        let S = CGFloat(size)
        for i in 0..<16 {
            let y = CGFloat(i) * S / 16
            ctx.setFillColor(CGColor(srgbRed: min(1, (0.2 + 0.03 * CGFloat(i)) * gain), green: min(1, 0.35 * gain),
                                     blue: min(1, (0.6 - 0.02 * CGFloat(i)) * gain), alpha: 1))
            ctx.fill(CGRect(x: 0, y: y, width: S, height: S / 16 + 1))
        }
        for _ in 0..<14 {
            ctx.setFillColor(CGColor(srgbRed: min(1, r() * gain), green: min(1, r() * gain), blue: min(1, r() * gain), alpha: 1))
            let d = S * (0.08 + 0.25 * r())
            let rect = CGRect(x: r() * S - d / 2, y: r() * S - d / 2, width: d, height: d)
            if r() > 0.5 { ctx.fillEllipse(in: rect) } else { ctx.fill(rect) }
        }
        return ctx.makeImage()
    }
}
