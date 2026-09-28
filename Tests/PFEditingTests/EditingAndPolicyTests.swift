import Testing
import Foundation
@testable import PFEditing
@testable import PFSafety

@Suite("Edit stack")
struct EditStackTests {
    func sample() -> EditStack {
        var s = EditStack(source: .init(photoKitLocalIdentifier: "ABC/L0/001", sha256Hex: "ab12",
                                        accessedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        var adj = Adjustments(); adj.exposure = 0.4; adj.toneCurve = [.init(x: 0, y: 0), .init(x: 1, y: 0.95)]
        s.push(EditLayer(operation: .adjust(adj), createdAt: Date(timeIntervalSince1970: 1_700_000_100)))
        s.push(EditLayer(operation: .generative(GenerativeRecord(
            operation: .objectRemoval, prompt: "", negativePrompt: nil, seed: 42, steps: 20, guidance: 5,
            model: .init(name: "lama", version: "1.0", license: "Apache-2.0", execution: "local"),
            resultAssetPath: "gen/0001.png", policyLabel: nil)),
            mask: .init(path: "masks/0001.png", kind: "brush"), createdAt: Date(timeIntervalSince1970: 1_700_000_200)))
        return s
    }

    @Test func roundTripsThroughJSON() throws {
        let s = sample()
        let decoded = try EditStack.decode(try s.encoded())
        #expect(decoded == s)
        #expect(decoded.containsGenerative)
    }

    @Test func undoRedoAndRevert() {
        var s = sample()
        s.undo(); #expect(s.activeLayers.count == 1 && !s.containsGenerative)
        s.redo(); #expect(s.activeLayers.count == 2)
        s.revertToOriginal(); #expect(s.activeLayers.isEmpty && s.layers.count == 2)   // history kept
        s.redo(); s.push(EditLayer(operation: .crop(.init(rect: [0, 0, 1, 1], angle: 0, flipH: false, flipV: false))))
        #expect(s.layers.count == 2)                      // pushing after undo discards the redo tail
    }

    @Test func rejectsRecipesFromTheFuture() throws {
        var s = sample(); s.version = EditStack.currentVersion + 1
        let json = try s.encoded()
        #expect(throws: DecodingError.self) { try EditStack.decode(json) }
    }

    @Test func generativeLayersCarryDisclosure() throws {
        guard case .generative(let rec) = sample().layers[1].operation else { Issue.record("expected generative"); return }
        #expect(rec.disclosure == "AI-generated alteration")
    }
}

@Suite("Generative edit policy")
struct PolicyTests {
    let policy = GenerativeEditPolicy()
    let adultOn = AdultWorkflowState(enabled: true, acknowledgedAt: .now)
    let adultOff = AdultWorkflowState(enabled: false, acknowledgedAt: nil)
    func sig(_ src: Double, _ out: Double = 0, minor: Double = 0, real: Bool = true) -> SafetySignals {
        .init(sourceExplicitness: src, outputExplicitness: out, minorLikelihood: minor, realPersonPresent: real)
    }
    func isHardBlock(_ d: PolicyDecision) -> Bool { if case .block(_, true) = d { true } else { false } }
    func isSoftBlock(_ d: PolicyDecision) -> Bool { if case .block(_, false) = d { true } else { false } }

    @Test func neverSexualisesARealPersonEvenWithAdultModeOn() {
        #expect(isHardBlock(policy.checkRequest(prompt: "make her nude", operation: .inpaint, signals: sig(0), adult: adultOn)))
        #expect(isHardBlock(policy.checkOutput(signals: sig(0.1, 0.8), adult: adultOn)))
    }

    @Test func minorsAreAHardBlockInEveryPath() {
        #expect(isHardBlock(policy.checkRequest(prompt: "remove the lamp", operation: .objectRemoval, signals: sig(0.9, minor: 0.3), adult: adultOn)))
        #expect(isHardBlock(policy.checkRequest(prompt: "teen at the beach, nsfw", operation: .inpaint, signals: sig(0, real: false), adult: adultOn)))
        #expect(isHardBlock(policy.checkOutput(signals: sig(0.9, 0.9, minor: 0.25), adult: adultOn)))
        #expect(isHardBlock(policy.checkConventionalEdit(signals: sig(0.9, minor: 0.3), adult: adultOn)))
    }

    @Test func lawfulOwnAdultMediaCanBeEditedLocallyWhenEnabled() {
        #expect(policy.checkRequest(prompt: "replace background with a beach", operation: .backgroundReplace, signals: sig(0.9), adult: adultOn) == .allow)
        #expect(policy.checkOutput(signals: sig(0.9, 0.92), adult: adultOn) == .allowWithLabel("Adult content · edited locally"))
        #expect(policy.checkConventionalEdit(signals: sig(0.9), adult: adultOn) == .allow)
    }

    @Test func adultModeOffIsASoftBlock() {
        #expect(isSoftBlock(policy.checkOutput(signals: sig(0.9, 0.9), adult: adultOff)))
        #expect(isSoftBlock(policy.checkConventionalEdit(signals: sig(0.9), adult: adultOff)))
        #expect(!AdultWorkflowState(enabled: true, acknowledgedAt: nil).isActive)   // toggle alone is not enough
    }

    @Test func ordinaryEditsAreUnaffected() {
        #expect(policy.checkRequest(prompt: "remove the kid's toy from the floor", operation: .objectRemoval, signals: sig(0), adult: adultOff) == .allow)
        #expect(policy.checkOutput(signals: sig(0, 0.05), adult: adultOff) == .allow)
    }
}
