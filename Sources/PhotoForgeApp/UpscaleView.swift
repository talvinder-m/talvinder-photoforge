import SwiftUI
import PFCore
import AppKit
import ImageIO
import CryptoKit
import UniformTypeIdentifiers
import PFDatabase
import PFVision
import PFEditing

enum UpscaleTarget: Int, CaseIterable, Identifiable {
    case fullHD = 1920, twoK = 2048
    var id: Int { rawValue }
    var label: String { self == .twoK ? "2K (2048 px)" : "Full HD (1920 px)" }
}

struct UpscaleView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let asset: AssetRow

    @State private var source: CGImage?
    @State private var sourceData: Data?
    @State private var target: UpscaleTarget = .twoK
    @State private var method: SuperResolution.Method = .fast
    @State private var running = false
    @State private var progress = 0.0
    @State private var startedAt = Date()
    @State private var result: SuperResolution.Result?
    @State private var baseline: CGImage?          // Lanczos at the same size, for comparison
    @State private var focus = CGPoint(x: 0.5, y: 0.5)
    @State private var error: String?
    @State private var job: Task<Void, Never>?
    @State private var keepMetadata = true
    @State private var removeGPS = true

    private var srcW: Int { source?.width ?? asset.pixelWidth }
    private var srcH: Int { source?.height ?? asset.pixelHeight }
    private var outSize: (Int, Int) { SuperResolution.outputSize(width: srcW, height: srcH, targetLongEdge: target.rawValue) }
    private var alreadyLarge: Bool { max(srcW, srcH) >= target.rawValue }

    var body: some View {
        HSplitView {
            comparison.frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
            controls.frame(minWidth: 300, idealWidth: 320, maxWidth: 360)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Close") { job?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .task { await load() }
        .onChange(of: target) { result = nil; baseline = nil }
        .onChange(of: method) { result = nil; baseline = nil }
    }

    // MARK: Comparison

    @ViewBuilder private var comparison: some View {
        if let source {
            VStack(spacing: 10) {
                // Overview: click to choose which spot to inspect at 100%.
                GeometryReader { geo in
                    let img = Image(decorative: source, scale: 1)
                    img.resizable().scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .overlay {
                            if result != nil {
                                let fit = fitRect(CGSize(width: srcW, height: srcH), in: geo.size)
                                let box = CGSize(width: fit.width * detailFraction.width, height: fit.height * detailFraction.height)
                                Rectangle().stroke(Color.yellow, lineWidth: 2)
                                    .frame(width: box.width, height: box.height)
                                    .position(x: fit.minX + focus.x * fit.width, y: fit.minY + focus.y * fit.height)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { p in
                            let fit = fitRect(CGSize(width: srcW, height: srcH), in: geo.size)
                            focus = CGPoint(x: min(1, max(0, (p.x - fit.minX) / fit.width)),
                                            y: min(1, max(0, (p.y - fit.minY) / fit.height)))
                        }
                }
                .frame(minHeight: 180, maxHeight: result == nil ? .infinity : 240)

                if let r = result {
                    Text("Detail at 100% — click the photo above to move the yellow box").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        detail(baseline, label: "Standard resize")
                        detail(r.image, label: "\(r.method == .standard ? "Standard" : "AI") · \(r.modelName)")
                    }
                }
            }
            .padding(12)
            .background(Color.black.opacity(0.85))
        } else if let error {
            ContentUnavailableView("Couldn't open this photo", systemImage: "exclamationmark.triangle", description: Text(error))
        } else {
            ProgressView("Loading photo…")
        }
    }

    private var detailFraction: CGSize {
        // A 520-px window of the upscaled output, expressed as a fraction of the image.
        let (w, h) = outSize
        return CGSize(width: min(1, 520 / Double(w)), height: min(1, 520 / Double(h)))
    }

    private func detail(_ img: CGImage?, label: String) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.black)
            if let img, let crop = cropAtFocus(img) {
                Image(decorative: crop, scale: 1).interpolation(.none).resizable().scaledToFit()
            } else {
                ProgressView()
            }
            Text(label).font(.caption.bold()).padding(6).background(.black.opacity(0.6), in: Capsule())
                .foregroundStyle(.white).padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func cropAtFocus(_ img: CGImage) -> CGImage? {
        let side = 520
        let w = min(side, img.width), h = min(side, img.height)
        let x = min(max(0, Int(focus.x * Double(img.width)) - w / 2), img.width - w)
        let y = min(max(0, Int(focus.y * Double(img.height)) - h / 2), img.height - h)
        return img.cropping(to: CGRect(x: x, y: y, width: w, height: h))
    }

    private func fitRect(_ size: CGSize, in box: CGSize) -> CGRect {
        let s = min(box.width / size.width, box.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }

    // MARK: Controls

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Upscale Photo").font(.title2.bold())
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    InfoRow("Current", "\(srcW) × \(srcH)")
                    InfoRow("Output", alreadyLarge ? "Already \(target.label) or larger" : "\(outSize.0) × \(outSize.1)")
                }.font(.callout)

                Picker("Target", selection: $target) {
                    ForEach(UpscaleTarget.allCases) { Text($0.label).tag($0) }
                }
                Picker("Method", selection: $method) {
                    ForEach(SuperResolution.Method.allCases) { m in
                        Text(m.label + (model.superRes.isAvailable(m) ? "" : " — not in this build")).tag(m)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(methodNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                if running {
                    ProgressView(value: progress) { Text(eta) }
                    Button("Stop") { job?.cancel() }
                } else {
                    Button {
                        start()
                    } label: {
                        Label("Upscale", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(source == nil || alreadyLarge || !model.superRes.isAvailable(method))
                }
                if let r = result {
                    Text("Done in \(String(format: "%.1f", r.seconds)) s · \(r.image.width) × \(r.image.height)")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Divider()
                Text("Save").font(.headline)
                Toggle("Keep camera metadata", isOn: $keepMetadata)
                Toggle("Remove location", isOn: $removeGPS).disabled(!keepMetadata)
                Button { Task { await saveToPhotos() } } label: {
                    Label("Save as New Photo", systemImage: "square.and.arrow.down.on.square").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(result == nil || !model.canSaveToLibrary || running)
                Button { Task { await export() } } label: {
                    Label("Export to File…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .disabled(result == nil || running)
                Text(model.canSaveToLibrary
                     ? "Saved to Photos in the album “PhotoForge Upscaled”. The original is kept and the edit history records that AI upscaling was used."
                     : "This library is read-only here, so use Export to File.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }

    private var methodNote: String {
        switch method {
        case .fast: "FSRCNN: a small neural network that sharpens edges and fine detail. Runs on your Mac's GPU through Metal; a few seconds per photo, even on older Intel Macs."
        case .best: "Real-ESRGAN (compact): a larger network that restores texture and removes compression artefacts. Noticeably sharper; can take 10–60 seconds per photo on older Intel Macs."
        case .standard: "High-quality Lanczos resizing with no AI, for comparison."
        }
    }

    private var eta: String {
        let elapsed = Date().timeIntervalSince(startedAt)
        guard progress > 0.02 else { return "Working…" }
        let remaining = elapsed / progress * (1 - progress)
        return "About \(Int(remaining.rounded()) + 1) s left"
    }

    // MARK: Work

    private func load() async {
        do {
            let data = try await model.mediaSource.fullImageData(for: asset.localIdentifier)
            guard let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            // Full size with EXIF orientation applied.
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1)]
            guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
            sourceData = data
            source = img
            if !model.superRes.isAvailable(.fast) { method = .standard }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func start() {
        guard let src = source else { return }
        running = true; progress = 0; startedAt = Date(); result = nil; baseline = nil
        let sr = model.superRes, m = method, t = target.rawValue
        job = Task {
            do {
                let r = try await Task.detached(priority: .userInitiated) {
                    try await sr.upscale(src, targetLongEdge: t, method: m) { p in
                        Task { @MainActor in progress = p }
                    }
                }.value
                let (w, h) = SuperResolution.outputSize(width: src.width, height: src.height, targetLongEdge: t)
                let base = await Task.detached { sr.lanczos(src, width: w, height: h) }.value
                result = r
                baseline = base
                model.db?.log("model", "Upscaled a photo to \(r.image.width)×\(r.image.height) with \(r.modelName) in \(String(format: "%.1f", r.seconds)) s",
                              model: r.modelName)
            } catch is CancellationError {
                model.banner = "Upscaling stopped."
            } catch {
                model.banner = "Upscaling failed: \(error.localizedDescription)"
            }
            running = false
        }
    }

    private func writeResult(to url: URL, type: UTType) throws {
        guard let r = result, let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var props = sourceData.map { EditRenderer.exportMetadata(from: $0, stripAll: !keepMetadata, removeGPS: removeGPS) } ?? [:]
        props[kCGImageDestinationLossyCompressionQuality] = 0.93
        props[kCGImagePropertyOrientation] = 1
        CGImageDestinationAddImage(dest, r.image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    private func provenance(outputID: String?, outputPath: String?) {
        guard let r = result else { return }
        var stack = EditStack(source: SourceReference(photoKitLocalIdentifier: asset.localIdentifier,
                                                      sha256Hex: sourceData.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() },
                                                      accessedAt: .now))
        let license = r.method == .best ? "BSD-3-Clause" : r.method == .fast ? "Apache-2.0" : "Apple system framework"
        stack.push(EditLayer(operation: .aiEnhance(tool: .upscale,
                                                   model: ModelStamp(name: r.modelName, version: "1", license: license, execution: "local"),
                                                   strength: Double(target.rawValue))))
        try? model.db?.saveEditProject(sourceAssetID: asset.id, name: "Upscale to \(target.label)",
                                       stackJSON: (try? stack.encoded()) ?? "{}", stackVersion: EditStack.currentVersion,
                                       containsGenerative: false, outputAssetID: outputID, outputPath: outputPath,
                                       modelsJSON: "{\"upscaler\":\"\(r.modelName)\",\"label\":\"AI-upscaled\"}",
                                       sourceChecksum: sourceData.map { Data(SHA256.hash(data: $0)) })
    }

    private func saveToPhotos() async {
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoForge-upscaled-\(UUID().uuidString).jpg")
            try writeResult(to: url, type: .jpeg)
            defer { try? FileManager.default.removeItem(at: url) }
            let id = try await model.photos.addDerivative(fileURL: url, toAlbumNamed: "PhotoForge Upscaled")
            provenance(outputID: id, outputPath: nil)
            model.banner = "Saved the upscaled photo to Photos (album “PhotoForge Upscaled”). The original is unchanged."
            dismiss()
            await model.syncLibrary()
        } catch {
            model.banner = "Couldn't save to Photos: \(error.localizedDescription)"
        }
    }

    private func export() async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg, .heic, .png, .tiff]
        panel.nameFieldStringValue = "Upscaled \(target.rawValue).jpg"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            let type = UTType(filenameExtension: dest.pathExtension) ?? .jpeg
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try writeResult(to: dest, type: type)
            provenance(outputID: nil, outputPath: dest.path)
            model.db?.log("export", "Exported an upscaled photo to \(dest.lastPathComponent)")
            model.banner = "Exported to \(dest.lastPathComponent)."
        } catch {
            model.banner = "Export failed: \(error.localizedDescription)"
        }
    }
}
