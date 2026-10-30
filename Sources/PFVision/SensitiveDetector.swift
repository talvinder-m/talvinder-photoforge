import Foundation
import CoreML
import CoreGraphics
import CoreVideo

/// Scores how likely a photo is to contain nudity or sexual content, on this Mac.
///
/// Model: Yahoo open_nsfw (BSD-2-Clause), converted to Core ML at build time by
/// tools/convert_nsfw.py. Scores are 0…1; PhotoForge stores the score and applies the
/// user's chosen level, so changing the level never needs a rescan.
public final class SensitiveDetector: @unchecked Sendable {
    public static let modelName = "OpenNSFW"
    private let model: MLModel
    private let lock = NSLock()

    public init?(modelsDirectory: URL?, computeUnits: MLComputeUnits = .cpuAndGPU) {
        guard let dir = modelsDirectory else { return nil }
        let url = dir.appendingPathComponent("\(Self.modelName).mlmodelc")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = computeUnits
        guard let m = try? MLModel(contentsOf: url, configuration: cfg) else { return nil }
        model = m
    }

    /// Probability (0…1) that the photo is not safe for work.
    public func score(_ image: CGImage) throws -> Double {
        guard let input = Self.prepare(image) else { throw CocoaError(.featureUnsupported) }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: input)])
        lock.lock(); defer { lock.unlock() }
        let out = try model.prediction(from: provider)
        guard let p = out.featureValue(for: "probabilities")?.multiArrayValue, p.count >= 2 else {
            throw CocoaError(.coderValueNotFound)
        }
        return p[p.count - 1].doubleValue
    }

    /// The model's own preprocessing: stretch to 256×256, take the centre 224×224.
    static func prepare(_ image: CGImage) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(nil, 224, 224, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess, let buf = pb else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: 224, height: 224, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buf), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .medium
        // 256×256 placed so that its centre 224×224 lands in the buffer.
        ctx.draw(image, in: CGRect(x: -16, y: -16, width: 256, height: 256))
        return buf
    }
}
