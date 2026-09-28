import SwiftUI
import PFCore
import AppKit
import PFDatabase
import PFPhotosBridge

enum GridFilter { case all, favorites, screenshots, blurry }

enum GridSort: String, CaseIterable, Identifiable {
    case newest = "Newest", oldest = "Oldest", sharpest = "Sharpest", largest = "Largest"
    var id: String { rawValue }
}

struct PhotoGridView: View {
    @Environment(AppModel.self) private var model
    let filter: GridFilter
    @State private var sort: GridSort = .newest
    @State private var tileSize: Double = 150
    @State private var selected: AssetRow?
    @State private var search = ""

    private var title: String {
        switch filter {
        case .all: "All Photos"
        case .favorites: "Favorites"
        case .screenshots: "Screenshots"
        case .blurry: "Blurry Photos"
        }
    }

    private var items: [AssetRow] {
        var rows = model.assets.filter { $0.mediaType == "image" }
        switch filter {
        case .all: break
        case .favorites: rows = rows.filter(\.favorite)
        case .screenshots: rows = rows.filter { $0.subtypeMask & 4 != 0 }
        // Low sharpness score; excludes screenshots (flat by nature).
        case .blurry: rows = rows.filter { ($0.sharpness ?? 1) < 0.25 && $0.subtypeMask & 4 == 0 }
        }
        if !search.isEmpty {
            let formatter = DateFormatter(); formatter.dateStyle = .long
            rows = rows.filter { r in
                (r.creationDate.map { formatter.string(from: $0) } ?? "").localizedCaseInsensitiveContains(search)
            }
        }
        switch sort {
        case .newest: rows.sort { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        case .oldest: rows.sort { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        case .sharpest: rows.sort { ($0.sharpness ?? 0) > ($1.sharpness ?? 0) }
        case .largest: rows.sort { $0.pixelWidth * $0.pixelHeight > $1.pixelWidth * $1.pixelHeight }
        }
        return rows
    }

    var body: some View {
        let rows = items
        HSplitView {
            VStack(spacing: 0) {
                if rows.isEmpty {
                    ContentUnavailableView(emptyTitle, systemImage: "photo",
                                           description: Text(emptyHint))
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: tileSize, maximum: tileSize * 1.6), spacing: 4)], spacing: 4) {
                            ForEach(rows) { row in
                                AssetThumbnail(localIdentifier: row.localIdentifier, side: tileSize * 2)
                                    .aspectRatio(1, contentMode: .fill)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    .overlay(RoundedRectangle(cornerRadius: 4)
                                        .stroke(selected?.id == row.id ? Color.accentColor : .clear, lineWidth: 3))
                                    .overlay(alignment: .bottomLeading) {
                                        if row.favorite {
                                            Image(systemName: "heart.fill").foregroundStyle(.white).shadow(radius: 2).padding(5)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { model.editingAsset = row }
                                    .onTapGesture { selected = row }
                                    .contextMenu {
                                        Button("Edit…") { model.editingAsset = row }
                                        Button("Add to Removal Queue") {
                                            Task {
                                                try? model.db?.queueForRemoval([row.id], reason: "Chosen by you", groupID: nil)
                                                await model.reloadFromDatabase()
                                            }
                                        }
                                        Button("Exclude from Duplicate Scans") { Task { await model.excludeFromScans([row.id]) } }
                                    }
                            }
                        }
                        .padding(8)
                    }
                }
            }
            .frame(minWidth: 420)

            InspectorView(asset: selected).frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
        }
        .navigationTitle(title)
        .navigationSubtitle("\(rows.count.formatted()) photos")
        .searchable(text: $search, prompt: "Search by date, e.g. “March 2024”")
        .toolbar {
            ToolbarItemGroup {
                Picker("Sort", selection: $sort) { ForEach(GridSort.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.menu).frame(width: 120)
                Slider(value: $tileSize, in: 80...300) { Text("Size") }.frame(width: 120)
                Button { if let s = selected { model.editingAsset = s } } label: { Label("Edit", systemImage: "slider.horizontal.3") }
                    .disabled(selected == nil)
            }
        }
    }

    private var emptyTitle: String { filter == .blurry ? "No blurry photos found" : "No photos here yet" }
    private var emptyHint: String {
        switch filter {
        case .blurry: "Run Analyze Photos from the Dashboard to measure sharpness."
        case .screenshots: "Screenshots from your Photos library appear here."
        default: "Photos appear as PhotoForge reads your library."
        }
    }
}

/// Async thumbnail from PhotoKit with a small in-memory cache.
struct AssetThumbnail: View {
    @Environment(AppModel.self) private var model
    let localIdentifier: String
    let side: Double
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary.opacity(0.4))
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .clipped()
        .task(id: localIdentifier) {
            if let cached = ThumbnailCache.shared.get(localIdentifier, side) { image = cached; return }
            let img = await model.photos.thumbnail(for: localIdentifier, side: side)
            if let img { ThumbnailCache.shared.set(img, localIdentifier, side) }
            image = img
        }
    }
}

final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    init() { cache.countLimit = 3000 }
    func get(_ id: String, _ side: Double) -> NSImage? { cache.object(forKey: "\(id)@\(Int(side))" as NSString) }
    func set(_ img: NSImage, _ id: String, _ side: Double) { cache.setObject(img, forKey: "\(id)@\(Int(side))" as NSString) }
}

struct InspectorView: View {
    @Environment(AppModel.self) private var model
    let asset: AssetRow?

    var body: some View {
        if let a = asset {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    AssetThumbnail(localIdentifier: a.localIdentifier, side: 600)
                        .aspectRatio(CGFloat(max(a.pixelWidth, 1)) / CGFloat(max(a.pixelHeight, 1)), contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Button { model.editingAsset = a } label: { Label("Edit Photo", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                        InfoRow("Date", a.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown")
                        InfoRow("Size", "\(a.pixelWidth) × \(a.pixelHeight)  (\(String(format: "%.1f", Double(a.pixelWidth * a.pixelHeight) / 1e6)) MP)")
                        InfoRow("Type", a.subtypeMask & 4 != 0 ? "Screenshot" : a.subtypeMask & 8 != 0 ? "Live Photo" : "Photo")
                        InfoRow("Favorite", a.favorite ? "Yes" : "No")
                        InfoRow("Stored", a.availability == "cloud_only" ? "iCloud only" : a.availability == "local" ? "On this Mac" : "—")
                        if let s = a.sharpness { InfoRow("Sharpness", Self.pct(s)) }
                        if let e = a.exposure { InfoRow("Exposure", Self.pct(e)) }
                        if let n = a.noise { InfoRow("Low noise", Self.pct(n)) }
                        if a.burstIdentifier != nil { InfoRow("Burst", "Part of a burst") }
                    }
                    .font(.callout)
                    let faces = model.people.filter { p in p.faces.contains { $0.assetID == a.id } }
                    if !faces.isEmpty {
                        Divider()
                        Text("People").font(.headline)
                        ForEach(faces) { p in Label(p.title, systemImage: "person.crop.circle") }
                    }
                }
                .padding()
            }
        } else {
            ContentUnavailableView("No selection", systemImage: "info.circle",
                                   description: Text("Select a photo to see its details. Double-click to edit."))
        }
    }

    static func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
}

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
