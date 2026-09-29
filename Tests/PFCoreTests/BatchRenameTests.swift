import Testing
import Foundation
@testable import PFCore

@Suite("Batch rename")
struct BatchRenameTests {
    let date = ISO8601DateFormatter().date(from: "2024-03-12T09:05:07Z")!
    var items: [BatchRename.Item] {
        (0..<3).map { .init(currentName: "IMG_40\($0)1.HEIC", date: date, camera: "iPhone 13") }
    }

    @Test func patternWithCounterAndDate() {
        var r = BatchRename()
        r.pattern = "Farm Visit {date} {n}"
        r.start = 9
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let names = r.apply(to: items)
        #expect(names.count == 3)
        #expect(names[0].hasPrefix("Farm Visit 2024-03-1") && names[0].hasSuffix(" 009"))
        #expect(names[2].hasSuffix(" 011"))
    }

    @Test func nameTokenDropsExtension() {
        var r = BatchRename(); r.pattern = "{name} - {camera}"
        #expect(r.apply(to: items)[0] == "IMG_4001 - iPhone 13")
    }

    @Test func findReplaceAndPrefix() {
        var r = BatchRename(); r.mode = .findReplace; r.find = "img_"; r.replace = "Seeds "
        #expect(r.apply(to: items)[1] == "Seeds 4011")
        r.mode = .prefixSuffix; r.prefix = "Hillsprouts "; r.suffix = " (farm)"
        #expect(r.apply(to: items)[0] == "Hillsprouts IMG_4001 (farm)")
    }

    @Test func unsafeCharactersAndEmptyResults() {
        var r = BatchRename(); r.pattern = "a/b:c"
        #expect(r.apply(to: items)[0] == "a-b-c")
        r.pattern = "   "
        #expect(r.apply(to: items)[0] == "IMG_4001")        // empty falls back to the current name
    }

    @Test func uniquing() {
        #expect(BatchRename.uniqued(["Farm", "farm", "Farm", "Seeds"]) == ["Farm", "farm 2", "Farm 3", "Seeds"])
    }

    @Test func stems() {
        #expect(BatchRename.nameStem("Farm Visit 012.jpg") == "Farm Visit")
        #expect(BatchRename.nameStem("Farm Visit-013") == "Farm Visit")
        #expect(BatchRename.nameStem("IMG_4021.HEIC") == "IMG")
        #expect(BatchRename.nameStem("Receipt (3).png") == "Receipt")
        #expect(BatchRename.nameStem("2024") == "2024")
    }
}
