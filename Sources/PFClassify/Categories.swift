import Foundation
import PFCore

/// What kind of picture a photo is. A photo can be in several (e.g. a WhatsApp'd receipt).
public enum PhotoCategory: String, CaseIterable, Sendable, Codable, Identifiable, Hashable {
    case document, receipt, screenshot, whatsapp, socialMedia, qrCode, camera
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .document: "Documents"
        case .receipt: "Receipts & Bills"
        case .screenshot: "Screenshots"
        case .whatsapp: "WhatsApp"
        case .socialMedia: "Social Media"
        case .qrCode: "QR & Barcodes"
        case .camera: "Camera Photos"
        }
    }
    public var singular: String {
        switch self {
        case .document: "document"
        case .receipt: "receipt or bill"
        case .screenshot: "screenshot"
        case .whatsapp: "WhatsApp image"
        case .socialMedia: "social media image"
        case .qrCode: "QR or barcode image"
        case .camera: "camera photo"
        }
    }
    public var symbol: String {
        switch self {
        case .document: "doc.text"
        case .receipt: "doc.text.below.ecg"
        case .screenshot: "camera.viewfinder"
        case .whatsapp: "message"
        case .socialMedia: "bubble.left.and.text.bubble.right"
        case .qrCode: "qrcode"
        case .camera: "camera"
        }
    }
}

/// Everything the rules look at, gathered from metadata and on-device Vision.
public struct ClassificationSignals: Sendable {
    public var metadata: PhotoMetadata
    public var width: Int
    public var height: Int
    public var isScreenshotSubtype: Bool          // PhotoKit says so
    public var sceneLabels: [String: Float]       // VNClassifyImageRequest (top labels)
    public var documentConfidence: Float          // VNDetectDocumentSegmentationRequest, 0 if none
    public var documentAreaFraction: Double       // area of the detected page / image area
    public var textCharacters: Int                // recognised characters (0 if OCR skipped)
    public var textAreaFraction: Double           // total text-box area / image area
    public var text: String                       // recognised text (lowercased)
    public var barcodeCount: Int

    public init(metadata: PhotoMetadata = .init(), width: Int, height: Int, isScreenshotSubtype: Bool = false,
                sceneLabels: [String: Float] = [:], documentConfidence: Float = 0, documentAreaFraction: Double = 0,
                textCharacters: Int = 0, textAreaFraction: Double = 0, text: String = "", barcodeCount: Int = 0) {
        self.metadata = metadata; self.width = width; self.height = height; self.isScreenshotSubtype = isScreenshotSubtype
        self.sceneLabels = sceneLabels; self.documentConfidence = documentConfidence
        self.documentAreaFraction = documentAreaFraction; self.textCharacters = textCharacters
        self.textAreaFraction = textAreaFraction; self.text = text; self.barcodeCount = barcodeCount
    }
}

public struct CategoryDecision: Sendable, Equatable {
    public let category: PhotoCategory
    public let confidence: Double       // ≥ 0.5 → shown in the category
    public let reason: String           // plain-language explanation shown to the user
}

/// Transparent, rule-based classifier. No cloud, no opaque model: every decision
/// carries the reason it was made, and users can override any of them.
public enum ClassificationRules {
    public static let threshold = 0.5

    public static func classify(_ s: ClassificationSignals) -> [CategoryDecision] {
        var out: [PhotoCategory: CategoryDecision] = [:]
        func add(_ c: PhotoCategory, _ conf: Double, _ why: String) {
            if (out[c]?.confidence ?? -1) < conf { out[c] = CategoryDecision(category: c, confidence: conf, reason: why) }
        }
        let name = (s.metadata.filename ?? "").trimmingCharacters(in: .whitespaces)
        let lower = name.lowercased()
        let ext = (name as NSString).pathExtension.lowercased()
        let uti = (s.metadata.uti ?? "").lowercased()
        let isPNG = ext == "png" || uti.contains("png")
        let isJPEG = ["jpg", "jpeg"].contains(ext) || uti.contains("jpeg")
        let noCamera = s.metadata.hasCameraData == false           // read and absent (not unknown)
        let noExifAtAll = s.metadata.hasAnyExif == false
        let longEdge = max(s.width, s.height), shortEdge = min(s.width, s.height)

        // Screenshots
        if s.isScreenshotSubtype {
            add(.screenshot, 1.0, "Marked as a screenshot by Photos")
        }
        if matches(lower, #"^(screenshot|screen shot|screen_shot|scr_|screencapture|capture d’écran|bildschirmfoto)"#) {
            add(.screenshot, 0.95, "File name “\(name)”")
        }
        if noCamera && isPNG && Self.screenSizes.contains(Size(shortEdge, longEdge)) {
            add(.screenshot, 0.75, "Screen-sized PNG (\(s.width)×\(s.height)) with no camera data")
        }
        let isScreenshot = (out[.screenshot]?.confidence ?? 0) >= 0.9

        // WhatsApp
        if matches(name, #"^IMG-\d{8}-WA\d+"#) || matches(lower, #"^whatsapp (image|video)"#) || matches(name, #"-WA\d{4}\.[A-Za-z]+$"#) {
            add(.whatsapp, 0.98, "WhatsApp file name “\(name)”")
        } else if noExifAtAll && isJPEG && !isScreenshot && Self.whatsappLongEdges.contains(longEdge) {
            add(.whatsapp, 0.6, "No camera data at all and WhatsApp's typical size (\(longEdge) px)")
        }

        // Social media downloads
        if matches(name, #"^(FB_IMG_|received_|Snapchat-|InShot_|IMG_\d{8}_\d{6}_\d+)"#) || lower.contains("instagram") {
            add(.socialMedia, 0.9, "Saved-from-app file name “\(name)”")
        } else if noCamera && !isScreenshot && out[.whatsapp] == nil && Self.socialSizes.contains(Size(s.width, s.height)) {
            let texty = s.textCharacters >= 20
            add(.socialMedia, texty ? 0.75 : 0.65,
                "\(s.width)×\(s.height), a social media post size, with no camera data" + (texty ? " and text on the image" : ""))
        }

        // Documents
        let docLabel = Self.documentLabels.compactMap { s.sceneLabels[$0] }.max() ?? 0
        if s.documentConfidence >= 0.8 && s.documentAreaFraction >= 0.2 && s.textCharacters >= 40 {
            add(.document, 0.9, "A page was detected with \(s.textCharacters) characters of text")
        }
        if !isScreenshot && s.textCharacters >= 250 && s.textAreaFraction >= 0.08 {
            add(.document, 0.75, "Mostly text (\(s.textCharacters) characters)")
        }
        if !isScreenshot && docLabel >= 0.4 && s.textCharacters >= 20 {
            add(.document, 0.7, "Looks like a document (\(Int(docLabel * 100))%) and contains text")
        }

        // Receipts & bills
        if (out[.document] != nil || s.textCharacters >= 60) && !isScreenshot {
            let hits = Self.receiptWords.filter { s.text.contains($0) }
            if hits.count >= 2 {
                add(.receipt, min(0.95, 0.6 + 0.1 * Double(hits.count)), "Mentions " + hits.prefix(4).map { "“\($0)”" }.joined(separator: ", "))
            }
        }

        // QR / barcodes
        if s.barcodeCount > 0 {
            add(.qrCode, 0.95, s.barcodeCount == 1 ? "A QR code or barcode was found" : "\(s.barcodeCount) QR codes or barcodes were found")
        }

        // Camera photos
        if let make = s.metadata.cameraMake, !make.isEmpty, !isScreenshot, (out[.document]?.confidence ?? 0) < 0.7 {
            let model = s.metadata.cameraModel ?? ""
            // "Apple" + "iPhone 13" → "iPhone 13"; "Canon" + "Canon EOS 80D" → "Canon EOS 80D".
            let device = model.isEmpty ? make
                : (make.lowercased() == "apple" || model.lowercased().contains(make.lowercased().split(separator: " ").first.map(String.init) ?? make.lowercased()))
                    ? model : "\(make) \(model)"
            add(.camera, 0.9, "Taken with \(device)")
        }

        return PhotoCategory.allCases.compactMap { out[$0] }
    }

    // MARK: Tables

    struct Size: Hashable { let a: Int, b: Int; init(_ a: Int, _ b: Int) { self.a = a; self.b = b } }

    /// Common phone and Mac screen sizes (short edge, long edge).
    static let screenSizes: Set<Size> = [
        Size(1170, 2532), Size(1179, 2556), Size(1284, 2778), Size(1290, 2796), Size(1125, 2436), Size(1242, 2688),
        Size(828, 1792), Size(750, 1334), Size(1080, 1920), Size(1242, 2208), Size(640, 1136), Size(1206, 2622),
        Size(1320, 2868), Size(1080, 2340), Size(1080, 2400), Size(1080, 2220), Size(1440, 3200), Size(1440, 3120),
        Size(1440, 3040), Size(1440, 2960), Size(720, 1600), Size(720, 1520), Size(1080, 2408), Size(1080, 2412),
        Size(1600, 2560), Size(1800, 2880), Size(900, 1440), Size(800, 1280), Size(1440, 2560), Size(1964, 3024),
        Size(2234, 3456), Size(1664, 2560), Size(1117, 1728), Size(982, 1512), Size(1050, 1680),
        Size(1200, 1920), Size(768, 1366), Size(1620, 2160), Size(1668, 2388), Size(2048, 2732), Size(1536, 2048),
    ]
    /// WhatsApp resizes sent photos to these long edges.
    static let whatsappLongEdges: Set<Int> = [1600, 1280, 2560, 4096, 1024]
    /// Typical post/story/link sizes (exact width × height).
    static let socialSizes: Set<Size> = [
        Size(1080, 1080), Size(1080, 1350), Size(1080, 1920), Size(1080, 566), Size(1080, 608), Size(1200, 630),
        Size(1200, 675), Size(1600, 900), Size(1080, 1440), Size(640, 640), Size(750, 750), Size(720, 1280),
        Size(1024, 512), Size(1500, 500), Size(1200, 1200),
    ]
    static let documentLabels = ["document", "paper", "receipt", "handwriting", "text", "printed_page", "menu", "letter"]
    static let receiptWords = ["total", "subtotal", "grand total", "gst", "cgst", "sgst", "igst", "invoice", "receipt",
                               "bill no", "amount", "qty", "tax", "cash", "paid", "₹", "rs.", "inr", "mrp", "balance",
                               "upi", "gstin", "hsn", "payment"]

    static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
