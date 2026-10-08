import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PFCore
import PFDatabase
import PFPhotosBridge

// MARK: - Selection (like Apple Photos and Finder)

/// Selection for one photo grid. Kept in its own object so clicking only redraws visible cells.
///
///  • click: select one · ⌘-click: add/remove · ⇧-click: range from the last click
///  • drag a box from an empty spot: select everything it touches (⌘/⇧ adds to the selection)
///  • ⌘A all · Esc none · arrows move · ⇧-arrows extend
@MainActor
@Observable
final class GridSelection {
    var ids: Set<Int64> = []
    var focused: AssetRow?
    /// The rubber-band rectangle while dragging (grid coordinates).
    var band: CGRect?
    /// Asks the grid to scroll to this item.
    var scrollTarget: Int64?
    /// Bumped when the grid should take keyboard focus.
    var focusRequest = 0

    /// Display order of the items in the grid, and their rows.
    @ObservationIgnored var order: [Int64] = []
    @ObservationIgnored var rowsByID: [Int64: AssetRow] = [:]
    @ObservationIgnored private var position: [Int64: Int] = [:]
    /// Where each cell is (grid coordinates), as last laid out.
    @ObservationIgnored var frames: [Int64: CGRect] = [:]
    @ObservationIgnored var anchor: Int64?
    @ObservationIgnored private var bandBase: Set<Int64> = []

    func setItems(_ rows: [AssetRow]) {
        order = rows.map(\.id)
        rowsByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let still = ids.filter { position[$0] != nil }
        if still.count != ids.count { ids = still }
        if let f = focused { focused = rowsByID[f.id] }
        if let a = anchor, position[a] == nil { anchor = nil }
    }

    func click(_ row: AssetRow, modifiers: NSEvent.ModifierFlags) {
        focusRequest &+= 1
        if modifiers.contains(.shift), let a = anchor, let i = position[a], let j = position[row.id] {
            let range = Set(order[min(i, j)...max(i, j)])
            ids = modifiers.contains(.command) ? ids.union(range) : range
        } else if modifiers.contains(.command) {
            if ids.contains(row.id) { ids.remove(row.id) } else { ids.insert(row.id) }
            anchor = row.id
        } else {
            ids = [row.id]
            anchor = row.id
        }
        focused = row
    }

    func selectAll() {
        ids = Set(order)
        if focused == nil, let first = order.first { focused = rowsByID[first] }
    }

    func clear() { ids = []; anchor = nil }

    enum Direction { case left, right, up, down }

    /// Arrow keys. With `extend`, grows the selection from the anchor like Finder.
    func move(_ dir: Direction, extend: Bool) {
        guard !order.isEmpty else { return }
        guard let cur = focused?.id ?? anchor, let i = position[cur] else {
            let first = order[0]; ids = [first]; anchor = first; focused = rowsByID[first]; scrollTarget = first; return
        }
        var target = i
        switch dir {
        case .left: target = max(0, i - 1)
        case .right: target = min(order.count - 1, i + 1)
        case .up, .down: target = verticalNeighbour(of: i, down: dir == .down)
        }
        let id = order[target]
        if extend {
            let a = anchor.flatMap { position[$0] } ?? i
            ids = Set(order[min(a, target)...max(a, target)])
            if anchor == nil { anchor = cur }
        } else {
            ids = [id]; anchor = id
        }
        focused = rowsByID[id]
        scrollTarget = id
    }

    /// The cell above or below, using where cells are on screen (sections make rows uneven).
    private func verticalNeighbour(of i: Int, down: Bool) -> Int {
        let id = order[i]
        let columns = estimatedColumns()
        guard let f = frames[id] else { return down ? min(order.count - 1, i + columns) : max(0, i - columns) }
        var best: (Int, CGFloat, CGFloat)? = nil      // index, row distance, column distance
        let lo = max(0, i - columns * 3), hi = min(order.count - 1, i + columns * 3)
        for j in lo...hi where j != i {
            guard let g = frames[order[j]] else { continue }
            let dy = down ? g.midY - f.midY : f.midY - g.midY
            guard dy > f.height / 2 else { continue }
            let dx = abs(g.midX - f.midX)
            if best == nil || dy < best!.1 - 1 || (abs(dy - best!.1) <= 1 && dx < best!.2) { best = (j, dy, dx) }
        }
        return best?.0 ?? (down ? min(order.count - 1, i + columns) : max(0, i - columns))
    }

    private func estimatedColumns() -> Int {
        guard let f = focused.flatMap({ frames[$0.id] }) else { return 5 }
        let sameRow = frames.values.filter { abs($0.midY - f.midY) < 1 }.count
        return max(1, sameRow)
    }

    // Rubber band
    func beginBand(additive: Bool) { bandBase = additive ? ids : []; focusRequest &+= 1 }
    func updateBand(_ rect: CGRect) {
        band = rect
        var hit = bandBase
        for (id, f) in frames where f.intersects(rect) && position[id] != nil { hit.insert(id) }
        if hit != ids { ids = hit }
    }
    func endBand() {
        band = nil
        if let last = order.last(where: { ids.contains($0) }) { anchor = last; focused = rowsByID[last] }
    }
}

/// The grid's empty space: drag to draw a selection box, click to deselect.
struct GridBackground: View {
    let sel: GridSelection
    @State private var dragging = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .named(GridSpace.name))
                    .onChanged { v in
                        if !dragging {
                            dragging = true
                            let m = NSApp.currentEvent?.modifierFlags ?? []
                            sel.beginBand(additive: m.contains(.command) || m.contains(.shift))
                        }
                        sel.updateBand(CGRect(x: min(v.startLocation.x, v.location.x), y: min(v.startLocation.y, v.location.y),
                                              width: abs(v.location.x - v.startLocation.x),
                                              height: abs(v.location.y - v.startLocation.y)))
                    }
                    .onEnded { _ in dragging = false; sel.endBand() }
            )
            .onTapGesture { sel.clear(); sel.focusRequest &+= 1 }
    }
}

enum GridSpace { static let name = "photoforge.grid" }

/// Draws the selection box (only this small view redraws while dragging).
struct RubberBandOverlay: View {
    let sel: GridSelection
    var body: some View {
        if let r = sel.band {
            Rectangle()
                .fill(Color.accentColor.opacity(0.15))
                .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1))
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
                .allowsHitTesting(false)
        }
    }
}

/// Scrolls the grid to the item the arrow keys moved to.
struct ScrollDriver: View {
    let sel: GridSelection
    let proxy: ScrollViewProxy
    var body: some View {
        Color.clear
            .onChange(of: sel.scrollTarget) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
            }
    }
}

// MARK: - Dragging photos to Finder (as real files) and onto albums or tags

/// One dragged item: Finder receives the original file (written when dropped); PhotoForge's
/// own sidebar receives the item's id.
final class AssetPromiseProvider: NSFilePromiseProvider {
    var assetID: Int64 = 0
    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [NSPasteboard.PasteboardType(UTType.photoforgeItems.identifier)]
    }
    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type.rawValue == UTType.photoforgeItems.identifier ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }
    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type.rawValue == UTType.photoforgeItems.identifier { return Data(String(assetID).utf8) }
        return super.pasteboardPropertyList(forType: type)
    }
}

/// Items of the current drag, readable from any thread (Finder asks for files on a background queue).
final class DragItemStore: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Int64: AppModel.ExportItem] = [:]
    private var names: [Int64: String] = [:]
    var photos: PhotoLibraryService?
    func set(_ list: [AppModel.ExportItem], photos: PhotoLibraryService) {
        lock.lock(); items = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }); names = [:]; self.photos = photos; lock.unlock()
    }
    func item(_ id: Int64) -> AppModel.ExportItem? { lock.lock(); defer { lock.unlock() }; return items[id] }
    /// Worked out when Finder asks (not when the drag starts), and remembered.
    func name(_ id: Int64) -> String {
        lock.lock()
        if let n = names[id] { lock.unlock(); return n }
        let item = items[id], ph = photos
        lock.unlock()
        guard let item, let ph else { return "Photo \(id)" }
        let n = AppModel.exportFileName(item, photos: ph)
        lock.lock(); names[id] = n; lock.unlock()
        return n
    }
}

final class GridDragController: NSObject, NSDraggingSource, NSFilePromiseProviderDelegate, @unchecked Sendable {
    static let shared = GridDragController()
    private let store = DragItemStore()
    private let queue: OperationQueue = {
        let q = OperationQueue(); q.qualityOfService = .userInitiated; q.maxConcurrentOperationCount = 3; return q
    }()

    /// Starts an AppKit drag of `rows` from the current mouse event.
    @MainActor
    func begin(_ rows: [AssetRow], model: AppModel) {
        guard let event = NSApp.currentEvent, let window = event.window ?? NSApp.keyWindow,
              let view = window.contentView, !rows.isEmpty else { return }
        store.set(rows.map { AppModel.ExportItem($0, fileURL: model.sourceFileURL($0), isPhotos: model.isSystemLibrary) },
                  photos: model.photos)
        let point = view.convert(event.locationInWindow, from: nil)
        var dragItems: [NSDraggingItem] = []
        for (i, row) in rows.enumerated() {
            let ext = ((row.originalFilename ?? "") as NSString).pathExtension
            let type = UTType(filenameExtension: ext) ?? (row.isVideo ? .movie : .jpeg)
            let provider = AssetPromiseProvider(fileType: type.identifier, delegate: self)
            provider.assetID = row.id
            let item = NSDraggingItem(pasteboardWriter: provider)
            // A small stack of thumbnails under the pointer.
            let image = i < 5 ? (ThumbnailCache.shared.anyImage(row.localIdentifier) ?? NSImage(systemSymbolName: "photo", accessibilityDescription: nil)) : nil
            let side: CGFloat = 72, offset = CGFloat(min(i, 4)) * 6
            item.setDraggingFrame(NSRect(x: point.x - side / 2 + offset, y: point.y - side / 2 - offset, width: side, height: side),
                                  contents: image)
            dragItems.append(item)
        }
        let session = view.beginDraggingSession(with: dragItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        store.name((filePromiseProvider as? AssetPromiseProvider)?.assetID ?? 0)
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        let id = (filePromiseProvider as? AssetPromiseProvider)?.assetID ?? 0
        guard let item = store.item(id), let photos = store.photos else { completionHandler(CocoaError(.fileNoSuchFile)); return }
        let sem = DispatchSemaphore(value: 0)
        let box = ErrorBox()
        Task.detached {
            do { try await AppModel.writeOriginal(key: item.key, fileURL: item.fileURL, photos: photos, to: url) }
            catch { box.error = error }
            sem.signal()
        }
        sem.wait()          // on our own operation queue, never the main thread
        completionHandler(box.error)
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }
}

final class ErrorBox: @unchecked Sendable { var error: Error? }

/// Reads PhotoForge item ids dropped on an album or tag.
enum ItemDrop {
    static func load(_ providers: [NSItemProvider], _ done: @escaping @MainActor ([Int64]) -> Void) -> Bool {
        let relevant = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.photoforgeItems.identifier) }
        guard !relevant.isEmpty else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var ids: [Int64] = []
        for p in relevant {
            group.enter()
            p.loadDataRepresentation(forTypeIdentifier: UTType.photoforgeItems.identifier) { data, _ in
                if let data, let s = String(data: data, encoding: .utf8) {
                    let parsed = s.split(separator: ",").compactMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
                    lock.lock(); ids += parsed; lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { done(ids) } }
        return true
    }
}
