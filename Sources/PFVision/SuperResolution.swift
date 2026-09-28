import Foundation
import CoreML
import CoreImage
import CoreGraphics
import PFCore

/// AI upscaling to a target long edge (e.g. 2K = 2048 px), sized for old Macs:
/// fixed-size tiles keep memory flat, and Core ML runs the network on the GPU through
/// Metal where available (Intel Iris/Radeon included), otherwise on the CPU.
///
/// Methods
///  • `.fast`     FSRCNN ×2/×3/×4 on luma; colour is scaled with Lanczos (how FSRCNN is designed to be used).
///                ~12k parameters: seconds per photo even on a 2015 MacBook Pro.
///  • `.best`     Real-ESRGAN compact ×4 (realesr-general-x4v3) on full RGB, then resized to the target.
///                Adds strong synthetic detail (over-sharpens normal photos; see the CI --srbench report).
///                Useful for very small, soft or heavily compressed images. Slow on older Intel Macs.
///  • `.standard` Lanczos only (no AI), for comparison.
public final class SuperResolution: @unchecked Sendable {
    public enum Method: String, CaseIterable, Sendable, Identifiable {
        case fast, best, standard
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .fast: "AI Detail (FSRCNN) — recommended"
            case .best: "AI Strong (Real-ESRGAN)"
            case .standard: "Standard (Lanczos)"
            }
        }
    }

    public enum SRError: LocalizedError {
        case modelMissing(String), badImage, alreadyLargeEnough
        public var errorDescription: String? {
            switch self {
            case .modelMissing(let m): "The \(m) model isn't included in this build."
            case .badImage: "This image couldn't be processed."
            case .alreadyLargeEnough: "This photo is already at or above the target size."
            }
        }
    }

    public struct Result: Sendable {
        public let image: CGImage
        public let method: Method
        public let modelName: String
        public let factorUsed: Int
        public let seconds: Double
    }

    private let modelsDir: URL?
    private var cache: [String: MLModel] = [:]
    private let lock = NSLock()
    private let ci = CIContext(options: [.cacheIntermediates: false])
    static let fsrcnnTile = 128
    static let esrganTile = 256

    public init(modelsDirectory: URL?) { modelsDir = modelsDirectory }

    public func isAvailable(_ m: Method) -> Bool {
        switch m {
        case .standard: true
        case .fast: modelURL("SR_x2") != nil
        case .best: modelURL("RealESRGANx4v3") != nil
        }
    }

    /// Output size for a target long edge, preserving aspect ratio.
    public static func outputSize(width: Int, height: Int, targetLongEdge: Int) -> (Int, Int) {
        let s = Double(targetLongEdge) / Double(max(width, height))
        return (max(1, Int((Double(width) * s).rounded())), max(1, Int((Double(height) * s).rounded())))
    }

    // MARK: Public entry point

    public func upscale(_ image: CGImage, targetLongEdge: Int, method: Method,
                        progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Result {
        let start = Date()
        let longEdge = max(image.width, image.height)
        guard longEdge < targetLongEdge else { throw SRError.alreadyLargeEnough }
        let (outW, outH) = Self.outputSize(width: image.width, height: image.height, targetLongEdge: targetLongEdge)
        let need = Double(targetLongEdge) / Double(longEdge)

        switch method {
        case .standard:
            guard let out = lanczos(image, width: outW, height: outH) else { throw SRError.badImage }
            progress(1)
            return Result(image: out, method: .standard, modelName: "Lanczos", factorUsed: 1, seconds: Date().timeIntervalSince(start))

        case .fast:
            let factor = need <= 2 ? 2 : need <= 3 ? 3 : 4
            let name = "SR_x\(factor)"
            let model = try loadModel(name)
            let sr = try await fsrcnn(image, model: model, factor: factor, progress: progress)
            guard let out = (sr.width == outW && sr.height == outH) ? sr : lanczos(sr, width: outW, height: outH) else {
                throw SRError.badImage
            }
            return Result(image: out, method: .fast, modelName: "FSRCNN ×\(factor)", factorUsed: factor, seconds: Date().timeIntervalSince(start))

        case .best:
            let model = try loadModel("RealESRGANx4v3")
            let sr = try await esrgan(image, model: model, progress: progress)
            guard let out = lanczos(sr, width: outW, height: outH) else { throw SRError.badImage }
            return Result(image: out, method: .best, modelName: "Real-ESRGAN x4v3", factorUsed: 4, seconds: Date().timeIntervalSince(start))
        }
    }

    // MARK: Models

    private func modelURL(_ name: String) -> URL? {
        guard let dir = modelsDir else { return nil }
        let u = dir.appendingPathComponent("\(name).mlmodelc")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    private func loadModel(_ name: String) throws -> MLModel {
        lock.lock(); defer { lock.unlock() }
        if let m = cache[name] { return m }
        guard let url = modelURL(name) else { throw SRError.modelMissing(name) }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuAndGPU      // GPU via Metal on Intel Macs; no Neural Engine there
        let m = try MLModel(contentsOf: url, configuration: cfg)
        cache[name] = m
        return m
    }

    // MARK: FSRCNN (luma)

    private func fsrcnn(_ image: CGImage, model: MLModel, factor f: Int,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> CGImage {
        let w = image.width, h = image.height
        guard var rgba = Self.rgba8(image, width: w, height: h) else { throw SRError.badImage }
        // Luma, BT.601 full range, 0…1
        var yPlane = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let r = Float(rgba[i * 4]), g = Float(rgba[i * 4 + 1]), b = Float(rgba[i * 4 + 2])
            yPlane[i] = (0.299 * r + 0.587 * g + 0.114 * b) / 255
        }
        rgba = []

        let T = Self.fsrcnnTile, m = 8, core = T - 2 * m
        let W = w * f, H = h * f
        var ySR = [Float](repeating: 0, count: W * H)
        let tilesX = (w + core - 1) / core, tilesY = (h + core - 1) / core
        let input = try MLMultiArray(shape: [1, 1, NSNumber(value: T), NSNumber(value: T)], dataType: .float32)
        var done = 0
        for ty in 0..<tilesY {
            for tx in 0..<tilesX {
                try Task.checkCancellation()
                let x0 = tx * core, y0 = ty * core
                // Fill the tile with edge replication beyond the image.
                input.withUnsafeMutableBufferPointer(ofType: Float.self) { buf, _ in
                    for yy in 0..<T {
                        let sy = min(max(y0 - m + yy, 0), h - 1)
                        for xx in 0..<T {
                            let sx = min(max(x0 - m + xx, 0), w - 1)
                            buf[yy * T + xx] = yPlane[sy * w + sx]
                        }
                    }
                }
                let out = try await model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["y": MLFeatureValue(multiArray: input)]))
                guard let sr = out.featureValue(for: "y_sr")?.multiArrayValue else { throw SRError.badImage }
                let OT = T * f
                sr.withUnsafeBufferPointer(ofType: Float.self) { src in
                    let cw = min(core, w - x0), chh = min(core, h - y0)
                    for yy in 0..<(chh * f) {
                        let srcRow = (m * f + yy) * OT + m * f
                        let dstRow = (y0 * f + yy) * W + x0 * f
                        for xx in 0..<(cw * f) { ySR[dstRow + xx] = src[srcRow + xx] }
                    }
                }
                done += 1
                progress(Double(done) / Double(tilesX * tilesY))
            }
        }

        // Colour: Lanczos-upscale the RGB image, then swap in the super-resolved luma.
        guard let big = lanczos(image, width: W, height: H), var px = Self.rgba8(big, width: W, height: H) else { throw SRError.badImage }
        for i in 0..<(W * H) {
            let r = Float(px[i * 4]), g = Float(px[i * 4 + 1]), b = Float(px[i * 4 + 2])
            let cb = -0.168736 * r - 0.331264 * g + 0.5 * b
            let cr = 0.5 * r - 0.418688 * g - 0.081312 * b
            let y = min(max(ySR[i], 0), 1) * 255
            px[i * 4]     = UInt8(clamping: Int((y + 1.402 * cr).rounded()))
            px[i * 4 + 1] = UInt8(clamping: Int((y - 0.344136 * cb - 0.714136 * cr).rounded()))
            px[i * 4 + 2] = UInt8(clamping: Int((y + 1.772 * cb).rounded()))
        }
        guard let result = Self.cgImage(rgba: px, width: W, height: H) else { throw SRError.badImage }
        return result
    }

    // MARK: Real-ESRGAN (RGB)

    private func esrgan(_ image: CGImage, model: MLModel, progress: @escaping @Sendable (Double) -> Void) async throws -> CGImage {
        let w = image.width, h = image.height, f = 4
        guard let rgba = Self.rgba8(image, width: w, height: h) else { throw SRError.badImage }
        let T = Self.esrganTile, m = 16, core = T - 2 * m
        let W = w * f, H = h * f
        var out = [UInt8](repeating: 255, count: W * H * 4)
        let tilesX = (w + core - 1) / core, tilesY = (h + core - 1) / core
        let input = try MLMultiArray(shape: [1, 3, NSNumber(value: T), NSNumber(value: T)], dataType: .float32)
        let plane = T * T
        var done = 0
        for ty in 0..<tilesY {
            for tx in 0..<tilesX {
                try Task.checkCancellation()
                let x0 = tx * core, y0 = ty * core
                input.withUnsafeMutableBufferPointer(ofType: Float.self) { buf, _ in
                    for yy in 0..<T {
                        let sy = min(max(y0 - m + yy, 0), h - 1)
                        for xx in 0..<T {
                            let sx = min(max(x0 - m + xx, 0), w - 1)
                            let p = (sy * w + sx) * 4
                            buf[yy * T + xx] = Float(rgba[p]) / 255
                            buf[plane + yy * T + xx] = Float(rgba[p + 1]) / 255
                            buf[2 * plane + yy * T + xx] = Float(rgba[p + 2]) / 255
                        }
                    }
                }
                let res = try await model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: input)]))
                guard let sr = res.featureValue(for: "output")?.multiArrayValue else { throw SRError.badImage }
                let OT = T * f, oplane = OT * OT
                let copy: (UnsafeBufferPointer<Float>) -> Void = { src in
                    let cw = min(core, w - x0), chh = min(core, h - y0)
                    for yy in 0..<(chh * f) {
                        let s0 = (m * f + yy) * OT + m * f
                        let d0 = ((y0 * f + yy) * W + x0 * f) * 4
                        for xx in 0..<(cw * f) {
                            out[d0 + xx * 4]     = UInt8(clamping: Int((src[s0 + xx] * 255).rounded()))
                            out[d0 + xx * 4 + 1] = UInt8(clamping: Int((src[oplane + s0 + xx] * 255).rounded()))
                            out[d0 + xx * 4 + 2] = UInt8(clamping: Int((src[2 * oplane + s0 + xx] * 255).rounded()))
                        }
                    }
                }
                if sr.dataType == .float32 {
                    sr.withUnsafeBufferPointer(ofType: Float.self, copy)
                } else {
                    // fp16 model outputs: convert once per tile
                    let n = sr.count
                    let floats = (0..<n).map { sr[$0].floatValue }
                    floats.withUnsafeBufferPointer(copy)
                }
                done += 1
                progress(Double(done) / Double(tilesX * tilesY))
            }
        }
        guard let result = Self.cgImage(rgba: out, width: W, height: H) else { throw SRError.badImage }
        return result
    }

    // MARK: Helpers

    public func lanczos(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        let src = CIImage(cgImage: image)
        let sx = CGFloat(width) / CGFloat(image.width), sy = CGFloat(height) / CGFloat(image.height)
        let f = CIFilter(name: "CILanczosScaleTransform")!
        f.setValue(src.clampedToExtent(), forKey: kCIInputImageKey)
        f.setValue(sy, forKey: kCIInputScaleKey)
        f.setValue(sx / sy, forKey: kCIInputAspectRatioKey)
        guard let out = f.outputImage else { return nil }
        return ci.createCGImage(out, from: CGRect(x: 0, y: 0, width: width, height: height),
                                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    static func rgba8(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        let ok = buf.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = CGContext(data: p.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? buf : nil
    }

    static func cgImage(rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        let data = Data(rgba) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// PSNR (dB) between two same-size images on luma — used by the self-test.
    public static func psnr(_ a: CGImage, _ b: CGImage) -> Double? {
        guard a.width == b.width, a.height == b.height,
              let pa = rgba8(a, width: a.width, height: a.height), let pb = rgba8(b, width: b.width, height: b.height) else { return nil }
        var mse = 0.0
        let n = a.width * a.height
        for i in 0..<n {
            let ya = 0.299 * Double(pa[i * 4]) + 0.587 * Double(pa[i * 4 + 1]) + 0.114 * Double(pa[i * 4 + 2])
            let yb = 0.299 * Double(pb[i * 4]) + 0.587 * Double(pb[i * 4 + 1]) + 0.114 * Double(pb[i * 4 + 2])
            mse += (ya - yb) * (ya - yb)
        }
        mse /= Double(n)
        return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
    }
}
