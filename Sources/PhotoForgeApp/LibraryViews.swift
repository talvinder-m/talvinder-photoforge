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
}

enum GridSort: String, CaseIterable, Identifiable {
    case newest = "Newest First", oldest = "Oldest First", sharpest = "Sharpest", largest = "Largest"
    var id: String { rawValue }
}

enum GridGrouping: String, CaseIterable, Identifiable {
    case month = "Month", year = "Year", none = "None"
    var id: String { rawValue }
}

/// One dated section of the grid (e.g. "March 2024") with its own grid of photos.
struct GridSection: Identifiable {
    let id: String
    let title: String
    let items: [AssetRow]
}

struct PhotoGridView: View {
    @Environment(AppModel.self) private var model
    let filter: GridFilter
    @AppStorage("grid.sort") private var sort: GridSort = .newest
    @AppStorage("grid.grouping") private var grouping: GridGrouping = .month
    @AppStorage("grid.tileSize") private var tileSize: Double = 140
    @AppStorage("grid.showPreview") private var showPreview = true
    @State private var selection: Set<Int64> = []
    @State private var focused: AssetRow?
    @State private var search = ""
    @State private var searchHits: Set<Int64>? = nil

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
        }
    }

    private var items: [AssetRow] {
        var rows = model.visibleAssets.filter { $0.mediaType == "image" }
        switch filter {
        case .onThisMac: rows = rows.filter { !$0.isICloudOnly && !$0.isShared }
        case .favorites: rows = rows.filter(\.favorite)
        case .screenshots: rows = rows.filter { $0.subtypeMask & 4 != 0 }
        // Low sharpness; screenshots are flat by nature, so they're excluded.
        case .blurry: rows = rows.filter { ($0.sharpness ?? 1) < 0.25 && $0.subtypeMask & 4 == 0 }
        case .iCloudOnly: rows = rows.filter { $0.isICloudOnly && !$0.isShared }
        case .sharedAlbums: rows = rows.filter(\.isShared)
        case .category(let c):
            let ids = model.categoryMembers[c] ?? []
            rows = rows.filter { ids.contains($0.id) }
        case .folder(let id):
            let keys = Set(model.folderIndex[id]?.assetKeys ?? [])
            rows = rows.filter { keys.contains($0.localIdentifier) }
        }
        if let hits = searchHits { rows = rows.filter { hits.contains($0.id) } }
        switch sort {
        case .newest: rows.sort { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        case .oldest: rows.sort { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        case .sharpest: rows.sort { ($0.sharpness ?? 0) > ($1.sharpness ?? 0) }
        case .largest: rows.sort { $0.pixelWidth * $0.pixelHeight > $1.pixelWidth * $1.pixelHeight }
        }
        return rows
    }

    private func sections(_ rows: [AssetRow]) -> [GridSection] {
        // Date sections only make sense when sorted by date.
        guard grouping != .none, sort == .newest || sort == .oldest else {
            return [GridSection(id: "all", title: "", items: rows)]
        }
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate(grouping == .month ? "MMMM yyyy" : "yyyy")
        var out: [GridSection] = []
        var currentKey: String?
        var bucket: [AssetRow] = []
        var bucketTitle = ""
        for r in rows {
            let key: String, t: String
            if let d = r.creationDate {
                let c = cal.dateComponents([.year, .month], from: d)
                key = grouping == .month ? "\(c.year!)-\(c.month!)" : "\(c.year!)"
                t = fmt.string(from: d)
            } else {
                key = "undated"; t = "No Date"
            }
            if key != currentKey {
                if let k = currentKey { out.append(GridSection(id: k, title: bucketTitle, items: bucket)) }
                currentKey = key; bucket = []; bucketTitle = t
            }
            bucket.append(r)
        }
        if let k = currentKey { out.append(GridSection(id: k, title: bucketTitle, items: bucket)) }
        return out
    }

    var body: some View {
        let rows = items
        let secs = sections(rows)
        Group {
            if rows.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: filter == .iCloudOnly ? "icloud" : "photo",
                                       description: Text(emptyHint))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: tileSize, maximum: tileSize * 1.5), spacing: 6)],
                              spacing: 6, pinnedViews: [.sectionHeaders]) {
                        ForEach(secs) { sec in
                            Section {
                                ForEach(sec.items) { row in cell(row) }
                            } header: {
                                if !sec.title.isEmpty { SectionHeader(title: sec.title, count: sec.items.count) }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(selection.count > 1 ? "\(selection.count) selected of \(rows.count.formatted())" : "\(rows.count.formatted()) photos")
        .inspector(isPresented: $showPreview) {
            PreviewPane(asset: focused)
                .inspectorColumnWidth(min: 260, ideal: 340, max: 620)
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("Group", selection: $grouping) { ForEach(GridGrouping.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.menu).help("Group photos into sections by month or year")
                Picker("Sort", selection: $sort) { ForEach(GridSort.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.menu)
                Slider(value: $tileSize, in: 80...320) { Text("Thumbnail size") }.frame(width: 110)
                    .help("Thumbnail size")
                Button {
                    let chosen = selection.count > 1 ? rows.filter { selection.contains($0.id) } : rows
                    model.startSlideshow(chosen, title: selection.count > 1 ? "\(selection.count) selected photos" : title,
                                         startAt: selection.count == 1 ? selection.first : nil)
                } label: { Label("Slideshow", systemImage: "play.rectangle") }
                .help(selection.count > 1 ? "Play the selected photos as a slideshow" : "Play these photos as a slideshow")
                .disabled(rows.isEmpty)
                if !selection.isEmpty {
                    Button { queueSelection() } label: { Label("Queue for Removal", systemImage: "tray.and.arrow.down") }
                        .help("Add the selected photos to the Removal Queue (nothing is deleted yet)")
                }
                Button { showPreview.toggle() } label: { Label("Preview", systemImage: "sidebar.right") }
                    .help(showPreview ? "Hide the preview pane" : "Show the preview pane")
            }
        }
        .onChange(of: filter) { selection = []; focused = nil }
        .searchable(text: $search, placement: .toolbar, prompt: "Search text in photos, file names")
        .task(id: search) {
            let q = search.trimmingCharacters(in: .whitespaces)
            guard q.count >= 2 else { searchHits = nil; return }
            try? await Task.sleep(for: .milliseconds(250))          // debounce typing
            if Task.isCancelled { return }
            searchHits = await model.searchText(q)
        }
    }

    @ViewBuilder
    private func cell(_ row: AssetRow) -> some View {
        let isSelected = selection.contains(row.id)
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
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.editingAsset = row }
            .onTapGesture { select(row, extend: NSEvent.modifierFlags.contains(.command)) }
            .contextMenu {
                Button("Edit…") { model.editingAsset = row }
                Button("Play Slideshow from Here") { model.startSlideshow(items, title: title, startAt: row.id) }
                Button("Upscale to 2K…") { model.upscaleRequest = row }
                    .disabled(max(row.pixelWidth, row.pixelHeight) >= 2048)
                Divider()
                Button("Add to Removal Queue") { selection.insert(row.id); queueSelection() }
                Button("Exclude from Duplicate Scans") { Task { await model.excludeFromScans([row.id]) } }
                if case .category(let c) = filter {
                    Divider()
                    let ids = selection.contains(row.id) ? Array(selection) : [row.id]
                    Button("Not \(c.singular.hasPrefix("a") || c.singular.hasPrefix("e") || c.singular.hasPrefix("i") || c.singular.hasPrefix("o") ? "an" : "a") \(c.singular)\(ids.count > 1 ? " (\(ids.count) photos)" : "")") {
                        Task { await model.setCategory(c, assetIDs: ids, included: false) }
                    }
                }
                Menu("Add to Category") {
                    ForEach(PhotoCategory.allCases) { c in
                        Button(c.title) { Task { await model.setCategory(c, assetIDs: selection.contains(row.id) ? Array(selection) : [row.id], included: true) } }
                    }
                }
            }
    }

    private func select(_ row: AssetRow, extend: Bool) {
        if extend {
            if selection.contains(row.id) { selection.remove(row.id) } else { selection.insert(row.id) }
        } else {
            selection = [row.id]
        }
        focused = row
    }

    private func queueSelection() {
        let ids = Array(selection)
        Task {
            try? model.db?.queueForRemoval(ids, reason: "Chosen by you", groupID: nil)
            selection = []
            await model.reloadFromDatabase()
        }
    }

    private var emptyTitle: String {
        switch filter {
        case .blurry: "No blurry photos found"
        case .iCloudOnly: "No iCloud-only photos"
        case .sharedAlbums: "No shared-album photos"
        case .category(let c): searchHits == nil ? "No \(c.title.lowercased()) yet" : "No matches"
        case .folder: searchHits == nil ? "This folder is empty" : "No matches"
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

struct SectionHeader: View {
    let title: String
    let count: Int
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.bold())
            Text("\(count.formatted())").font(.callout).foregroundStyle(.secondary)
            Spacer()
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

    var body: some View {
        Rectangle()
            .fill(.quaternary.opacity(0.45))
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .clipped()
            .task(id: "\(localIdentifier)@\(Int(side))") {
                if let cached = ThumbnailCache.shared.get(localIdentifier, side) { image = cached; return }
                let img = await model.thumbnail(for: localIdentifier, side: side)
                if let img { ThumbnailCache.shared.set(img, localIdentifier, side) }
                image = img
            }
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
}

/// Right-hand preview pane: large preview on top, details below. Resizable and hideable.
struct PreviewPane: View {
    @Environment(AppModel.self) private var model
    let asset: AssetRow?

    var body: some View {
        if let a = asset {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    AssetThumbnail(localIdentifier: a.localIdentifier, side: 1400, contentMode: .fit)
                        .aspectRatio(CGFloat(max(a.pixelWidth, 1)) / CGFloat(max(a.pixelHeight, 1)), contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .onTapGesture(count: 2) { model.editingAsset = a }
                    HStack {
                        Button { model.editingAsset = a } label: { Label("Edit", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent)
                        Button { model.upscaleRequest = a } label: { Label("Upscale", systemImage: "arrow.up.left.and.arrow.down.right").frame(maxWidth: .infinity) }
                            .disabled(max(a.pixelWidth, a.pixelHeight) >= 2048)
                            .help("Upscale to 2K with AI")
                    }
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                        InfoRow("Date", a.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown")
                        InfoRow("Size", "\(a.pixelWidth) × \(a.pixelHeight)  (\(String(format: "%.1f", Double(a.pixelWidth * a.pixelHeight) / 1e6)) MP)")
                        InfoRow("Type", a.subtypeMask & 4 != 0 ? "Screenshot" : a.subtypeMask & 8 != 0 ? "Live Photo" : "Photo")
                        InfoRow("Favorite", a.favorite ? "Yes" : "No")
                        InfoRow("Stored", a.storageLabel)
                        if let s = a.sharpness { InfoRow("Sharpness", Self.pct(s)) }
                        if let e = a.exposure { InfoRow("Exposure", Self.pct(e)) }
                        if let n = a.noise { InfoRow("Low noise", Self.pct(n)) }
                        if a.burstIdentifier != nil { InfoRow("Burst", "Part of a burst") }
                    }
                    .font(.callout)
                    CategoryChips(asset: a)
                    let people = model.people.filter { p in p.faces.contains { $0.assetID == a.id } }
                    if !people.isEmpty {
                        Divider()
                        Text("People").font(.headline)
                        ForEach(people) { p in Label(p.title, systemImage: "person.crop.circle") }
                    }
                }
                .padding()
            }
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
