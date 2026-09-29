import Foundation
import PFClassify
import CoreText
import PFPhotosBridge
import SQLite3
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
import AVFoundation
import CoreVideo

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

        // 4b. Face embedder (bundled SFace Core ML model when present)
        let face = FaceEmbedding.load()
        print("     face model: \(face.summary)")
        check(face.isDedicatedFaceModel, "SFace model bundled and loads")
        if let crop = FaceAligner.align(scene, points: FaceAligner.arcFaceTemplate.map { CGPoint(x: $0.x * 4, y: $0.y * 4) }) {
            let sem = DispatchSemaphore(value: 0)
            var v: [Float] = []
            Task.detached { v = (try? await face.model.embed([crop]).first) ?? []; sem.signal() }
            sem.wait()
            let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
            check(!v.isEmpty && abs(norm - 1) < 1e-3, "face embedding runs (\(v.count)-d, |v|=\(String(format: "%.4f", norm)))")
        }

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
            let pending = try db.pending(stage: .thumbnailHashes, sourceID: src, includeCloudOnly: false)
            guard pending.count == 3 else { return false }
            let emb = [e1, e2, e3]
            let hs = [h1!, h2!, h3!]
            for (i, p) in pending.sorted(by: { $0.localIdentifier < $1.localIdentifier }).enumerated() {
                try db.saveAnalysis(assetID: p.id, pHash: hs[i].pHash, dHash: hs[i].dHash, laplacianVariance: 100,
                                    noiseSigma: 2, meanLuma: 120, clipped: 0, sharpness: 0.5, noise: 0.8, exposure: 0.9,
                                    sceneEmbedding: emb[i].isEmpty ? nil : emb[i], cipher: cipher)
            }
            guard try db.pending(stage: .thumbnailHashes, sourceID: src, includeCloudOnly: false).isEmpty else { return false }
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

        // 9. On-disk libraries: synthetic Photos library + iPhoto-style folder
        attempt("read-only Photos library reader") {
            let lib = dir.appendingPathComponent("Test.photoslibrary")
            try makeFakePhotosLibrary(at: lib, image: scene)
            let src = try FileLibrarySource(url: lib)
            let found = try src.scan()
            let byKey = Dictionary(uniqueKeysWithValues: found.map { ($0.key, $0) })
            print("     library kind: \(src.inspection.kind.rawValue); assets: \(found.map { "\($0.key) local=\($0.isOriginalLocal) url=\($0.url != nil)" })")
            guard src.inspection.kind == .photosLibrary, found.count == 3,
                  byKey["pkg:LOCAL-1"]?.isOriginalLocal == true,
                  byKey["pkg:CLOUD-2"]?.isOriginalLocal == false, byKey["pkg:CLOUD-2"]?.url != nil,   // derivative preview
                  byKey["pkg:SHOT-4"]?.subtypeMask == 4,
                  byKey["pkg:TRASH-3"] == nil else { return false }
            let sem = DispatchSemaphore(value: 0)
            var thumbOK = false, analysisOK = false
            Task.detached {
                thumbOK = await src.thumbnail(for: "pkg:LOCAL-1", side: 200) != nil
                analysisOK = (try? await src.analysisImage(for: "pkg:CLOUD-2", maxDimension: 256, allowNetwork: false)) != nil
                sem.signal()
            }
            sem.wait()
            // Nothing inside the library may change.
            let dbFile = lib.appendingPathComponent("database/Photos.sqlite")
            let before = try Data(contentsOf: dbFile)
            _ = try src.scan()
            let unchanged = try Data(contentsOf: dbFile) == before
            return thumbOK && analysisOK && unchanged
        }
        attempt("iPhoto-style folder library reader") {
            let lib = dir.appendingPathComponent("Old.photolibrary")
            let masters = lib.appendingPathComponent("Masters/2014/05/03")
            try FileManager.default.createDirectory(at: masters, withIntermediateDirectories: true)
            for i in 0..<3 { try writeJPEG(scene, to: masters.appendingPathComponent("IMG_\(i).JPG"), exifDate: "2014:05:03 10:0\(i):00") }
            let src = try FileLibrarySource(url: lib)
            let found = try src.scan()
            let dated = found.filter { $0.creationDate.map { Calendar.current.component(.year, from: $0) } == 2014 }.count
            print("     legacy kind: \(src.inspection.kind.rawValue), \(found.count) photos, \(dated) with EXIF 2014 dates")
            return src.inspection.kind == .legacyLibrary && found.count == 3 && dated == 3
        }
        attempt("libraries are kept separate in the database") {
            let db = try AppDatabase.open(at: dir.appendingPathComponent("libs.sqlite"))
            let sys = try db.systemSourceID()
            let other = try db.addLibrary(kind: "photoslibrary_readonly", name: "Other", path: "/tmp/Other.photoslibrary")
            let now = Date()
            func up(_ k: String, _ avail: String?, _ src: String = "library") -> AssetUpsert {
                AssetUpsert(localIdentifier: k, mediaType: "image", subtypeMask: 0, creationDate: now, modificationDate: now,
                            pixelWidth: 100, pixelHeight: 100, duration: 0, favorite: false, hidden: false, burstIdentifier: nil,
                            assetSource: src, filePath: nil, availability: avail)
            }
            try db.upsert([up("A", "local"), up("B", "cloud_only"), up("C", nil, "shared")], sourceID: sys, scanStamp: now)
            try db.upsert([up("pkg:X", "local")], sourceID: other, scanStamp: now)
            // A later sync that doesn't know availability must not erase it.
            try db.upsert([up("B", nil)], sourceID: sys, scanStamp: now)
            let s1 = try db.stats(sourceID: sys), s2 = try db.stats(sourceID: other)
            let libs = try db.libraries()
            print("     system: \(s1.photos) photos, \(s1.cloudOnly) iCloud-only, \(s1.shared) shared · other: \(s2.photos)")
            let otherKeys = try db.assets(sourceID: other).map(\.localIdentifier)
            return s1.photos == 3 && s1.cloudOnly == 1 && s1.shared == 1 && s2.photos == 1
                && otherKeys == ["pkg:X"] && libs.count == 2 && libs.first?.isSystem == true
        }

        // 10. Upscaling: FSRCNN (fast), Real-ESRGAN (best), Lanczos (standard)
        do {
            let sr = SuperResolution(modelsDirectory: Bundle.main.resourceURL?.appendingPathComponent("Models"))
            check(sr.isAvailable(.fast), "FSRCNN models bundled")
            check(sr.isAvailable(.best), "Real-ESRGAN model bundled")
            // Downscale the 640px scene to 320, upscale back to 640, compare with the original.
            if let small = sr.lanczos(scene, width: 320, height: 320) {
                for m in SuperResolution.Method.allCases where sr.isAvailable(m) {
                    let sem = DispatchSemaphore(value: 0)
                    var out: SuperResolution.Result?
                    var err: Error?
                    Task.detached {
                        do { out = try await sr.upscale(small, targetLongEdge: 640, method: m) } catch { err = error }
                        sem.signal()
                    }
                    sem.wait()
                    if let r = out {
                        let p = SuperResolution.psnr(r.image, scene) ?? 0
                        print(String(format: "     %@: %dx%d in %.2f s, PSNR vs original %.2f dB", r.modelName, r.image.width, r.image.height, r.seconds, p))
                        check(r.image.width == 640 && r.image.height == 640, "upscale \(m.rawValue) produces the requested size")
                    } else {
                        check(false, "upscale \(m.rawValue) — \(err.map { "\($0)" } ?? "no result")")
                    }
                }
                // Target larger than 2K keeps aspect ratio.
                let (w, h) = SuperResolution.outputSize(width: 1200, height: 800, targetLongEdge: 2048)
                check(w == 2048 && h == 1365, "2K output size keeps aspect ratio (\(w)×\(h))")
            }
        }

        // 11. Classification with real Vision
        do {
            let analyzer = PhotoAnalyzer()
            let camera = PhotoMetadata(filename: "IMG_2231.JPG", uti: "public.jpeg", cameraMake: "Apple", cameraModel: "iPhone 12",
                                       hasCameraData: true, hasAnyExif: true)
            if let page = makeDocument(lines: ["SHARMA TRADERS", "Invoice No: 4471", "Date: 12/03/2024", "Item   Qty   Rate   Amount",
                                               "Seeds   2   250   500", "Fertilizer   1   400   400", "Subtotal   900",
                                               "CGST 9%   81", "SGST 9%   81", "Total Rs. 1062", "Paid via UPI", "Thank you, visit again"]) {
                let out = try? analyzer.analyze(page, width: 1500, height: 2000, metadata: camera, isScreenshotSubtype: false)
                let cats = Set(out?.decisions.filter { $0.confidence >= 0.5 }.map(\.category) ?? [])
                print("     invoice photo → \((out?.decisions ?? []).map { "\($0.category.rawValue) \(String(format: "%.2f", $0.confidence)): \($0.reason)" })")
                print("       OCR: \(out?.signals.textCharacters ?? 0) chars, page confidence \(out?.signals.documentConfidence ?? 0), labels \(out?.sceneLabels.prefix(3).map { $0.0 } ?? [])")
                check(cats.contains(.document) && cats.contains(.receipt) && !cats.contains(.camera),
                      "photographed invoice → Documents + Receipts (not Camera Photos)")
            }
            if let qr = makeQR("https://hillsprouts.in") {
                let out = try? analyzer.analyze(qr, width: qr.width, height: qr.height,
                                                metadata: PhotoMetadata(filename: "qr.png", uti: "public.png", hasCameraData: false, hasAnyExif: false),
                                                isScreenshotSubtype: false)
                check(out?.decisions.contains { $0.category == .qrCode } == true, "QR code detected")
            }
            let plain = try? analyzer.analyze(scene, width: 4032, height: 3024, metadata: camera, isScreenshotSubtype: false)
            let pc = Set(plain?.decisions.map(\.category) ?? [])
            check(pc == [.camera], "ordinary camera photo → Camera Photos only (\(pc.map(\.rawValue)))")
        }

        // 12. Metadata reading from files
        attempt("camera metadata and stripped-file detection") {
            let folder = dir.appendingPathComponent("MetaFolder")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try writeJPEG(scene, to: folder.appendingPathComponent("canon.jpg"), exifDate: "2023:01:02 03:04:05",
                          tiff: [kCGImagePropertyTIFFMake: "Canon", kCGImagePropertyTIFFModel: "Canon EOS 80D"],
                          exposure: 0.004)
            try writeJPEG(scene, to: folder.appendingPathComponent("IMG-20240315-WA0012.jpg"))
            let src = try FileLibrarySource(url: folder)
            _ = try src.scan()
            let sem = DispatchSemaphore(value: 0)
            var a = PhotoMetadata(), b = PhotoMetadata()
            Task.detached {
                a = await src.metadata(for: "file:canon.jpg")
                b = await src.metadata(for: "file:IMG-20240315-WA0012.jpg")
                sem.signal()
            }
            sem.wait()
            print("     canon: make=\(a.cameraMake ?? "nil") model=\(a.cameraModel ?? "nil") camera=\(String(describing: a.hasCameraData)); wa: exif=\(String(describing: b.hasAnyExif)) camera=\(String(describing: b.hasCameraData))")
            let wa = ClassificationRules.classify(.init(metadata: b, width: 1600, height: 1200)).map(\.category)
            return a.cameraMake == "Canon" && a.hasCameraData == true && b.hasCameraData == false && wa.contains(.whatsapp)
        }

        // 13. Folder trees: albums from a Photos database, directories from an iPhoto library
        attempt("albums & folders tree") {
            let lib = dir.appendingPathComponent("Albums.photoslibrary")
            try makeFakePhotosLibrary(at: lib, image: scene)
            let src = try FileLibrarySource(url: lib)
            _ = try src.scan()
            func describe(_ n: AlbumNode, _ depth: Int = 0) -> String {
                String(repeating: "  ", count: depth) + "\(n.title) [\(n.kind.rawValue), \(n.assetKeys.count)]\n" + n.children.map { describe($0, depth + 1) }.joined()
            }
            print("     albums:\n" + src.albums.map { describe($0, 3) }.joined(), terminator: "")
            let trips = src.albums.first { $0.title == "Trips" }
            let goa = trips?.children.first { $0.title == "Goa" }
            let bills = src.albums.first { $0.title == "Bills" }
            let legacy = try FileLibrarySource(url: dir.appendingPathComponent("Old.photolibrary"))
            _ = try legacy.scan()
            let y2014 = legacy.albums.first { $0.title == "2014" }
            print("     iPhoto folders: \(legacy.albums.map { describe($0) }.joined().replacingOccurrences(of: "\n", with: " | "))")
            return trips?.kind == .folder && goa?.assetKeys == ["pkg:LOCAL-1"] && trips?.assetKeys == ["pkg:LOCAL-1"]
                && bills?.assetKeys == ["pkg:SHOT-4"] && y2014?.assetKeys.count == 3
        }

        // 14. Slideshow requests travel between windows as Codable values
        attempt("slideshow request encodes for its window") {
            let r = SlideshowRequest(title: "Goa", keys: ["a", "b", "c"], startIndex: 1)
            let back = try JSONDecoder().decode(SlideshowRequest.self, from: JSONEncoder().encode(r))
            return back == r
        }

        // 15. This Mac
        do {
            let m = MachineProfile.detect()
            print("     this Mac: \(m.summary) · \(m.tier.label) · GPU \(m.gpu) · macOS \(m.macOS) · Rosetta \(m.isTranslated)")
            print("     tuned: \(m.analysisConcurrency) parallel · OCR \(m.ocrAccurate ? "accurate" : "fast") · cache \(m.thumbnailCacheMB) MB · compute \(m.computeUnits) · upscaler \(m.recommendedUpscaler)")
            check(m.cores > 0 && m.memoryGB > 0 && m.analysisConcurrency >= 1, "machine profile detected")
            #if arch(arm64)
            check(m.isAppleSilicon, "Apple silicon recognised")
            #endif
        }

        // 16. Video support
        let videoURL = dir.appendingPathComponent("VideoFolder/clip.mp4")
        attempt("video: write, probe, thumbnail, playable") {
            try FileManager.default.createDirectory(at: videoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard makeVideo(at: videoURL, frames: 20, image: scene) else { return false }
            let p = MediaFiles.probe(videoURL)
            let sem = DispatchSemaphore(value: 0)
            var thumb: CGImage?, playable = false
            Task.detached {
                thumb = await MediaFiles.videoThumbnail(videoURL, maxPixel: 200)
                playable = await MediaFiles.isNativelyPlayable(videoURL)
                sem.signal()
            }
            sem.wait()
            print("     video: \(p.mediaType) \(p.width)x\(p.height) \(String(format: "%.2f", p.duration)) s, thumbnail \(thumb != nil), native \(playable)")
            return p.mediaType == "video" && p.width == 320 && p.duration > 1 && thumb != nil && playable
        }
        attempt("folders include videos") {
            try writeJPEG(scene, to: videoURL.deletingLastPathComponent().appendingPathComponent("a.jpg"))
            let src = try FileLibrarySource(url: videoURL.deletingLastPathComponent())
            let found = try src.scan()
            return found.count == 2 && found.contains { $0.mediaType == "video" }
        }
        #if canImport(VLCKit)
        print("     VLC engine: bundled")
        check(true, "VLC engine linked")
        #else
        print("INFO VLC engine not in this build; only formats macOS plays natively")
        #endif

        // 17. PhotoForge Library: create, import (skip duplicates), rename, album, trash, reopen
        attempt("PhotoForge Library end-to-end") {
            let (pkg, manifest) = try PhotoForgePackage.create(named: "Farm", in: dir)
            guard PhotoForgePackage.isPackage(pkg), try PhotoForgePackage.open(pkg).id == manifest.id else { return false }
            let dbURL = pkg.appendingPathComponent("Database/photoforge.sqlite")
            var db: AppDatabase? = try AppDatabase.open(at: dbURL)
            let sid = try db!.addLibrary(kind: "pflibrary", name: "Farm", path: pkg.path)
            let managed = ManagedLibrarySource(root: pkg)
            let inbox = dir.appendingPathComponent("Inbox")
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            try writeJPEG(scene, to: inbox.appendingPathComponent("IMG_1.jpg"), exifDate: "2021:06:01 09:00:00")
            try writeJPEG(other, to: inbox.appendingPathComponent("IMG_2.jpg"))
            try FileManager.default.copyItem(at: inbox.appendingPathComponent("IMG_1.jpg"), to: inbox.appendingPathComponent("copy of IMG_1.jpg"))
            try FileManager.default.copyItem(at: videoURL, to: inbox.appendingPathComponent("clip.mp4"))
            var seen = Set<Data>(), keys: [String] = [], skipped = 0
            for f in try FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
                let h = try FileLibrarySource.sha256(of: f)
                if !seen.insert(h).inserted { skipped += 1; continue }
                let pr = MediaFiles.probe(f)
                let rel = try managed.importFile(f, date: pr.captureDate)
                let key = ManagedLibrarySource.newKey()
                managed.set(key, relativePath: rel)
                try db!.upsert([AssetUpsert(localIdentifier: key, mediaType: pr.mediaType, subtypeMask: 0, creationDate: pr.captureDate,
                                            modificationDate: .now, pixelWidth: pr.width, pixelHeight: pr.height, duration: pr.duration,
                                            favorite: false, hidden: false, burstIdentifier: nil, filePath: rel, availability: "local",
                                            originalFilename: f.lastPathComponent, fileHash: h)], sourceID: sid, scanStamp: .now)
                keys.append(key)
            }
            let rows = try db!.assets(sourceID: sid)
            print("     library: \(rows.count) items (\(rows.filter(\.isVideo).count) video), \(skipped) duplicate skipped · \(rows.compactMap(\.filePath).sorted())")
            guard rows.count == 3, skipped == 1, rows.filter(\.isVideo).count == 1,
                  rows.contains(where: { $0.filePath == "Originals/2021/06/IMG_1.jpg" }) else { return false }
            // Rename (name in the database + file on disk)
            let first = rows.first { $0.filePath == "Originals/2021/06/IMG_1.jpg" }!
            let newRel = try managed.renameFile(first.localIdentifier, to: "Goat Shed 001")
            try db!.updateFileLocation(assetID: first.id, filePath: newRel, originalFilename: (newRel as NSString).lastPathComponent)
            try db!.setTitles([(assetID: first.id, title: "Goat Shed 001")])
            guard FileManager.default.fileExists(atPath: pkg.appendingPathComponent(newRel).path) else { return false }
            // Album
            let album = try db!.createAlbum(title: "Sheds", parentID: nil, isFolder: false, sourceID: sid, assetIDs: [first.id])
            // Trash
            let video = rows.first(where: \.isVideo)!
            try managed.moveToTrash(video.localIdentifier)
            try db!.markDeleted(assetIDs: [video.id])
            let untracked = managed.untrackedFiles().count
            // Reopen from disk, as after an app upgrade.
            db = nil
            let again = try AppDatabase.open(at: dbURL)
            let back = try again.assets(sourceID: sid)
            let named = back.first { $0.id == first.id }
            let albums = try again.albums(sourceID: sid)
            let trashed = FileManager.default.fileExists(atPath: pkg.appendingPathComponent("Trash/\(video.filePath!)").path)
            print("     after reopen: \(back.count) items, name \(named?.displayName ?? "nil"), albums \(albums.map { "\($0.title):\($0.assetIDs.count)" }), trashed \(trashed), untracked \(untracked)")
            return named?.displayName == "Goat Shed 001" && albums.first?.id == album && albums.first?.assetIDs == [first.id]
                && trashed && untracked == 0 && back.count == 2
        }

        // 18. Per-library databases: splitting an older combined database, and carrying analysis across
        attempt("older combined database splits into one per library") {
            let support = dir.appendingPathComponent("Support")
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let legacy = try AppDatabase.open(at: support.appendingPathComponent("photoforge.sqlite"))
            let sys = try legacy.systemSourceID()
            let ext = try legacy.addLibrary(kind: "photoslibrary_readonly", name: "Old Mac", path: "/Volumes/X/Old.photoslibrary")
            let now = Date()
            func up(_ k: String) -> AssetUpsert {
                AssetUpsert(localIdentifier: k, mediaType: "image", subtypeMask: 0, creationDate: now, modificationDate: now,
                            pixelWidth: 10, pixelHeight: 10, duration: 0, favorite: false, hidden: false, burstIdentifier: nil)
            }
            try legacy.upsert([up("S1"), up("S2")], sourceID: sys, scanStamp: now)
            try legacy.upsert([up("pkg:E1")], sourceID: ext, scanStamp: now)
            _ = try VectorCipher(store: .file(support.appendingPathComponent("vector.key")))
            let registry = LibraryRegistry(fileURL: support.appendingPathComponent("Libraries.json"))
            let entries = try LibraryRegistry.upgradeCombinedDatabase(supportDir: support, registry: registry)
            let apple = entries.first { $0.kind == .applePhotos }, old = entries.first { $0.kind == .external }
            guard let apple, let old else { return false }
            let appleKeys = try AppDatabase.open(at: apple.databaseURL).assets().map(\.localIdentifier).sorted()
            let oldKeys = try AppDatabase.open(at: old.databaseURL).assets().map(\.localIdentifier)
            let keyCopied = FileManager.default.fileExists(atPath: old.keyURL.path)
            let reloaded = LibraryRegistry(fileURL: support.appendingPathComponent("Libraries.json"))
            let backups = (try? FileManager.default.contentsOfDirectory(atPath: support.appendingPathComponent("Backups").path)) ?? []
            print("     split: apple \(appleKeys), \(old.name) \(oldKeys), key copied \(keyCopied), registry \(reloaded.entries.count), backups \(backups.count)")
            return appleKeys == ["S1", "S2"] && oldKeys == ["pkg:E1"] && keyCopied && reloaded.entries.count == 2 && !backups.isEmpty
        }
        attempt("analysis, faces and people carry over between libraries") {
            let cipher = try VectorCipher(store: .file(dir.appendingPathComponent("carry.key")))
            let a = try AppDatabase.open(at: dir.appendingPathComponent("carryA.sqlite"))
            let b = try AppDatabase.open(at: dir.appendingPathComponent("carryB.sqlite"))
            let sa = try a.systemSourceID(), sb = try b.systemSourceID()
            let now = Date()
            try a.upsert([AssetUpsert(localIdentifier: "APPLE-1", mediaType: "image", subtypeMask: 0, creationDate: now, modificationDate: now,
                                      pixelWidth: 640, pixelHeight: 640, duration: 0, favorite: false, hidden: false, burstIdentifier: nil)],
                         sourceID: sa, scanStamp: now)
            try b.upsert([AssetUpsert(localIdentifier: "pf:NEW-1", mediaType: "image", subtypeMask: 0, creationDate: now, modificationDate: now,
                                      pixelWidth: 640, pixelHeight: 640, duration: 0, favorite: false, hidden: false, burstIdentifier: nil)],
                         sourceID: sb, scanStamp: now)
            let aid = try a.assets()[0].id, bid = try b.assets()[0].id
            try a.saveAnalysis(assetID: aid, pHash: h1!.pHash, dHash: h1!.dHash, laplacianVariance: 100, noiseSigma: 2, meanLuma: 120,
                               clipped: 0, sharpness: 0.5, noise: 0.8, exposure: 0.9, sceneEmbedding: nil, cipher: cipher)
            let f = NewFace(box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), quality: 0.9, yaw: 0, pitch: 0, roll: 0,
                            pixelSize: 120, cropPath: nil, embedding: [0.6, 0.8, 0])
            try a.replaceFaces(assetID: aid, faces: [f], modelName: "sface", modelVersion: "1", cipher: cipher)
            _ = try a.createPerson(named: "Ravi", faceIDs: [try a.storedFaces(cipher: cipher)[0].id], sourceID: sa)
            try a.setTitles([(assetID: aid, title: "Ravi at the farm")])
            let n = try b.copyAnalysis(from: a, sourceCipher: cipher, cipher: cipher, mapping: [aid: bid],
                                       sourceCropDir: dir.appendingPathComponent("cropsA"), cropDir: dir.appendingPathComponent("cropsB"), newSourceID: sb)
            let faces = try b.storedFaces(cipher: cipher), people = try b.persons()
            let row = try b.assets()[0]
            print("     carried \(n) item(s): faces \(faces.count), people \(people.map { $0.displayName ?? "?" }), name \(row.displayName), pHash \(row.pHash != nil)")
            return faces.count == 1 && faces[0].embedding == [0.6, 0.8, 0] && people.first?.displayName == "Ravi"
                && people.first?.confirmedFaceIDs == [faces[0].id] && row.pHash == h1!.pHash && row.displayName == "Ravi at the farm"
        }
        attempt("database backups") {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("bk"), withIntermediateDirectories: true)
            let db = try AppDatabase.open(at: dir.appendingPathComponent("bk/lib.sqlite"))
            let u = try db.backup(reason: "test")
            let ro = try AppDatabase.openReadOnly(at: u)
            return FileManager.default.fileExists(atPath: u.path) && (try? ro.assets()) != nil
        }

        // 19. Sharing API: request parsing, tokens and permissions
        do {
            let secret = "pf_test_secret"
            let tokens = [APIToken(name: "Viewer", secretHash: LocalAPIServer.hash(secret), scopes: [.read, .thumbnails])]
            func req(_ line: String, auth: String?) -> LocalAPIServer.Request? {
                var head = "\(line) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                if let auth { head += "Authorization: \(auth)\r\n" }
                return LocalAPIServer.parse(Data(head.utf8))
            }
            let noAuth = req("GET /v1/assets?type=video&limit=5", auth: nil)
            check(noAuth?.path == "/v1/assets" && noAuth?.query["type"] == "video" && noAuth?.query["limit"] == "5", "API request parsing")
            func status(_ r: LocalAPIServer.Request?) -> Int {
                guard let r else { return 400 }
                switch LocalAPIServer.authenticate(r, tokens: tokens) {
                case .failure(let resp): return resp.status
                case .success(let i): return tokens[i].scopes.contains(LocalAPIServer.requiredScope(r.path)) ? 200 : 403
                }
            }
            let s1 = status(noAuth)
            let s2 = status(req("GET /v1/assets", auth: "Bearer wrong"))
            let s3 = status(req("GET /v1/assets", auth: "Bearer \(secret)"))
            let s4 = status(req("GET /v1/assets/3/thumbnail", auth: "Bearer \(secret)"))
            let s5 = status(req("GET /v1/assets/3/original", auth: "Bearer \(secret)"))
            print("     API: no token \(s1), wrong \(s2), list \(s3), thumbnail \(s4), original \(s5)")
            check(s1 == 401 && s2 == 401 && s3 == 200 && s4 == 200 && s5 == 403, "API tokens and permissions")
        }

        // 20. Renaming rules
        do {
            var r = BatchRename(); r.mode = .pattern; r.pattern = "Farm {n}"; r.start = 1; r.padding = 3
            let names = r.apply(to: ["a.jpg", "b.jpg"].map { BatchRename.Item(currentName: $0, date: nil, camera: nil) })
            check(names == ["Farm 001", "Farm 002"], "batch rename (\(names))")
        }

        print(failures == 0 ? "SELFTEST OK" : "SELFTEST FAILED (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }

    /// A short H.264 clip (320×240) made from a still, for the video checks.
    static func makeVideo(at url: URL, frames: Int, image: CGImage) -> Bool {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240])
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
            guard let pool = adaptor.pixelBufferPool else { return false }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let buf = pb else { return false }
            CVPixelBufferLockBaseAddress(buf, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: 320, height: 240, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(buf), space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
                ctx.draw(image, in: CGRect(x: -CGFloat(i * 4), y: 0, width: 400, height: 400))
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            guard adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 10)) else { return false }
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        return writer.status == .completed
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

    // MARK: Fixtures for library tests

    static func writeJPEG(_ img: CGImage, to url: URL, exifDate: String? = nil, tiff: [CFString: Any]? = nil,
                          exposure: Double? = nil) throws {
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        var exif: [CFString: Any] = [:]
        if let exifDate { exif[kCGImagePropertyExifDateTimeOriginal] = exifDate }
        if let exposure { exif[kCGImagePropertyExifExposureTime] = exposure }
        if !exif.isEmpty { props[kCGImagePropertyExifDictionary] = exif }
        if let tiff { props[kCGImagePropertyTIFFDictionary] = tiff }
        CGImageDestinationAddImage(d, img, props as CFDictionary)
        guard CGImageDestinationFinalize(d) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Minimal Photos 5+ layout: database/Photos.sqlite with a ZASSET table, originals/, and a derivative.
    static func makeFakePhotosLibrary(at lib: URL, image: CGImage) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: lib.appendingPathComponent("database"), withIntermediateDirectories: true)
        try fm.createDirectory(at: lib.appendingPathComponent("originals/A"), withIntermediateDirectories: true)
        try fm.createDirectory(at: lib.appendingPathComponent("resources/derivatives/C"), withIntermediateDirectories: true)
        try writeJPEG(image, to: lib.appendingPathComponent("originals/A/LOCAL-1.jpeg"))
        try writeJPEG(image, to: lib.appendingPathComponent("originals/A/SHOT-4.png"))
        try writeJPEG(image, to: lib.appendingPathComponent("resources/derivatives/C/CLOUD-2_1_105_c.jpeg"))   // original only in iCloud
        var db: OpaquePointer?
        guard sqlite3_open(lib.appendingPathComponent("database/Photos.sqlite").path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE ZASSET (Z_PK INTEGER PRIMARY KEY, ZUUID TEXT, ZDIRECTORY TEXT, ZFILENAME TEXT, ZDATECREATED REAL,
            ZMODIFICATIONDATE REAL, ZWIDTH INTEGER, ZHEIGHT INTEGER, ZKIND INTEGER, ZKINDSUBTYPE INTEGER,
            ZFAVORITE INTEGER, ZHIDDEN INTEGER, ZTRASHEDSTATE INTEGER, ZDURATION REAL, ZAVALANCHEUUID TEXT, ZSOMETHINGNEW TEXT);
        INSERT INTO ZASSET VALUES (1,'LOCAL-1','A','LOCAL-1.jpeg', 700000000, 700000000, 640, 640, 0, 0, 1, 0, 0, 0, NULL, 'x');
        INSERT INTO ZASSET VALUES (2,'CLOUD-2','C','CLOUD-2.heic', 700000100, 700000100, 4032, 3024, 0, 0, 0, 0, 0, 0, NULL, 'x');
        INSERT INTO ZASSET VALUES (3,'TRASH-3','A','TRASH-3.jpeg', 700000200, 700000200, 640, 640, 0, 0, 0, 0, 1, 0, NULL, 'x');
        INSERT INTO ZASSET VALUES (4,'SHOT-4','A','SHOT-4.png', 700000300, 700000300, 640, 640, 0, 10, 0, 0, 0, 0, NULL, 'x');
        CREATE TABLE ZGENERICALBUM (Z_PK INTEGER PRIMARY KEY, ZKIND INTEGER, ZTITLE TEXT, ZPARENTFOLDER INTEGER, ZTRASHEDSTATE INTEGER);
        INSERT INTO ZGENERICALBUM VALUES (1, 3999, NULL, NULL, 0), (2, 4000, 'Trips', 1, 0), (3, 2, 'Goa', 2, 0),
                                         (4, 2, 'Bills', 1, 0), (5, 2, 'Deleted album', 1, 1);
        CREATE TABLE Z_26ASSETS (Z_26ALBUMS INTEGER, Z_3ASSETS INTEGER, Z_FOK_3ASSETS INTEGER);
        INSERT INTO Z_26ASSETS VALUES (3, 1, 1), (4, 4, 1), (5, 2, 1);
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }

    /// A white "page" with typed lines on a grey desk, like a photographed invoice.
    static func makeDocument(lines: [String]) -> CGImage? {
        let W = 1500, H = 2000
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.35, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        let page = CGRect(x: 180, y: 160, width: 1140, height: 1680)
        ctx.setFillColor(CGColor(gray: 0.98, alpha: 1)); ctx.fill(page)
        let font = CTFontCreateWithName("Helvetica" as CFString, 46, nil)
        for (i, line) in lines.enumerated() {
            let attr = NSAttributedString(string: line, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.05, alpha: 1)])
            let ctLine = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: page.minX + 80, y: page.maxY - 140 - CGFloat(i) * 118)
            CTLineDraw(ctLine, ctx)
        }
        return ctx.makeImage()
    }

    static func makeQR(_ text: String) -> CGImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(text.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let qr = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 16, y: 16)) else { return nil }
        let canvas = CIImage(color: .white).cropped(to: qr.extent.insetBy(dx: -80, dy: -80))
        let img = qr.composited(over: canvas)
        return CIContext().createCGImage(img, from: img.extent)
    }
}
