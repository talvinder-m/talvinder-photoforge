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
    public var qualityPenalty: Float = 0.10    // raise the bar for low-quality pairs
    public var smallFacePx: Double = 64        // below this, add a further penalty
    public var smallFacePenalty: Float = 0.05
    public var profileYaw: Double = 0.6        // ~35°; profile-vs-frontal pairs get a small penalty
    public var profilePenalty: Float = 0.04
    public var minQualityToCluster: Double = 0.15   // Vision capture quality; calibrated on LFW
    public var minClusterSize = 3              // smaller groups go to review, not to a "person"
    public var maxIterations = 40
    public var ambiguityMargin: Float = 0.05   // best vs second-best cluster
    /// Extra similarity (to the user-confirmed faces) a face needs to join a named person.
    public var namedPersonMargin: Float = 0.05
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
        var usable: [FaceSample] = []
        usable.reserveCapacity(all.count)
        for f in all {
            if f.quality < config.minQualityToCluster {
                review.append(.init(face: f.id, suggestedClusterIndex: nil, similarity: nil, reason: .lowQuality))
            } else { usable.append(f) }
        }
        // Work with array positions instead of dictionaries: tens of thousands of faces.
        let n = usable.count
        var pos: [FaceID: Int] = [:]
        pos.reserveCapacity(n)
        for (i, f) in usable.enumerated() { pos[f.id] = i }

        // 1. Must-link → super-nodes (confirmed faces of the same person are must-linked too).
        var parent = Array(0..<n)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { r = parent[r] }
            var c = x
            while parent[c] != r { let next = parent[c]; parent[c] = r; c = next }
            return r
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            guard ra != rb else { return }
            // Smaller face id becomes root → deterministic super-node ids.
            if usable[ra].id < usable[rb].id { parent[rb] = ra } else { parent[ra] = rb }
        }
        for (a, b) in constraints.mustLink { if let ia = pos[a], let ib = pos[b] { union(ia, ib) } }
        var confirmedByPerson: [PersonID: [Int]] = [:]
        for (f, p) in constraints.confirmed { if let i = pos[f] { confirmedByPerson[p, default: []].append(i) } }
        for (_, idx) in confirmedByPerson { for pair in zip(idx, idx.dropFirst()) { union(pair.0, pair.1) } }

        // Cannot-link between super-nodes.
        var cannot: [Int: Set<Int>] = [:]
        for (a, b) in constraints.cannotLink {
            guard let ia = pos[a], let ib = pos[b] else { continue }
            let ra = find(ia), rb = find(ib)
            guard ra != rb else { continue }              // contradictory feedback: handled in verification
            cannot[ra, default: []].insert(rb); cannot[rb, default: []].insert(ra)
        }
        // Different confirmed persons can never merge.
        let personRoots = confirmedByPerson.compactMapValues { $0.first.map(find) }
        for (p1, r1) in personRoots { for (p2, r2) in personRoots where p1 != p2 { cannot[r1, default: []].insert(r2) } }

        // 2. Weighted graph over super-nodes (adjacency lists).
        var root = [Int](repeating: 0, count: n)
        for i in 0..<n { root[i] = find(i) }
        var adj = [[Int: Float]](repeating: [:], count: n)
        for i in 0..<n {
            let ri = root[i]
            for (nid, sim) in index.neighbors(of: usable[i].id, k: config.k) {
                guard let j = pos[nid] else { continue }
                let rj = root[j]
                guard rj != ri, !(cannot[ri]?.contains(rj) ?? false) else { continue }
                if sim >= threshold(usable[i], usable[j]) {
                    adj[ri][rj, default: 0] += sim
                    adj[rj][ri, default: 0] += sim
                }
            }
        }
        let edges: [[(Int, Float)]] = adj.map { $0.sorted { $0.key < $1.key }.map { ($0.key, $0.value) } }
        adj = []

        // 3. Chinese Whispers with cannot-link-aware label adoption.
        let nodes = Array(Set(root)).sorted { usable[$0].id < usable[$1].id }
        var label = Array(0..<n)
        var rng = SplitMix64(seed: config.seed)
        var scoreLabels: [Int] = [], scoreValues: [Float] = []
        for _ in 0..<config.maxIterations {
            var changed = false
            for node in nodes.shuffled(using: &rng) {
                let es = edges[node]
                guard !es.isEmpty else { continue }
                scoreLabels.removeAll(keepingCapacity: true); scoreValues.removeAll(keepingCapacity: true)
                for (m, w) in es {
                    let l = label[m]
                    if let k = scoreLabels.firstIndex(of: l) { scoreValues[k] += w } else { scoreLabels.append(l); scoreValues.append(w) }
                }
                let blocked = cannot[node]
                var best = -1; var bestScore: Float = -.infinity
                for (k, l) in scoreLabels.enumerated() {
                    // A label is forbidden if any node cannot-linked to us currently carries it.
                    if let blocked, blocked.contains(where: { label[$0] == l }) { continue }
                    let sc = scoreValues[k]
                    if sc > bestScore || (sc == bestScore && usable[l].id < usable[best].id) { best = l; bestScore = sc }
                }
                if best >= 0, best != label[node] { label[node] = best; changed = true }
            }
            if !changed { break }
        }

        // 4. Expand super-nodes back to faces and build clusters.
        var membersByLabel: [Int: [Int]] = [:]
        for i in 0..<n { membersByLabel[label[root[i]], default: []].append(i) }

        var clusters: [FaceCluster] = []
        for (_, idx) in membersByLabel.sorted(by: { usable[$0.key].id < usable[$1.key].id }) {
            let samples = idx.map { usable[$0] }
            let person = Set(samples.compactMap { constraints.confirmed[$0.id] })
            if samples.count < config.minClusterSize && person.isEmpty {
                review.append(contentsOf: samples.map { .init(face: $0.id, suggestedClusterIndex: nil, similarity: nil, reason: .belowClusterThreshold) })
                continue
            }
            clusters.append(makeCluster(samples, existingPerson: person.count == 1 ? person.first : nil))
        }
        let byID = Dictionary(uniqueKeysWithValues: usable.map { ($0.id, $0) })

        // 5. Verification: evict faces that violate cannot-link or sit below the
        //    cluster's own adaptive threshold (μ − 3σ, floored at the base threshold).
        //    For a named person, a face must also look like the faces the user confirmed:
        //    this stops a loose group of strangers being attached to a name.
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
            // Centroid of the faces the user confirmed for this person.
            var confirmedCentroid: [Float]? = nil
            if c.existingPerson != nil {
                let conf = c.faces.filter { constraints.confirmed[$0] != nil }.compactMap { byID[$0] }
                if !conf.isEmpty { confirmedCentroid = makeCluster(conf, existingPerson: nil).centroid }
            }
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
                } else if !isConfirmed, let cc = confirmedCentroid,
                          Self.dot(byID[f]!.embedding, cc) < config.baseThreshold + config.namedPersonMargin {
                    review.append(.init(face: f, suggestedClusterIndex: ci, similarity: s, reason: .belowClusterThreshold))
                } else { keep.append(f) }
            }
            if keep.count != c.faces.count {
                c = makeCluster(keep.compactMap { byID[$0] }, existingPerson: c.existingPerson)
            }
            clusters[ci] = c
        }

        // 6. Faces close to two clusters are ambiguous → review, never auto-assigned.
        //    Only clusters the face's nearest neighbours belong to are compared (fast and enough:
        //    a face near another cluster's centre has neighbours in it).
        if clusters.count > 1 {
            var clusterOf: [FaceID: Int] = [:]
            for (ci, c) in clusters.enumerated() { for f in c.faces { clusterOf[f] = ci } }
            for ci in clusters.indices {
                let keep = clusters[ci].faces.filter { f in
                    guard !protected.contains(f), let e = byID[f]?.embedding else { return true }
                    let own = Self.dot(e, clusters[ci].centroid)
                    var others = Set<Int>()
                    for (nid, _) in index.neighbors(of: f, k: config.k) { if let o = clusterOf[nid], o != ci { others.insert(o) } }
                    let other = others.map { Self.dot(e, clusters[$0].centroid) }.max() ?? -1
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
