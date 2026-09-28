import Testing
import Foundation
@testable import PFSimilarity
import PFCore

// Fixtures mirror tools/reference_check.py, where the same scenarios are verified numerically.

struct Rand {
    var g: SplitMix64Test
    init(_ seed: UInt64) { g = SplitMix64Test(seed: seed) }
    mutating func uniform(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * Double(g.next() >> 11) / Double(1 << 53) }
}
struct SplitMix64Test { var s: UInt64
    init(seed: UInt64) { s = seed }
    mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
}

/// 32×32 scene of Gaussian blobs — a broad-spectrum stand-in for a photo.
func blobScene(_ seed: UInt64, size n: Int = 32) -> LumaImage {
    var r = Rand(seed)
    var px = [Float](repeating: 60, count: n * n)
    for _ in 0..<12 {
        let cx = r.uniform(0, Double(n)), cy = r.uniform(0, Double(n)), s = r.uniform(2, 8), a = r.uniform(-40, 60)
        for y in 0..<n { for x in 0..<n {
            let d = (Double(x) - cx) * (Double(x) - cx) + (Double(y) - cy) * (Double(y) - cy)
            px[y * n + x] += Float(a * exp(-d / (2 * s * s)))
        } }
    }
    return LumaImage(width: n, height: n, pixels: px.map { min(255, max(0, $0)) })
}

@Suite("Perceptual hashing")
struct HashTests {
    @Test func exposureChangeDoesNotMoveHash() {
        // pHash is invariant to positive affine intensity changes: scale multiplies every
        // DCT coefficient equally and offset only touches DC, which is always above the median.
        for seed in UInt64(1)...20 {
            let a = blobScene(seed)
            let b = LumaImage(width: 32, height: 32, pixels: a.pixels.map { $0 * 1.1 + 5 })
            #expect(PerceptualHash.hamming(PerceptualHash.pHash(a), PerceptualHash.pHash(b)) == 0)
        }
    }

    @Test func differentScenesAreFarApart() {
        for seed in UInt64(1)...20 {
            let d = PerceptualHash.hamming(PerceptualHash.pHash(blobScene(seed)), PerceptualHash.pHash(blobScene(seed + 500)))
            #expect(d >= 12)   // reference run: min 18 over 200 pairs
        }
    }

    @Test func storageRoundTripPreservesBits() {
        for h: UInt64 in [0, 1, .max, 0x8000_0000_0000_0000, 0x0F0F_F0F0_1234_5678] {
            #expect(PerceptualHash.fromStorage(PerceptualHash.toStorage(h)) == h)
        }
    }

    @Test func dHashDetectsGradientDirection() {
        let rising = LumaImage(width: 9, height: 8, pixels: (0..<72).map { Float($0 % 9) * 20 })
        let falling = LumaImage(width: 9, height: 8, pixels: (0..<72).map { Float(8 - $0 % 9) * 20 })
        #expect(PerceptualHash.dHash(rising) == .max)
        #expect(PerceptualHash.dHash(falling) == 0)
    }

    @Test func bkTreeMatchesBruteForce() {
        var r = SplitMix64Test(seed: 42)
        let hashes = (0..<2_000).map { _ in r.next() }
        var tree = HammingBKTree<Int>()
        for (i, h) in hashes.enumerated() { tree.insert(h, id: i) }
        let q = hashes[5] ^ 0b1011
        let brute = hashes.indices.filter { PerceptualHash.hamming(q, hashes[$0]) <= 10 }.sorted()
        #expect(tree.query(q, radius: 10).map(\.id).sorted() == brute)
        #expect(brute.contains(5))
    }
}

@Suite("Quality metrics")
struct QualityTests {
    @Test func noiseEstimateIsCalibrated() {
        // Flat grey + Gaussian noise σ=8 (Box–Muller). Reference estimate: 7.99.
        var r = Rand(9)
        let n = 128
        let px: [Float] = (0..<(n * n)).map { _ in
            let u1 = max(1e-12, r.uniform(0, 1)), u2 = r.uniform(0, 1)
            return Float(120 + 8 * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2))
        }
        let m = QualityMetrics.measure(LumaImage(width: n, height: n, pixels: px))
        #expect(abs(m.noiseSigma - 8) < 1)
        #expect(QualityMetrics.measure(LumaImage(width: n, height: n, pixels: .init(repeating: 120, count: n * n))).noiseSigma < 0.01)
    }

    @Test func sharpBeatsBlurred() {
        let sharp = blobScene(3, size: 64)
        var blur = sharp.pixels
        for _ in 0..<4 {
            var next = blur
            for y in 1..<63 { for x in 1..<63 {
                next[y * 64 + x] = (blur[(y - 1) * 64 + x] + blur[(y + 1) * 64 + x] + blur[y * 64 + x - 1] + blur[y * 64 + x + 1] + blur[y * 64 + x]) / 5
            } }
            blur = next
        }
        let a = QualityMetrics.measure(sharp), b = QualityMetrics.measure(LumaImage(width: 64, height: 64, pixels: blur))
        #expect(a.laplacianVariance > b.laplacianVariance)
        #expect(a.sharpnessScore > b.sharpnessScore)
    }
}

@Suite("Duplicate grouping and best-shot scoring")
struct GroupingTests {
    func unit(_ v: [Float]) -> [Float] { let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot(); return v.map { $0 / n } }
    func vec(_ seed: UInt64) -> [Float] { var r = Rand(seed); return unit((0..<64).map { _ in Float(r.uniform(-1, 1)) }) }
    func jitter(_ v: [Float], _ seed: UInt64) -> [Float] { var r = Rand(seed); return unit(v.map { $0 + Float(r.uniform(-0.03, 0.03)) }) }
    func q(_ lap: Double, _ noise: Double, _ mean: Double) -> QualityMetrics {
        QualityMetrics(laplacianVariance: lap, noiseSigma: noise, meanLuma: mean, clippedFraction: 0)
    }

    /// 1,2 byte-identical · 3,4 near (tiny hash distance) · 5,6 PhotoKit burst · 7 unrelated
    func library() -> [AssetFeatures] {
        let P: UInt64 = 0x0F0F_F0F0_1234_5678, D: UInt64 = 0x1111_2222_3333_4444
        let base = vec(1), other = vec(2), near = jitter(base, 3)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        func make(_ id: Int64, sha: UInt8, size: Int, w: Int, h: Int, p: UInt64, d: UInt64, e: [Float],
                  dt: TimeInterval, qm: QualityMetrics, fav: Bool = false, burst: String? = nil) -> AssetFeatures {
            var a = AssetFeatures(id: AssetID(id), pixelWidth: w, pixelHeight: h)
            a.fileHash = Data([sha]); a.fileSize = size; a.pHash = p; a.dHash = d; a.embedding = e
            a.captureDate = t0.addingTimeInterval(dt); a.quality = qm; a.isFavorite = fav; a.burstIdentifier = burst
            return a
        }
        return [
            make(1, sha: 0xA, size: 100, w: 4000, h: 3000, p: P, d: D, e: base, dt: 0, qm: q(200, 3, 118)),
            make(2, sha: 0xA, size: 100, w: 4000, h: 3000, p: P, d: D, e: base, dt: 60, qm: q(200, 3, 118)),
            make(3, sha: 0xB, size: 90, w: 4000, h: 3000, p: P ^ 0b111, d: D ^ 0b11, e: near, dt: 120, qm: q(600, 2, 120), fav: true),
            make(4, sha: 0xC, size: 40, w: 2000, h: 1500, p: P ^ 0b11, d: D ^ 0b1, e: near, dt: 130, qm: q(90, 6, 80)),
            make(5, sha: 0xD, size: 80, w: 4000, h: 3000, p: ~P, d: ~D, e: other, dt: 5000, qm: q(300, 3, 118), burst: "B1"),
            make(6, sha: 0xE, size: 81, w: 4000, h: 3000, p: ~P ^ (1 << 40 - 1), d: ~D ^ (1 << 40 - 1), e: other, dt: 5001, qm: q(500, 2, 118), burst: "B1"),
            make(7, sha: 0xF, size: 70, w: 4000, h: 3000, p: 0xAAAA_5555_AAAA_5555, d: 0x5555_AAAA_5555_AAAA, e: vec(7), dt: 9000, qm: q(300, 3, 118)),
        ]
    }

    @Test func exactAndNearDuplicatesAreSeparateGroups() {
        let groups = DuplicateGrouper().groups(for: library())
        let byType = Dictionary(uniqueKeysWithValues: groups.map { ($0.type, $0.members.map(\.rawValue)) })
        #expect(groups.count == 3)
        #expect(byType[.exact] == [1, 2])
        #expect(byType[.near] == [3, 4])
        #expect(byType[.burst] == [5, 6])
        #expect(!groups.flatMap(\.members).contains(AssetID(7)))
    }

    @Test func bestShotIsExplained() throws {
        let near = try #require(DuplicateGrouper().groups(for: library()).first { $0.type == .near })
        #expect(near.recommended == AssetID(3))
        #expect(near.explanation.hasPrefix("Recommended because it has the sharpest, cleanest detail"))
    }

    @Test func notSimilarFeedbackIsRespected() {
        var ex = SimilarityExclusions()
        ex.notSimilarPairs = [.init(AssetID(4), AssetID(3))]      // order-independent
        #expect(!DuplicateGrouper().groups(for: library(), exclusions: ex).contains { $0.type == .near })
    }

    @Test func excludedAssetsNeverAppear() {
        var ex = SimilarityExclusions(); ex.excludedAssets = [AssetID(1)]
        let groups = DuplicateGrouper().groups(for: library(), exclusions: ex)
        #expect(!groups.flatMap(\.members).contains(AssetID(1)))
        #expect(!groups.contains { $0.type == .exact })
    }

    @Test func missingFactorsAreNotPenalised() {
        // No faces anywhere: face weight is redistributed, scores still span 0…1.
        let ranked = BestShotScorer().rank(library().filter { [3, 4].contains($0.id.rawValue) })
        #expect(ranked.first?.components[.faceQuality] == nil)
        #expect(abs((ranked.first?.score ?? 0) - 1) < 1e-9)
    }
}
