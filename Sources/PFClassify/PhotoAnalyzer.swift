import Foundation
import Vision
import CoreGraphics
import PFCore

/// Gathers classification signals with Apple Vision, entirely on-device.
public struct PhotoAnalyzer: Sendable {
    public init() {}

    public struct Output: Sendable {
        public var signals: ClassificationSignals
        public var decisions: [CategoryDecision]
        public var sceneLabels: [(String, Float)]     // for tags / future search
        public var ocrText: String                    // original case, for search
        public var ranOCR: Bool
    }

    /// - Parameters:
    ///   - image: an upright analysis rendition (≈1280 px long edge is plenty for OCR).
    ///   - width/height: the photo's real pixel size (used by the size rules).
    public func analyze(_ image: CGImage, width: Int, height: Int, metadata: PhotoMetadata,
                        isScreenshotSubtype: Bool) throws -> Output {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        let classify = VNClassifyImageRequest()
        let barcodes = VNDetectBarcodesRequest()
        let document = VNDetectDocumentSegmentationRequest()
        try handler.perform([classify, barcodes, document])

        let labels = (classify.results ?? []).filter { $0.confidence >= 0.1 }
            .sorted { $0.confidence > $1.confidence }.prefix(20)
            .map { ($0.identifier, $0.confidence) }
        var labelMap: [String: Float] = [:]
        for (k, v) in labels { labelMap[k] = v }

        let doc = document.results?.first
        let docConf = doc?.confidence ?? 0
        let docArea: Double = doc.map { Self.quadArea($0) } ?? 0

        // OCR is the slow part on older Macs: only run it when text is plausible.
        let textyLabel = ClassificationRules.documentLabels.compactMap { labelMap[$0] }.max() ?? 0
        let needOCR = docConf >= 0.5 || textyLabel >= 0.1 || isScreenshotSubtype
            || metadata.hasCameraData != true                    // downloads, posts, forwards often carry text
        var text = "", chars = 0, textArea = 0.0
        if needOCR {
            let ocr = VNRecognizeTextRequest()
            ocr.recognitionLevel = .fast
            ocr.usesLanguageCorrection = false
            ocr.minimumTextHeight = 0.012
            try handler.perform([ocr])
            let obs = ocr.results ?? []
            let lines = obs.compactMap { $0.topCandidates(1).first?.string }
            text = lines.joined(separator: "\n")
            chars = text.filter { !$0.isWhitespace }.count
            textArea = min(1, obs.reduce(0) { $0 + Double($1.boundingBox.width * $1.boundingBox.height) })
        }

        let signals = ClassificationSignals(
            metadata: metadata, width: width, height: height, isScreenshotSubtype: isScreenshotSubtype,
            sceneLabels: labelMap, documentConfidence: docConf, documentAreaFraction: docArea,
            textCharacters: chars, textAreaFraction: textArea, text: text.lowercased(),
            barcodeCount: (barcodes.results ?? []).count)
        return Output(signals: signals, decisions: ClassificationRules.classify(signals),
                      sceneLabels: Array(labels), ocrText: text, ranOCR: needOCR)
    }

    static func quadArea(_ r: VNRectangleObservation) -> Double {
        // Shoelace formula on the normalized corner points.
        let p = [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft]
        var s = 0.0
        for i in 0..<4 {
            let a = p[i], b = p[(i + 1) % 4]
            s += Double(a.x * b.y - b.x * a.y)
        }
        return abs(s) / 2
    }
}
