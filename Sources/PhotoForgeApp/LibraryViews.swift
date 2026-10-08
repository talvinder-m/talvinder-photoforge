import SwiftUI
import PFClassify
import PFCore
import AppKit
import PFDatabase
import PFPhotosBridge

enum GridFilter: Equatable {
    case onThisMac, favorites, screenshots, blurry, iCloudOnly, sharedAlbums
    case category(PhotoCategory)
    case folder(String)
    case album(Int64)
    case tag(String)
    case videos
}

enum GridSort: String, CaseIterable, Identifiable {
    case newest = "Newest First", oldest = "Oldest First", name = "Name", sharpest = "Sharpest", largest = "Largest"
    var id: String { rawValue }
}

enum GridGrouping: String, CaseIterable, Identifiable {
    case month = "Month", year = "Year", name = "Name", none = "None"
    var id: String { rawValue }
}

/// One dated section of the grid (e.g. "March 2024") with its own grid of photos.
struct GridSection: Identifiable {
    let id: String
    let title: String
    let items: [AssetRow]
}

/// Selection lives in its own object so that clicking a photo only redraws the visible
/// cells, not the whole grid.
@MainActor
@Observable
final class GridSelection {
    var ids: Set<Int64> = []
    var focused: AssetRow?

    func select(_ row: AssetRow, extend: Bool) {
        if extend {
            if ids.contains(row.id) { ids.remove(row.id) } else { ids.insert(row.id) }
        } else {
            ids = [row.id]
        }
        focused = row
    }
}

/// What the grid shows, computed off the main thread.
struct GridData: Sendable {
    var rows: [AssetRow] = []
    var sections: [GridSection] = []
    var version = 0
}

struct GridKey: Equatable {
    var filter: GridFilter
    var sort: GridSort
    var grouping: GridGrouping
    var searchHits: Set<Int64>?
    var dataVersion: Int
}

/// Everything a cell's menu can do, supplied by the grid.
struct GridActions {
    var filter: GridFilter
    var title: String
    var rename: ([Int64]) -> Void
    var newAlbum: ([Int64]) -> Void
    var slideshowFrom: (AssetRow) -> Void
    var queueForRemoval: ([Int64]) -> Void
    var tag: ([Int64]) -> Void
    var makeAlbum: (_ title: String, _ ids: [Int64]) -> Void
    var isSmartAlbum = false
}

struct PhotoGridView: View {
    @Environment(AppModel.self) private var model
    let filter: GridFilter
    @AppStorage("grid.sort") private var sort: GridSort = .newest
    @AppStorage("grid.grouping") private var grouping: GridGrouping = .month
    @AppStorage("grid.tileSize") private var tileSize: Double = 140
    @AppStorage("grid.showPreview") private var showPreview = true
    @State private var sel = GridSelection()
    @State private var data = GridData()
    @State private var loaded = false
    @State private var search = ""
    @State private var searchHits: Set<Int64>? = nil
    @State private var renameRequest: RenameRequest?
    @State private var newAlbum: NewAlbumRequest?
    @State private var tagRequest: TagRequest?

    private var title: String {
        switch filter {
        case .onThisMac: "All Photos"
        case .favorites: "Favorites"
        case .screenshots: "Screenshots"
        case .blurry: "Blurry Photos"
        case .iCloudOnly: "iCloud Photos"
        case .sharedAlbums: "Shared Albums"
        case .category(let c): c.title
        case .folder(let id): model.folderIndex[id]?.title ?? "Folder"
        case .album(let id): model.albums.first { $0.id == id }?.title ?? "Album"
        case .tag(let t): t
        case .videos: "Videos"
        }
    }

    private var key: GridKey {
        GridKey(filter: filter, sort: sort, grouping: grouping, searchHits: searchHits, dataVersion: model.dataVersion)
    }

    /// Filters, sorts and groups on a background thread.
    private func recompute() async {
        let assets = model.visibleAssets
        var memberIDs: Set<Int64>? = nil, keys: Set<String>? = nil
        switch filter {
        case .album(let id): memberIDs = model.albumAssetIDs(id)
        case .category(let c): memberIDs = model.categoryMembers[c] ?? []
        case .tag(let t): memberIDs = model.userTags[t] ?? []
        case .folder(let id): keys = Set(model.folderIndex[id]?.assetKeys ?? [])
        default: break
        }
        let f = filter, so = sort, gr = grouping, hits = searchHits, version = data.version &+ 1
        let result = await Offload.run {
            Self.compute(assets, filter: f, memberIDs: memberIDs, keys: keys, hits: hits, sort: so, grouping: gr, version: version)
        }
        guard !Task.isCancelled else { return }
        data = result
        loaded = true
        // Keep the preview pointing at the current copy of the focused item (e.g. after a rename).
        if let f = sel.focused { sel.focused = model.assetsByID[f.id] }
    }

    nonisolated static func compute(_ all: [AssetRow], filter: GridFilter, memberIDs: Set<Int64>?, keys: Set<String>?,
                                    hits: Set<Int64>?, sort: GridSort, grouping: GridGrouping, version: Int) -> GridData {
        // Albums and folders show photos and videos; photo views show photos; Videos shows videos.
        var rows: [AssetRow]
        switch filter {
        case .videos: rows = all.filter(\.isVideo)
        case .album, .folder, .tag: rows = all.filter { $0.mediaType == "image" || $0.isVideo }
        default: rows = all.filter { $0.mediaType == "image" }
        }
        switch filter {
        case .videos: break
        case .album, .category, .tag: if let ids = memberIDs { rows = rows.filter { ids.contains($0.id) } }
        case .folder: if let k = keys { rows = rows.filter { k.contains($0.localIdentifier) } }
        case .onThisMac: rows = rows.filter { !$0.isICloudOnly && !$0.isShared }
        case .favorites: rows = rows.filter(\.favorite)
        case .screenshots: rows = rows.filter { $0.subtypeMask & 4 != 0 }
        // Low sharpness; screenshots are flat by nature, so they're excluded.
        case .blurry: rows = rows.filter { ($0.sharpness ?? 1) < 0.25 && $0.subtypeMask & 4 == 0 }
        case .iCloudOnly: rows = rows.filter { $0.isICloudOnly && !$0.isShared }
        case .sharedAlbums: rows = rows.filter(\.isShared)
        }
        if let hits { rows = rows.filter { hits.contains($0.id) } }
        switch sort {
        case .newest: rows.sort { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        case .oldest: rows.sort { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        case .sharpest: rows.sort { ($0.sharpness ?? 0) > ($1.sharpness ?? 0) }
        case .largest: rows.sort { $0.pixelWidth * $0.pixelHeight > $1.pixelWidth * $1.pixelHeight }
        case .name:
            let names = rows.map(\.displayName)
            let order = names.indices.sorted { names[$0].localizedStandardCompare(names[$1]) == .orderedAscending }
            rows = order.map { rows[$0] }
        }
        return GridData(rows: rows, sections: sections(rows, sort: sort, grouping: grouping), version: version)
    }

    nonisolated static func sections(_ rows: [AssetRow], sort: GridSort, grouping: GridGrouping) -> [GridSection] {
        // Group by name: one section per name stem ("Farm Visit 001", "Farm Visit 002" → "Farm Visit").
        if grouping == .name {
            let groups = Dictionary(grouping: rows) { BatchRename.nameStem($0.displayName) }
            return groups.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { k in
                GridSection(id: "name:\(k)", title: k,
                            items: groups[k]!.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending })
            }
        }
        // Date sections only make sense when sorted by date.
        guard grouping != .none, sort == .newest || sort == .oldest else {
            return [GridSection(id: "all", title: "", items: rows)]
        }
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate(grouping == .month ? "MMMM yyyy" : "yyyy")
        var out: [GridSection] = []
        var currentKey: Int?
        var bucket: [AssetRow] = []
        var bucketTitle = ""
        for r in rows {
            let key: Int
            if let d = r.creationDate {
                let c = cal.dateComponents([.year, .month], from: d)
                key = grouping == .month ? c.year! * 100 + c.month! : c.year! * 100
            } else {
                key = -1
            }
            if key != currentKey {
                if let k = currentKey { out.append(GridSection(id: "\(k)", title: bucketTitle, items: bucket)) }
                currentKey = key; bucket = []
                // Format the title once per section, not once per photo.
                bucketTitle = r.creationDate.map { fmt.string(from: $0) } ?? "No Date"
            }
            bucket.append(r)
        }
        if let k = currentKey { out.append(GridSection(id: "\(k)", title: bucketTitle, items: bucket)) }
        return out
    }

    private var actions: GridActions {
        let rows = data.rows
        return GridActions(
            filter: filter, title: title,
            rename: { ids in renameRequest = RenameRequest(assetIDs: ids) },
            newAlbum: { ids in newAlbum = NewAlbumRequest(isFolder: false, assetIDs: ids) },
            slideshowFrom: { row in model.startSlideshow(rows, title: title, startAt: row.id) },
            queueForRemoval: { ids in queue(ids) },
            tag: { ids in tagRequest = TagRequest(assetIDs: ids) },
            makeAlbum: { t, ids in newAlbum = NewAlbumRequest(isFolder: false, assetIDs: ids, initialTitle: t) },
            isSmartAlbum: { if case .album(let id) = filter { return model.albums.first { $0.id == id }?.isSmart ?? false }; return false }())
    }

    var body: some View {
        let rows = data.rows
        Group {
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: filter == .iCloudOnly ? "icloud" : "photo",
                                       description: Text(emptyHint))
            } else {
                GridContent(data: data, tileSize: tileSize, showNames: grouping == .name || sort == .name,
                            sel: sel, actions: actions)
                    .equatable()
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(sel.ids.count > 1 ? "\(sel.ids.count) selected of \(rows.count.formatted())"
                            : "\(rows.count.formatted()) \(filter == .videos ? "videos" : "items")")
        .sheet(item: $renameRequest) { r in RenameSheet(request: r).environment(model) }
        .sheet(item: $newAlbum) { r in NewAlbumSheet(request: r).environment(model) }
        .sheet(item: $tagRequest) { r in TagSheet(request: r).environment(model) }
        .inspector(isPresented: $showPreview) {
            PreviewPane(asset: sel.focused)
                .inspectorColumnWidth(min: 260, ideal: 340, max: 620)
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("Group", selection: $grouping) { ForEach(GridGrouping.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.menu).help("Group into sections by month, year or name")
                Picker("Sort", selection: $sort) { ForEach(GridSort.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.menu)
                Slider(value: $tileSize, in: 80...320) { Text("Thumbnail size") }.frame(width: 110)
                    .help("Thumbnail size")
                Button {
                    let chosen = sel.ids.count > 1 ? rows.filter { sel.ids.contains($0.id) } : rows
                    model.startSlideshow(chosen, title: sel.ids.count > 1 ? "\(sel.ids.count) selected photos" : title,
                                         startAt: sel.ids.count == 1 ? sel.ids.first : nil)
                } label: { Label("Slideshow", systemImage: "play.rectangle") }
                .help(sel.ids.count > 1 ? "Play the selected photos as a slideshow" : "Play these photos as a slideshow")
                .disabled(rows.isEmpty)
                Button { renameRequest = RenameRequest(assetIDs: sel.ids.isEmpty ? rows.map(\.id) : rows.filter { sel.ids.contains($0.id) }.map(\.id)) } label: {
                    Label("Rename", systemImage: "character.cursor.ibeam")
                }
                .help(sel.ids.isEmpty ? "Rename everything shown here" : "Rename the selected items")
                .disabled(rows.isEmpty)
                if !sel.ids.isEmpty {
                    let ids = rows.filter { sel.ids.contains($0.id) }.map(\.id)
                    AddToAlbumMenu(ids: ids) { newAlbum = NewAlbumRequest(isFolder: false, assetIDs: ids) }
                        .help("Put the selected items in an album")
                    Button { tagRequest = TagRequest(assetIDs: ids) } label: { Label("Tag", systemImage: "tag") }
                        .help("Tag the selected items")
                    Button { queue(Array(sel.ids)) } label: { Label("Queue for Removal", systemImage: "tray.and.arrow.down") }
                        .help("Add the selected photos to the Removal Queue (nothing is deleted yet)")
                }
                Button { showPreview.toggle() } label: { Label("Preview", systemImage: "sidebar.right") }
                    .help(showPreview ? "Hide the preview pane" : "Show the preview pane")
            }
        }
        .onChange(of: filter) { sel.ids = []; sel.focused = nil }
        .task(id: key) { await recompute() }
        .searchable(text: $search, placement: .toolbar, prompt: "Search text in photos, file names")
        .task(id: search) {
            let q = search.trimmingCharacters(in: .whitespaces)
            guard q.count >= 2 else { searchHits = nil; return }
            try? await Task.sleep(for: .milliseconds(250))          // debounce typing
            if Task.isCancelled { return }
            searchHits = await model.searchText(q)
        }
    }

    private func queue(_ ids: [Int64]) {
        Task {
            try? model.db?.queueForRemoval(ids, reason: "Chosen by you", groupID: nil)
            sel.ids = []
            await model.reloadQueue()
        }
    }

    private var emptyTitle: String {
        switch filter {
        case .blurry: "No blurry photos found"
        case .iCloudOnly: "No iCloud-only photos"
        case .sharedAlbums: "No shared-album photos"
        case .category(let c): searchHits == nil ? "No \(c.title.lowercased()) yet" : "No matches"
        case .folder: searchHits == nil ? "This folder is empty" : "No matches"
        case .album(let id): model.albums.first { $0.id == id }?.isSmart == true ? "Nothing matches this smart album yet" : "This album is empty"
        case .tag: "Nothing has this tag"
        default: "No photos here yet"
        }
    }
    private var emptyHint: String {
        switch filter {
        case .blurry: "Run Analyze Photos from the Dashboard to measure sharpness."
        case .screenshots: "Screenshots from your library appear here."
        case .iCloudOnly: "Photos that are stored in iCloud but not downloaded to this Mac appear here."
        case .sharedAlbums: "Photos from iCloud Shared Albums appear here."
        case .category: searchHits == nil ? "Run Analyze Photos from the Dashboard to sort photos into categories." : "Try other words."
        default: "Photos appear as PhotoForge reads your library."
        }
    }
}

/// The scrolling grid. Rebuilt only when the photos, tile size or name labels change —
/// never on a click.
struct GridContent: View, Equatable {
    let data: GridData
    let tileSize: Double
    let showNames: Bool
    let sel: GridSelection
    let actions: GridActions

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.data.version == b.data.version && a.tileSize == b.tileSize && a.showNames == b.showNames && a.sel === b.sel
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: tileSize, maximum: tileSize * 1.5), spacing: 6)],
                      spacing: 6, pinnedViews: [.sectionHeaders]) {
                ForEach(data.sections) { sec in
                    Section {
                        ForEach(sec.items) { row in
                            GridCell(row: row, tileSize: tileSize, showNames: showNames, sel: sel, actions: actions)
                        }
                    } header: {
                        if !sec.title.isEmpty {
                            SectionHeader(title: sec.title, count: sec.items.count) {
                                actions.makeAlbum(sec.title, sec.items.map(\.id))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct GridCell: View {
    @Environment(AppModel.self) private var model
    let row: AssetRow
    let tileSize: Double
    let showNames: Bool
    let sel: GridSelection
    let actions: GridActions

    var body: some View {
        let isSelected = sel.ids.contains(row.id)
        AssetThumbnail(localIdentifier: row.localIdentifier, side: tileSize * 2)
            .aspectRatio(1, contentMode: .fit)                          // square cell, exactly the column width
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 4) {
                    if row.favorite { Image(systemName: "heart.fill") }
                    if row.isICloudOnly { Image(systemName: "icloud") }
                    if row.isShared { Image(systemName: "person.2.fill") }
                }
                .font(.caption).foregroundStyle(.white).shadow(radius: 2).padding(5)
            }
            .overlay(alignment: .bottomTrailing) {
                if row.isVideo {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill")
                        Text(MediaFiles.duration(row.duration))
                    }
                    .font(.caption2.bold()).foregroundStyle(.white).shadow(radius: 2).padding(5)
                }
            }
            .overlay(alignment: .topLeading) {
                if showNames || row.title != nil {
                    Text(row.displayName).font(.caption2).lineLimit(1).padding(.horizontal, 4).padding(.vertical, 2)
                        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(.white).padding(4)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if row.isVideo { model.playRequest = row } else { model.editingAsset = row } }
            .onTapGesture { sel.select(row, extend: NSEvent.modifierFlags.contains(.command)) }
            .draggable(AssetDrag.payload(sel.ids.contains(row.id) ? Array(sel.ids) : [row.id])) {
                let n = sel.ids.contains(row.id) ? sel.ids.count : 1
                AssetThumbnail(localIdentifier: row.localIdentifier, side: 160)
                    .frame(width: 80, height: 80).clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .topTrailing) {
                        if n > 1 { Text("\(n)").font(.caption.bold()).padding(4).background(.red, in: Capsule()).foregroundStyle(.white) }
                    }
            }
            .contextMenu { menu }
    }

    @ViewBuilder private var menu: some View {
        let ids = sel.ids.contains(row.id) ? Array(sel.ids) : [row.id]
        if row.isVideo { Button("Play") { model.playRequest = row } } else { Button("Edit…") { model.editingAsset = row } }
        Button(ids.count > 1 ? "Rename \(ids.count) Items…" : "Rename…") { actions.rename(ids) }
        AddToAlbumMenu(ids: ids) { actions.newAlbum(ids) }
        Menu("Tags") {
            Button("Add or Remove Tags…") { actions.tag(ids) }
            let names = model.tagNames
            if !names.isEmpty { Divider() }
            ForEach(names.prefix(15), id: \.self) { t in
                let all = ids.allSatisfy { model.userTags[t]?.contains($0) == true }
                Button { Task { all ? await model.removeTag(t, from: ids) : await model.addTag(t, to: ids) } } label: {
                    if all { Label(t, systemImage: "checkmark") } else { Text(t) }
                }
            }
        }
        if case .album(let aid) = actions.filter, !actions.isSmartAlbum {
            Button("Remove from Album") { model.removeFromAlbum(aid, ids) }
        }
        Divider()
        Button("Play Slideshow from Here") { actions.slideshowFrom(row) }
        Button("Upscale to 2K…") { model.upscaleRequest = row }
            .disabled(max(row.pixelWidth, row.pixelHeight) >= 2048)
        Divider()
        Button("Add to Removal Queue") { actions.queueForRemoval(ids) }
        Button("Exclude from Duplicate Scans") { Task { await model.excludeFromScans(ids) } }
        if case .category(let c) = actions.filter {
            Divider()
            let article = "aeio".contains(c.singular.prefix(1).lowercased()) ? "an" : "a"
            Button("Not \(article) \(c.singular)\(ids.count > 1 ? " (\(ids.count) photos)" : "")") {
                Task { await model.setCategory(c, assetIDs: ids, included: false) }
            }
        }
        Menu("Add to Category") {
            ForEach(PhotoCategory.allCases) { c in
                Button(c.title) { Task { await model.setCategory(c, assetIDs: ids, included: true) } }
            }
        }
    }
}

struct SectionHeader: View {
    let title: String
    let count: Int
    var makeAlbum: (() -> Void)? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.bold())
            Text("\(count.formatted())").font(.callout).foregroundStyle(.secondary)
            Spacer()
            if let makeAlbum {
                Button(action: makeAlbum) { Label("Make Album", systemImage: "rectangle.stack.badge.plus") }
                    .buttonStyle(.borderless).font(.callout)
                    .help("Put these \(count) items in a new album called “\(title)”")
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(.bar)
    }
}

/// A thumbnail that always fills exactly the space it's given and never overflows it.
/// (Size it from outside with `.frame` or `.aspectRatio`.)
struct AssetThumbnail: View {
    @Environment(AppModel.self) private var model
    let localIdentifier: String
    let side: Double
    var contentMode: ContentMode = .fill
    @State private var image: NSImage?
    @State private var tried = false

    var body: some View {
        Rectangle()
            .fill(.quaternary.opacity(0.45))
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
                } else if tried {
                    Image(systemName: "photo").font(.title2).foregroundStyle(.tertiary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .clipped()
            .task(id: "\(localIdentifier)@\(Int(side))") {
                if let cached = ThumbnailCache.shared.get(localIdentifier, side) { image = cached; return }
                // A few at a time, newest request first: cells scrolled past are skipped.
                await ThumbnailGate.shared.acquire()
                if Task.isCancelled { await ThumbnailGate.shared.release(); return }
                let img = await model.thumbnail(for: localIdentifier, side: side)
                await ThumbnailGate.shared.release()
                if let img { ThumbnailCache.shared.set(img, localIdentifier, side) }
                image = img
                tried = true
            }
    }
}

/// Limits how many thumbnails load at once, so fast scrolling can't swamp the CPU.
/// Waiting requests are served newest-first (what's on screen now).
actor ThumbnailGate {
    static let shared = ThumbnailGate(limit: max(2, min(6, ProcessInfo.processInfo.activeProcessorCount)))
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if running < limit { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if let next = waiters.popLast() { next.resume() } else { running -= 1 }
    }
}

final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    init() { cache.countLimit = 2500; cache.totalCostLimit = 300_000_000 }
    func get(_ id: String, _ side: Double) -> NSImage? { cache.object(forKey: "\(id)@\(Int(side))" as NSString) }
    func set(_ img: NSImage, _ id: String, _ side: Double) {
        let cost = Int(img.size.width * img.size.height * 4)
        cache.setObject(img, forKey: "\(id)@\(Int(side))" as NSString, cost: cost)
    }
    func removeAll() { cache.removeAllObjects() }
    func configure(megabytes: Int) { cache.totalCostLimit = megabytes * 1_000_000 }
}

/// Right-hand preview pane: large preview on top, details below. Resizable and hideable.
struct PreviewPane: View {
    @Environment(AppModel.self) private var model
    let asset: AssetRow?
    @State private var showFaces = false
    @State private var name = ""
    @State private var renaming = false

    var body: some View {
        if let a = asset {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        if renaming {
                            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                                .onSubmit {
                                    renaming = false
                                    Task { await model.rename([a.id], to: [BatchRename.clean(name)], renameFiles: model.isManagedLibrary, writeToPhotos: false) }
                                }
                        } else {
                            Text(a.displayName).font(.headline).lineLimit(2).textSelection(.enabled)
                            Spacer()
                            Button { name = BatchRename.stripExtension(a.displayName); renaming = true } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless).help("Rename")
                        }
                    }
                    if a.isVideo {
                        AssetThumbnail(localIdentifier: a.localIdentifier, side: 900, contentMode: .fit)
                            .aspectRatio(CGFloat(max(a.pixelWidth, 16)) / CGFloat(max(a.pixelHeight, 9)), contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay { Image(systemName: "play.circle.fill").font(.system(size: 44)).foregroundStyle(.white).shadow(radius: 4) }
                            .onTapGesture { model.playRequest = a }
                        Button { model.playRequest = a } label: { Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent)
                    } else {
                        FaceTaggingImage(asset: a, showFaces: showFaces)
                            .onTapGesture(count: 2) { model.editingAsset = a }
                        HStack {
                            Button { model.editingAsset = a } label: { Label("Edit", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity) }
                                .buttonStyle(.borderedProminent)
                            Button { model.upscaleRequest = a } label: { Label("Upscale", systemImage: "arrow.up.left.and.arrow.down.right").frame(maxWidth: .infinity) }
                                .disabled(max(a.pixelWidth, a.pixelHeight) >= 2048)
                                .help("Upscale to 2K with AI")
                        }
                        Toggle(isOn: $showFaces) { Label("Show & tag faces", systemImage: "person.crop.square") }
                            .toggleStyle(.switch)
                            .help("Show detected faces. Click a face to say who it is, or drag a box around a face that was missed.")
                    }
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                        InfoRow("Date", a.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown")
                        InfoRow("Size", "\(a.pixelWidth) × \(a.pixelHeight)  (\(String(format: "%.1f", Double(a.pixelWidth * a.pixelHeight) / 1e6)) MP)")
                        InfoRow("Type", a.isVideo ? "Video · \(MediaFiles.duration(a.duration))" : a.subtypeMask & 4 != 0 ? "Screenshot" : a.subtypeMask & 8 != 0 ? "Live Photo" : "Photo")
                        if let f = a.originalFilename, f != a.displayName { InfoRow("File", f) }
                        InfoRow("Favorite", a.favorite ? "Yes" : "No")
                        InfoRow("Stored", a.storageLabel)
                        if let s = a.sharpness { InfoRow("Sharpness", Self.pct(s)) }
                        if let e = a.exposure { InfoRow("Exposure", Self.pct(e)) }
                        if let n = a.noise { InfoRow("Low noise", Self.pct(n)) }
                        if a.burstIdentifier != nil { InfoRow("Burst", "Part of a burst") }
                    }
                    .font(.callout)
                    CategoryChips(asset: a)
                    AssetTagsRow(asset: a)
                    let people = model.people.filter { p in p.faces.contains { $0.assetID == a.id } }
                    if !people.isEmpty {
                        Divider()
                        Text("People").font(.headline)
                        ForEach(people) { p in Label(p.title, systemImage: "person.crop.circle") }
                    }
                    let inAlbums = model.albumsContaining(a.id)
                    if !inAlbums.isEmpty {
                        Divider()
                        Text("Albums").font(.headline)
                        ForEach(inAlbums) { al in
                            Button { model.selection = .album(al.id) } label: { Label(al.title, systemImage: "rectangle.stack") }.buttonStyle(.link)
                        }
                    }
                }
                .padding()
            }
            .onChange(of: a.id) { renaming = false }
        } else {
            ContentUnavailableView("No selection", systemImage: "photo",
                                   description: Text("Click a photo to preview it here. Double-click to edit. ⌘-click to select several."))
        }
    }

    static func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
}

/// Kept for callers elsewhere (duplicates, people).
typealias InspectorView = PreviewPane

struct InfoRow: View {
    let label: String, value: String
    init(_ label: String, _ value: String) { self.label = label; self.value = value }
    var body: some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

extension AssetRow {
    var isICloudOnly: Bool { availability == "cloud_only" }
    var isShared: Bool { assetSource == "shared" }
    var storageLabel: String {
        if isShared { return "iCloud Shared Album" }
        switch availability {
        case "cloud_only": return "iCloud only (not downloaded)"
        case "local": return "On this Mac"
        default: return "—"
        }
    }
}


/// Categories this photo is in, with the reason for each, and a way to correct them.
struct CategoryChips: View {
    @Environment(AppModel.self) private var model
    let asset: AssetRow
    @State private var details: [(category: String, confidence: Double, reason: String, source: String)] = []

    var body: some View {
        let inCats = PhotoCategory.allCases.filter { model.categoryMembers[$0]?.contains(asset.id) == true }
        VStack(alignment: .leading, spacing: 6) {
            if !inCats.isEmpty {
                Divider()
                Text("Categories").font(.headline)
                ForEach(inCats) { c in
                    let d = details.first { $0.category == c.rawValue && ($0.source == "user" || $0.confidence >= 0.5) }
                    HStack(alignment: .top) {
                        Image(systemName: c.symbol).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.title).font(.callout)
                            if let d { Text(d.reason).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button { Task { await model.setCategory(c, assetIDs: [asset.id], included: false) } } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.borderless).help("Not \(c.singular) — remove from \(c.title)")
                    }
                }
            }
        }
        .task(id: "\(asset.id)-\(inCats.count)") { details = model.categoryDetails(asset.id) }
    }
}

/// Tags on one item in the preview pane: remove with ×, add by typing.
struct AssetTagsRow: View {
    @Environment(AppModel.self) private var model
    let asset: AssetRow
    @State private var text = ""

    var body: some View {
        let tags = model.tags(of: asset.id)
        VStack(alignment: .leading, spacing: 6) {
            Text("Tags").font(.headline)
            if !tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { t in
                        HStack(spacing: 3) {
                            Button(t) { model.selection = .tag(t) }.buttonStyle(.plain)
                            Button { Task { await model.removeTag(t, from: [asset.id]) } } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove this tag")
                        }
                        .font(.callout).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
            }
            TextField("Add a tag", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    let t = text; text = ""
                    Task { await model.addTag(t, to: [asset.id]) }
                }
        }
    }
}
