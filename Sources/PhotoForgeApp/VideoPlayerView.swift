import SwiftUI
import AVKit
import AVFoundation
import PFCore
import PFDatabase
import PFPhotosBridge
#if canImport(VLCKit)
import VLCKit
#endif

struct PlayerWindowRoot: View {
    @Environment(AppModel.self) private var model
    let assetID: Int64?

    var body: some View {
        Group {
            if let id = assetID, let asset = model.assetsByID[id] {
                VideoPlayerScreen(asset: asset).navigationTitle(asset.displayName)
            } else {
                ContentUnavailableView("Video not available", systemImage: "film")
            }
        }
        .background(WindowConfigurator(floating: false, minSize: CGSize(width: 480, height: 300)))
    }
}

/// Picks the engine: Apple's hardware-accelerated player when the format allows (best on
/// older Macs), otherwise VLC's engine, which plays almost any format (MKV, AVI, WMV, FLV, WebM…).
struct VideoPlayerScreen: View {
    @Environment(AppModel.self) private var model
    let asset: AssetRow
    enum Engine { case loading, apple(AVPlayer), vlc(URL), unsupported(URL?), failed(String) }
    @State private var engine: Engine = .loading

    var body: some View {
        ZStack {
            Color.black
            switch engine {
            case .loading:
                ProgressView("Opening video…").tint(.white).foregroundStyle(.white)
            case .apple(let player):
                AVPlayerViewRepresentable(player: player)
                    .overlay(alignment: .topTrailing) { EngineBadge(text: "Apple player") }
            case .vlc(let url):
                #if canImport(VLCKit)
                VLCPlayerView(url: url).overlay(alignment: .topTrailing) { EngineBadge(text: "VLC engine") }
                #else
                unsupported(url)
                #endif
            case .unsupported(let url):
                unsupported(url)
            case .failed(let msg):
                ContentUnavailableView("Couldn't play this video", systemImage: "exclamationmark.triangle", description: Text(msg))
                    .foregroundStyle(.white)
            }
        }
        .task(id: asset.id) { await load() }
        .onDisappear { if case .apple(let p) = engine { p.pause() } }
    }

    @ViewBuilder private func unsupported(_ url: URL?) -> some View {
        ContentUnavailableView {
            Label("This format needs the VLC engine", systemImage: "film.stack")
        } description: {
            Text("This build doesn't include it. You can open the file in another player.")
        } actions: {
            if let url { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
        }
        .foregroundStyle(.white)
    }

    private func load() async {
        do {
            switch try await model.playback(for: asset) {
            case .asset(let av):
                engine = .apple(AVPlayer(playerItem: AVPlayerItem(asset: av)))
            case .url(let url):
                if await MediaFiles.isNativelyPlayable(url) {
                    engine = .apple(AVPlayer(url: url))
                } else if model.videoEngineAvailable {
                    engine = .vlc(url)
                } else {
                    engine = .unsupported(url)
                }
            }
            if case .apple(let p) = engine { p.play() }
        } catch {
            engine = .failed(error.localizedDescription)
        }
    }
}

struct EngineBadge: View {
    let text: String
    var body: some View {
        Text(text).font(.caption2).padding(.horizontal, 6).padding(.vertical, 3)
            .background(.black.opacity(0.5), in: Capsule()).foregroundStyle(.white.opacity(0.8)).padding(10)
    }
}

struct AVPlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .floating
        v.showsFullScreenToggleButton = true
        v.allowsPictureInPicturePlayback = true
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) { if v.player !== player { v.player = player } }
    static func dismantleNSView(_ v: AVPlayerView, coordinator: ()) { v.player?.pause() }
}

#if canImport(VLCKit)
/// VLCKit playback with simple controls.
struct VLCPlayerView: View {
    let url: URL
    @State private var controller = VLCController()

    var body: some View {
        VStack(spacing: 0) {
            VLCVideoSurface(controller: controller)
            HStack(spacing: 14) {
                Button { controller.togglePlay() } label: { Image(systemName: controller.playing ? "pause.fill" : "play.fill") }
                    .keyboardShortcut(.space, modifiers: [])
                Text(controller.timeText).monospacedDigit().font(.caption)
                Slider(value: Binding(get: { controller.position }, set: { controller.seek($0) }), in: 0...1)
                Text(controller.lengthText).monospacedDigit().font(.caption)
                Image(systemName: "speaker.wave.2")
                Slider(value: Binding(get: { controller.volume }, set: { controller.setVolume($0) }), in: 0...1).frame(width: 90)
            }
            .buttonStyle(.plain)
            .padding(10)
            .background(.bar)
        }
        .onAppear { controller.play(url) }
        .onDisappear { controller.stop() }
    }
}

@MainActor
@Observable
final class VLCController: NSObject, VLCMediaPlayerDelegate {
    let player = VLCMediaPlayer()
    var playing = false
    var position: Double = 0
    var volume: Double = 1
    var timeText = "0:00"
    var lengthText = ""

    func play(_ url: URL) {
        player.delegate = self
        player.media = VLCMedia(url: url)
        player.play()
        playing = true
    }
    func togglePlay() { if player.isPlaying { player.pause(); playing = false } else { player.play(); playing = true } }
    func stop() { player.stop() }
    func seek(_ p: Double) { position = p; player.position = Float(p) }
    func setVolume(_ v: Double) { volume = v; player.audio?.volume = Int32(v * 100) }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor in
            position = Double(player.position)
            timeText = player.time.stringValue ?? ""
            if let len = player.media?.length.stringValue, !len.isEmpty { lengthText = len }
        }
    }
    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        Task { @MainActor in playing = player.isPlaying }
    }
}

struct VLCVideoSurface: NSViewRepresentable {
    let controller: VLCController
    func makeNSView(context: Context) -> VLCVideoView {
        let v = VLCVideoView()
        v.backColor = .black
        v.fillScreen = false
        controller.player.drawable = v
        return v
    }
    func updateNSView(_ nsView: VLCVideoView, context: Context) {}
}
#endif
