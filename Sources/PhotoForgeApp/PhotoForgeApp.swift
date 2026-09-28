import SwiftUI
import PFCore
import PFDatabase
import PFPhotosBridge

@main
struct PhotoForgeApp: App {
    @State private var model = AppModel()

    init() {
        let args = CommandLine.arguments
        if args.contains("--selftest") { SelfTest.runAndExit() }
        if let i = args.firstIndex(of: "--srbench"), i + 1 < args.count {
            UpscaleBenchmark.runAndExit(dir: URL(fileURLWithPath: args[i + 1]))
        }
        if let i = args.firstIndex(of: "--facecal"), i + 1 < args.count {
            FaceCalibrationRun.runAndExit(dir: URL(fileURLWithPath: args[i + 1]))
        }
    }

    var body: some Scene {
        WindowGroup("PhotoForge") {
            RootView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 640)
                .task { await model.bootstrap() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Rescan Library") { Task { await model.syncLibrary() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Analyze Photos") { Task { await model.startAnalysis() } }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView().environment(model).frame(width: 560, height: 620)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let err = model.startupError {
                ContentUnavailableView("PhotoForge couldn't start", systemImage: "exclamationmark.triangle",
                                       description: Text(err))
            } else {
                if !model.isSystemLibrary {
                    MainView()                 // an on-disk library doesn't need Photos permission
                } else {
                    switch model.access {
                    case .authorized, .limited: MainView()
                    case .notDetermined: ConnectView()
                    case .denied, .restricted: DeniedView()
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let banner = model.banner {
                HStack(spacing: 12) {
                    Image(systemName: "info.circle")
                    Text(banner).lineLimit(3)
                    Spacer()
                    Button("Dismiss") { model.banner = nil }.buttonStyle(.borderless)
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding()
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: model.banner)
    }
}

struct ConnectView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "photo.stack").font(.system(size: 56)).foregroundStyle(.tint)
            Text("Welcome to PhotoForge").font(.largeTitle.bold())
            Text("Find duplicates, group faces into people, and edit photos non-destructively.\nEverything runs on this Mac. Nothing is uploaded.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Label("Reads your library through Apple's Photos framework", systemImage: "lock.shield")
                Label("Never changes Apple's library files", systemImage: "externaldrive.badge.checkmark")
                Label("Edits are saved as new photos; originals stay untouched", systemImage: "square.on.square")
                Label("Deleting always asks you first, and goes to Recently Deleted", systemImage: "trash.slash")
            }
            .padding().background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            Button {
                Task { await model.connectPhotos() }
            } label: {
                Text("Connect Apple Photos").frame(minWidth: 220)
            }
            .controlSize(.large).buttonStyle(.borderedProminent)
            Text("macOS will ask for permission to access your photo library.").font(.footnote).foregroundStyle(.secondary)
            Button("Open Another Library or Folder…") { Task { await model.chooseLibraryWithPanel() } }
                .buttonStyle(.link)
        }
        .padding(40)
    }
}

struct DeniedView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ContentUnavailableView {
            Label("Photos access is off", systemImage: "hand.raised")
        } description: {
            Text("PhotoForge needs access to your photo library. Turn it on in System Settings › Privacy & Security › Photos, then reopen PhotoForge.")
        } actions: {
            Button("Open Privacy Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
            }
            Button("Open Another Library or Folder…") { Task { await model.chooseLibraryWithPanel() } }
        }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                Section {
                    Label("Dashboard", systemImage: "gauge.with.dots.needle.50percent").tag(SidebarItem.dashboard)
                    Label(model.isSystemLibrary ? "On This Mac" : "All Photos", systemImage: "photo.on.rectangle")
                        .tag(SidebarItem.allPhotos)
                    Label("Favorites", systemImage: "heart").tag(SidebarItem.favorites)
                    Label("Screenshots", systemImage: "camera.viewfinder").tag(SidebarItem.screenshots)
                    Label("Blurry Photos", systemImage: "camera.metering.unknown").tag(SidebarItem.blurry)
                } header: {
                    LibrarySwitcher()
                }
                if model.isSystemLibrary || model.stats.cloudOnly > 0 {
                    Section("iCloud") {
                        Label("iCloud Photos", systemImage: "icloud")
                            .badge(model.stats.cloudOnly).tag(SidebarItem.iCloudOnly)
                            .help("Photos stored in iCloud but not downloaded to this Mac")
                        if model.isSystemLibrary {
                            Label("Shared Albums", systemImage: "person.2.crop.square.stack")
                                .badge(model.stats.shared).tag(SidebarItem.sharedAlbums)
                        }
                    }
                }
                Section("Organize") {
                    Label("Duplicates", systemImage: "square.on.square")
                        .badge(model.duplicateGroups.count).tag(SidebarItem.duplicates)
                    Label("Removal Queue", systemImage: "tray.full")
                        .badge(model.removalQueue.count).tag(SidebarItem.removalQueue)
                    Label("People", systemImage: "person.2.crop.square.stack")
                        .badge(model.people.count).tag(SidebarItem.people)
                }
                Section("App") {
                    Label("Activity", systemImage: "list.bullet.rectangle").tag(SidebarItem.activity)
                    Label("Settings & Privacy", systemImage: "lock.shield").tag(SidebarItem.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
            .safeAreaInset(edge: .bottom) { IndexStatusFooter().padding(10) }
        } detail: {
            switch model.selection ?? .dashboard {
            case .dashboard: DashboardView()
            case .allPhotos: PhotoGridView(filter: .onThisMac)
            case .iCloudOnly: PhotoGridView(filter: .iCloudOnly)
            case .sharedAlbums: PhotoGridView(filter: .sharedAlbums)
            case .favorites: PhotoGridView(filter: .favorites)
            case .screenshots: PhotoGridView(filter: .screenshots)
            case .blurry: PhotoGridView(filter: .blurry)
            case .duplicates: DuplicatesView()
            case .removalQueue: RemovalQueueView()
            case .people: PeopleView()
            case .activity: ActivityView()
            case .settings: ScrollView { SettingsView().padding() }
            }
        }
        .sheet(item: $model.editingAsset) { asset in
            EditorView(asset: asset).environment(model).frame(minWidth: 1100, minHeight: 720)
        }
        .sheet(item: $model.upscaleRequest) { asset in
            UpscaleView(asset: asset).environment(model).frame(minWidth: 980, minHeight: 680)
        }
    }
}

struct IndexStatusFooter: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let s = model.status
        if s.running || model.syncing || !s.message.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(s.message.isEmpty ? "Working…" : s.message).font(.caption).lineLimit(2)
                if s.running { ProgressView(value: s.fraction).controlSize(.small) }
                if let t = s.throttle { Text(t).font(.caption2).foregroundStyle(.orange) }
                if s.running {
                    HStack {
                        Button(s.paused ? "Resume" : "Pause") {
                            Task {
                                if s.paused { await model.resumeAnalysis() } else { await model.pauseAnalysis() }
                            }
                        }
                        Button("Stop") { Task { await model.cancelAnalysis() } }
                    }.controlSize(.small)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let st = model.stats
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Dashboard").font(.largeTitle.bold())

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
                    StatCard(title: "Photos", value: st.photos, symbol: "photo")
                    StatCard(title: "Videos", value: st.videos, symbol: "video")
                    StatCard(title: "Screenshots", value: st.screenshots, symbol: "camera.viewfinder")
                    StatCard(title: "Live Photos", value: st.livePhotos, symbol: "livephoto")
                    StatCard(title: "Duplicate groups", value: model.duplicateGroups.count, symbol: "square.on.square")
                    StatCard(title: "People found", value: model.people.count, symbol: "person.2")
                    StatCard(title: "Faces to review", value: model.reviewFaces.count, symbol: "questionmark.square.dashed")
                    StatCard(title: "Only in iCloud", value: st.cloudOnly, symbol: "icloud")
                }

                GroupBox("Analysis") {
                    VStack(alignment: .leading, spacing: 10) {
                        ProgressRow(label: "Hashes & quality", done: st.hashed, total: st.photos)
                        ProgressRow(label: "Face detection", done: st.facesScanned, total: st.photos)
                        HStack {
                            Button {
                                Task { await model.startAnalysis() }
                            } label: {
                                Label(st.hashed < st.photos ? "Analyze Photos" : "Check for New Photos", systemImage: "sparkle.magnifyingglass")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.status.running)
                            Button("Rescan Library") { Task { await model.syncLibrary() } }.disabled(model.syncing)
                            Spacer()
                            if st.cloudOnly > 0 && !model.allowICloudDownloads {
                                Text("\(st.cloudOnly) photos are only in iCloud. Allow downloads in Settings to include them.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text("Runs in the background and can be paused. It slows down automatically on battery or when the Mac is hot.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(6)
                }

                GroupBox("Quick actions") {
                    HStack(spacing: 12) {
                        QuickAction(title: "Find duplicates", symbol: "square.on.square") { model.selection = .duplicates }
                        QuickAction(title: "Review people", symbol: "person.crop.rectangle.stack") { model.selection = .people }
                        QuickAction(title: "Blurry shots", symbol: "camera.metering.unknown") { model.selection = .blurry }
                        QuickAction(title: "Screenshots", symbol: "camera.viewfinder") { model.selection = .screenshots }
                        QuickAction(title: "Free storage", symbol: "externaldrive.badge.minus") { model.selection = .removalQueue }
                    }.padding(6)
                }
            }
            .padding(28)
        }
    }
}

struct StatCard: View {
    let title: String; let value: Int; let symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tint)
            Text(value.formatted()).font(.title.bold()).monospacedDigit()
            Text(title).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ProgressRow: View {
    let label: String; let done: Int; let total: Int
    var body: some View {
        HStack {
            Text(label).frame(width: 150, alignment: .leading)
            ProgressView(value: Double(min(done, total)), total: Double(max(total, 1)))
            Text("\(done.formatted()) / \(total.formatted())").monospacedDigit().font(.caption).frame(width: 130, alignment: .trailing)
        }
    }
}

struct QuickAction: View {
    let title: String; let symbol: String; let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.title2)
                Text(title).font(.caption)
            }.frame(maxWidth: .infinity, minHeight: 60)
        }.buttonStyle(.bordered)
    }
}


/// Sidebar header: which library PhotoForge is showing, and a menu to switch or add one.
struct LibrarySwitcher: View {
    @Environment(AppModel.self) private var model
    @State private var discovered: [URL] = []

    var body: some View {
        Menu {
            ForEach(model.libraries) { lib in
                Button {
                    Task { await model.switchLibrary(lib.id) }
                } label: {
                    if lib.id == model.activeLibraryID { Label(title(lib), systemImage: "checkmark") } else { Text(title(lib)) }
                }
            }
            if !discovered.isEmpty {
                Divider()
                Section("Found on this Mac") {
                    ForEach(discovered, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent + " — " + url.deletingLastPathComponent().path) {
                            Task { await model.openLibrary(at: url) }
                        }
                    }
                }
            }
            Divider()
            Button("Choose Library or Folder…") { Task { await model.chooseLibraryWithPanel() } }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.isSystemLibrary ? "photo.stack" : "externaldrive")
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.activeLibrary.map(title) ?? "System Photo Library").font(.callout.bold()).lineLimit(1)
                    if !model.isSystemLibrary { Text("Read-only").font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
        .menuStyle(.borderlessButton)
        .textCase(nil)
        .task { discovered = await model.discoverLibraries() }
        .help("Switch between your System Photo Library and other libraries or folders")
    }

    private func title(_ lib: LibraryRow) -> String {
        lib.isSystem ? "System Photo Library" : "\(lib.name) (\(lib.assetCount.formatted()))"
    }
}
