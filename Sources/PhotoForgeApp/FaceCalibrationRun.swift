import Foundation
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
            print(String(format: "     %.2f → %2d clusters, precision %5.1f%%, recall %5.1f%%, review %d",
                         t, r.clusters.count, prec * 100, rec * 100, r.review.count))
        }
    }
}
