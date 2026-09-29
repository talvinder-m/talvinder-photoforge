import SwiftUI
import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import PFCore
import PFDatabase
import PFPhotosBridge
import PFVision
import PFClassify

struct ImportProgress: Equatable {
    var title: String
    var done = 0
    var total = 0
    var added = 0
    var skipped = 0
    var failed = 0
    var running = true
    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    var summary: String {
        var parts = ["\(added.formatted()) added"]
        if skipped > 0 { parts.append("\(skipped.formatted()) already in the library") }
        if failed > 0 { parts.append("\(failed.formatted()) couldn't be copied") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - This Mac

extension AppModel {
    func applyMachineProfile() {
        let base = machine.analysisConcurrency
        switch performanceMode {
        case .automatic: analysisConcurrency = base
        case .batterySaver: analysisConcurrency = max(1, base / 2)
        case .maximum: analysisConcurrency = max(base, machine.cores)
        }
        ThumbnailCache.shared.configure(megabytes: machine.thumbnailCacheMB)
        let key = "machineFingerprint"
        if UserDefaults.standard.string(forKey: key) != machine.fingerprint {
            UserDefaults.standard.set(machine.fingerprint, forKey: key)
            banner = "PhotoForge is tuned for this Mac: \(machine.summary). See Settings › This Mac."
        }
    }
}

// MARK: - PhotoForge Libraries: create, import, keep in sync

extension AppModel {
    /// Asks where to put a new PhotoForge Library (any folder, any drive) and opens it.
    func newPhotoForgeLibraryWithPanel() async {
        let panel = NSSavePanel()
        panel.title = "New PhotoForge Library"
        panel.message = "Choose a name and a location — any folder or drive. Photos you add are copied into the library."
        panel.nameFieldStringValue = "My Photos"
        panel.prompt = "Create"
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await createPhotoForgeLibrary(named: url.deletingPathExtension().lastPathComponent, in: url.deletingLastPathComponent())
    }

    @discardableResult
    func createPhotoForgeLibrary(named name: String, in parent: URL) async -> LibraryEntry? {
        do {
            let (url, m) = try PhotoForgePackage.create(named: name, in: parent)
            let entry = LibraryEntry(id: m.id, kind: .photoForge, name: m.name, sourcePath: url.path,
                                     dataPath: url.appendingPathComponent("Database").path)
            registry.upsert(entry)
            libraries = registry.entries
            guard await open(entry) else { return nil }
            db?.log("scan", "Created PhotoForge Library “\(m.name)” at \(url.path)")
            return entry
        } catch {
            banner = "Couldn't create the library: \(error.localizedDescription)"
            return nil
        }
    }

    /// Checks a PhotoForge Library against its files: missing files are marked gone,
    /// files added to it by hand (e.g. in Finder) are picked up in place.
    func syncManagedLibrary(db: AppDatabase, id: Int64, source: ManagedLibrarySource) async {
        syncing = true
        defer { syncing = false }
        let paths = (try? db.filePaths(sourceID: id)) ?? [:]
        let missing = paths.filter { !FileManager.default.fileExists(atPath: source.root.appendingPathComponent($0.value).path) }.map(\.key)
        if !missing.isEmpty {
            try? db.markDeleted(localIdentifiers: missing)
            for k in missing { source.remove(k) }
        }
        let untracked = await Task.detached { source.untrackedFiles() }.value
        if !untracked.isEmpty {
            _ = await addFiles(untracked, copy: false, title: "Adding files found in the library")
        }
        await reloadFromDatabase()
        refreshLibraries()
    }

    func importWithPanel() async {
        guard isManagedLibrary else {
            banner = "Importing copies photos into a PhotoForge Library. Create or open one first (library menu at the top of the sidebar)."
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Add Photos & Videos"
        panel.message = "Choose photos, videos or folders. They're copied into “\(activeEntry?.name ?? "")”; the originals stay where they are."
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        await importFiles(panel.urls)
    }

    /// Imports files and folders (recursively) by copying them into the open PhotoForge Library.
    func importFiles(_ urls: [URL]) async {
        guard isManagedLibrary else { return }
        let files = await Task.detached { Self.expandMedia(urls) }.value
        guard !files.isEmpty else { banner = "No photos or videos were found there."; return }
        let r = await addFiles(files, copy: true, title: "Adding \(files.count.formatted()) items")
        banner = "Import finished: \(r.summary)."
        await reloadFromDatabase()
        refreshLibraries()
    }

    nonisolated static func expandMedia(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue && !PhotoForgePackage.isPackage(u) {
                if let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    for case let f as URL in e where MediaFiles.isMedia(f) { out.append(f) }
                }
            } else if MediaFiles.isMedia(u) {
                out.append(u)
            }
        }
        return out
    }

    /// Core of every import: dedupe by content (SHA-256), copy (or adopt in place), record.
    @discardableResult
    func addFiles(_ files: [URL], copy: Bool, title: String) async -> ImportProgress {
        guard let db, let sid = activeLibraryID, let managed = managedSource else { return ImportProgress(title: title) }
        var progress = ImportProgress(title: title, total: files.count)
        importStatus = progress
        var known = (try? db.fileHashes(sourceID: sid)) ?? []
        var batch: [AssetUpsert] = []
        func flush() {
            guard !batch.isEmpty else { return }
            try? db.upsert(batch, sourceID: sid, scanStamp: .now)
            batch.removeAll()
        }
        for f in files {
            if Task.isCancelled { break }
            let knownNow = known
            let result: (upsert: AssetUpsert, key: String, rel: String)? = await Task.detached(priority: .utility) {
                guard let hash = try? Self.sha256(f) else { return nil }
                if knownNow.contains(hash) { return (AssetUpsert(localIdentifier: "", mediaType: "", subtypeMask: 0, creationDate: nil, modificationDate: nil,
                                                              pixelWidth: 0, pixelHeight: 0, duration: 0, favorite: false, hidden: false,
                                                              burstIdentifier: nil, fileHash: hash), "", "") }
                let p = MediaFiles.probe(f)
                let values = try? f.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey])
                let date = p.captureDate ?? values?.creationDate
                guard let rel = copy ? (try? managed.importFile(f, date: date)) : managed.relative(f) else { return nil }
                let key = ManagedLibrarySource.newKey()
                let up = AssetUpsert(localIdentifier: key, mediaType: p.mediaType, subtypeMask: p.isScreenshot ? 4 : 0,
                                     creationDate: date, modificationDate: values?.contentModificationDate,
                                     pixelWidth: p.width, pixelHeight: p.height, duration: p.duration,
                                     favorite: false, hidden: false, burstIdentifier: nil, assetSource: "library",
                                     filePath: rel, availability: "local", originalFilename: f.lastPathComponent,
                                     fileSize: values?.fileSize, fileHash: hash)
                return (up, key, rel)
            }.value
            progress.done += 1
            if let r = result {
                if r.key.isEmpty { progress.skipped += 1 }
                else {
                    known.insert(r.upsert.fileHash!)
                    managed.set(r.key, relativePath: r.rel)
                    batch.append(r.upsert)
                    progress.added += 1
                    if batch.count >= 100 { flush() }
                }
            } else {
                progress.failed += 1
            }
            if progress.done % 10 == 0 || progress.done == progress.total { importStatus = progress }
        }
        flush()
        progress.running = false
        importStatus = progress
        db.log("scan", "\(title): \(progress.summary)", assetCount: progress.added)
        Task { try? await Task.sleep(for: .seconds(6)); if importStatus?.running == false { importStatus = nil } }
        return progress
    }

    nonisolated static func sha256(_ u: URL) throws -> Data {
        let h = try FileHandle(forReadingFrom: u)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return Data(hasher.finalize())
    }

    // MARK: Copy from Apple Photos

    struct ApplePhotosImportOptions {
        var onlyIdentifiers: [String]? = nil      // nil = whole library
        var includeVideos = true
        var downloadFromICloud = false
        var copyAnalysis = true
        var recreateAlbums = true
    }

    /// Builds (or tops up) the open PhotoForge Library from Apple Photos: copies originals
    /// (as currently edited), recreates albums, and carries over everything already analysed
    /// — names, categories, faces and people — so nothing has to be rescanned.
    func importFromApplePhotos(_ opts: ApplePhotosImportOptions) async {
        guard let db, let sid = activeLibraryID, let managed = managedSource, let cipher else { return }
        guard photos.accessState == .authorized || photos.accessState == .limited else {
            banner = "PhotoForge needs access to Apple Photos first. Open the Apple Photos library once and allow access."
            return
        }
        var snapshots: [AssetSnapshot] = []
        do {
            if let ids = opts.onlyIdentifiers {
                snapshots = photos.snapshots(for: ids, includeLocation: false)
            } else {
                for try await b in photos.allAssets(batchSize: 500, includeLocation: false) { snapshots += b }
            }
        } catch { banner = "Couldn't read Apple Photos: \(error.localizedDescription)"; return }
        snapshots = snapshots.filter { !$0.isShared && ($0.mediaType == .image || (opts.includeVideos && $0.mediaType == .video)) }
        let already = Set((try? db.importedFromPhotos()) ?? [])
        snapshots = snapshots.filter { !already.contains($0.localIdentifier) }
        guard !snapshots.isEmpty else { banner = "Everything from Apple Photos is already in this library."; return }

        var progress = ImportProgress(title: "Copying \(snapshots.count.formatted()) items from Apple Photos", total: snapshots.count)
        importStatus = progress
        var known = (try? db.fileHashes(sourceID: sid)) ?? []
        var newByIdentifier: [String: Int64] = [:]
        let cal = Calendar.current
        for snap in snapshots {
            if Task.isCancelled { break }
            let d = snap.creationDate ?? .now
            let dir = managed.root.appendingPathComponent(String(format: "Originals/%04d/%02d", cal.component(.year, from: d), cal.component(.month, from: d)))
            do {
                let out = try await photos.exportOriginal(snap.localIdentifier, to: dir, allowNetwork: opts.downloadFromICloud)
                let hash = try await Task.detached { try Self.sha256(out.url) }.value
                progress.done += 1
                if known.contains(hash) {
                    try? FileManager.default.removeItem(at: out.url)
                    progress.skipped += 1
                } else {
                    known.insert(hash)
                    let rel = managed.relative(out.url)
                    let key = ManagedLibrarySource.newKey()
                    let size = (try? out.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                    try db.upsert([AssetUpsert(localIdentifier: key, mediaType: snap.mediaType.rawValue, subtypeMask: Int(snap.subtypeMask),
                                               creationDate: snap.creationDate, modificationDate: snap.modificationDate,
                                               pixelWidth: snap.pixelWidth, pixelHeight: snap.pixelHeight, duration: snap.duration,
                                               favorite: snap.isFavorite, hidden: snap.isHidden, burstIdentifier: snap.burstIdentifier,
                                               assetSource: "library", filePath: rel, availability: "local",
                                               originalFilename: out.originalFilename, fileSize: size, fileHash: hash)],
                                  sourceID: sid, scanStamp: .now)
                    managed.set(key, relativePath: rel)
                    if let newID = try db.assetIDs(forKeys: [key], sourceID: sid)[key] {
                        newByIdentifier[snap.localIdentifier] = newID
                        try? db.recordDecision("imported_from_photos", subjectType: "asset", subjectID: newID, detail: snap.localIdentifier)
                    }
                    progress.added += 1
                }
            } catch {
                progress.done += 1
                progress.failed += 1          // typically "only in iCloud" with downloads off
            }
            if progress.done % 5 == 0 { importStatus = progress }
        }

        // Carry over what was already learned about these photos in the Apple Photos library.
        if opts.copyAnalysis, !newByIdentifier.isEmpty,
           let apple = registry.entries.first(where: { $0.kind == .applePhotos }),
           let appleDB = try? AppDatabase.open(at: apple.databaseURL),
           let appleCipher = try? VectorCipher(store: .file(apple.keyURL)),
           let appleSID = try? appleDB.systemSourceID() {
            progress.title = "Copying names, categories and faces"
            importStatus = progress
            let old = (try? appleDB.assetIDs(forKeys: Array(newByIdentifier.keys), sourceID: appleSID)) ?? [:]
            var mapping: [Int64: Int64] = [:]
            for (ident, oldID) in old { if let n = newByIdentifier[ident] { mapping[oldID] = n } }
            let faces = (try? db.copyAnalysis(from: appleDB, sourceCipher: appleCipher, cipher: cipher, mapping: mapping,
                                              sourceCropDir: apple.faceCropDir, cropDir: faceCropDir, newSourceID: sid)) ?? 0
            db.log("scan", "Carried over analysis for \(mapping.count) items and \(faces) faces from Apple Photos")
        }
        if opts.recreateAlbums, !newByIdentifier.isEmpty {
            let memberships = await Task.detached { [photos] in photos.albumMemberships() }.value
            if !memberships.isEmpty {
                let root = try? db.createAlbum(title: "From Apple Photos", parentID: nil, isFolder: true, sourceID: sid)
                var folders: [String: Int64] = [:]
                for m in memberships {
                    let members = m.localIdentifiers.compactMap { newByIdentifier[$0] }
                    guard !members.isEmpty else { continue }
                    var parent = root
                    for (i, part) in m.path.dropLast().enumerated() {
                        let key = m.path[0...i].joined(separator: "/")
                        if let f = folders[key] { parent = f; continue }
                        let f = try? db.createAlbum(title: part, parentID: parent, isFolder: true, sourceID: sid)
                        folders[key] = f; parent = f
                    }
                    try? db.createAlbum(title: m.path.last ?? "Album", parentID: parent, isFolder: false, sourceID: sid, assetIDs: members)
                }
            }
        }
        progress.running = false
        progress.title = "Copied from Apple Photos"
        importStatus = progress
        banner = "Apple Photos copy finished: \(progress.summary)." + (progress.failed > 0 && !opts.downloadFromICloud
            ? " Items only in iCloud were skipped; turn on “Download from iCloud” to include them." : "")
        await reloadFromDatabase()
        refreshLibraries()
    }

    func cancelImport() {
        importTask?.cancel()
        importTask = nil
    }
}

// MARK: - Library data: location, backups, restore

extension AppModel {
    /// Moves a library's PhotoForge data (database, key, face thumbnails, backups) to a folder the
    /// user picks — any drive. (A PhotoForge Library keeps its data inside the library itself.)
    func moveLibraryDataWithPanel(_ entry: LibraryEntry) async {
        guard entry.kind != .photoForge else {
            banner = "A PhotoForge Library keeps its database inside the library. Move the whole library in Finder, then open it again."
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Choose Where to Keep “\(entry.name)” Data"
        panel.message = "PhotoForge will keep this library's database, face data and backups here. You can pick an external drive."
        panel.prompt = "Move Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let dest = parent.appendingPathComponent("\(entry.name) — PhotoForge Data", isDirectory: true)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            let wasActive = entry.id == activeEntry?.id
            // Consistent copy of the database even while it's open.
            if wasActive, let db { try db.copy(to: dest.appendingPathComponent("photoforge.sqlite")) }
            else { try AppDatabase.open(at: entry.databaseURL).copy(to: dest.appendingPathComponent("photoforge.sqlite")) }
            for item in ["vector.key", "FaceCrops", "Backups"] {
                let src = entry.dataURL.appendingPathComponent(item)
                if fm.fileExists(atPath: src.path) { try? fm.copyItem(at: src, to: dest.appendingPathComponent(item)) }
            }
            var moved = entry
            moved.dataPath = dest.path
            // Verify the copy opens before switching over.
            _ = try AppDatabase.open(at: moved.databaseURL)
            registry.upsert(moved)
            libraries = registry.entries
            if wasActive { await open(moved) }
            for item in LibraryEntry.dataItems { try? fm.removeItem(at: entry.dataURL.appendingPathComponent(item)) }
            db?.log("privacy", "Moved “\(entry.name)” data to \(dest.path)")
            banner = "“\(entry.name)” data now lives in \(dest.path)."
        } catch {
            banner = "Couldn't move the data: \(error.localizedDescription). Nothing was changed."
        }
    }

    func backupNow() {
        guard let db else { return }
        do {
            let url = try db.backup(reason: "manual", keep: 10)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            banner = "Backed up “\(activeEntry?.name ?? "library")” data."
        } catch { banner = "Backup failed: \(error.localizedDescription)" }
    }

    /// Replaces the open library's database with a backup (the current one is backed up first).
    func restoreBackupWithPanel() async {
        guard let db, let entry = activeEntry else { return }
        let panel = NSOpenPanel()
        panel.title = "Restore Library Data"
        panel.message = "Choose a PhotoForge backup (.sqlite). The current data is backed up first."
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite") ?? .data]
        panel.directoryURL = db.backupsDirectory
        guard panel.runModal() == .OK, let src = panel.url else { return }
        do {
            _ = try AppDatabase.openReadOnly(at: src).stats()          // is it a PhotoForge database?
            try db.backup(reason: "before-restore", keep: 10)
            await cancelAnalysis()
            self.db = nil
            let fm = FileManager.default
            for ext in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: entry.databaseURL.path + ext) }
            try fm.copyItem(at: src, to: entry.databaseURL)
            await open(entry)
            banner = "Restored “\(entry.name)” from \(src.lastPathComponent)."
        } catch {
            banner = "Couldn't restore: \(error.localizedDescription)"
            await open(entry)
        }
    }
}

// MARK: - Names

extension AppModel {
    /// Sets names. For a PhotoForge Library the files can be renamed too; for Apple Photos the
    /// name can also be written to the photo's Title in Photos.
    func rename(_ ids: [Int64], to names: [String], renameFiles: Bool, writeToPhotos: Bool) async {
        guard let db, ids.count == names.count else { return }
        try? db.setTitles(Array(zip(ids, names.map { Optional($0) })).map { (assetID: $0.0, title: $0.1) })
        var fileErrors = 0
        if renameFiles, let managed = managedSource {
            for (id, name) in zip(ids, names) {
                guard let key = assetsByID[id]?.localIdentifier else { continue }
                do {
                    let rel = try managed.renameFile(key, to: name)
                    try db.updateFileLocation(assetID: id, filePath: rel, originalFilename: (rel as NSString).lastPathComponent)
                } catch { fileErrors += 1 }
            }
        }
        db.log("edit", "Renamed \(ids.count) item(s)\(renameFiles ? " (files too)" : "")")
        await reloadFromDatabase()
        if writeToPhotos && isSystemLibrary {
            let items = zip(ids, names).compactMap { id, n in assetsByID[id].map { (localIdentifier: $0.localIdentifier, title: n) } }
            banner = "Writing \(items.count) name(s) to Apple Photos…"
            let r = await PhotoLibraryService.writeTitlesToPhotos(items)
            banner = r.error.map { "Names saved in PhotoForge. \($0)" }
                ?? "Names saved in PhotoForge and written to Apple Photos (\(r.written) of \(items.count))."
        } else if fileErrors > 0 {
            banner = "Names saved; \(fileErrors) file(s) couldn't be renamed on disk."
        }
    }
}

// MARK: - Albums (PhotoForge's own groups, for any library)

extension AppModel {
    func reloadAlbums() {
        albums = (try? db?.albums(sourceID: activeLibraryID)) ?? []
        let byParent = Dictionary(grouping: albums) { $0.parentID ?? -1 }
        func node(_ a: PFAlbum, depth: Int) -> AlbumNode {
            let kids = depth < 12 ? (byParent[a.id] ?? []).map { node($0, depth: depth + 1) } : []
            let keys = a.assetIDs.compactMap { assetsByID[$0]?.localIdentifier }
            return AlbumNode(id: "pfa:\(a.id)", title: a.title, kind: a.isFolder ? .folder : .album, children: kids, assetKeys: keys)
        }
        albumTree = (byParent[-1] ?? []).map { node($0, depth: 0) }
    }

    func albumAssetIDs(_ id: Int64) -> Set<Int64> {
        // A folder shows everything inside it.
        var out = Set<Int64>()
        var stack = [id]
        while let cur = stack.popLast() {
            if let a = albums.first(where: { $0.id == cur }) { out.formUnion(a.assetIDs) }
            stack += albums.filter { $0.parentID == cur }.map(\.id)
        }
        return out
    }

    @discardableResult
    func createAlbum(title: String, parent: Int64? = nil, isFolder: Bool = false, assetIDs: [Int64] = []) -> Int64? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let db else { return nil }
        let id = try? db.createAlbum(title: t, parentID: parent, isFolder: isFolder, sourceID: activeLibraryID, assetIDs: assetIDs)
        reloadAlbums()
        return id
    }

    func addToAlbum(_ album: Int64, _ ids: [Int64]) { try? db?.addToAlbum(album, assetIDs: ids); reloadAlbums() }
    func removeFromAlbum(_ album: Int64, _ ids: [Int64]) { try? db?.removeFromAlbum(album, assetIDs: ids); reloadAlbums() }
    func renameAlbum(_ album: Int64, _ title: String) { try? db?.renameAlbum(album, to: title); reloadAlbums() }
    func deleteAlbum(_ album: Int64) {
        try? db?.deleteAlbum(album)
        if selection == .album(album) { selection = .allPhotos }
        reloadAlbums()
    }
}

// MARK: - Saving edits / upscales back into the library

extension AppModel {
    /// Apple Photos: a new photo in `album`. PhotoForge Library: a new file in Edits/, added to `album`.
    func saveDerivative(fileURL: URL, suggestedName: String, album: String) async throws -> String {
        if let managed = managedSource, let db, let sid = activeLibraryID {
            let rel = try managed.addEdited(fileURL, name: suggestedName)
            let u = managed.root.appendingPathComponent(rel)
            let p = MediaFiles.probe(u)
            let key = ManagedLibrarySource.newKey()
            let hash = try? Self.sha256(u)
            try db.upsert([AssetUpsert(localIdentifier: key, mediaType: p.mediaType, subtypeMask: 0, creationDate: .now, modificationDate: .now,
                                       pixelWidth: p.width, pixelHeight: p.height, duration: 0, favorite: false, hidden: false,
                                       burstIdentifier: nil, assetSource: "library", filePath: rel, availability: "local",
                                       originalFilename: u.lastPathComponent, fileHash: hash)], sourceID: sid, scanStamp: .now)
            managed.set(key, relativePath: rel)
            if let newID = try db.assetIDs(forKeys: [key], sourceID: sid)[key] {
                let existing = albums.first { $0.title == album && !$0.isFolder }?.id
                if let a = existing { addToAlbum(a, [newID]) } else { createAlbum(title: album, assetIDs: [newID]) }
            }
            return key
        }
        return try await photos.addDerivative(fileURL: fileURL, toAlbumNamed: album)
    }
}

// MARK: - Faces: identify by hand, suggestions, face data

extension AppModel {
    func faces(in assetID: Int64) -> [StoredFace] { storedFaces.filter { $0.assetID == assetID } }

    func person(forFace id: Int64) -> PersonVM? {
        guard let pid = faceOwnerIndex[id] else { return nil }
        return people.first { $0.id == pid }
    }

    var namedPeople: [PersonVM] { people.filter { $0.name != nil }.sorted { ($0.name ?? "") < ($1.name ?? "") } }

    /// The user says who a face is. PhotoForge then groups similar faces under that name,
    /// and, if some photos haven't been checked for faces yet, starts looking in them.
    func identifyFace(_ faceID: Int64, as name: String) async {
        guard let db else { return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        if let existing = namedPeople.first(where: { $0.name?.caseInsensitiveCompare(n) == .orderedSame }), let pid = existing.personID {
            try? db.addFaces([faceID], toPerson: pid)
        } else {
            try? db.createPerson(named: n, faceIDs: [faceID], sourceID: activeLibraryID)
        }
        db.log("edit", "Identified a face as \(n)")
        await rebuildPeople()
        if faceAnalysisEnabled, currentJob == nil, stats.facesScanned < stats.photos {
            await startAnalysis()
            banner = "Looking for \(n) in the photos that haven't been checked yet…"
        }
    }

    func unassignFace(_ faceID: Int64) async {
        guard let p = person(forFace: faceID) else { return }
        try? db?.rejectFace(faceID, fromPerson: p.personID, againstFaces: p.faces.map(\.id).filter { $0 != faceID })
        await rebuildPeople()
    }

    /// Adds a face the user drew (normalized box, top-left origin) and returns its id.
    func addManualFace(asset: AssetRow, box: CGRect) async -> Int64? {
        guard let db, let cipher, box.width > 0.01, box.height > 0.01 else { return nil }
        do {
            let img = try await mediaSource.analysisImage(for: asset.localIdentifier, maxDimension: 1600, allowNetwork: true)
            let W = CGFloat(img.width), H = CGFloat(img.height)
            // Look for a face (with landmarks, for proper alignment) in a margin around the box.
            let pad = box.insetBy(dx: -box.width * 0.3, dy: -box.height * 0.3)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            let region = CGRect(x: pad.minX * W, y: pad.minY * H, width: pad.width * W, height: pad.height * H).integral
            var crop: CGImage?
            var quality = 0.35
            if let sub = img.cropping(to: region), let f = (try? FaceDetector().detect(in: sub))?.max(by: { $0.pixelSize < $1.pixelSize }),
               let aligned = f.alignedCrop {
                crop = aligned; quality = Double(f.captureQuality ?? 0.5)
            } else {
                // No landmarks found: use the drawn square as-is (less accurate for grouping).
                let side = max(box.width * W, box.height * H)
                let sq = CGRect(x: box.midX * W - side / 2, y: box.midY * H - side / 2, width: side, height: side).integral
                    .intersection(CGRect(x: 0, y: 0, width: W, height: H))
                crop = img.cropping(to: sq).flatMap { Self.resized($0, to: 112) }
            }
            var embedding: [Float]? = nil
            if let c = crop { embedding = try? await faceModel.model.embed([c]).first }
            var cropName: String? = nil
            if storeFaceCrops, let c = crop {
                try? FileManager.default.createDirectory(at: faceCropDir, withIntermediateDirectories: true)
                let name = "\(asset.id)-m\(Int(Date().timeIntervalSince1970 * 1000)).jpg"
                if AnalysisJob.writeJPEG(c, to: faceCropDir.appendingPathComponent(name)) { cropName = name }
            }
            let id = try db.addManualFace(assetID: asset.id, box: box, quality: quality, pixelSize: Double(box.height * H),
                                          embedding: embedding, cropPath: cropName, modelName: faceModel.name,
                                          modelVersion: faceModel.version, cipher: cipher)
            await rebuildPeople()
            return id
        } catch {
            banner = "Couldn't add the face: \(error.localizedDescription)"
            return nil
        }
    }

    nonisolated static func resized(_ img: CGImage, to side: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: side, height: side))
        return ctx.makeImage()
    }

    /// Faces not yet given to anyone that look like this person, best first.
    func suggestions(for person: PersonVM, limit: Int = 60) -> [(face: StoredFace, similarity: Double)] {
        guard person.personID != nil, !person.faces.isEmpty else { return [] }
        let dim = person.faces[0].embedding.count
        var c = [Float](repeating: 0, count: dim)
        for f in person.faces where f.embedding.count == dim { for i in 0..<dim { c[i] += f.embedding[i] } }
        let norm = c.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return [] }
        c = c.map { $0 / norm }
        let threshold = faceModel.threshold(strictness: faceStrictness) - 0.05
        let named = Set(people.filter { $0.name != nil }.map(\.id))
        let mine = Set(person.faces.map(\.id))
        // Faces the user already said aren't this person.
        var rejected = Set<Int64>()
        if let cannot = (try? db?.faceConstraints())?.cannot {
            for (a, b) in cannot {
                if mine.contains(a) { rejected.insert(b) }
                if mine.contains(b) { rejected.insert(a) }
            }
        }
        return storedFaces.compactMap { f -> (face: StoredFace, similarity: Double)? in
            guard !mine.contains(f.id), !rejected.contains(f.id), f.embedding.count == dim else { return nil }
            if let owner = faceOwnerIndex[f.id], named.contains(owner) { return nil }
            var s: Float = 0
            for i in 0..<dim { s += f.embedding[i] * c[i] }
            return Double(s) >= threshold ? (f, Double(s)) : nil
        }
        .sorted { $0.similarity > $1.similarity }
        .prefix(limit).map { $0 }
    }

    func acceptSuggestions(_ faces: [StoredFace], for person: PersonVM) async {
        guard let pid = person.personID else { return }
        try? db?.addFaces(faces.map(\.id), toPerson: pid)
        db?.log("edit", "Confirmed \(faces.count) suggested face(s) as \(person.title)")
        await rebuildPeople()
    }

    func rejectSuggestion(_ face: StoredFace, for person: PersonVM) async {
        try? db?.rejectFace(face.id, fromPerson: nil, againstFaces: person.faces.map(\.id))
        await rebuildPeople()
    }

    // Settings › Face Data
    func personSummaries() -> [PersonSummary] { (try? db?.personSummaries(sourceID: activeLibraryID)) ?? [] }

    func renamePerson(_ id: Int64, _ name: String) async {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        try? db?.renamePerson(id, to: n)
        await rebuildPeople()
    }

    func deletePerson(_ id: Int64, deleteFaces: Bool) async {
        try? db?.deletePerson(id, deleteFaces: deleteFaces)
        db?.log("privacy", deleteFaces ? "Deleted a person and their face data" : "Removed a person's name (faces kept)")
        await rebuildPeople()
    }

    func mergePeople(_ source: Int64, into target: Int64) async {
        try? db?.mergePerson(source, into: target)
        await rebuildPeople()
    }

    func redetectFaces() async {
        try? db?.resetFaceDetection(sourceID: activeLibraryID)
        await startAnalysis()
    }
}

// MARK: - Video

extension AppModel {
    var videoEngineAvailable: Bool {
        #if canImport(VLCKit)
        return true
        #else
        return false
        #endif
    }

    func playback(for asset: AssetRow) async throws -> PlaybackSource {
        try await mediaSource.playback(for: asset.localIdentifier)
    }
}
