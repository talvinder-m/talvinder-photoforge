import Foundation
import Vision
import CoreGraphics
import PFCore

/// Built-in image embedder backed by Vision's `VNGenerateImageFeaturePrintRequest`.
///
/// It ships with macOS, needs no download, has no third-party licence, and runs
/// on Intel and Apple Silicon. Used for:
///  • scene similarity (burst / similar-shot grouping), and
///  • the default face embedder, applied to 5-point-aligned face crops.
///
/// For faces it is a *general* image descriptor, not an identity model, so person
/// grouping is less accurate than with a dedicated face-recognition model
/// (see docs/ARCHITECTURE.md, risk R5). The People screen therefore exposes a
/// "grouping strictness" control and every group stays "Possible Person" until
/// the user confirms it. A Core ML face model can replace it via `CoreMLFaceEmbedder`.
public struct VisionFeaturePrintEmbedder: ImageEmbeddingModel {
    public let descriptor: ModelDescriptor
    public let preferredBatchSize = 16

    public init(purpose: ModelDescriptor.Purpose) {
        descriptor = ModelDescriptor(
            name: "vision-featureprint", version: "2", purpose: purpose,
            license: "Apple system framework", licenseAllowsRedistribution: true,
            licenseAllowsCommercialUse: true, execution: .local, outputDimension: nil, inputSize: nil,
            minimumMemoryGB: 1, dataHandling: "Runs on this Mac via Apple's Vision framework. Nothing leaves the device.",
            safetyRestrictions: [], modelCardURL: nil)
    }

    public func embed(_ images: [CGImage]) async throws -> [[Float]] {
        try images.map { try Self.featurePrint($0) }
    }

    public static func featurePrint(_ image: CGImage) throws -> [Float] {
        let req = VNGenerateImageFeaturePrintRequest()
        req.preferBackgroundProcessing = true   // yield the GPU to the window
        req.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
        guard let obs = req.results?.first else { throw PhotoForgeError.corruptImage }
        let n = obs.elementCount
        var v: [Float]
        switch obs.elementType {
        case .float:
            v = obs.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(n)) }
        case .double:
            v = obs.data.withUnsafeBytes { $0.bindMemory(to: Double.self).prefix(n).map(Float.init) }
        default:
            throw PhotoForgeError.corruptImage
        }
        // Feature-print vectors share a sizeable common component, which pushes raw cosines
        // between unrelated images up. Removing each vector's mean spreads them out.
        let mean = v.reduce(0, +) / Float(max(1, v.count))
        v = v.map { $0 - mean }
        return VectorMath.l2Normalized(v)
    }
}
