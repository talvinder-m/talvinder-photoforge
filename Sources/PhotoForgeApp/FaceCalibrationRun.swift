import Foundation
import PFSimilarity
import CoreGraphics
import ImageIO
import PFCore
import PFVision
import PFPeople

/// `PhotoForge --facecal <dir>`: measures face-grouping accuracy on a labelled folder
/// (<dir>/<person>/<image>.jpg) using the app's own detect → align → embed → cluster path,
/// for every available embedder. Prints same/different-person cosine statistics and
/// pairwise precision/recall of the clusterer across thresholds. Used by CI to calibrate
/// `FaceCalibration`; never run on user photos.
enum FaceCalibrationRun {
    struct Sample { let person: String; let crop: CGImage; let quality: Double; let size: Double }

    static func runAndExit(dir: URL) -> Never {
        let fm = FileManager.default
        let people = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.hasDirectoryPath }.sorted { $0.path < $1.path }
        let detector = FaceDetector()
        var samples: [Sample] = []
        var missed = 0
        for p in people {
            let files = ((try? fm.contentsOfDirectory(at: p, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }
            for f in files {
                guard let src = CGImageSourceCreateWithURL(f as CFURL, nil),
                      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
                // LFW frames are centred on one person: take the largest detected face.
                let faces = ((try? detector.detect(in: img)) ?? []).filter { $0.alignedCrop != nil }
                guard let best = faces.max(by: { $0.pixelSize < $1.pixelSize }), let crop = best.alignedCrop else { missed += 1; continue }
                samples.append(Sample(person: p.lastPathComponent, crop: crop,
                                      quality: Double(best.captureQuality ?? 0.5), size: Double(best.pixelSize)))
            }
        }
        print("FACECAL: \(people.count) people, \(samples.count) faces aligned, \(missed) images without a usable face")

        let face = FaceEmbedding.load()
        var embedders: [(String, any ImageEmbeddingModel)] = [("vision-featureprint", VisionFeaturePrintEmbedder(purpose: .faceEmbedding))]
        if face.isDedicatedFaceModel { embedders.insert(("sface", face.model), at: 0) }
        else { print("FACECAL: SFace model NOT bundled — only feature prints evaluated") }

        for (name, model) in embedders {
            let sem = DispatchSemaphore(value: 0)
            var vecs: [[Float]] = []
            Task.detached {
                for s in samples { vecs.append((try? await model.embed([s.crop]).first) ?? []) }
                sem.signal()
            }
            sem.wait()
            report(name: name, samples: samples, vectors: vecs)
        }
        exit(0)
    }

    static func report(name: String, samples: [Sample], vectors: [[Float]]) {
        let n = samples.count
        var same: [Double] = [], diff: [Double] = []
        for i in 0..<n { for j in (i + 1)..<max(i + 1, n) where !vectors[i].isEmpty && !vectors[j].isEmpty {
            let c = Double(VectorMath.dot(vectors[i], vectors[j]))
            if samples[i].person == samples[j].person { same.append(c) } else { diff.append(c) }
        } }
        func pct(_ a: [Double], _ p: Double) -> Double { let s = a.sorted(); return s.isEmpty ? .nan : s[min(s.count - 1, Int(Double(s.count - 1) * p))] }
        print("")
        print("== \(name): \(same.count) same-person pairs, \(diff.count) different-person pairs")
        print(String(format: "   same   p5 %.3f  p50 %.3f  p95 %.3f", pct(same, 0.05), pct(same, 0.5), pct(same, 0.95)))
        print(String(format: "   diff   p5 %.3f  p50 %.3f  p95 %.3f  p99 %.3f", pct(diff, 0.05), pct(diff, 0.5), pct(diff, 0.95), pct(diff, 0.99)))

        // Best single pairwise threshold (balanced accuracy)
        var bestT = 0.0, bestAcc = 0.0
        for t in stride(from: -0.2, through: 0.99, by: 0.01) {
            let tpr = Double(same.filter { $0 >= t }.count) / Double(max(1, same.count))
            let tnr = Double(diff.filter { $0 < t }.count) / Double(max(1, diff.count))
            if (tpr + tnr) / 2 > bestAcc { bestAcc = (tpr + tnr) / 2; bestT = t }
        }
        print(String(format: "   best pairwise threshold %.2f → balanced accuracy %.1f%%", bestT, bestAcc * 100))

        // Clusterer sweep: pairwise precision / recall over faces the clusterer assigned.
        let faceSamples = samples.indices.compactMap { i -> FaceSample? in
            vectors[i].isEmpty ? nil : FaceSample(id: FaceID(Int64(i)), embedding: vectors[i], quality: samples[i].quality, pixelSize: samples[i].size)
        }
        print("   clusterer sweep (base threshold → clusters, precision, recall, faces sent to review):")
        for step in 0...12 {
            let t = bestT - 0.18 + Double(step) * 0.03
            var c = FaceClusterer()
            c.config.baseThreshold = Float(t)
            c.config.minClusterSize = 2
            let r = c.cluster(faceSamples, index: BruteForceIndex(faceSamples))
            var home: [Int: Int] = [:]
            for (ci, cl) in r.clusters.enumerated() { for f in cl.faces { home[Int(f.rawValue)] = ci } }
            var tp = 0, fp = 0, fn = 0
            let ids = faceSamples.map { Int($0.id.rawValue) }
            for a in 0..<ids.count { for b in (a + 1)..<max(a + 1, ids.count) {
                let sameP = samples[ids[a]].person == samples[ids[b]].person
                let together = home[ids[a]] != nil && home[ids[a]] == home[ids[b]]
                if together && sameP { tp += 1 } else if together { fp += 1 } else if sameP { fn += 1 }
            } }
            let prec = Double(tp) / Double(max(1, tp + fp)), rec = Double(tp) / Double(max(1, tp + fn))
            let reasons = Dictionary(grouping: r.review, by: { $0.reason.rawValue }).mapValues(\.count)
                .sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            print(String(format: "     %.2f → %2d clusters, precision %5.1f%%, recall %5.1f%%, review %d",
                         t, r.clusters.count, prec * 100, rec * 100, r.review.count) + (reasons.isEmpty ? "" : " (\(reasons))"))
        }
    }
}


/// `PhotoForge --srbench <dir>`: upscaling quality on real photos. Each photo is shrunk by 2×
/// and 4× (Lanczos), then brought back to its original size by every method; reports PSNR
/// against the original and a sharpness ratio (Laplacian variance vs the original).
enum UpscaleBenchmark {
    static func runAndExit(dir: URL) -> Never {
        let fm = FileManager.default
        var files: [URL] = []
        if let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil) {
            for case let f as URL in e where ["jpg", "jpeg", "png"].contains(f.pathExtension.lowercased()) { files.append(f) }
        }
        files = Array(files.sorted { $0.path < $1.path }.prefix(24))
        let sr = SuperResolution(modelsDirectory: Bundle.main.resourceURL?.appendingPathComponent("Models"))
        print("SRBENCH: \(files.count) photos")
        for factor in [2, 4] {
            var psnr: [SuperResolution.Method: [Double]] = [:], sharp: [SuperResolution.Method: [Double]] = [:]
            var secs: [SuperResolution.Method: Double] = [:]
            for f in files {
                guard let src = CGImageSourceCreateWithURL(f as CFURL, nil),
                      let full = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
                let W = full.width / (factor * 4) * factor * 4, H = full.height / (factor * 4) * factor * 4
                guard W >= 64, H >= 64, let orig = full.cropping(to: CGRect(x: 0, y: 0, width: W, height: H)),
                      let small = sr.lanczos(orig, width: W / factor, height: H / factor) else { continue }
                let target = max(W, H)
                for m in SuperResolution.Method.allCases where sr.isAvailable(m) {
                    let sem = DispatchSemaphore(value: 0)
                    var out: SuperResolution.Result?
                    Task.detached { out = try? await sr.upscale(small, targetLongEdge: target, method: m); sem.signal() }
                    sem.wait()
                    guard let r = out, r.image.width == W, r.image.height == H else { continue }
                    psnr[m, default: []].append(SuperResolution.psnr(r.image, orig) ?? 0)
                    sharp[m, default: []].append(sharpness(r.image) / max(1e-6, sharpness(orig)))
                    secs[m, default: 0] += r.seconds
                }
            }
            print("  ×\(factor):")
            for m in SuperResolution.Method.allCases {
                guard let p = psnr[m], !p.isEmpty else { continue }
                let s = sharp[m] ?? []
                print(String(format: "    %-24@ PSNR %.2f dB   sharpness %.0f%% of original   %.2f s/photo",
                             m.label as NSString, p.reduce(0, +) / Double(p.count),
                             100 * s.reduce(0, +) / Double(max(1, s.count)), (secs[m] ?? 0) / Double(p.count)))
            }
        }
        exit(0)
    }

    static func sharpness(_ img: CGImage) -> Double {
        let (w, h) = (min(img.width, 512), min(img.height, 512))
        guard let crop = img.cropping(to: CGRect(x: 0, y: 0, width: w, height: h)),
              let luma = LumaImage.from(crop, width: w, height: h) else { return 0 }
        return QualityMetrics.measure(luma).laplacianVariance
    }
}
