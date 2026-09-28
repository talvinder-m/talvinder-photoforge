import Foundation
import PFCore
import PFSafety

/// Non-destructive edit recipe. The source pixels are never modified; rendering
/// replays `layers` over the original. Serialized to edit_projects.editStackJSON.
public struct EditStack: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version = EditStack.currentVersion
    public var source: SourceReference
    public var layers: [EditLayer] = []
    public var undoCursor: Int? = nil          // layers beyond this index are "redo" history

    public init(source: SourceReference) { self.source = source }

    public var activeLayers: ArraySlice<EditLayer> { layers.prefix(undoCursor ?? layers.count) }
    public var containsGenerative: Bool { activeLayers.contains { $0.isGenerative && $0.enabled } }

    public mutating func push(_ layer: EditLayer) {
        if let c = undoCursor { layers.removeSubrange(c...) ; undoCursor = nil }  // new edit discards redo tail
        layers.append(layer)
    }
    public mutating func undo() { undoCursor = max(0, (undoCursor ?? layers.count) - 1) }
    public mutating func redo() {
        guard let c = undoCursor else { return }
        undoCursor = c + 1 >= layers.count ? nil : c + 1
    }
    /// "Revert to original" — keeps history so the user can step forward again.
    public mutating func revertToOriginal() { undoCursor = 0 }

    public func encoded() throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return String(decoding: try enc.encode(self), as: UTF8.self)
    }

    public static func decode(_ json: String) throws -> EditStack {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var stack = try dec.decode(EditStack.self, from: Data(json.utf8))
        stack = try migrate(stack)
        return stack
    }

    /// Forward-migrates older recipes. Add a case per bump of `currentVersion`.
    static func migrate(_ s: EditStack) throws -> EditStack {
        guard s.version <= currentVersion else { throw DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "Edit stack v\(s.version) is newer than this app")) }
        return s
    }
}

public struct SourceReference: Codable, Sendable, Equatable {
    public var photoKitLocalIdentifier: String?
    public var filePath: String?
    public var sha256Hex: String?
    public var accessedAt: Date
    public init(photoKitLocalIdentifier: String? = nil, filePath: String? = nil, sha256Hex: String? = nil, accessedAt: Date) {
        self.photoKitLocalIdentifier = photoKitLocalIdentifier; self.filePath = filePath
        self.sha256Hex = sha256Hex; self.accessedAt = accessedAt
    }
}

public struct EditLayer: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var enabled = true
    public var opacity = 1.0
    public var mask: MaskReference?
    public var operation: Operation
    public var createdAt: Date

    public init(operation: Operation, mask: MaskReference? = nil, createdAt: Date = .now) {
        self.operation = operation; self.mask = mask; self.createdAt = createdAt
    }

    public var isGenerative: Bool { if case .generative = operation { true } else { false } }

    public enum Operation: Codable, Sendable, Equatable {
        case adjust(Adjustments)
        case crop(CropSpec)
        case aiEnhance(tool: AITool, model: ModelStamp, strength: Double)
        case generative(GenerativeRecord)
    }
}

public struct Adjustments: Codable, Sendable, Equatable {
    public var exposure = 0.0, contrast = 0.0, highlights = 0.0, shadows = 0.0, whites = 0.0, blacks = 0.0
    public var temperature = 0.0, tint = 0.0, vibrance = 0.0, saturation = 0.0
    public var clarity = 0.0, texture = 0.0, dehaze = 0.0, vignette = 0.0, grain = 0.0
    public var sharpness = 0.0, noiseReduction = 0.0
    public var toneCurve: [CurvePoint]? = nil
    public init() {}
}
public struct CurvePoint: Codable, Sendable, Equatable {
    public var x: Double; public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct CropSpec: Codable, Sendable, Equatable {
    public var rect: [Double]            // normalized x, y, w, h (top-left origin)
    public var angle: Double             // radians
    public var flipH: Bool, flipV: Bool
    public init(rect: [Double], angle: Double, flipH: Bool, flipV: Bool) {
        self.rect = rect; self.angle = angle; self.flipH = flipH; self.flipV = flipV
    }
}

public enum AITool: String, Codable, Sendable {
    case autoEnhance, denoise, deblur, upscale, jpegArtifacts, colorize, restore, dustAndScratch,
         faceRestore, backgroundRemoval, depthBlur, documentCleanup
}

public struct ModelStamp: Codable, Sendable, Equatable {
    public var name: String, version: String, license: String
    public var execution: String         // "local" | "cloud:<provider>"
}

/// Everything needed to reproduce or audit a generative change.
public struct GenerativeRecord: Codable, Sendable, Equatable {
    public var operation: GenerativeOperation
    public var prompt: String
    public var negativePrompt: String?
    public var seed: UInt64
    public var steps: Int
    public var guidance: Double
    public var model: ModelStamp
    public var resultAssetPath: String   // generated pixels live beside the project, never over the source
    public var policyLabel: String?      // e.g. "Adult content · edited locally"
    /// Always shown in history and embedded in exports (XMP + optional C2PA manifest).
    public var disclosure = "AI-generated alteration"
}

public struct MaskReference: Codable, Sendable, Equatable {
    public var path: String              // 8-bit mask PNG in the project folder
    public var kind: String              // brush | subject | sky | person | object | semantic
}
