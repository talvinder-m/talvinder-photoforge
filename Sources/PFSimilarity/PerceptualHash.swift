import Foundation
import CoreGraphics

/// A single-channel luminance raster (row-major, top-left origin, values 0…255).
/// All hash and quality maths operates on this type, so it is unit-testable
/// with synthetic data and identical across the app and its test suite.
public struct LumaImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public var pixels: [Float]

    public init(width: Int, height: Int, pixels: [Float]) {
        precondition(pixels.count == width * height)
        self.width = width; self.height = height; self.pixels = pixels
    }

    @inline(__always) public subscript(x: Int, y: Int) -> Float { pixels[y * width + x] }

    /// Renders any CGImage to a width×height grey raster. High-quality interpolation
    /// acts as the anti-aliasing filter pHash/dHash rely on.
    public static func from(_ image: CGImage, width: Int, height: Int) -> LumaImage? {
        var bytes = [UInt8](repeating: 0, count: width * height)
        let ok = bytes.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? LumaImage(width: width, height: height, pixels: bytes.map(Float.init)) : nil
    }
}

public enum PerceptualHash {

    /// 64-bit DCT perceptual hash (the classic pHash used by `imagehash.phash`):
    /// 32×32 luma → 2-D DCT-II → top-left 8×8 coefficients → bit = coefficient > median.
    /// Robust to resizing, recompression, mild colour and exposure changes.
    public static func pHash(_ img: LumaImage) -> UInt64 {
        precondition(img.width == 32 && img.height == 32, "pHash expects a 32×32 raster")
        let N = 32, K = 8
        let c = dctMatrix(N)
        // rows: tmp = C · X, then D = tmp · Cᵀ  (only the first K rows/cols are needed)
        var tmp = [Double](repeating: 0, count: K * N)
        for u in 0..<K {
            for x in 0..<N {
                var s = 0.0
                for y in 0..<N { s += c[u * N + y] * Double(img.pixels[y * N + x]) }
                tmp[u * N + x] = s
            }
        }
        var low = [Double](repeating: 0, count: K * K)
        for u in 0..<K {
            for v in 0..<K {
                var s = 0.0
                for x in 0..<N { s += tmp[u * N + x] * c[v * N + x] }
                low[u * K + v] = s
            }
        }
        let med = median(low)
        var h: UInt64 = 0
        for (i, value) in low.enumerated() where value > med { h |= (1 << UInt64(63 - i)) }
        return h
    }

    /// 64-bit gradient hash: 9×8 luma, bit = pixel brighter than its right neighbour.
    /// Complements pHash: cheap, and sensitive to local structure rather than global energy.
    public static func dHash(_ img: LumaImage) -> UInt64 {
        precondition(img.width == 9 && img.height == 8, "dHash expects a 9×8 raster")
        var h: UInt64 = 0, bit = 0
        for y in 0..<8 {
            for x in 0..<8 {
                if img[x, y] < img[x + 1, y] { h |= (1 << UInt64(63 - bit)) }
                bit += 1
            }
        }
        return h
    }

    public static func hamming(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

    /// Convenience: both hashes straight from an analysis image.
    public static func hashes(for image: CGImage) -> (pHash: UInt64, dHash: UInt64)? {
        guard let p = LumaImage.from(image, width: 32, height: 32),
              let d = LumaImage.from(image, width: 9, height: 8) else { return nil }
        return (pHash(p), dHash(d))
    }

    /// Stored in SQLite as INTEGER (Int64) — bit pattern preserved.
    public static func toStorage(_ h: UInt64) -> Int64 { Int64(bitPattern: h) }
    public static func fromStorage(_ v: Int64) -> UInt64 { UInt64(bitPattern: v) }

    // Unnormalised DCT-II basis (row u = frequency), proportional to scipy's
    // `dct(norm=None)` as used by imagehash. Keeping the DC row unscaled matters:
    // an orthonormal basis rescales it by 1/√2 and flips bits against the median.
    static func dctMatrix(_ n: Int) -> [Double] {
        var m = [Double](repeating: 0, count: n * n)
        for u in 0..<n {
            for x in 0..<n { m[u * n + x] = cos(Double.pi * (2 * Double(x) + 1) * Double(u) / (2 * Double(n))) }
        }
        return m
    }

    static func median(_ v: [Double]) -> Double {
        let s = v.sorted(), n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
}

/// BK-tree over Hamming distance: exact radius queries on 64-bit hashes without
/// comparing every pair. Used to find near-duplicate candidates in large libraries.
public struct HammingBKTree<ID: Hashable & Sendable>: Sendable {
    private final class Node: @unchecked Sendable {
        let hash: UInt64
        var ids: [ID]
        var children: [Int: Node] = [:]
        init(hash: UInt64, id: ID) { self.hash = hash; self.ids = [id] }
    }
    private var root: Node?
    public private(set) var count = 0
    public init() {}

    public mutating func insert(_ hash: UInt64, id: ID) {
        count += 1
        guard var node = root else { root = Node(hash: hash, id: id); return }
        while true {
            let d = PerceptualHash.hamming(hash, node.hash)
            if d == 0 { node.ids.append(id); return }
            if let next = node.children[d] { node = next }
            else { node.children[d] = Node(hash: hash, id: id); return }
        }
    }

    /// All ids whose hash is within `radius` of `hash`, with their distance.
    public func query(_ hash: UInt64, radius: Int) -> [(id: ID, distance: Int)] {
        guard let root else { return [] }
        var out: [(ID, Int)] = [], stack = [root]
        while let node = stack.popLast() {
            let d = PerceptualHash.hamming(hash, node.hash)
            if d <= radius { out.append(contentsOf: node.ids.map { ($0, d) }) }
            for (edge, child) in node.children where edge >= d - radius && edge <= d + radius {
                stack.append(child)
            }
        }
        return out.map { (id: $0.0, distance: $0.1) }
    }
}
