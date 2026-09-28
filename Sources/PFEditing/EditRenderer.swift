import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

/// Renders an `EditStack` over the original pixels with Core Image. Pure function of
/// (source, recipe): the source is never modified, so every edit is reversible.
public final class EditRenderer: @unchecked Sendable {
    public let context: CIContext

    public init() {
        context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                      .cacheIntermediates: false])
    }

    /// Loads image data with its EXIF orientation applied.
    public static func image(from data: Data) -> CIImage? {
        CIImage(data: data, options: [.applyOrientationProperty: true])
    }

    public func render(_ source: CIImage, stack: EditStack) -> CIImage {
        var img = source
        for layer in stack.activeLayers where layer.enabled {
            switch layer.operation {
            case .adjust(let a): img = apply(a, to: img)
            case .crop(let c): img = apply(c, to: img)
            case .aiEnhance, .generative: continue   // not available in this build
            }
        }
        return img
    }

    public func apply(_ a: Adjustments, to input: CIImage) -> CIImage {
        let extent = input.extent
        // Blur-based filters (clarity, dehaze, sharpening, noise reduction) read beyond the
        // edges and grow the extent; clamp first so edges stay clean, crop back at the end.
        var img = input.clampedToExtent()
        if a.exposure != 0 {
            let f = CIFilter.exposureAdjust(); f.inputImage = img; f.ev = Float(a.exposure); img = f.outputImage ?? img
        }
        if a.temperature != 0 || a.tint != 0 {
            // Slider −1…1 maps to ±2000 K around neutral 6500 K, tint to ±50.
            let f = CIFilter.temperatureAndTint(); f.inputImage = img
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: 6500 - CGFloat(a.temperature) * 2000, y: CGFloat(a.tint) * 50)
            img = f.outputImage ?? img
        }
        if a.highlights != 0 || a.shadows != 0 {
            let f = CIFilter.highlightShadowAdjust(); f.inputImage = img
            f.highlightAmount = Float(max(0.1, 1 - max(0, -a.highlights) * 0.9))   // filter can only recover highlights
            f.shadowAmount = Float(a.shadows)
            img = f.outputImage ?? img
        }
        if a.whites != 0 || a.blacks != 0 {
            // Move the white and black points with a tone curve.
            let f = CIFilter.toneCurve(); f.inputImage = img
            let b = CGFloat(a.blacks) * 0.1, w = CGFloat(a.whites) * 0.1
            f.point0 = CGPoint(x: 0, y: max(0, b)); f.point1 = CGPoint(x: 0.25, y: 0.25 + b * 0.5)
            f.point2 = CGPoint(x: 0.5, y: 0.5); f.point3 = CGPoint(x: 0.75, y: 0.75 + w * 0.5)
            f.point4 = CGPoint(x: 1, y: min(1, 1 + w))
            img = f.outputImage ?? img
        }
        if a.contrast != 0 || a.saturation != 0 {
            let f = CIFilter.colorControls(); f.inputImage = img
            f.contrast = Float(1 + a.contrast * 0.5)
            f.saturation = Float(1 + a.saturation)
            f.brightness = 0
            img = f.outputImage ?? img
        }
        if a.vibrance != 0 {
            let f = CIFilter.vibrance(); f.inputImage = img; f.amount = Float(a.vibrance); img = f.outputImage ?? img
        }
        if a.dehaze != 0 {
            // Approximation: local contrast + slight saturation lift.
            let f = CIFilter.unsharpMask(); f.inputImage = img; f.radius = 40; f.intensity = Float(a.dehaze) * 0.5
            img = f.outputImage ?? img
        }
        if a.clarity != 0 {
            let f = CIFilter.unsharpMask(); f.inputImage = img; f.radius = 12; f.intensity = Float(a.clarity) * 0.8
            img = f.outputImage ?? img
        }
        if a.noiseReduction > 0 {
            let f = CIFilter.noiseReduction(); f.inputImage = img
            f.noiseLevel = Float(a.noiseReduction) * 0.05; f.sharpness = 0.4
            img = f.outputImage ?? img
        }
        if a.sharpness > 0 || a.texture > 0 {
            let f = CIFilter.sharpenLuminance(); f.inputImage = img
            f.sharpness = Float(a.sharpness + a.texture * 0.5); f.radius = 1.5
            img = f.outputImage ?? img
        }
        if let curve = a.toneCurve, curve.count == 5 {
            let f = CIFilter.toneCurve(); f.inputImage = img
            let p = curve.map { CGPoint(x: $0.x, y: $0.y) }
            f.point0 = p[0]; f.point1 = p[1]; f.point2 = p[2]; f.point3 = p[3]; f.point4 = p[4]
            img = f.outputImage ?? img
        }
        if a.vignette != 0 {
            let f = CIFilter.vignetteEffect(); f.inputImage = img
            f.center = CGPoint(x: extent.midX, y: extent.midY)
            f.radius = Float(hypot(extent.width, extent.height) / 2 * 0.75)
            f.intensity = Float(a.vignette)
            f.falloff = 0.6
            img = f.outputImage ?? img
        }
        if a.grain > 0 {
            let noise = CIFilter.randomGenerator().outputImage!
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 1, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 1, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(a.grain) * 0.15),
                    "inputBiasVector": CIVector(x: -0.5, y: -0.5, z: -0.5, w: 0)])
                .cropped(to: extent)
            img = noise.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: img])
        }
        return img.cropped(to: extent)
    }

    public func apply(_ c: CropSpec, to input: CIImage) -> CIImage {
        var img = input
        if c.angle != 0 {
            let f = CIFilter.straighten(); f.inputImage = img; f.angle = Float(c.angle); img = f.outputImage ?? img
        }
        if c.flipH { img = img.transformed(by: CGAffineTransform(scaleX: -1, y: 1)) }
        if c.flipV { img = img.transformed(by: CGAffineTransform(scaleX: 1, y: -1)) }
        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        if c.rect.count == 4, c.rect != [0, 0, 1, 1] {
            let e = img.extent
            // rect is normalized with a top-left origin; Core Image is bottom-left.
            let r = CGRect(x: e.width * c.rect[0], y: e.height * (1 - c.rect[1] - c.rect[3]),
                           width: e.width * c.rect[2], height: e.height * c.rect[3])
            img = img.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
        }
        return img
    }

    public func cgImage(_ img: CIImage, maxDimension: CGFloat? = nil) -> CGImage? {
        var i = img
        if let m = maxDimension {
            let s = min(1, m / max(img.extent.width, img.extent.height))
            if s < 1 { i = img.transformed(by: CGAffineTransform(scaleX: s, y: s)) }
        }
        return context.createCGImage(i, from: i.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// Writes a JPEG or HEIC with the given metadata (EXIF/IPTC/XMP can be preserved or stripped).
    public func write(_ img: CIImage, to url: URL, type: UTType, quality: Double = 0.92,
                      metadata: [CFString: Any]? = nil) throws {
        guard let cg = cgImage(img),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var props: [CFString: Any] = metadata ?? [:]
        props[kCGImageDestinationLossyCompressionQuality] = quality
        props[kCGImagePropertyOrientation] = 1       // pixels are already upright
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Source metadata minus GPS (and optionally everything), for export.
    public static func exportMetadata(from data: Data, stripAll: Bool, removeGPS: Bool) -> [CFString: Any] {
        guard !stripAll, let src = CGImageSourceCreateWithData(data as CFData, nil),
              var props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return [:] }
        if removeGPS { props.removeValue(forKey: kCGImagePropertyGPSDictionary) }
        props.removeValue(forKey: kCGImagePropertyOrientation)
        props.removeValue(forKey: kCGImagePropertyPixelWidth)
        props.removeValue(forKey: kCGImagePropertyPixelHeight)
        return props
    }
}
