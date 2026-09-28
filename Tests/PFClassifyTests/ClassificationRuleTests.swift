import Testing
import PFCore
@testable import PFClassify

@Suite("Photo classification rules")
struct ClassificationRuleTests {
    func cats(_ s: ClassificationSignals) -> Set<PhotoCategory> {
        Set(ClassificationRules.classify(s).filter { $0.confidence >= ClassificationRules.threshold }.map(\.category))
    }
    let camera = PhotoMetadata(filename: "IMG_4021.HEIC", uti: "public.heic", cameraMake: "Apple", cameraModel: "iPhone 13",
                               hasCameraData: true, hasAnyExif: true)
    let stripped = PhotoMetadata(filename: "photo.jpg", uti: "public.jpeg", hasCameraData: false, hasAnyExif: false)

    @Test func cameraPhoto() {
        let d = ClassificationRules.classify(.init(metadata: camera, width: 4032, height: 3024))
        #expect(Set(d.map(\.category)) == [.camera])
        #expect(d.first?.reason == "Taken with iPhone 13")
    }

    @Test func screenshotBySubtypeAndName() {
        #expect(cats(.init(metadata: .init(filename: "IMG_1.PNG"), width: 1170, height: 2532, isScreenshotSubtype: true)) == [.screenshot])
        #expect(cats(.init(metadata: .init(filename: "Screenshot 2024-03-02 at 10.11.12.png"), width: 2880, height: 1800)).contains(.screenshot))
        #expect(cats(.init(metadata: .init(filename: "x.png", uti: "public.png", hasCameraData: false, hasAnyExif: false),
                           width: 1179, height: 2556)).contains(.screenshot))
    }

    @Test func screenshotFullOfTextIsNotADocument() {
        let s = ClassificationSignals(metadata: .init(filename: "Screenshot.png"), width: 1170, height: 2532,
                                      isScreenshotSubtype: true, textCharacters: 900, textAreaFraction: 0.4, text: "lots of text")
        #expect(cats(s) == [.screenshot])
    }

    @Test func whatsappByNameAndByShape() {
        #expect(cats(.init(metadata: .init(filename: "IMG-20240315-WA0012.jpg"), width: 1600, height: 1200)).contains(.whatsapp))
        #expect(cats(.init(metadata: .init(filename: "WhatsApp Image 2024-03-15 at 10.22.01.jpeg"), width: 1280, height: 960)).contains(.whatsapp))
        #expect(cats(.init(metadata: stripped, width: 1600, height: 1200)).contains(.whatsapp))
        // Unknown metadata (e.g. original only in iCloud) must NOT be treated as "no camera data".
        #expect(!cats(.init(metadata: .init(filename: "photo.jpg", uti: "public.jpeg"), width: 1600, height: 1200)).contains(.whatsapp))
    }

    @Test func socialMedia() {
        #expect(cats(.init(metadata: .init(filename: "FB_IMG_1712345678901.jpg"), width: 960, height: 720)).contains(.socialMedia))
        let post = PhotoMetadata(filename: "a.jpg", uti: "public.jpeg", hasCameraData: false, hasAnyExif: true)
        #expect(cats(.init(metadata: post, width: 1080, height: 1350, textCharacters: 40)).contains(.socialMedia))
        #expect(!cats(.init(metadata: camera, width: 1080, height: 1350)).contains(.socialMedia))
    }

    @Test func documentAndReceipt() {
        let receipt = ClassificationSignals(metadata: camera, width: 3024, height: 4032, documentConfidence: 0.95,
                                            documentAreaFraction: 0.6, textCharacters: 320, textAreaFraction: 0.2,
                                            text: "sharma traders\ninvoice no 41\ncgst 9% sgst 9%\ntotal ₹ 1,180")
        let c = cats(receipt)
        #expect(c.contains(.document) && c.contains(.receipt))
        #expect(!c.contains(.camera))           // a photographed page is a document, not a "camera photo"
        let reason = ClassificationRules.classify(receipt).first { $0.category == .receipt }?.reason ?? ""
        #expect(reason.contains("“total”") || reason.contains("“invoice”"))
    }

    @Test func plainPhotoWithASignIsNotADocument() {
        #expect(!cats(.init(metadata: camera, width: 4032, height: 3024, textCharacters: 30, textAreaFraction: 0.01, text: "exit")).contains(.document))
    }

    @Test func qrCode() {
        #expect(cats(.init(metadata: stripped, width: 800, height: 800, barcodeCount: 1)).contains(.qrCode))
    }

    @Test func noDuplicateTableEntries() {
        // Set literals with duplicates trap at launch; this also guards future edits.
        #expect(ClassificationRules.screenSizes.count > 30)
        #expect(ClassificationRules.socialSizes.count > 10)
    }
}
