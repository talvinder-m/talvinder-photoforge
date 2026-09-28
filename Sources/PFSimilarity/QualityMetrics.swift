import Foundation

/// Technical-quality measures computed on the analysis raster (≈512 px long edge).
/// All scores are mapped to 0…1 where higher is better, so they combine linearly
/// in `BestShotScorer`. Raw values are kept for display in the comparison view.
public struct QualityMetrics: Sendable, Equatable, Codable {
    public let laplacianVariance: Double   // raw sharpness
    public let noiseSigma: Double          // raw noise estimate (grey levels)
    public let meanLuma: Double
    public let clippedFraction: Double     // share of pixels at ≤2 or ≥253

    public var sharpnessScore: Double { 1 - exp(-laplacianVariance / 300) }            // ~0.63 at var=300
    public var noiseScore: Double { max(0, 1 - noiseSigma / 12) }                       // σ≥12 → 0
    public var exposureScore: Double {
        let centred = 1 - min(1, abs(meanLuma - 118) / 118)                            // mid-grey ≈ best
        return max(0, centred - 2 * clippedFraction)
    }

    public static func measure(_ img: LumaImage) -> QualityMetrics {
        QualityMetrics(laplacianVariance: laplacianVariance(img),
                       noiseSigma: immerkaerNoise(img),
                       meanLuma: Double(img.pixels.reduce(0, +)) / Double(img.pixels.count),
                       clippedFraction: Double(img.pixels.filter { $0 <= 2 || $0 >= 253 }.count) / Double(img.pixels.count))
    }

    /// Variance of the 4-neighbour Laplacian — the standard blur detector.
    static func laplacianVariance(_ img: LumaImage) -> Double {
        let w = img.width, h = img.height
        guard w > 2, h > 2 else { return 0 }
        var sum = 0.0, sumSq = 0.0, n = 0.0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let l = Double(img[x - 1, y] + img[x + 1, y] + img[x, y - 1] + img[x, y + 1] - 4 * img[x, y])
                sum += l; sumSq += l * l; n += 1
            }
        }
        let mean = sum / n
        return sumSq / n - mean * mean
    }

    /// Immerkær (1996) fast noise-variance estimate. Its 3×3 kernel cancels
    /// linear image structure, so what remains is dominated by sensor noise.
    static func immerkaerNoise(_ img: LumaImage) -> Double {
        let w = img.width, h = img.height
        guard w > 2, h > 2 else { return 0 }
        let k: [Float] = [1, -2, 1, -2, 4, -2, 1, -2, 1]
        var acc = 0.0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                var s: Float = 0, i = 0
                for dy in -1...1 { for dx in -1...1 { s += k[i] * img[x + dx, y + dy]; i += 1 } }
                acc += Double(abs(s))
            }
        }
        return acc * (Double.pi / 2).squareRoot() / (6 * Double(w - 2) * Double(h - 2))
    }
}
