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
/// (see .github/workflows/build.yml, "Face calibration"). Update from its report.
enum FaceCalibration {
    static let sface: ClosedRange<Double> = 0.30...0.50
    static let featurePrint: ClosedRange<Double> = 0.90...0.98
}
