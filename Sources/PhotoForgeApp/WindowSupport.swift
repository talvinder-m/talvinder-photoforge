import SwiftUI
import AppKit
import PFCore
import PFDatabase

/// Sizes for new windows, derived from the screen the user is actually on,
/// so a 13-inch display (1280×800 or 1440×900 points) gets a window that fits.
enum ScreenFit {
    static var visible: CGRect { NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800) }

    /// ~90% of the visible screen, capped so huge displays don't get absurd windows.
    static func size(widthFraction: CGFloat = 0.9, heightFraction: CGFloat = 0.9,
                     maxWidth: CGFloat = 1800, maxHeight: CGFloat = 1200) -> CGSize {
        CGSize(width: min(visible.width * widthFraction, maxWidth), height: min(visible.height * heightFraction, maxHeight))
    }
}

/// Configures the hosting NSWindow: floating level, fit-to-screen on first show, minimum size.
struct WindowConfigurator: NSViewRepresentable {
    var floating: Bool
    var minSize: CGSize = CGSize(width: 700, height: 480)
    var fitOnFirstShow = true
    var fullScreen = false

    final class Coordinator { var configured = false }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.level = floating ? .floating : .normal
            window.collectionBehavior.insert(.fullScreenAuxiliary)
            window.hidesOnDeactivate = false
            guard !context.coordinator.configured else { return }
            context.coordinator.configured = true
            window.minSize = minSize
            if fitOnFirstShow, let screen = window.screen ?? NSScreen.main {
                let vis = screen.visibleFrame
                var frame = window.frame
                // Never larger than the visible screen; centred on it.
                frame.size.width = min(frame.width, vis.width * 0.95)
                frame.size.height = min(frame.height, vis.height * 0.95)
                frame.origin.x = vis.midX - frame.width / 2
                frame.origin.y = vis.midY - frame.height / 2
                window.setFrame(frame, display: true, animate: false)
            }
            if fullScreen && !window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
        }
    }
}

/// Toolbar button that toggles "keep on top" for the current window.
struct FloatToggle: View {
    @Binding var floating: Bool
    var body: some View {
        Button { floating.toggle() } label: {
            Label(floating ? "On Top" : "Normal", systemImage: floating ? "pin.fill" : "pin.slash")
        }
        .help(floating ? "Window stays above other windows — click to release" : "Keep this window above other windows")
    }
}

/// Window content for the editor, looked up by asset id.
struct EditorWindowRoot: View {
    @Environment(AppModel.self) private var model
    let assetID: Int64?
    @AppStorage("editor.floating") private var floating = true

    var body: some View {
        Group {
            if let id = assetID, let asset = model.assetsByID[id] {
                EditorView(asset: asset)
                    .toolbar { ToolbarItem(placement: .primaryAction) { FloatToggle(floating: $floating) } }
                    .navigationTitle("Edit — \(asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "Photo")")
            } else {
                ContentUnavailableView("Photo not available", systemImage: "photo",
                                       description: Text("It may have been removed, or a different library is open."))
            }
        }
        .background(WindowConfigurator(floating: floating, minSize: CGSize(width: 640, height: 440)))
    }
}

struct UpscaleWindowRoot: View {
    @Environment(AppModel.self) private var model
    let assetID: Int64?
    @AppStorage("editor.floating") private var floating = true

    var body: some View {
        Group {
            if let id = assetID, let asset = model.assetsByID[id] {
                UpscaleView(asset: asset)
                    .toolbar { ToolbarItem(placement: .primaryAction) { FloatToggle(floating: $floating) } }
                    .navigationTitle("Upscale Photo")
            } else {
                ContentUnavailableView("Photo not available", systemImage: "photo")
            }
        }
        .background(WindowConfigurator(floating: floating, minSize: CGSize(width: 680, height: 460)))
    }
}
