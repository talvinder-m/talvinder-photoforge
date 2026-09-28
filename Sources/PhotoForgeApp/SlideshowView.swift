import SwiftUI
import AppKit
import PFCore

struct SlideshowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: SlideshowRequest

    @AppStorage("slideshow.interval") private var interval: Double = 4
    @AppStorage("slideshow.shuffle") private var shuffle = false
    @AppStorage("slideshow.loop") private var loop = true
    @State private var order: [Int] = []
    @State private var position = 0
    @State private var playing = true
    @State private var image: NSImage?
    @State private var nextImage: (Int, NSImage)?
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var side: Double {
        let s = NSScreen.main
        let px = max(s?.frame.width ?? 1440, s?.frame.height ?? 900) * (s?.backingScaleFactor ?? 2)
        return min(px, 3000)       // enough for a sharp full-screen image, gentle on older Macs
    }
    private var currentKey: String? { order.isEmpty ? nil : request.keys[order[position]] }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .id(position)
                    .transition(.opacity)
            } else {
                ProgressView().controlSize(.large).tint(.white)
            }
            if controlsVisible { controls.transition(.opacity) }
        }
        .animation(.easeInOut(duration: 0.8), value: position)
        .animation(.easeInOut(duration: 0.25), value: controlsVisible)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.space) { playing.toggle(); poke(); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .onContinuousHover { _ in poke() }
        .onTapGesture { poke() }
        .onAppear {
            order = makeOrder()
            position = 0
            focused = true
            poke()
        }
        .onChange(of: shuffle) { order = makeOrder(keeping: currentKey); position = 0 }
        .task(id: position) { await loadCurrent() }
        .task(id: "\(playing)-\(position)-\(interval)") {
            guard playing else { return }
            try? await Task.sleep(for: .seconds(interval))
            if !Task.isCancelled { step(1, fromTimer: true) }
        }
        .background(WindowConfigurator(floating: false, minSize: CGSize(width: 480, height: 320), fitOnFirstShow: false, fullScreen: true))
        .navigationTitle(request.title)
    }

    private var controls: some View {
        VStack {
            HStack {
                Text(request.title).font(.headline)
                Spacer()
                Text("\(position + 1) / \(order.count)").monospacedDigit()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                    .buttonStyle(.plain).help("Exit slideshow (Esc)")
            }
            .padding(14)
            .background(.black.opacity(0.45))
            Spacer()
            HStack(spacing: 22) {
                Button { step(-1) } label: { Image(systemName: "backward.fill") }.help("Previous (←)")
                Button { playing.toggle(); poke() } label: { Image(systemName: playing ? "pause.fill" : "play.fill").font(.title) }
                    .help(playing ? "Pause (Space)" : "Play (Space)")
                Button { step(1) } label: { Image(systemName: "forward.fill") }.help("Next (→)")
                Divider().frame(height: 22)
                Menu {
                    ForEach([2.0, 3, 4, 6, 8, 12], id: \.self) { s in
                        Button { interval = s } label: { Text("\(Int(s)) seconds") + Text(interval == s ? "  ✓" : "") }
                    }
                } label: { Label("\(Int(interval)) s", systemImage: "timer") }
                .menuStyle(.borderlessButton).fixedSize()
                Toggle(isOn: $shuffle) { Image(systemName: "shuffle") }.toggleStyle(.button).help("Shuffle")
                Toggle(isOn: $loop) { Image(systemName: "repeat") }.toggleStyle(.button).help("Repeat")
            }
            .font(.title2)
            .buttonStyle(.plain)
            .padding(.horizontal, 24).padding(.vertical, 12)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 30)
        }
        .foregroundStyle(.white)
    }

    // MARK: Logic

    private func makeOrder(keeping key: String? = nil) -> [Int] {
        var o = Array(request.keys.indices)
        if shuffle {
            o.shuffle()
            if let key, let i = request.keys.firstIndex(of: key), let p = o.firstIndex(of: i) { o.swapAt(0, p) }
        } else {
            let start = key.flatMap { request.keys.firstIndex(of: $0) } ?? request.startIndex
            o = Array(o[start...] + o[..<start])
        }
        return o
    }

    private func step(_ delta: Int, fromTimer: Bool = false) {
        guard !order.isEmpty else { return }
        var p = position + delta
        if p >= order.count {
            if loop { p = 0 } else { playing = false; return }
        }
        if p < 0 { p = loop ? order.count - 1 : 0 }
        position = p
        if !fromTimer { poke() }
    }

    private func loadCurrent() async {
        guard let key = currentKey else { return }
        if let (i, img) = nextImage, i == position { image = img }
        else if let img = await model.thumbnail(for: key, side: side) { image = img }
        // Preload the next photo so the crossfade doesn't wait.
        let n = position + 1 < order.count ? position + 1 : (loop ? 0 : -1)
        if n >= 0, let img = await model.thumbnail(for: request.keys[order[n]], side: side) { nextImage = (n, img) }
    }

    /// Show controls on activity; hide them again after a moment while playing.
    private func poke() {
        controlsVisible = true
        NSCursor.unhide()
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled && playing {
                controlsVisible = false
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
    }
}
