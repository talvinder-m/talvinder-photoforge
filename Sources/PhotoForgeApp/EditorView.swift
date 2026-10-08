import SwiftUI
import PFCore
import AppKit
import CoreImage
import CryptoKit
import UniformTypeIdentifiers
import PFDatabase
import PFEditing

struct EditSnapshot: Equatable {
    var adjustments = Adjustments()
    var crop = CropSpec(rect: [0, 0, 1, 1], angle: 0, flipH: false, flipV: false)
}

enum CompareMode: String, CaseIterable, Identifiable {
    case edited = "Edited", original = "Original", sideBySide = "Side by Side"
    var id: String { rawValue }
}

@MainActor
@Observable
final class EditorState {
    var sourceData: Data?
    var fullSource: CIImage?
    var previewSource: CIImage?
    var preview: NSImage?
    var original: NSImage?
    var current = EditSnapshot()
    var history: [EditSnapshot] = [EditSnapshot()]
    var historyIndex = 0
    var loading = true
    var busy = false
    var error: String?
    var aspect: Double? = nil        // nil = original

    var canUndo: Bool { historyIndex > 0 }
    var canRedo: Bool { historyIndex < history.count - 1 }
    var isModified: Bool { current != EditSnapshot() }

    func commit() {
        guard current != history[historyIndex] else { return }
        history = Array(history.prefix(historyIndex + 1)) + [current]
        historyIndex = history.count - 1
    }
    func undo() { guard canUndo else { return }; historyIndex -= 1; current = history[historyIndex] }
    func redo() { guard canRedo else { return }; historyIndex += 1; current = history[historyIndex] }
    func revert() { current = EditSnapshot(); aspect = nil; commit() }

    func stack(for asset: AssetRow) -> EditStack {
        var s = EditStack(source: SourceReference(photoKitLocalIdentifier: asset.localIdentifier,
                                                  sha256Hex: sourceData.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() },
                                                  accessedAt: .now))
        s.push(EditLayer(operation: .adjust(current.adjustments)))
        s.push(EditLayer(operation: .crop(current.crop)))
        return s
    }
}

struct EditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let asset: AssetRow
    @State private var state = EditorState()
    @State private var mode: CompareMode = .edited
    @State private var keepMetadata = true
    @State private var removeGPS = true
    @State private var confirmClose = false
    @AppStorage("editor.showControls") private var showControls = true

    var body: some View {
        // Adapts to the window: side-by-side when there's room, otherwise the controls
        // slide over the photo and can be hidden (toolbar "Adjustments" button).
        GeometryReader { geo in
            let narrow = geo.size.width < 900
            ZStack(alignment: .trailing) {
                HStack(spacing: 0) {
                    canvas.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity).background(Color.black.opacity(0.85))
                    if showControls && !narrow {
                        Divider()
                        controls.frame(width: min(340, max(270, geo.size.width * 0.28)))
                    }
                }
                if showControls && narrow {
                    controls.frame(width: min(320, geo.size.width * 0.6))
                        .background(.regularMaterial)
                        .shadow(radius: 8)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showControls)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button("Close") { if state.isModified { confirmClose = true } else { dismiss() } }
                    .keyboardShortcut(.cancelAction)
            }
            ToolbarItemGroup {
                Button { showControls.toggle() } label: { Label("Adjustments", systemImage: "slider.horizontal.3") }
                    .help(showControls ? "Hide the adjustment panel" : "Show the adjustment panel")
                Button { state.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .keyboardShortcut("z", modifiers: .command).disabled(!state.canUndo)
                Button { state.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                    .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!state.canRedo)
                Picker("View", selection: $mode) { ForEach(CompareMode.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).frame(maxWidth: 280)
            }
        }
        .task { await load() }
        .task(id: state.current) { await renderPreview() }
        .confirmationDialog("Discard your edits?", isPresented: $confirmClose) {
            Button("Discard Edits", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        } message: { Text("Your original photo is unchanged either way.") }
    }

    // MARK: Canvas

    @ViewBuilder private var canvas: some View {
        if state.loading {
            ProgressView("Loading full-resolution photo…").foregroundStyle(.white)
        } else if let err = state.error {
            ContentUnavailableView("Couldn't open this photo", systemImage: "exclamationmark.triangle", description: Text(err))
        } else {
            switch mode {
            case .edited: imageView(state.preview, label: nil)
            case .original: imageView(state.original, label: "Original")
            case .sideBySide:
                HStack(spacing: 2) { imageView(state.original, label: "Original"); imageView(state.preview, label: "Edited") }
            }
        }
    }

    private func imageView(_ img: NSImage?, label: String?) -> some View {
        ZStack(alignment: .topLeading) {
            if let img { Image(nsImage: img).resizable().scaledToFit().padding(12) }
            if let label {
                Text(label).font(.caption.bold()).padding(6).background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white).padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Controls

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("Light") {
                    slider("Exposure", \.adjustments.exposure, -2...2)
                    slider("Contrast", \.adjustments.contrast, -1...1)
                    slider("Highlights", \.adjustments.highlights, -1...0)
                    slider("Shadows", \.adjustments.shadows, -1...1)
                    slider("Whites", \.adjustments.whites, -1...1)
                    slider("Blacks", \.adjustments.blacks, -1...1)
                }
                section("Color") {
                    slider("Temperature", \.adjustments.temperature, -1...1)
                    slider("Tint", \.adjustments.tint, -1...1)
                    slider("Vibrance", \.adjustments.vibrance, -1...1)
                    slider("Saturation", \.adjustments.saturation, -1...1)
                }
                section("Detail") {
                    slider("Clarity", \.adjustments.clarity, -1...1)
                    slider("Dehaze", \.adjustments.dehaze, 0...1)
                    slider("Sharpness", \.adjustments.sharpness, 0...2)
                    slider("Noise Reduction", \.adjustments.noiseReduction, 0...1)
                }
                section("Effects") {
                    slider("Vignette", \.adjustments.vignette, 0...1)
                    slider("Grain", \.adjustments.grain, 0...1)
                }
                section("Crop & Rotate") {
                    slider("Straighten", \.crop.angle, -0.5...0.5)
                    Picker("Aspect", selection: Binding(get: { state.aspect }, set: { setAspect($0) })) {
                        Text("Original").tag(Double?.none)
                        Text("Square").tag(Optional(1.0))
                        Text("4:3").tag(Optional(4.0 / 3))
                        Text("3:2").tag(Optional(3.0 / 2))
                        Text("16:9").tag(Optional(16.0 / 9))
                        Text("4:5").tag(Optional(4.0 / 5))
                    }
                    HStack {
                        Button { state.current.crop.flipH.toggle(); state.commit() } label: { Label("Flip H", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                        Button { state.current.crop.flipV.toggle(); state.commit() } label: { Label("Flip V", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down") }
                    }.controlSize(.small)
                }
                Button("Revert to Original") { state.revert() }.disabled(!state.isModified)
                Button { model.upscaleRequest = asset; dismiss() } label: {
                    Label("Upscale to 2K…", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .disabled(max(asset.pixelWidth, asset.pixelHeight) >= 2048)
                .help("AI upscaling of the original photo")

                Divider()
                section("Save") {
                    Button {
                        Task { await saveToPhotos() }
                    } label: { Label("Save as New Photo", systemImage: "square.and.arrow.down.on.square").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).disabled(!state.isModified || state.busy || !model.canSaveToLibrary)
                    Text(model.canSaveToLibrary
                         ? "Adds the edited version to Photos (album “PhotoForge Edits”). The original is kept."
                         : "This library is opened read-only. Use Export to File to save your edit.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Keep camera metadata", isOn: $keepMetadata)
                    Toggle("Remove location", isOn: $removeGPS).disabled(!keepMetadata)
                    Button { Task { await exportFile() } } label: { Label("Export to File…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                        .disabled(state.busy || state.fullSource == nil)
                    if state.busy { ProgressView().controlSize(.small) }
                }
            }
            .padding(16)
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func slider(_ label: String, _ kp: WritableKeyPath<EditSnapshot, Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.callout)
                Spacer()
                Text(String(format: "%+.2f", state.current[keyPath: kp])).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { state.current[keyPath: kp] }, set: { state.current[keyPath: kp] = $0 }),
                   in: range, onEditingChanged: { editing in if !editing { state.commit() } })
            .controlSize(.small)
        }
        .contextMenu { Button("Reset \(label)") { state.current[keyPath: kp] = 0; state.commit() } }
    }

    private func setAspect(_ a: Double?) {
        state.aspect = a
        guard let a, let src = state.fullSource else {
            state.current.crop.rect = [0, 0, 1, 1]; state.commit(); return
        }
        let W = src.extent.width, H = src.extent.height
        let imgAspect = Double(W / H)
        // Largest centered rect with the requested aspect, normalized.
        if a > imgAspect {
            let h = imgAspect / a
            state.current.crop.rect = [0, (1 - h) / 2, 1, h]
        } else {
            let w = a / imgAspect
            state.current.crop.rect = [(1 - w) / 2, 0, w, 1]
        }
        state.commit()
    }

    // MARK: Work

    private func load() async {
        do {
            let data = try await model.mediaSource.fullImageData(for: asset.localIdentifier)
            guard let full = EditRenderer.image(from: data) else { throw CocoaError(.fileReadCorruptFile) }
            state.sourceData = data
            state.fullSource = full
            let scale = min(1, 1800 / max(full.extent.width, full.extent.height))
            let preview = full.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            state.previewSource = preview
            if let cg = model.renderer.cgImage(preview) { state.original = NSImage(cgImage: cg, size: .zero) }
            state.loading = false
            await renderPreview()
        } catch {
            state.error = error.localizedDescription
            state.loading = false
        }
    }

    private func renderPreview() async {
        guard let src = state.previewSource else { return }
        let stack = state.stack(for: asset)
        let renderer = model.renderer
        let cg = await Offload.run { renderer.cgImage(renderer.render(src, stack: stack)) }
        if let cg { state.preview = NSImage(cgImage: cg, size: .zero) }
    }

    private func renderFull(type: UTType) async throws -> URL {
        guard let src = state.fullSource, let data = state.sourceData else { throw CocoaError(.fileReadUnknown) }
        let stack = state.stack(for: asset)
        let renderer = model.renderer
        let meta = EditRenderer.exportMetadata(from: data, stripAll: !keepMetadata, removeGPS: removeGPS)
        let ext = type.preferredFilenameExtension ?? "jpg"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoForge-\(UUID().uuidString).\(ext)")
        try await Offload.run {
            try renderer.write(renderer.render(src, stack: stack), to: url, type: type, metadata: meta)
        }
        return url
    }

    private func saveToPhotos() async {
        state.busy = true
        defer { state.busy = false }
        do {
            let url = try await renderFull(type: .jpeg)
            defer { try? FileManager.default.removeItem(at: url) }
            let newID = try await model.saveDerivative(fileURL: url, suggestedName: BatchRename.stripExtension(asset.displayName) + " (edited).jpg", album: "PhotoForge Edits")
            let stack = state.stack(for: asset)
            try model.db?.saveEditProject(sourceAssetID: asset.id, name: "Edit \(Date().formatted())",
                                          stackJSON: try stack.encoded(), stackVersion: EditStack.currentVersion,
                                          containsGenerative: stack.containsGenerative, outputAssetID: newID,
                                          outputPath: nil, modelsJSON: nil,
                                          sourceChecksum: state.sourceData.map { Data(SHA256.hash(data: $0)) })
            model.db?.log("edit", "Saved an edited copy to Photos (original unchanged)")
            model.banner = "Saved as a new photo in the “PhotoForge Edits” album. The original is unchanged."
            dismiss()
            await model.syncLibrary()
        } catch {
            state.error = nil
            model.banner = "Couldn't save to Photos: \(error.localizedDescription)"
        }
    }

    private func exportFile() async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg, .heic, .png, .tiff]
        panel.nameFieldStringValue = "PhotoForge Export.jpg"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        state.busy = true
        defer { state.busy = false }
        do {
            let type = UTType(filenameExtension: dest.pathExtension) ?? .jpeg
            let tmp = try await renderFull(type: type)
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.moveItem(at: tmp, to: dest)
            model.db?.log("export", "Exported an edited photo to \(dest.lastPathComponent)\(keepMetadata ? (removeGPS ? " (location removed)" : "") : " (metadata stripped)")")
            model.banner = "Exported to \(dest.lastPathComponent)."
        } catch {
            model.banner = "Export failed: \(error.localizedDescription)"
        }
    }
}
