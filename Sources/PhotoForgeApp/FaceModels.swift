import Foundation
import CoreML
import PFCore
import PFVision

/// Picks the face embedder: the bundled SFace Core ML model when present,
/// otherwise Apple Vision feature prints (lower accuracy, but always available).
struct FaceEmbedding: Sendable {
    let model: any ImageEmbeddingModel
    let name: String
    let version: String
    /// Cosine threshold for linking two faces, at grouping strictness 0 (loose) … 1 (strict).
    let thresholds: ClosedRange<Double>
    let summary: String

    var isDedicatedFaceModel: Bool { name == "sface" }

    func threshold(strictness: Double) -> Double {
        thresholds.lowerBound + (thresholds.upperBound - thresholds.lowerBound) * min(1, max(0, strictness))
    }

    static func load() -> FaceEmbedding {
        if let url = Bundle.main.url(forResource: "SFace", withExtension: "mlmodelc", subdirectory: "Models")
            ?? Bundle.main.url(forResource: "SFace", withExtension: "mlmodelc") {
            let descriptor = ModelDescriptor(
                name: "sface", version: "2021dec", purpose: .faceEmbedding,
                license: "Apache-2.0 (OpenCV Zoo)", licenseAllowsRedistribution: true, licenseAllowsCommercialUse: true,
                execution: .local, outputDimension: 128, inputSize: 112, minimumMemoryGB: 1,
                dataHandling: "Runs on this Mac with Core ML. Face data never leaves the device.",
                safetyRestrictions: ["Grouping your own photos only; not for identification or surveillance"],
                modelCardURL: URL(string: "https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface"))
            if let m = try? CoreMLFaceEmbedder(compiledModelURL: url, descriptor: descriptor,
                                               inputName: "input", outputName: "embedding",
                                               batchSize: 8, flipAugment: true, pixelMean: 0, pixelScale: 1) {
                return FaceEmbedding(model: m, name: "sface", version: "2021dec",
                                     thresholds: FaceCalibration.sface,
                                     summary: "SFace face-recognition model (OpenCV, Apache-2.0) · Core ML · on-device")
            }
        }
        return FaceEmbedding(model: VisionFeaturePrintEmbedder(purpose: .faceEmbedding), name: "vision-featureprint",
                             version: "2-face", thresholds: FaceCalibration.featurePrint,
                             summary: "Apple Vision feature prints · on-device (basic accuracy)")
    }
}

/// Threshold ranges measured by `PhotoForge --facecal` on the CI calibration set
/// (LFW sample: 12 people × 8 photos; see .github/workflows/build.yml, "Face calibration").
///  • SFace: same-person p5 = 0.55, different-person p99 = 0.33 → range centred between them.
///  • Feature prints: distributions overlap heavily (best pairwise accuracy ~80%), so the
///    fallback is set strict: it groups less and sends more faces to review.
enum FaceCalibration {
    static let sface: ClosedRange<Double> = 0.30...0.45
    static let featurePrint: ClosedRange<Double> = 0.84...0.90
}
