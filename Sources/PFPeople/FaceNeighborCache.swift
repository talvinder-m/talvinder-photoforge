import Foundation
import Accelerate
import PFCore

/// Nearest-neighbour lists for every face, kept between regroupings.
///
/// Finding each face's closest faces is the expensive part of grouping (every face against
/// every other). The lists only change when faces are added or removed — not when you name
/// someone — so they're computed once, extended for new faces, and reused. The comparisons use
/// Apple's Accelerate matrix routines, many times faster than a plain loop.
public final class FaceNeighborCache: NeighborIndex, @unchecked Sendable {
    public let k: Int
    /// Pairs below this similarity are never useful for grouping, so they aren't stored.
    public let minSimilarity: Float
    private let lock = NSLock()
    private var ids: [FaceID] = []
    private var row: [FaceID: Int] = [:]
    private var matrix: [Float] = []           // ids.count × dim, row-major
    private var dim = 0
    private var lists: [FaceID: [(FaceID, Float)]] = [:]

    public init(k: Int = 30, minSimilarity: Float = 0.2) {
        self.k = k; self.minSimilarity = minSimilarity
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return ids.count }

    /// Makes the cache match `samples`: forgets removed faces and adds new ones.
    /// Returns how many were added and removed.
    @discardableResult
    public func update(_ samples: [FaceSample]) -> (added: Int, removed: Int) {
        lock.lock(); defer { lock.unlock() }
        let d = samples.first?.embedding.count ?? 0
        let wanted = Set(samples.map(\.id))
        let removed = ids.filter { !wanted.contains($0) }
        // A different face model, or most faces gone: start over.
        if d != dim || removed.count * 3 > max(ids.count, 1) {
            ids = []; row = [:]; matrix = []; lists = [:]; dim = d
        } else if !removed.isEmpty {
            let gone = Set(removed)
            var newIDs: [FaceID] = [], newMatrix: [Float] = []
            newIDs.reserveCapacity(ids.count - gone.count)
            newMatrix.reserveCapacity((ids.count - gone.count) * dim)
            for (i, id) in ids.enumerated() where !gone.contains(id) {
                newIDs.append(id)
                newMatrix.append(contentsOf: matrix[(i * dim)..<((i + 1) * dim)])
            }
            ids = newIDs; matrix = newMatrix
            row = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
            for id in gone { lists[id] = nil }
            for (id, l) in lists where l.contains(where: { gone.contains($0.0) }) {
                lists[id] = l.filter { !gone.contains($0.0) }
            }
        }
        let fresh = samples.filter { row[$0.id] == nil && $0.embedding.count == dim }
        guard dim > 0, !fresh.isEmpty else { return (0, removed.count) }
        let firstNew = ids.count
        for s in fresh {
            row[s.id] = ids.count
            ids.append(s.id)
            matrix.append(contentsOf: s.embedding)
        }
        let n = ids.count
        // New faces against all faces, a block of rows at a time.
        let block = max(16, min(256, 20_000_000 / max(n, 1)))
        var sims = [Float](repeating: 0, count: block * n)
        var start = firstNew
        while start < n {
            let rows = min(block, n - start)
            matrix.withUnsafeBufferPointer { m in
                sims.withUnsafeMutableBufferPointer { out in
                    // out[rows × n] = M[start..<start+rows] · Mᵀ
                    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(rows), Int32(n), Int32(dim),
                                1, m.baseAddress! + start * dim, Int32(dim), m.baseAddress!, Int32(dim),
                                0, out.baseAddress!, Int32(n))
                }
            }
            for r in 0..<rows {
                let i = start + r
                let base = r * n
                var cands: [(FaceID, Float)] = []
                for j in 0..<n where j != i {
                    let s = sims[base + j]
                    guard s >= minSimilarity else { continue }
                    cands.append((ids[j], s))
                    // Existing faces learn about this new neighbour.
                    if j < firstNew { Self.insert((ids[i], s), into: &lists[ids[j], default: []], k: k) }
                }
                if cands.count > k { cands.sort { $0.1 > $1.1 }; cands.removeSubrange(k...) } else { cands.sort { $0.1 > $1.1 } }
                lists[ids[i]] = cands
            }
            start += rows
        }
        return (fresh.count, removed.count)
    }

    private static func insert(_ item: (FaceID, Float), into list: inout [(FaceID, Float)], k: Int) {
        if list.count >= k, let last = list.last, last.1 >= item.1 { return }
        let at = list.firstIndex { $0.1 < item.1 } ?? list.count
        list.insert(item, at: at)
        if list.count > k { list.removeLast() }
    }

    public func neighbors(of id: FaceID, k: Int) -> [(FaceID, Float)] {
        lock.lock(); defer { lock.unlock() }
        guard let l = lists[id] else { return [] }
        return l.count > k ? Array(l.prefix(k)) : l
    }
}
