import Foundation
import PFCore

/// Safety gate for generative edits and the opt-in adult-content workflow.
///
/// Design principles (see docs/PRIVACY_AND_SAFETY.md):
///  • Hard blocks cannot be overridden by any setting.
///  • Local adult-content editing is allowed only for the user's own lawful media,
///    only when explicitly enabled, and never adds sexual content to real people.
///  • Everything is evaluated on-device; nothing is uploaded to decide.
///  • Classifier outputs are used transiently for gating and are never stored as
///    attributes of a person (no age/sensitive-trait inference is persisted).

public enum GenerativeOperation: String, Sendable, Codable, CaseIterable {
    case inpaint, outpaint, objectRemoval, backgroundReplace, relight, styleTransfer, regionEnhance
    // Deliberately not offered: face swap, identity transfer, age transformation,
    // watermark removal, "undress"-type edits. The enum has no cases for them.
}

/// Local classifier signals. Scores are 0…1 probabilities from on-device models
/// listed in the model registry (purpose = .safetyClassifier).
public struct SafetySignals: Sendable {
    public var sourceExplicitness: Double      // how sexually explicit the source already is
    public var outputExplicitness: Double      // explicitness of the generated result
    public var minorLikelihood: Double         // max over people in source OR output; conservative
    public var realPersonPresent: Bool         // a detected human face/body in source (Vision)
    public init(sourceExplicitness: Double, outputExplicitness: Double,
                minorLikelihood: Double, realPersonPresent: Bool) {
        self.sourceExplicitness = sourceExplicitness; self.outputExplicitness = outputExplicitness
        self.minorLikelihood = minorLikelihood; self.realPersonPresent = realPersonPresent
    }
}

public struct AdultWorkflowState: Sendable {
    /// Set only after the user reads the privacy/legality notice and confirms that
    /// the media is their own, lawful, and consensual. Stored in settings; revocable.
    public var enabled: Bool
    public var acknowledgedAt: Date?
    public init(enabled: Bool, acknowledgedAt: Date?) { self.enabled = enabled; self.acknowledgedAt = acknowledgedAt }
    public var isActive: Bool { enabled && acknowledgedAt != nil }
}

public enum PolicyDecision: Sendable, Equatable {
    case allow
    case allowWithLabel(String)                       // e.g. adult-content label in edit history
    case block(reason: String, hard: Bool)            // hard = no setting can change this
}

public struct GenerativeEditPolicy: Sendable {
    public var explicitThreshold = 0.5
    public var minorThreshold = 0.2                   // deliberately low: false positives are acceptable here
    public var escalationMargin = 0.15                // output may not be meaningfully more explicit than source
    public init() {}

    /// Pre-flight check on the request, before any pixels are generated.
    public func checkRequest(prompt: String, operation: GenerativeOperation,
                             signals: SafetySignals, adult: AdultWorkflowState) -> PolicyDecision {
        let p = prompt.lowercased()
        let sexualIntent = Self.sexualTerms.contains { p.contains($0) }
        let minorTerms = Self.minorTerms.contains { Self.containsWord(p, $0) }

        if (sexualIntent || signals.sourceExplicitness >= explicitThreshold)
            && (minorTerms || signals.minorLikelihood >= minorThreshold) {
            return .block(reason: "Sexual content involving anyone who may be a minor is never allowed.", hard: true)
        }
        if sexualIntent && signals.realPersonPresent && signals.sourceExplicitness < explicitThreshold {
            return .block(reason: "Generative edits can't make a photo of a real person sexual or nude. "
                                 + "This protects against non-consensual intimate imagery.", hard: true)
        }
        if sexualIntent && !adult.isActive {
            return .block(reason: "Adult-content editing is off. You can enable local adult-content editing "
                                 + "for lawful, consensual, user-owned media in Settings › Privacy.", hard: false)
        }
        return .allow
    }

    /// Post-generation check on the actual output. Runs even if the request passed.
    public func checkOutput(signals: SafetySignals, adult: AdultWorkflowState) -> PolicyDecision {
        let explicitOut = signals.outputExplicitness >= explicitThreshold
        if (explicitOut || signals.sourceExplicitness >= explicitThreshold) && signals.minorLikelihood >= minorThreshold {
            return .block(reason: "Result blocked: sexual content with a person who may be a minor.", hard: true)
        }
        // No escalation: generation must not make a real person's image more explicit than it was.
        if signals.realPersonPresent && explicitOut
            && signals.outputExplicitness > signals.sourceExplicitness + escalationMargin {
            return .block(reason: "Result blocked: the edit added sexual content to a photo of a real person.", hard: true)
        }
        if explicitOut && !adult.isActive {
            return .block(reason: "Result contains adult content and adult-content editing is off.", hard: false)
        }
        if explicitOut {
            return .allowWithLabel("Adult content · edited locally")
        }
        return .allow
    }

    /// Non-generative adjustments (exposure, crop, denoise…) on the user's own media.
    /// Only the minor check applies; ordinary retouching of lawful adult media is allowed
    /// when the workflow is active.
    public func checkConventionalEdit(signals: SafetySignals, adult: AdultWorkflowState) -> PolicyDecision {
        if signals.sourceExplicitness >= explicitThreshold && signals.minorLikelihood >= minorThreshold {
            return .block(reason: "This image can't be edited.", hard: true)
        }
        if signals.sourceExplicitness >= explicitThreshold && !adult.isActive {
            return .block(reason: "Adult-content editing is off.", hard: false)
        }
        return .allow
    }

    // Prompt screens are a first, cheap layer only; the classifiers above are the real gate.
    static let sexualTerms = ["nude", "naked", "topless", "undress", "nsfw", "explicit", "sexual", "lingerie", "porn"]
    static let minorTerms = ["child", "children", "kid", "kids", "teen", "teenage", "underage", "minor", "schoolgirl",
                             "schoolboy", "young-looking", "loli", "shota", "baby", "toddler"]

    static func containsWord(_ text: String, _ word: String) -> Bool {
        text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b", options: .regularExpression) != nil
    }
}
