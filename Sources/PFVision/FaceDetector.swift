import Foundation
import Vision
import CoreGraphics
import ImageIO
import PFCore

/// One detected face, in coordinates normalized to the *oriented* image
/// (top-left origin, 0…1), ready to store in `faces`.
public struct DetectedFace: Sendable {
    public let boundingBox: CGRect          // normalized, top-left origin
    public let fivePoints: [CGPoint]        // pixel coords, top-left origin: eyeL, eyeR, nose, mouthL, mouthR (image-left first)
    public let captureQuality: Float?       // VNDetectFaceCaptureQualityRequest, 0…1
    public let roll: Double?
    public let yaw: Double?
    public let pitch: Double?
    public let pixelSize: CGFloat           // face box height in source pixels
    public let alignedCrop: CGImage?        // 112×112 ArcFace-aligned crop (nil if alignment failed)
}

public struct FaceDetectionConfig: Sendable {
    public var minFacePixels: CGFloat = 36         // smaller faces are unreliable for recognition
    public var minCaptureQuality: Float = 0.25     // below this, detect but do not embed
    public var alignedSize: Int = 112
    public init() {}
}

/// Vision-based detector. Stateless and Sendable; run many in a TaskGroup.
public struct FaceDetector: Sendable {
    public let config: FaceDetectionConfig
    public init(config: FaceDetectionConfig = .init()) { self.config = config }

    /// - Parameters:
    ///   - image: pixels as decoded. For PhotoKit images this is already upright.
    ///   - orientation: EXIF orientation for raw file imports (use `orientation(of:)`).
    public func detect(in image: CGImage,
                       orientation: CGImagePropertyOrientation = .up) throws -> [DetectedFace] {
        // Normalize orientation first so every stored coordinate refers to the upright image.
        let upright = orientation == .up ? image : try Self.applyOrientation(image, orientation)
        let W = CGFloat(upright.width), H = CGFloat(upright.height)

        let landmarks = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: upright, orientation: .up, options: [:])
        try handler.perform([landmarks])
        let faces = landmarks.results ?? []
        guard !faces.isEmpty else { return [] }

        let quality = VNDetectFaceCaptureQualityRequest()
        quality.inputFaceObservations = faces
        try handler.perform([quality])
        // Match quality results back to faces by bounding-box centre rather than by
        // UUID, since result observations are not documented to preserve identity.
        let qualityResults = quality.results ?? []
        func captureQuality(for obs: VNFaceObservation) -> Float? {
            let c = CGPoint(x: obs.boundingBox.midX, y: obs.boundingBox.midY)
            return qualityResults.min(by: {
                hypot($0.boundingBox.midX - c.x, $0.boundingBox.midY - c.y) <
                hypot($1.boundingBox.midX - c.x, $1.boundingBox.midY - c.y)
            })?.faceCaptureQuality
        }

        return faces.compactMap { obs -> DetectedFace? in
            // Vision boxes are normalized with a bottom-left origin; flip to top-left.
            let bb = obs.boundingBox
            let box = CGRect(x: bb.minX, y: 1 - bb.maxY, width: bb.width, height: bb.height)
            let pxHeight = bb.height * H
            guard pxHeight >= config.minFacePixels else { return nil }

            let q = captureQuality(for: obs)
            let pts = Self.fivePoints(obs, imageSize: CGSize(width: W, height: H))
            var crop: CGImage? = nil
            if let pts, (q ?? 1) >= config.minCaptureQuality {
                crop = FaceAligner.align(upright, points: pts, outputSize: config.alignedSize)
            }
            return DetectedFace(boundingBox: box, fivePoints: pts ?? [], captureQuality: q,
                                roll: obs.roll?.doubleValue, yaw: obs.yaw?.doubleValue,
                                pitch: obs.pitch?.doubleValue, pixelSize: pxHeight, alignedCrop: crop)
        }
    }

    /// Eye centres, nose tip, mouth corners in pixel coords with a top-left origin.
    /// Left/right are assigned by image x-position, matching the ArcFace template.
    static func fivePoints(_ obs: VNFaceObservation, imageSize: CGSize) -> [CGPoint]? {
        guard let lm = obs.landmarks,
              let le = lm.leftEye, let re = lm.rightEye,
              let nose = lm.nose, let lips = lm.outerLips else { return nil }

        func toTopLeft(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: imageSize.height - p.y) }
        func centroid(_ r: VNFaceLandmarkRegion2D) -> CGPoint {
            let pts = r.pointsInImage(imageSize: imageSize)
            let sx = pts.reduce(0) { $0 + $1.x }, sy = pts.reduce(0) { $0 + $1.y }
            return toTopLeft(CGPoint(x: sx / CGFloat(pts.count), y: sy / CGFloat(pts.count)))
        }
        let eyes = [centroid(le), centroid(re)].sorted { $0.x < $1.x }
        let lipPts = lips.pointsInImage(imageSize: imageSize).map(toTopLeft)
        guard let mL = lipPts.min(by: { $0.x < $1.x }), let mR = lipPts.max(by: { $0.x < $1.x }) else { return nil }
        // Nose tip ≈ the lowest point of the nose outline (largest y in top-left coords).
        let nosePts = nose.pointsInImage(imageSize: imageSize).map(toTopLeft)
        guard let tip = nosePts.max(by: { $0.y < $1.y }) else { return nil }
        return [eyes[0], eyes[1], tip, mL, mR]
    }

    public static func orientation(of url: URL) -> CGImagePropertyOrientation {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let raw = props[kCGImagePropertyOrientation] as? UInt32,
              let o = CGImagePropertyOrientation(rawValue: raw) else { return .up }
        return o
    }

    static func applyOrientation(_ image: CGImage, _ o: CGImagePropertyOrientation) throws -> CGImage {
        let ci = CIImageBridge.oriented(image, o)
        guard let out = ci else { throw PhotoForgeError.corruptImage }
        return out
    }
}

/// 5-point similarity alignment to the standard ArcFace 112×112 template.
public enum FaceAligner {
    /// ArcFace reference landmarks for a 112×112 crop (top-left origin).
    public static let arcFaceTemplate: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014),
        CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655), CGPoint(x: 70.7299, y: 92.2041),
    ]

    /// Least-squares similarity transform (rotation, uniform scale, translation)
    /// mapping `src` to `dst` — the 2-D closed form of Umeyama (1991).
    /// Returned transform maps top-left-origin source pixels to top-left-origin dest pixels.
    public static func similarityTransform(from src: [CGPoint], to dst: [CGPoint]) -> CGAffineTransform? {
        guard src.count == dst.count, src.count >= 2 else { return nil }
        let n = CGFloat(src.count)
        let ms = CGPoint(x: src.map(\.x).reduce(0, +) / n, y: src.map(\.y).reduce(0, +) / n)
        let md = CGPoint(x: dst.map(\.x).reduce(0, +) / n, y: dst.map(\.y).reduce(0, +) / n)
        var a: CGFloat = 0, b: CGFloat = 0, v: CGFloat = 0
        for (p, q) in zip(src, dst) {
            let px = p.x - ms.x, py = p.y - ms.y, qx = q.x - md.x, qy = q.y - md.y
            a += px * qx + py * qy
            b += px * qy - py * qx
            v += px * px + py * py
        }
        guard v > 1e-9 else { return nil }
        let sc = a / v, ss = b / v                 // s·cosθ, s·sinθ
        let tx = md.x - (sc * ms.x - ss * ms.y)
        let ty = md.y - (ss * ms.x + sc * ms.y)
        // CG convention: x' = a·x + c·y + tx ; y' = b·x + d·y + ty
        return CGAffineTransform(a: sc, b: ss, c: -ss, d: sc, tx: tx, ty: ty)
    }

    public static func align(_ image: CGImage, points: [CGPoint], outputSize: Int = 112) -> CGImage? {
        let scale = CGFloat(outputSize) / 112
        let template = arcFaceTemplate.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
        guard let T = similarityTransform(from: points, to: template) else { return nil }

        let S = CGFloat(outputSize), H = CGFloat(image.height)
        guard let ctx = CGContext(data: nil, width: outputSize, height: outputSize, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        // CGContext draws in bottom-left coordinates on both sides, so conjugate T with y-flips:
        // user space (source, bottom-left) → source top-left → T → dest top-left → dest bottom-left.
        let flipSrc = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: H)
        let flipDst = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: S)
        ctx.concatenate(flipSrc.concatenating(T).concatenating(flipDst))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }
}

import CoreImage
enum CIImageBridge {
    static let context = CIContext(options: [.useSoftwareRenderer: false])
    static func oriented(_ image: CGImage, _ o: CGImagePropertyOrientation) -> CGImage? {
        let ci = CIImage(cgImage: image).oriented(o)
        return context.createCGImage(ci, from: ci.extent)
    }
}
