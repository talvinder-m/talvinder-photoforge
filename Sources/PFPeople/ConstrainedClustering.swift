import Foundation
import PFCore

// MARK: - Inputs

public struct FaceSample: Sendable {
    public let id: FaceID
    public let embedding: [Float]      // unit length
    public let quality: Double         // Vision capture quality 0…1
    public let pixelSize: Double       // face height in source pixels
    public let yaw: Double?            // radians, nil if unknown
    public let captureDate: Date?
    public init(id: FaceID, embedding: [Float], quality: Double, pixelSize: Double,
                yaw: Double? = nil, captureDate: Date? = nil) {
        self.id = id; self.embedding = embedding; self.quality = quality
        self.pixelSize = pixelSize; self.yaw = yaw; self.captureDate = captureDate
    }
}

/// User feedback, stored in `face_constraints` and `person_face_membership`.
public struct ClusteringConstraints: Sendable {
    public var mustLink: [(FaceID, FaceID)] = []
    public var cannotLink: [(FaceID, FaceID)] = []
    /// Faces the user confirmed for an existing person. Keeps person IDs stable across re-clustering.
    public var confirmed: [FaceID: PersonID] = [:]
    public init() {}
}

/// Pluggable nearest-neighbour index. Production uses an on-disk HNSW index
/// (e.g. USearch via SPM); tests use `BruteForceIndex`.
public protocol NeighborIndex: Sendable {
    func neighbors(of id: FaceID, k: Int) -> [(FaceID, Float)]
}

public struct BruteForceIndex: NeighborIndex {
    let samples: [FaceID: [Float]]
    public init(_ faces: [FaceSample]) { samples = Dictionary(uniqueKeysWithValues: faces.map { ($0.id, $0.embedding) }) }
    public func neighbors(of id: FaceID, k: Int) -> [(FaceID, Float)] {
        guard let q = samples[id] else { return [] }
        return samples.lazy.filter { $0.key != id }
            .map { ($0.key, FaceClusterer.dot(q, $0.value)) }
            .sorted { $0.1 > $1.1 }
            .prefix(k).map { $0 }
    }
}

// MARK: - Outputs

public struct FaceCluster: Sendable {
    public var faces: [FaceID]
    public var centroid: [Float]
    public var meanSimilarity: Double          // mean cosine to centroid
    public var confidence: PersonConfidence
    public var existingPerson: PersonID?       // set when the cluster contains confirmed faces
}

public struct ReviewItem: Sendable {
    public enum Reason: String, Sendable { case lowQuality, belowClusterThreshold, constraintConflict, ambiguousBetweenClusters }
    public let face: FaceID
    public let suggestedClusterIndex: Int?
    public let similarity: Double?
    public let reason: Reason
}

public struct ClusteringResult: Sendable {
    public var clusters: [FaceCluster]
    public var review: [ReviewItem]
}

// MARK: - Clusterer

public struct FaceClusterConfig: Sendable {
    public var k = 30                          // graph neighbours per face
    public var baseThreshold: Float = 0.45     // ArcFace-family cosine; calibrate per model
    public var qualityPenalty: Float = 0.15    // raise the bar for low-quality pairs
    public var smallFacePx: Double = 64        // below this, add a further penalty
    public var smallFacePenalty: Float = 0.05
    public var profileYaw: Double = 0.6        // ~35°; profile-vs-frontal pairs get a small penalty
    public var profilePenalty: Float = 0.04
    public var minQualityToCluster: Double = 0.3
    public var minClusterSize = 3              // smaller groups go to review, not to a "person"
    public var maxIterations = 40
    public var ambiguityMargin: Float = 0.05   // best vs second-best cluster
    public var seed: UInt64 = 0x5EED
    public init() {}
}

/// Graph clustering (Chinese Whispers, Biemann 2006) with:
///  • pairwise adaptive edge thresholds (quality, face size, pose),
///  • must-link faces collapsed into super-nodes before propagation,
///  • cannot-link enforced during propagation *and* verified afterwards,
///  • per-cluster acceptance thresholds from the intra-cluster similarity distribution.
public struct FaceClusterer: Sendable {
    public var config = FaceClusterConfig()
    public init() {}

    public func cluster(_ all: [FaceSample], index: any NeighborIndex,
                        constraints: ClusteringConstraints = .init()) -> ClusteringResult {
        var review: [ReviewItem] = []
        let usable = all.filter { f in
            if f.quality < config.minQualityToCluster {
                review.append(.init(face: f.id, suggestedClusterIndex: nil, similarity: nil, reason: .lowQuality))
                return false
            }
            return true
        }
        let byID = Dictionary(uniqueKeysWithValues: usable.map { ($0.id, $0) })

        // 1. Must-link → super-nodes (confirmed faces of the same person are must-linked too).
        var uf = UnionFindFaces()
        for f in usable { _ = uf.find(f.id) }
        for (a, b) in constraints.mustLink where byID[a] != nil && byID[b] != nil { uf.union(a, b) }
        let confirmedByPerson = Dictionary(grouping: constraints.confirmed.filter { byID[$0.key] != nil }, by: { $0.value })
        for (_, faces) in confirmedByPerson { for pair in zip(faces, faces.dropFirst()) { uf.union(pair.0.key, pair.1.key) } }

        // Cannot-link between super-nodes.
        var cannot: [FaceID: Set<FaceID>] = [:]           // keyed by super-node root
        for (a, b) in constraints.cannotLink where byID[a] != nil && byID[b] != nil {
            let ra = uf.find(a), rb = uf.find(b)
            guard ra != rb else { continue }              // contradictory feedback: handled in verification
            cannot[ra, default: []].insert(rb); cannot[rb, default: []].insert(ra)
        }
        // Different confirmed persons can never merge.
        let personRoots = confirmedByPerson.mapValues { uf.find($0[0].key) }
        for (p1, r1) in personRoots { for (p2, r2) in personRoots where p1 != p2 {
            cannot[r1, default: []].insert(r2)
        } }

        // 2. Weighted graph over super-nodes.
        var graph: [FaceID: [FaceID: Float]] = [:]
        for f in usable {
            let rf = uf.find(f.id)
            for (n, sim) in index.neighbors(of: f.id, k: config.k) {
                guard let g = byID[n] else { continue }
                let rn = uf.find(n)
                guard rn != rf, !(cannot[rf]?.contains(rn) ?? false) else { continue }
                if sim >= threshold(f, g) {
                    graph[rf, default: [:]][rn, default: 0] += sim
                    graph[rn, default: [:]][rf, default: 0] += sim
                }
            }
        }

        // 3. Chinese Whispers with cannot-link-aware label adoption.
        let nodes = Set(usable.map { uf.find($0.id) }).sorted()
        var label = Dictionary(uniqueKeysWithValues: nodes.map { ($0, $0) })
        var rng = SplitMix64(seed: config.seed)
        for _ in 0..<config.maxIterations {
            var changed = false
            for node in nodes.shuffled(using: &rng) {
                guard let edges = graph[node], !edges.isEmpty else { continue }
                var score: [FaceID: Float] = [:]
                for (n, w) in edges { score[label[n]!, default: 0] += w }
                let blocked = cannot[node] ?? []
                // A label is forbidden if any node cannot-linked to us currently carries it.
                // (Checks the small blocked set, not every node, so this stays O(edges).)
                let best = score.filter { cand, _ in
                    !blocked.contains { label[$0] == cand }
                }.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }
                if let best, best.key != label[node] { label[node] = best.key; changed = true }
            }
            if !changed { break }
        }

        // 4. Expand super-nodes back to faces and build clusters.
        var membersByLabel: [FaceID: [FaceID]] = [:]
        for f in usable { membersByLabel[label[uf.find(f.id)]!, default: []].append(f.id) }

        var clusters: [FaceCluster] = []
        for (_, faceIDs) in membersByLabel.sorted(by: { $0.key < $1.key }) {
            let samples = faceIDs.compactMap { byID[$0] }
            let person = Set(faceIDs.compactMap { constraints.confirmed[$0] })
            if samples.count < config.minClusterSize && person.isEmpty {
                review.append(contentsOf: faceIDs.map { .init(face: $0, suggestedClusterIndex: nil, similarity: nil, reason: .belowClusterThreshold) })
                continue
            }
            clusters.append(makeCluster(samples, existingPerson: person.count == 1 ? person.first : nil))
        }

        // 5. Verification: evict faces that violate cannot-link or sit below the
        //    cluster's own adaptive threshold (μ − 3σ, floored at the base threshold).
        //    User-confirmed and must-linked faces are protected: feedback always wins.
        let protected = Set(constraints.confirmed.keys).union(constraints.mustLink.flatMap { [$0.0, $0.1] })
        var cannotFaces: [FaceID: Set<FaceID>] = [:]
        for (a, b) in constraints.cannotLink { cannotFaces[a, default: []].insert(b); cannotFaces[b, default: []].insert(a) }
        for ci in clusters.indices {
            var c = clusters[ci]
            let scored = c.faces.map { ($0, Double(Self.dot(byID[$0]!.embedding, c.centroid))) }
            let sims = scored.map(\.1)
            let mu = sims.reduce(0, +) / Double(sims.count)
            let sd = (sims.map { ($0 - mu) * ($0 - mu) }.reduce(0, +) / Double(sims.count)).squareRoot()
            let floor = max(Double(config.baseThreshold), mu - 3 * sd)
            var keep: [FaceID] = []
            // Confirmed faces first, then most central: on a conflict the weaker face is evicted.
            let ordered = scored.sorted {
                let pa = protected.contains($0.0), pb = protected.contains($1.0)
                return pa != pb ? pa : $0.1 > $1.1
            }
            for (f, s) in ordered {
                let isConfirmed = protected.contains(f)
                let conflict = !(cannotFaces[f] ?? []).isDisjoint(with: keep)
                if conflict && !isConfirmed {
                    review.append(.init(face: f, suggestedClusterIndex: ci, similarity: s, reason: .constraintConflict))
                } else if s < floor && !isConfirmed {
                    review.append(.init(face: f, suggestedClusterIndex: ci, similarity: s, reason: .belowClusterThreshold))
                } else { keep.append(f) }
            }
            if keep.count != c.faces.count {
                c = makeCluster(keep.compactMap { byID[$0] }, existingPerson: c.existingPerson)
            }
            clusters[ci] = c
        }

        // 6. Faces close to two clusters are ambiguous → review, never auto-assigned.
        if clusters.count > 1 {
            for ci in clusters.indices {
                let keep = clusters[ci].faces.filter { f in
                    guard !protected.contains(f), let e = byID[f]?.embedding else { return true }
                    let own = Self.dot(e, clusters[ci].centroid)
                    let other = clusters.indices.filter { $0 != ci }.map { Self.dot(e, clusters[$0].centroid) }.max() ?? -1
                    if other > own - config.ambiguityMargin {
                        review.append(.init(face: f, suggestedClusterIndex: ci, similarity: Double(own), reason: .ambiguousBetweenClusters))
                        return false
                    }
                    return true
                }
                if keep.count != clusters[ci].faces.count {
                    clusters[ci] = makeCluster(keep.compactMap { byID[$0] }, existingPerson: clusters[ci].existingPerson)
                }
            }
        }
        return ClusteringResult(clusters: clusters.filter { !$0.faces.isEmpty }, review: review)
    }

    /// Pairwise adaptive threshold: harder to link poor-quality, tiny, or pose-mismatched faces.
    func threshold(_ a: FaceSample, _ b: FaceSample) -> Float {
        var t = config.baseThreshold
        t += config.qualityPenalty * Float(1 - min(a.quality, b.quality))
        if min(a.pixelSize, b.pixelSize) < config.smallFacePx { t += config.smallFacePenalty }
        if let ya = a.yaw, let yb = b.yaw, (abs(ya) > config.profileYaw) != (abs(yb) > config.profileYaw) {
            t += config.profilePenalty
        }
        return t
    }

    func makeCluster(_ samples: [FaceSample], existingPerson: PersonID?) -> FaceCluster {
        guard let dim = samples.first?.embedding.count else {
            return FaceCluster(faces: [], centroid: [], meanSimilarity: 0, confidence: .lowConfidence, existingPerson: existingPerson)
        }
        // Quality-weighted centroid: sharp frontal faces define the person more than blurry ones.
        var c = [Float](repeating: 0, count: dim)
        for s in samples { for i in 0..<dim { c[i] += Float(s.quality) * s.embedding[i] } }
        let norm = c.reduce(0) { $0 + $1 * $1 }.squareRoot()
        if norm > 0 { c = c.map { $0 / norm } }
        let mean = samples.map { Double(Self.dot($0.embedding, c)) }.reduce(0, +) / Double(samples.count)

        // Confidence is a UI label, not an identity claim. Only user confirmation yields `.confirmed`.
        let conf: PersonConfidence
        if existingPerson != nil { conf = .confirmed }
        else if mean >= 0.70 && samples.count >= 5 { conf = .likely }
        else if mean >= 0.55 { conf = .needsReview }
        else { conf = .lowConfidence }
        return FaceCluster(faces: samples.map(\.id), centroid: c, meanSimilarity: mean,
                           confidence: conf, existingPerson: existingPerson)
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        for i in 0..<min(a.count, b.count) { s += a[i] * b[i] }
        return s
    }
}

// MARK: - Small utilities

struct UnionFindFaces {
    private var parent: [FaceID: FaceID] = [:]
    mutating func find(_ x: FaceID) -> FaceID {
        if parent[x] == nil { parent[x] = x; return x }
        var r = x
        while let p = parent[r], p != r { r = p }
        var c = x
        while let p = parent[c], p != r { parent[c] = r; c = p }
        return r
    }
    /// Smaller id becomes root → deterministic super-node ids.
    mutating func union(_ a: FaceID, _ b: FaceID) {
        let ra = find(a), rb = find(b)
        guard ra != rb else { return }
        if ra < rb { parent[rb] = ra } else { parent[ra] = rb }
    }
}

/// Deterministic RNG so clustering is reproducible run to run (and testable).
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
