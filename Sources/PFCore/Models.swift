import Foundation

// MARK: - Identifiers

public struct AssetID: Hashable, Sendable, Codable, Comparable {
    public let rawValue: Int64
    public init(_ v: Int64) { rawValue = v }
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public struct FaceID: Hashable, Sendable, Codable, Comparable {
    public let rawValue: Int64
    public init(_ v: Int64) { rawValue = v }
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public struct PersonID: Hashable, Sendable, Codable {
    public let rawValue: Int64
    public init(_ v: Int64) { rawValue = v }
}

// MARK: - Pipeline stages (assets.analysisStage bitmask)

/// Multi-stage analysis. Each stage is idempotent and recorded as a bit so an
/// interrupted scan resumes where it stopped instead of re-indexing everything.
public struct IndexStage: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let metadata        = IndexStage(rawValue: 1 << 0)
    public static let thumbnailHashes = IndexStage(rawValue: 1 << 1)  // pHash, dHash, quality
    public static let fileHash        = IndexStage(rawValue: 1 << 2)  // SHA-256 of original (may need iCloud)
    public static let faces           = IndexStage(rawValue: 1 << 3)
    public static let faceEmbeddings  = IndexStage(rawValue: 1 << 4)
    public static let sceneEmbedding  = IndexStage(rawValue: 1 << 5)
    public static let ocr             = IndexStage(rawValue: 1 << 6)

    public static let all: IndexStage = [.metadata, .thumbnailHashes, .fileHash, .faces,
                                         .faceEmbeddings, .sceneEmbedding, .ocr]
}

// MARK: - Common enums (mirror CHECK constraints in 0001_initial.sql)

public enum LocalAvailability: String, Sendable, Codable {
    case local, cloudOnly = "cloud_only", downloading, unavailable, unknown
}

public enum DuplicateGroupType: String, Sendable, Codable, CaseIterable {
    case exact, near, burst, similar
}

public enum PersonConfidence: String, Sendable, Codable, Comparable {
    case lowConfidence = "low_confidence", needsReview = "needs_review", likely, confirmed

    private var order: Int {
        switch self { case .lowConfidence: 0; case .needsReview: 1; case .likely: 2; case .confirmed: 3 }
    }
    public static func < (a: Self, b: Self) -> Bool { a.order < b.order }

    /// Label shown in the UI. Unconfirmed clusters are never presented as a named identity.
    public var displayLabel: String {
        switch self {
        case .confirmed: "Confirmed"
        case .likely: "Likely"
        case .needsReview: "Needs review"
        case .lowConfidence: "Low confidence"
        }
    }
}

public enum ExecutionLocation: String, Sendable, Codable { case local, cloud }

// MARK: - Errors

public enum PhotoForgeError: Error, Sendable, Equatable {
    case photosAccessDenied
    case photosAccessLimited
    case assetUnavailable(localIdentifier: String)
    case iCloudDownloadRequired(localIdentifier: String)
    case unsupportedFormat(uti: String)
    case corruptImage
    case modelMissing(name: String)
    case modelLicenseNotDistributable(name: String)
    case cancelled
    case policyBlocked(reason: String)
}
