import Testing
import Foundation
@testable import PFPeople
import PFCore

/// Synthetic identities: a random unit centre per person plus small per-face jitter
/// (cos ≈ 0.97 to centre), like well-behaved ArcFace embeddings. Same construction
/// as the clustering scenario in tools/reference_check.py.
func identity(_ count: Int, seed: UInt64, firstID: Int64, dim: Int = 128, spread: Float = 0.25) -> [FaceSample] {
    var rng = SplitMix64(seed: seed)
    func gauss() -> Float {
        let u1 = max(1e-12, Double(rng.next() >> 11) / Double(1 << 53)), u2 = Double(rng.next() >> 11) / Double(1 << 53)
        return Float((-2 * log(u1)).squareRoot() * cos(2 * .pi * u2))
    }
    func unit(_ v: [Float]) -> [Float] { let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot(); return v.map { $0 / n } }
    let centre = unit((0..<dim).map { _ in gauss() })
    let s = spread / Float(dim).squareRoot()
    return (0..<count).map { i in
        FaceSample(id: FaceID(firstID + Int64(i)), embedding: unit(centre.map { $0 + s * gauss() }),
                   quality: 0.9, pixelSize: 150)
    }
}

@Suite("Constrained face clustering")
struct ClusteringTests {
    let A = identity(12, seed: 1, firstID: 1)      // ids 1…12
    let B = identity(10, seed: 2, firstID: 13)     // ids 13…22
    let C = identity(8, seed: 3, firstID: 23)      // ids 23…30
    var all: [FaceSample] { A + B + C }

    func homes(_ r: ClusteringResult) -> [FaceID: Int] {
        Dictionary(uniqueKeysWithValues: r.clusters.enumerated().flatMap { i, c in c.faces.map { ($0, i) } })
    }

    @Test func recoversDistinctPeople() {
        let r = FaceClusterer().cluster(all, index: BruteForceIndex(all))
        #expect(r.clusters.map(\.faces.count).sorted() == [8, 10, 12])
        // Unconfirmed groups are never labelled "Confirmed".
        #expect(r.clusters.allSatisfy { $0.confidence != .confirmed && $0.existingPerson == nil })
    }

    @Test func lowQualityFacesGoToReviewNotToAPerson() {
        let blurry = FaceSample(id: FaceID(99), embedding: A[0].embedding, quality: 0.1, pixelSize: 40)
        let faces = all + [blurry]
        let r = FaceClusterer().cluster(faces, index: BruteForceIndex(faces))
        #expect(r.review.contains { $0.face == FaceID(99) && $0.reason == .lowQuality })
        #expect(homes(r)[FaceID(99)] == nil)
    }

    @Test func cannotLinkSeparatesFaces() {
        var c = ClusteringConstraints(); c.cannotLink = [(FaceID(1), FaceID(2))]
        let h = homes(FaceClusterer().cluster(all, index: BruteForceIndex(all), constraints: c))
        #expect(h[FaceID(1)] == nil || h[FaceID(2)] == nil || h[FaceID(1)] != h[FaceID(2)])
    }

    @Test func mustLinkKeepsFacesTogether() {
        var c = ClusteringConstraints(); c.mustLink = [(FaceID(1), FaceID(13))]    // user: "same person"
        let h = homes(FaceClusterer().cluster(all, index: BruteForceIndex(all), constraints: c))
        #expect(h[FaceID(1)] != nil && h[FaceID(1)] == h[FaceID(13)])
    }

    @Test func confirmedPersonsAreStableAndNeverMerged() {
        var c = ClusteringConstraints()
        c.confirmed = [FaceID(1): PersonID(501), FaceID(2): PersonID(501), FaceID(13): PersonID(777)]
        let r = FaceClusterer().cluster(all, index: BruteForceIndex(all), constraints: c)
        #expect(Set(r.clusters.compactMap(\.existingPerson)) == [PersonID(501), PersonID(777)])
        #expect(r.clusters.filter { $0.confidence == .confirmed }.count == 2)
        let h = homes(r)
        #expect(h[FaceID(1)] != h[FaceID(13)])
    }

    @Test func clusteringIsDeterministic() {
        let a = FaceClusterer().cluster(all, index: BruteForceIndex(all))
        let b = FaceClusterer().cluster(all, index: BruteForceIndex(all))
        #expect(a.clusters.map(\.faces) == b.clusters.map(\.faces))
    }

    @Test func adaptiveThresholdRisesForPoorPairs() {
        let good = FaceSample(id: FaceID(1), embedding: [1], quality: 1, pixelSize: 200)
        let poor = FaceSample(id: FaceID(2), embedding: [1], quality: 0.4, pixelSize: 40)
        let k = FaceClusterer()
        #expect(k.threshold(good, poor) > k.threshold(good, good))
    }
}

@Suite struct FaceNeighborCacheTests {
    static func randomFaces(_ n: Int, dim: Int = 16, seed: UInt64 = 7, startID: Int64 = 1) -> [FaceSample] {
        var rng = SplitMix64(seed: seed)
        return (0..<n).map { i in
            var v = (0..<dim).map { _ in Float(rng.next() % 2000) / 1000 - 1 }
            let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
            v = v.map { $0 / norm }
            return FaceSample(id: FaceID(startID + Int64(i)), embedding: v, quality: 0.9, pixelSize: 120)
        }
    }

    @Test func matchesBruteForce() {
        let faces = Self.randomFaces(300)
        let cache = FaceNeighborCache(k: 10, minSimilarity: -2)
        cache.update(faces)
        let brute = BruteForceIndex(faces)
        for f in faces.prefix(40) {
            let a = cache.neighbors(of: f.id, k: 10).map(\.0)
            let b = brute.neighbors(of: f.id, k: 10).map(\.0)
            #expect(a == b)
        }
    }

    @Test func incrementalEqualsFullBuild() {
        let faces = Self.randomFaces(240)
        let full = FaceNeighborCache(k: 8, minSimilarity: -2)
        full.update(faces)
        let inc = FaceNeighborCache(k: 8, minSimilarity: -2)
        inc.update(Array(faces.prefix(150)))
        let r = inc.update(faces)
        #expect(r.added == 90 && r.removed == 0)
        for f in faces { #expect(inc.neighbors(of: f.id, k: 8).map(\.0) == full.neighbors(of: f.id, k: 8).map(\.0)) }
    }

    @Test func removedFacesDisappear() {
        let faces = Self.randomFaces(100)
        let cache = FaceNeighborCache(k: 8, minSimilarity: -2)
        cache.update(faces)
        let kept = Array(faces.dropFirst(10))
        let r = cache.update(kept)
        #expect(r.removed == 10 && cache.count == 90)
        let gone = Set(faces.prefix(10).map(\.id))
        for f in kept { #expect(cache.neighbors(of: f.id, k: 8).allSatisfy { !gone.contains($0.0) }) }
    }
}
