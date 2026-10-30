import Foundation
import AppKit
import PFCore
import PFDatabase

// MARK: - Private review (photos with nudity or a lot of bare skin)

extension AppModel {
    /// Detector levels offered in Settings (score at or above which a photo is included).
    static let reviewLevels: [(label: String, value: Double)] = [
        ("Broad — more skin, more false alarms", 0.35),
        ("Balanced", 0.6),
        ("Explicit only", 0.85),
    ]

    var reviewAvailable: Bool { sensitiveDetector != nil }

    func recomputeSensitive() {
        var ids = Set<Int64>()
        for (id, v) in sensitiveScores {
            if let o = v.override { if o { ids.insert(id) } }
            else if let s = v.score, s >= sensitiveLevel { ids.insert(id) }
        }
        if ids != sensitiveIDs { sensitiveIDs = ids }
    }

    /// Your decision: true = belongs in the review, false = doesn't, nil = let the detector decide.
    func markSensitive(_ ids: [Int64], _ value: Bool?) async {
        guard let db, !ids.isEmpty else { return }
        await Offload.run { try? db.setSensitiveOverride(ids, value) }
        for id in ids { sensitiveScores[id] = (sensitiveScores[id]?.score, value) }
        recomputeSensitive()
        let n = ids.count
        if value == false { banner = "\(n) item\(n == 1 ? "" : "s") taken out of “\(reviewName)”. PhotoForge remembers." }
        else if value == true { banner = "\(n) item\(n == 1 ? "" : "s") added to “\(reviewName)”." }
    }

    /// Turns the review on (and checks photos not checked yet) or off (scores are kept).
    func setReviewEnabled(_ on: Bool) async {
        sensitiveEnabled = on
        if on, currentJob == nil, reviewAvailable { await startAnalysis() }
    }

    /// Forgets every score (your own decisions are kept). Photos are checked again on the next analysis.
    func clearReviewScores() async {
        guard let db else { return }
        let sid = activeLibraryID
        await Offload.run { try? db.clearSensitiveScores(sourceID: sid) }
        for (id, v) in sensitiveScores { sensitiveScores[id] = (nil, v.override) }
        recomputeSensitive()
        banner = "Scores cleared. Photos will be checked again next time analysis runs."
    }

    /// Copies the originals to a folder you choose, then removes them from the library:
    /// Apple Photos keeps them in Recently Deleted for 30 days; a PhotoForge Library keeps them
    /// in its Trash. Only items that were copied successfully are removed.
    func moveToFolderWithPanel(_ ids: [Int64]) async {
        let rows = ids.compactMap { assetsByID[$0] }
        guard !rows.isEmpty else { return }
        guard canDelete else {
            banner = "This library is opened read-only, so items can only be copied out. Use Copy to Folder."
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Move \(rows.count) Item\(rows.count == 1 ? "" : "s") to a Folder"
        panel.message = "Choose a folder. The original files are copied there, then removed from this library."
        panel.prompt = "Move Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let alert = NSAlert()
        alert.messageText = "Move \(rows.count) item\(rows.count == 1 ? "" : "s") to “\(folder.lastPathComponent)”?"
        alert.informativeText = isSystemLibrary
            ? "They're copied to the folder first. Then they're removed from Apple Photos: Photos asks you to confirm, and keeps them in Recently Deleted for 30 days."
            : "They're copied to the folder first, then moved to this library's Trash."
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        importTask = Task {
            let written = await exportOriginalsByID(rows, to: folder, title: "Moving to “\(folder.lastPathComponent)”")
            let done = written.map(\.id)
            guard !done.isEmpty else { banner = "Nothing could be copied, so nothing was removed."; return }
            let removed = await delete(assetIDs: done)
            let failed = rows.count - done.count
            banner = removed
                ? "Moved \(done.count) item\(done.count == 1 ? "" : "s") to “\(folder.lastPathComponent)”." + (failed > 0 ? " \(failed) couldn't be copied and were left in place." : "")
                : "Copied \(done.count) item\(done.count == 1 ? "" : "s") to “\(folder.lastPathComponent)”, but they weren't removed from the library."
            NSWorkspace.shared.activateFileViewerSelecting(Array(written.prefix(50).map(\.url)))
        }
    }
}
