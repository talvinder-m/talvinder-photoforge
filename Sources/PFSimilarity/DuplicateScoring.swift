import Foundation
import PFCore

/// Everything the grouping engine needs about one asset. Built from the app DB.
public struct AssetFeatures: Sendable, Identifiable {
    public let id: AssetID
    public var fileHash: Data?            // SHA-256 of original, if read
    public var fileSize: Int?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var pHash: UInt64?
    public var dHash: UInt64?
    public var embedding: [Float]?        // unit-length scene embedding
    public var captureDate: Date?
    public var burstIdentifier: String?
    public var quality: QualityMetrics?
    public var faceQuality: Double?       // mean Vision capture quality of faces, 0…1
    public var aestheticScore: Double?    // 0…1 from an aesthetics model, if installed
    public var isFavorite: Bool = false
    public var hasEdits: Bool = false
    public var isInAlbum: Bool = false

    public init(id: AssetID, pixelWidth: Int, pixelHeight: Int) {
        self.id = id; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
    }
    public var megapixels: Double { Double(pixelWidth * pixelHeight) / 1_000_000 }
}

public struct DuplicateThresholds: Sendable {
    public var nearMaxPHash = 6              // Hamming bits
    public var nearMaxDHash = 10
    public var nearLoosePHash = 12           // allowed when embeddings agree strongly
    public var nearEmbeddingMin: Float = 0.95
    public var burstWindow: TimeInterval = 4
    public var burstEmbeddingMin: Float = 0.85
    public var similarWindow: TimeInterval = 15 * 60
    public var similarEmbeddingMin: Float = 0.90
    public init() {}
}

public struct DuplicateGroup: Sendable {
    public let type: DuplicateGroupType
    public let members: [AssetID]
    public let similarity: Double              // 0…1 group confidence
    public var ranking: [RankedMember] = []
    public var recommended: AssetID? { ranking.first?.id }
    public var explanation: String = ""
}

/// Pairs the user said are "not similar" and assets excluded from scans entirely.
public struct SimilarityExclusions: Sendable {
    public var excludedAssets: Set<AssetID> = []
    public var notSimilarPairs: Set<Pair> = []
    public struct Pair: Hashable, Sendable {
        public let a: AssetID, b: AssetID
        public init(_ x: AssetID, _ y: AssetID) { (a, b) = x < y ? (x, y) : (y, x) }
    }
    public init() {}
    func blocks(_ x: AssetID, _ y: AssetID) -> Bool { notSimilarPairs.contains(Pair(x, y)) }
}

/// Multi-stage grouping. Each asset lands in at most one group — the tightest
/// relation it has — so exact duplicates and near duplicates are always shown
/// separately, as the acceptance criteria require.
public struct DuplicateGrouper: Sendable {
    public var thresholds = DuplicateThresholds()
    public var scorer = BestShotScorer()
    public init() {}

    public func groups(for input: [AssetFeatures], exclusions: SimilarityExclusions = .init()) -> [DuplicateGroup] {
        let assets = input.filter { !exclusions.excludedAssets.contains($0.id) }
        let byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        var assigned = Set<AssetID>()
        var out: [DuplicateGroup] = []

        // 1 — Exact: identical cryptographic hash AND identical size. Deterministic.
        var byHash: [Data: [AssetID]] = [:]
        for a in assets { if let h = a.fileHash { byHash[h + Self.sizeTag(a.fileSize), default: []].append(a.id) } }
        for ids in byHash.values where ids.count > 1 {
            out.append(DuplicateGroup(type: .exact, members: ids.sorted(), similarity: 1))
            assigned.formUnion(ids)
        }

        // 2 — Near: perceptual-hash neighbourhood via BK-tree, confirmed by a second signal.
        var tree = HammingBKTree<AssetID>()
        for a in assets where !assigned.contains(a.id) { if let p = a.pHash { tree.insert(p, id: a.id) } }
        var uf = UnionFind<AssetID>()
        var nearScores: [SimilarityExclusions.Pair: Double] = [:]
        for a in assets where !assigned.contains(a.id) {
            guard let p = a.pHash else { continue }
            for (other, dist) in tree.query(p, radius: thresholds.nearLoosePHash) where other != a.id {
                guard !exclusions.blocks(a.id, other), let b = byID[other] else { continue }
                if isNear(a, b, pDist: dist) {
                    uf.union(a.id, other)
                    nearScores[.init(a.id, other)] = 1 - Double(dist) / 64
                }
            }
        }
        for comp in uf.components() where comp.count > 1 {
            out.append(DuplicateGroup(type: .near, members: comp.sorted(),
                                      similarity: Self.meanScore(comp, nearScores)))
            assigned.formUnion(comp)
        }

        // 3 — Burst: PhotoKit burst id, or a tight time window with visual agreement.
        let remaining = assets.filter { !assigned.contains($0.id) }
        let bursts = timeWindowGroups(remaining, window: thresholds.burstWindow,
                                      minSim: thresholds.burstEmbeddingMin, exclusions: exclusions, useBurstID: true)
        for g in bursts { out.append(DuplicateGroup(type: .burst, members: g.ids, similarity: g.sim)); assigned.formUnion(g.ids) }

        // 4 — Similar: same scene within a longer window. Seed-based (star) grouping,
        // not union-find, so A~B~C chains cannot drag unrelated photos together.
        let rest = assets.filter { !assigned.contains($0.id) }
        let similar = timeWindowGroups(rest, window: thresholds.similarWindow,
                                       minSim: thresholds.similarEmbeddingMin, exclusions: exclusions, useBurstID: false)
        for g in similar { out.append(DuplicateGroup(type: .similar, members: g.ids, similarity: g.sim)) }

        return out.map { g in
            var g = g
            let members = g.members.compactMap { byID[$0] }
            g.ranking = scorer.rank(members)
            g.explanation = scorer.explain(g.ranking)
            return g
        }
    }

    func isNear(_ a: AssetFeatures, _ b: AssetFeatures, pDist: Int) -> Bool {
        let dDist: Int? = (a.dHash != nil && b.dHash != nil) ? PerceptualHash.hamming(a.dHash!, b.dHash!) : nil
        let cos: Float? = (a.embedding != nil && b.embedding != nil) ? Self.dot(a.embedding!, b.embedding!) : nil
        // Tight: both hashes agree.
        if pDist <= thresholds.nearMaxPHash, (dDist ?? 0) <= thresholds.nearMaxDHash { return true }
        // Loose hash distance only when the semantic embedding is almost identical
        // (catches crops/watermarks that move pHash bits).
        if pDist <= thresholds.nearLoosePHash, let cos, cos >= thresholds.nearEmbeddingMin { return true }
        return false
    }

    private func timeWindowGroups(_ assets: [AssetFeatures], window: TimeInterval, minSim: Float,
                                  exclusions: SimilarityExclusions, useBurstID: Bool) -> [(ids: [AssetID], sim: Double)] {
        var result: [(ids: [AssetID], sim: Double)] = []
        var used = Set<AssetID>()

        if useBurstID {
            let byBurst = Dictionary(grouping: assets.filter { $0.burstIdentifier != nil }, by: { $0.burstIdentifier! })
            for members in byBurst.values where members.count > 1 {
                result.append((members.map(\.id).sorted(), 1)); used.formUnion(members.map(\.id))
            }
        }
        let dated = assets.filter { $0.captureDate != nil && $0.embedding != nil && !used.contains($0.id) }
                          .sorted { $0.captureDate! < $1.captureDate! }
        var i = 0
        while i < dated.count {
            let seed = dated[i]
            guard !used.contains(seed.id) else { i += 1; continue }
            var members = [seed.id], sims: [Double] = []
            var j = i + 1
            while j < dated.count, dated[j].captureDate!.timeIntervalSince(seed.captureDate!) <= window {
                let c = dated[j]
                if !used.contains(c.id), !exclusions.blocks(seed.id, c.id) {
                    let s = Self.dot(seed.embedding!, c.embedding!)
                    if s >= minSim { members.append(c.id); sims.append(Double(s)) }
                }
                j += 1
            }
            if members.count > 1 {
                result.append((members.sorted(), sims.reduce(0, +) / Double(sims.count)))
                used.formUnion(members)
            }
            i += 1
        }
        return result
    }

    static func sizeTag(_ size: Int?) -> Data { withUnsafeBytes(of: Int64(size ?? -1).littleEndian) { Data($0) } }
    static func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
    static func meanScore(_ comp: [AssetID], _ scores: [SimilarityExclusions.Pair: Double]) -> Double {
        let set = Set(comp)
        let vals = scores.filter { set.contains($0.key.a) && set.contains($0.key.b) }.map(\.value)
        return vals.isEmpty ? 0 : vals.reduce(0, +) / Double(vals.count)
    }
}

// MARK: - Best-shot scoring

public struct RankedMember: Sendable {
    public let id: AssetID
    public let score: Double
    public let components: [BestShotScorer.Factor: Double]   // normalised 0…1 within the group
}

/// Transparent weighted scorer. Weights are user-configurable in Settings; factors
/// with no data for any member are dropped and the remaining weights renormalised,
/// so a group of faceless landscapes is not penalised for having no faces.
public struct BestShotScorer: Sendable {
    public enum Factor: String, Sendable, CaseIterable, Codable {
        case technical, faceQuality, aesthetic, resolution, exposure, preference

        var phrase: String {
            switch self {
            case .technical: "the sharpest, cleanest detail"
            case .faceQuality: "the best face-capture quality"
            case .aesthetic: "the strongest composition score"
            case .resolution: "more usable resolution"
            case .exposure: "the most balanced exposure"
            case .preference: "your favourite/edit history"
            }
        }
    }

    public var weights: [Factor: Double] = [
        .technical: 0.30, .faceQuality: 0.20, .aesthetic: 0.15,
        .resolution: 0.15, .exposure: 0.10, .preference: 0.10,
    ]
    public init() {}

    func raw(_ a: AssetFeatures, _ f: Factor) -> Double? {
        switch f {
        case .technical:   a.quality.map { 0.75 * $0.sharpnessScore + 0.25 * $0.noiseScore }
        case .faceQuality: a.faceQuality
        case .aesthetic:   a.aestheticScore
        case .resolution:  a.megapixels
        case .exposure:    a.quality?.exposureScore
        case .preference:  (a.isFavorite ? 0.7 : 0) + (a.hasEdits ? 0.2 : 0) + (a.isInAlbum ? 0.1 : 0)
        }
    }

    public func rank(_ members: [AssetFeatures]) -> [RankedMember] {
        var normalised: [Factor: [AssetID: Double]] = [:]
        for f in Factor.allCases {
            let vals = members.compactMap { m in raw(m, f).map { (m.id, $0) } }
            guard !vals.isEmpty else { continue }
            let lo = vals.map(\.1).min()!, hi = vals.map(\.1).max()!
            // Min–max within the group; a factor where everyone ties contributes nothing.
            normalised[f] = Dictionary(uniqueKeysWithValues: vals.map { ($0.0, hi > lo ? ($0.1 - lo) / (hi - lo) : 0) })
        }
        let active = normalised.keys
        let total = active.reduce(0) { $0 + (weights[$1] ?? 0) }
        guard total > 0 else { return members.map { RankedMember(id: $0.id, score: 0, components: [:]) } }

        return members.map { m in
            var comps: [Factor: Double] = [:]
            var s = 0.0
            for f in active {
                let v = normalised[f]?[m.id] ?? 0
                comps[f] = v
                s += (weights[f] ?? 0) / total * v
            }
            return RankedMember(id: m.id, score: s, components: comps)
        }
        .sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }  // deterministic ties
    }

    /// "Recommended because it has the sharpest, cleanest detail, more usable resolution, and …"
    public func explain(_ ranking: [RankedMember]) -> String {
        guard let best = ranking.first, ranking.count > 1 else { return "" }
        let others = ranking.dropFirst()
        let reasons = best.components
            .filter { f, v in
                let otherMax = others.map { $0.components[f] ?? 0 }.max() ?? 0
                return v > otherMax + 0.1 && (weights[f] ?? 0) > 0
            }
            .sorted { l, r in
                let wl = (weights[l.key] ?? 0) * l.value, wr = (weights[r.key] ?? 0) * r.value
                if wl != wr { return wl > wr }
                // Deterministic tie-break in declaration order (Dictionary order is random).
                return Factor.allCases.firstIndex(of: l.key)! < Factor.allCases.firstIndex(of: r.key)!
            }
            .prefix(3)
            .map(\.key.phrase)
        guard !reasons.isEmpty else { return "Recommended as the best overall balance; differences are small." }
        let list = reasons.count == 1 ? reasons[0]
                 : reasons.dropLast().joined(separator: ", ") + ", and " + reasons.last!
        return "Recommended because it has \(list)."
    }
}

// MARK: - Union-find

public struct UnionFind<T: Hashable & Sendable>: Sendable {
    private var parent: [T: T] = [:]
    private var rank: [T: Int] = [:]
    public init() {}

    public mutating func find(_ x: T) -> T {
        if parent[x] == nil { parent[x] = x; rank[x] = 0; return x }
        var root = x
        while let p = parent[root], p != root { root = p }
        var cur = x
        while let p = parent[cur], p != root { parent[cur] = root; cur = p }   // path compression
        return root
    }

    public mutating func union(_ a: T, _ b: T) {
        let ra = find(a), rb = find(b)
        guard ra != rb else { return }
        let (ka, kb) = (rank[ra]!, rank[rb]!)
        if ka < kb { parent[ra] = rb } else if ka > kb { parent[rb] = ra }
        else { parent[rb] = ra; rank[ra] = ka + 1 }
    }

    public mutating func components() -> [[T]] {
        var groups: [T: [T]] = [:]
        for k in Array(parent.keys) { groups[find(k), default: []].append(k) }
        return Array(groups.values)
    }
}
