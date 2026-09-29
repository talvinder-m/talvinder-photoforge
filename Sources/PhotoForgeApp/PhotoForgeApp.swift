import SwiftUI
import PFClassify
import PFCore
import PFDatabase
import PFPhotosBridge

/// Opens .pflibrary packages (and photo folders) double-clicked in Finder.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var pendingOpen: [URL] = []
    static var handler: (([URL]) -> Void)?
    func application(_ application: NSApplication, open urls: [URL]) {
        if let h = Self.handler { h(urls) } else { Self.pendingOpen += urls }
    }
}

@main
struct PhotoForgeApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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
                .task {
                    await model.bootstrap()
                    AppDelegate.handler = { urls in Task { @MainActor in for u in urls { await model.openLibrary(at: u) } } }
                    for u in AppDelegate.pendingOpen { await model.openLibrary(at: u) }
                    AppDelegate.pendingOpen = []
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New PhotoForge Library…") { Task { await model.newPhotoForgeLibraryWithPanel() } }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                Button("Open Library or Folder…") { Task { await model.chooseLibraryWithPanel() } }
                    .keyboardShortcut("o", modifiers: [.command, .option])
                Button("Add Photos & Videos…") { Task { await model.importWithPanel() } }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(!model.isManagedLibrary)
                Divider()
                Button("Rescan Library") { Task { await model.syncLibrary() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Analyze Photos") { Task { await model.startAnalysis() } }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
            }
        }

        // Editor and upscaler: separate, floating, screen-fitted windows (one per photo).
        WindowGroup("Edit Photo", id: "editor", for: Int64.self) { $assetID in
            EditorWindowRoot(assetID: assetID).environment(model)
        }
        .defaultSize(ScreenFit.size())
        .windowResizability(.contentMinSize)

        WindowGroup("Upscale Photo", id: "upscale", for: Int64.self) { $assetID in
            UpscaleWindowRoot(assetID: assetID).environment(model)
        }
        .defaultSize(ScreenFit.size(widthFraction: 0.85, heightFraction: 0.85))
        .windowResizability(.contentMinSize)

        WindowGroup("Video", id: "player", for: Int64.self) { $assetID in
            PlayerWindowRoot(assetID: assetID).environment(model)
        }
        .defaultSize(ScreenFit.size(widthFraction: 0.75, heightFraction: 0.75))

        WindowGroup("Slideshow", id: "slideshow", for: SlideshowRequest.self) { $request in
            if let request {
                SlideshowView(request: request).environment(model)
            }
        }
        .defaultSize(ScreenFit.size(widthFraction: 1, heightFraction: 1, maxWidth: 10_000, maxHeight: 10_000))
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView().environment(model).frame(width: 620, height: 680)
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
    @Environment(\.openWindow) private var openWindow
    @State private var nearExpanded = true
    @State private var dupExpanded = true
    @State private var newAlbum: NewAlbumRequest?
    @State private var showApplePhotosImport = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                Section {
                    Label("Dashboard", systemImage: "gauge.with.dots.needle.50percent").tag(SidebarItem.dashboard)
                    Label(model.isSystemLibrary ? "On This Mac" : "All Photos", systemImage: "photo.on.rectangle")
                        .tag(SidebarItem.allPhotos)
                    Label("Videos", systemImage: "film").badge(model.stats.videos).tag(SidebarItem.videos)
                    Label("Favorites", systemImage: "heart").tag(SidebarItem.favorites)
                    Label("Screenshots", systemImage: "camera.viewfinder").tag(SidebarItem.screenshots)
                    Label("Blurry Photos", systemImage: "camera.metering.unknown").tag(SidebarItem.blurry)
                } header: {
                    LibrarySwitcher()
                }
                Section("Categories") {
                    ForEach(PhotoCategory.allCases) { c in
                        Label(c.title, systemImage: c.symbol)
                            .badge(model.categoryMembers[c]?.count ?? 0)
                            .tag(SidebarItem.category(c))
                    }
                }
                Section {
                    OutlineGroup(model.albumTree, children: \.childrenOrNil) { node in
                        AlbumSidebarRow(node: node, newAlbum: $newAlbum)
                    }
                    if model.albumTree.isEmpty {
                        Text("Select photos, then right-click › Add to Album").font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        Text("My Albums")
                        Spacer()
                        Menu {
                            Button("New Album…") { newAlbum = NewAlbumRequest(isFolder: false) }
                            Button("New Folder…") { newAlbum = NewAlbumRequest(isFolder: true) }
                        } label: { Image(systemName: "plus") }
                        .menuStyle(.borderlessButton).fixedSize().help("New album or folder")
                    }
                }
                if !model.folderTree.isEmpty {
                    Section(model.isSystemLibrary ? "Albums & Folders" : "Folders") {
                        OutlineGroup(model.folderTree, children: \.childrenOrNil) { node in
                            Label(node.title, systemImage: node.symbol)
                                .badge(node.assetKeys.count)
                                .tag(SidebarItem.folder(node.id))
                        }
                    }
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
                    DisclosureGroup(isExpanded: $dupExpanded) {
                        Label("Exact Duplicates", systemImage: "equal.square")
                            .badge(model.duplicateGroups.filter { $0.type == .exact }.count)
                            .tag(SidebarItem.duplicates(.exact))
                        DisclosureGroup(isExpanded: $nearExpanded) {
                            Label("Burst Shots", systemImage: "square.stack.3d.down.right")
                                .badge(model.duplicateGroups.filter { $0.type == .burst }.count)
                                .tag(SidebarItem.duplicates(.burst))
                            Label("Similar Shots", systemImage: "rectangle.on.rectangle.angled")
                                .badge(model.duplicateGroups.filter { $0.type == .similar }.count)
                                .tag(SidebarItem.duplicates(.similar))
                        } label: {
                            Label("Near Duplicates", systemImage: "square.on.square.dashed")
                                .badge(model.duplicateGroups.filter { $0.type != .exact }.count)
                                .tag(SidebarItem.duplicates(.near))
                        }
                    } label: {
                        Label("Duplicates", systemImage: "square.on.square")
                            .badge(model.duplicateGroups.count).tag(SidebarItem.duplicates(.all))
                    }
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
            case .category(let c): PhotoGridView(filter: .category(c))
            case .folder(let id): PhotoGridView(filter: .folder(id))
            case .album(let id): PhotoGridView(filter: .album(id))
            case .dashboard: DashboardView()
            case .allPhotos: PhotoGridView(filter: .onThisMac)
            case .videos: PhotoGridView(filter: .videos)
            case .iCloudOnly: PhotoGridView(filter: .iCloudOnly)
            case .sharedAlbums: PhotoGridView(filter: .sharedAlbums)
            case .favorites: PhotoGridView(filter: .favorites)
            case .screenshots: PhotoGridView(filter: .screenshots)
            case .blurry: PhotoGridView(filter: .blurry)
            case .duplicates(let section): DuplicatesView(section: section).id(section)
            case .removalQueue: RemovalQueueView()
            case .people: PeopleView()
            case .activity: ActivityView()
            case .settings: ScrollView { SettingsView().padding() }
            }
        }
        // Requests from anywhere in the app open their own windows.
        .onChange(of: model.editingAsset) { _, asset in
            guard let asset else { return }
            openWindow(id: "editor", value: asset.id)
            model.editingAsset = nil
        }
        .onChange(of: model.upscaleRequest) { _, asset in
            guard let asset else { return }
            openWindow(id: "upscale", value: asset.id)
            model.upscaleRequest = nil
        }
        .onChange(of: model.slideshowRequest) { _, req in
            guard let req else { return }
            openWindow(id: "slideshow", value: req)
            model.slideshowRequest = nil
        }
        .onChange(of: model.playRequest) { _, asset in
            guard let asset else { return }
            openWindow(id: "player", value: asset.id)
            model.playRequest = nil
        }
        .sheet(item: $newAlbum) { req in NewAlbumSheet(request: req).environment(model) }
        .sheet(isPresented: $showApplePhotosImport) { ApplePhotosImportSheet().environment(model) }
        .onReceive(NotificationCenter.default.publisher(for: .showApplePhotosImport)) { _ in showApplePhotosImport = true }
        .toolbar {
            if model.isManagedLibrary {
                ToolbarItem(placement: .navigation) {
                    Menu {
                        Button("Photos & Videos from Files…") { Task { await model.importWithPanel() } }
                        Button("From Apple Photos…") { showApplePhotosImport = true }
                    } label: { Label("Add", systemImage: "square.and.arrow.down") }
                    .help("Add photos and videos to this library")
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard model.isManagedLibrary else { return false }
            Task { await model.importFiles(urls) }
            return true
        }
    }
}

struct IndexStatusFooter: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let s = model.status
        if let imp = model.importStatus {
            VStack(alignment: .leading, spacing: 6) {
                Text(imp.title).font(.caption).lineLimit(2)
                ProgressView(value: imp.fraction).controlSize(.small)
                Text("\(imp.done.formatted()) of \(imp.total.formatted()) · \(imp.summary)").font(.caption2).foregroundStyle(.secondary)
                if imp.running { Button("Stop") { model.cancelImport() }.controlSize(.small) }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
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
                        QuickAction(title: "Find duplicates", symbol: "square.on.square") { model.selection = .duplicates(.all) }
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


/// Sidebar header: which library is open, and a menu to switch, create or add one.
struct LibrarySwitcher: View {
    @Environment(AppModel.self) private var model
    @State private var discovered: [URL] = []

    var body: some View {
        Menu {
            Section("Libraries") {
                ForEach(model.libraries) { lib in
                    Button {
                        Task { await model.switchLibrary(lib.id) }
                    } label: {
                        let t = "\(lib.name) — \(lib.kindLabel)"
                        if lib.id == model.activeEntry?.id { Label(t, systemImage: "checkmark") } else { Text(t) }
                    }
                }
            }
            Divider()
            Button("New PhotoForge Library…") { Task { await model.newPhotoForgeLibraryWithPanel() } }
            Button("Open Library or Folder…") { Task { await model.chooseLibraryWithPanel() } }
            if !discovered.isEmpty {
                Menu("Found on this Mac") {
                    ForEach(discovered, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent + " — " + url.deletingLastPathComponent().path) {
                            Task { await model.openLibrary(at: url) }
                        }
                    }
                }
            }
            if model.isManagedLibrary {
                Divider()
                Button("Add Photos & Videos…") { Task { await model.importWithPanel() } }
                Button("Copy from Apple Photos…") { NotificationCenter.default.post(name: .showApplePhotosImport, object: nil) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.activeEntry?.name ?? "Apple Photos").font(.callout.bold()).lineLimit(1)
                    Text(model.activeEntry?.kindLabel ?? "").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .textCase(nil)
        .task { discovered = await model.discoverLibraries() }
        .help("Switch libraries, create a PhotoForge Library, or open another library or folder")
    }

    private var icon: String {
        switch model.activeEntry?.kind ?? .applePhotos {
        case .applePhotos: "photo.stack"
        case .photoForge: "books.vertical"
        case .external: "externaldrive"
        }
    }
}

extension Notification.Name {
    static let showApplePhotosImport = Notification.Name("PhotoForge.showApplePhotosImport")
}

extension AlbumNode {
    /// OutlineGroup wants nil (not []) for leaves so no disclosure triangle is drawn.
    var childrenOrNil: [AlbumNode]? { children.isEmpty ? nil : children }
    var symbol: String {
        switch kind {
        case .folder: "folder"
        case .album: "rectangle.stack"
        case .smartAlbum: "gearshape"
        case .directory: "folder"
        case .date: "calendar"
        }
    }
}
