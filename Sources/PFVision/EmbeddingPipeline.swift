import Foundation
import CoreML
import CoreGraphics
import Accelerate
import PFCore

// MARK: - Model descriptors & capability registry

public struct ModelDescriptor: Sendable, Hashable, Codable {
    public enum Purpose: String, Sendable, Codable {
        case faceEmbedding, sceneEmbedding, textEmbedding, inpainting, upscaling, denoise, segmentation, safetyClassifier
    }
    public let name: String
    public let version: String
    public let purpose: Purpose
    public let license: String                  // SPDX id or "Proprietary: <terms URL>"
    public let licenseAllowsRedistribution: Bool // false => must be user-downloaded, never bundled
    public let licenseAllowsCommercialUse: Bool
    public let execution: ExecutionLocation
    public let outputDimension: Int?
    public let inputSize: Int?
    public let minimumMemoryGB: Double
    public let dataHandling: String             // plain-language: what leaves the Mac, if anything
    public let safetyRestrictions: [String]
    public let modelCardURL: URL?

    public init(name: String, version: String, purpose: Purpose, license: String,
                licenseAllowsRedistribution: Bool, licenseAllowsCommercialUse: Bool,
                execution: ExecutionLocation, outputDimension: Int?, inputSize: Int?,
                minimumMemoryGB: Double, dataHandling: String, safetyRestrictions: [String], modelCardURL: URL?) {
        self.name = name; self.version = version; self.purpose = purpose; self.license = license
        self.licenseAllowsRedistribution = licenseAllowsRedistribution
        self.licenseAllowsCommercialUse = licenseAllowsCommercialUse
        self.execution = execution; self.outputDimension = outputDimension; self.inputSize = inputSize
        self.minimumMemoryGB = minimumMemoryGB; self.dataHandling = dataHandling
        self.safetyRestrictions = safetyRestrictions; self.modelCardURL = modelCardURL
    }
}

public enum ModelRegistryError: Error, Sendable {
    case notRegistered(String), cloudDisabled(String), notCommerciallyUsable(String)
}

/// Single place that decides whether a model may run. The privacy dashboard lists `all()`.
public actor ModelRegistry {
    private var descriptors: [String: ModelDescriptor] = [:]
    private var cloudEnabled = false
    private let commercialBuild: Bool

    public init(commercialBuild: Bool) { self.commercialBuild = commercialBuild }

    public func register(_ d: ModelDescriptor) { descriptors["\(d.name)@\(d.version)"] = d }
    public func all() -> [ModelDescriptor] { descriptors.values.sorted { $0.name < $1.name } }
    public func setCloudEnabled(_ on: Bool) { cloudEnabled = on }

    /// Throws unless the model is registered, local (or cloud explicitly enabled),
    /// and licensed for this build's distribution mode.
    public func authorize(name: String, version: String) throws -> ModelDescriptor {
        guard let d = descriptors["\(name)@\(version)"] else { throw ModelRegistryError.notRegistered(name) }
        if d.execution == .cloud && !cloudEnabled { throw ModelRegistryError.cloudDisabled(name) }
        if commercialBuild && !d.licenseAllowsCommercialUse { throw ModelRegistryError.notCommerciallyUsable(name) }
        return d
    }
}

// MARK: - Embedding abstraction

/// Any model that turns images into fixed-length, L2-normalised vectors.
public protocol ImageEmbeddingModel: Sendable {
    var descriptor: ModelDescriptor { get }
    var preferredBatchSize: Int { get }
    /// Returns one unit-length vector per input, in order.
    func embed(_ images: [CGImage]) async throws -> [[Float]]
}

/// Core ML runner for ArcFace-style face embedders (112×112 RGB, (x−127.5)/127.5).
/// The model file is supplied at runtime from the app's model cache; it is never
/// bundled unless its descriptor says redistribution is allowed.
public final class CoreMLFaceEmbedder: ImageEmbeddingModel, @unchecked Sendable {
    public let descriptor: ModelDescriptor
    public let preferredBatchSize: Int
    private let model: MLModel
    private let inputName: String
    private let outputName: String
    private let side: Int
    private let flipAugment: Bool
    private let pixelMean: Float
    private let pixelScale: Float

    /// - Parameters:
    ///   - pixelMean/pixelScale: input = (pixel − mean) / scale. ArcFace-style models use
    ///     127.5/127.5; OpenCV SFace takes raw 0–255 (mean 0, scale 1).
    public init(compiledModelURL: URL, descriptor: ModelDescriptor,
                inputName: String = "input", outputName: String = "embedding",
                batchSize: Int = 32, flipAugment: Bool = true,
                pixelMean: Float = 127.5, pixelScale: Float = 127.5) throws {
        let cfg = MLModelConfiguration()
        #if arch(x86_64)
        // Intel Macs: the face model is small, so run it on the CPU and leave the
        // (integrated) GPU to draw the window. Sharing it made the app stutter.
        cfg.computeUnits = .cpuOnly
        #else
        cfg.computeUnits = .all          // Neural Engine + GPU + CPU on Apple silicon
        #endif
        self.model = try MLModel(contentsOf: compiledModelURL, configuration: cfg)
        self.descriptor = descriptor
        self.inputName = inputName
        self.outputName = outputName
        self.side = descriptor.inputSize ?? 112
        self.preferredBatchSize = batchSize
        self.flipAugment = flipAugment
        self.pixelMean = pixelMean
        self.pixelScale = pixelScale
    }

    public func embed(_ images: [CGImage]) async throws -> [[Float]] {
        var out: [[Float]] = []
        out.reserveCapacity(images.count)
        for chunkStart in stride(from: 0, to: images.count, by: preferredBatchSize) {
            try Task.checkCancellation()
            let chunk = Array(images[chunkStart..<min(chunkStart + preferredBatchSize, images.count)])
            var vectors = try predict(chunk, flipped: false)
            if flipAugment {
                // Sum of original + horizontally-flipped embeddings: a cheap, standard accuracy gain.
                let flipped = try predict(chunk, flipped: true)
                vectors = zip(vectors, flipped).map { a, b in zip(a, b).map(+) }
            }
            out.append(contentsOf: vectors.map(VectorMath.l2Normalized))
        }
        return out
    }

    private func predict(_ batch: [CGImage], flipped: Bool) throws -> [[Float]] {
        let providers: [MLFeatureProvider] = try batch.map { img in
            let arr = try Self.preprocess(img, side: side, flipped: flipped, mean: pixelMean, scale: pixelScale)
            return try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: arr)])
        }
        let results = try model.predictions(fromBatch: MLArrayBatchProvider(array: providers))
        return (0..<results.count).map { i in
            guard let m = results.features(at: i).featureValue(for: outputName)?.multiArrayValue else { return [] }
            return VectorMath.floats(from: m)
        }
    }

    /// RGBA8 → planar RGB Float32 [1,3,side,side], (x − mean) / scale.
    static func preprocess(_ image: CGImage, side: Int, flipped: Bool,
                           mean: Float = 127.5, scale: Float = 127.5) throws -> MLMultiArray {
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        // The buffer pointer must outlive the context, so do all drawing inside the closure.
        let drew = rgba.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            if flipped { ctx.translateBy(x: CGFloat(side), y: 0); ctx.scaleBy(x: -1, y: 1) }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drew else { throw PhotoForgeError.corruptImage }

        let arr = try MLMultiArray(shape: [1, 3, NSNumber(value: side), NSNumber(value: side)], dataType: .float32)
        let plane = side * side
        arr.withUnsafeMutableBufferPointer(ofType: Float32.self) { dst, _ in
            for i in 0..<plane {
                dst[i]             = (Float(rgba[i * 4])     - mean) / scale
                dst[plane + i]     = (Float(rgba[i * 4 + 1]) - mean) / scale
                dst[2 * plane + i] = (Float(rgba[i * 4 + 2]) - mean) / scale
            }
        }
        return arr
    }
}

// MARK: - Batch pipeline

/// Collects aligned crops from many detector tasks and feeds the embedder in full
/// batches, which is where Apple Silicon throughput comes from.
public actor EmbeddingBatcher {
    public struct Item: Sendable { public let faceID: FaceID; public let crop: CGImage }
    private let model: any ImageEmbeddingModel
    private var pending: [Item] = []
    private let sink: @Sendable ([(FaceID, [Float])]) async throws -> Void

    public init(model: any ImageEmbeddingModel,
                sink: @escaping @Sendable ([(FaceID, [Float])]) async throws -> Void) {
        self.model = model
        self.sink = sink
    }

    public func submit(_ items: [Item]) async throws {
        pending.append(contentsOf: items)
        while pending.count >= model.preferredBatchSize {
            let batch = Array(pending.prefix(model.preferredBatchSize))
            pending.removeFirst(batch.count)
            try await run(batch)
        }
    }

    public func flush() async throws {
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll()
        try await run(batch)
    }

    private func run(_ batch: [Item]) async throws {
        let vectors = try await model.embed(batch.map(\.crop))
        try await sink(Array(zip(batch.map(\.faceID), vectors)))
    }
}

// MARK: - Vector helpers

public enum VectorMath {
    public static func l2Normalized(_ v: [Float]) -> [Float] {
        let norm = sqrt(vDSP.sumOfSquares(v))
        return norm > 0 ? vDSP.divide(v, norm) : v
    }
    /// Cosine similarity for unit vectors = dot product.
    public static func dot(_ a: [Float], _ b: [Float]) -> Float { vDSP.dot(a, b) }

    static func floats(from m: MLMultiArray) -> [Float] {
        let n = m.count
        switch m.dataType {
        case .float32:
            return m.withUnsafeBufferPointer(ofType: Float.self) { Array($0.prefix(n)) }
        default:
            return (0..<n).map { m[$0].floatValue }
        }
    }
}
