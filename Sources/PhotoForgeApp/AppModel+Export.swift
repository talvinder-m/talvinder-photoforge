import Foundation
import AppKit
import UniformTypeIdentifiers
import PFCore
import PFDatabase
import PFPhotosBridge

// MARK: - Getting photos out: copy (⌘C), drag to Finder, Export to a folder

extension AppModel {
    /// File name an item gets when copied out: the name you gave it (if any) with the
    /// original's extension, otherwise the original file name.
    func exportFileName(for row: AssetRow) -> String {
        Self.exportFileName(ExportItem(row, fileURL: sourceFileURL(row), isPhotos: isSystemLibrary), photos: photos)
    }

    /// What's needed to copy one item out, usable from any thread.
    struct ExportItem: Sendable {
        let key: String
        let title: String?
        let originalFilename: String?
        let isVideo: Bool
        let id: Int64
        let fileURL: URL?
        let isPhotos: Bool
        init(_ row: AssetRow, fileURL: URL?, isPhotos: Bool) {
            key = row.localIdentifier; title = row.title; originalFilename = row.originalFilename
            isVideo = row.isVideo; id = row.id; self.fileURL = fileURL; self.isPhotos = isPhotos
        }
    }

    nonisolated static func exportFileName(_ item: ExportItem, photos: PhotoLibraryService) -> String {
        var original = item.originalFilename
        if original == nil || item.isPhotos, item.fileURL == nil {
            original = photos.exportResource(item.key)?.fileName ?? original
        }
        if original == nil, let u = item.fileURL { original = u.lastPathComponent }
        let base = original ?? "Photo-\(item.id).\(item.isVideo ? "mov" : "jpg")"
        let ext = (base as NSString).pathExtension
        if let t = item.title?.trimmingCharacters(in: .whitespaces), !t.isEmpty {
            let clean = BatchRename.clean(BatchRename.stripExtension(t))
            if !clean.isEmpty { return ext.isEmpty ? clean : "\(clean).\(ext)" }
        }
        return base
    }

    /// The item's file on disk, for libraries made of files (PhotoForge and read-only libraries).
    func sourceFileURL(_ row: AssetRow) -> URL? {
        if let m = managedSource { return m.url(for: row.localIdentifier) }
        if let e = externalSource { return e.fileURL(for: row.localIdentifier) }
        return nil
    }

    /// Writes one item's original to exactly `url`. Safe to call from any thread.
    nonisolated static func writeOriginal(key: String, fileURL: URL?, photos: PhotoLibraryService, to url: URL) async throws {
        if let src = fileURL {
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: src, to: url)
        } else {
            try await photos.writeOriginal(key, toFile: url, allowNetwork: true)
        }
    }

    /// Copies the originals of `rows` into `folder` (names made unique). Shows progress in the
    /// sidebar footer. Returns the files written.
    @discardableResult
    func exportOriginals(_ rows: [AssetRow], to folder: URL, title: String) async -> [URL] {
        var progress = ImportProgress(title: title, total: rows.count)
        progress.addedLabel = "copied"
        importStatus = progress
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var written: [URL] = []
        var used = Set<String>()
        let photos = self.photos
        for row in rows {
            if Task.isCancelled { break }
            var name = exportFileName(for: row)
            let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
            var n = 2
            while used.contains(name.lowercased()) || FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
                name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"; n += 1
            }
            used.insert(name.lowercased())
            let dest = folder.appendingPathComponent(name)
            do {
                try await Self.writeOriginal(key: row.localIdentifier, fileURL: sourceFileURL(row), photos: photos, to: dest)
                written.append(dest); progress.added += 1
            } catch { progress.failed += 1 }
            progress.done += 1
            if progress.done % 5 == 0 || progress.done == rows.count { importStatus = progress }
        }
        progress.running = false
        importStatus = progress
        return written
    }

    /// ⌘C: puts the selected items on the clipboard as files, so ⌘V in Finder copies them.
    func copyToPasteboard(_ ids: [Int64]) async {
        let rows = ids.compactMap { assetsByID[$0] }
        guard !rows.isEmpty else { return }
        var urls: [URL]
        // Files we can hand over as they are (no name change needed).
        let direct = rows.compactMap { r -> URL? in (r.title ?? "").isEmpty ? sourceFileURL(r) : nil }
        if direct.count == rows.count {
            urls = direct
        } else {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("PhotoForge Copy \(Int(Date().timeIntervalSince1970))", isDirectory: true)
            urls = await exportOriginals(rows, to: dir, title: "Preparing \(rows.count) item\(rows.count == 1 ? "" : "s") to copy")
        }
        guard !urls.isEmpty else { banner = "Nothing could be copied."; return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
        banner = "Copied \(urls.count) item\(urls.count == 1 ? "" : "s"). Paste in a Finder window with ⌘V."
    }

    /// Asks for a folder, then copies the originals there.
    func exportWithPanel(_ ids: [Int64]) async {
        let rows = ids.compactMap { assetsByID[$0] }
        guard !rows.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Export \(rows.count) Item\(rows.count == 1 ? "" : "s")"
        panel.message = "Choose a folder. The original files are copied there (with the names you gave them)."
        panel.prompt = "Export"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        importTask = Task {
            let written = await exportOriginals(rows, to: folder, title: "Exporting to “\(folder.lastPathComponent)”")
            banner = "Exported \(written.count) of \(rows.count) item\(rows.count == 1 ? "" : "s") to “\(folder.lastPathComponent)”."
            if !written.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(Array(written.prefix(50))) }
        }
    }
}

extension UTType {
    /// PhotoForge items dragged inside the app (onto an album or tag).
    static let photoforgeItems = UTType(exportedAs: "com.talvinder.photoforge.items", conformingTo: .data)
}
