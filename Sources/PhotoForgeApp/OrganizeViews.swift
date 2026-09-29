import SwiftUI
import PFCore
import PFDatabase
import PFPhotosBridge

// MARK: - Albums

struct NewAlbumRequest: Identifiable {
    var id = UUID()
    var isFolder: Bool
    var parent: Int64? = nil
    var assetIDs: [Int64] = []
    var renaming: Int64? = nil
    var initialTitle = ""
}

struct NewAlbumSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: NewAlbumRequest
    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.renaming != nil ? "Rename" : request.isFolder ? "New Folder" : "New Album").font(.title3.bold())
            TextField(request.isFolder ? "Folder name" : "Album name", text: $title)
                .textFieldStyle(.roundedBorder).frame(minWidth: 320)
                .onSubmit(save)
            if !request.assetIDs.isEmpty {
                Text("\(request.assetIDs.count) selected item(s) will be added.").font(.caption).foregroundStyle(.secondary)
            }
            if request.renaming == nil {
                Picker("Inside", selection: Binding(get: { parent }, set: { parent = $0 })) {
                    Text("Top level").tag(Int64?.none)
                    ForEach(model.albums.filter(\.isFolder)) { f in Text(f.title).tag(Optional(f.id)) }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.renaming != nil ? "Rename" : "Create", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .onAppear { title = request.initialTitle; parent = request.parent }
    }

    @State private var parent: Int64?

    private func save() {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        if let id = request.renaming { model.renameAlbum(id, t) }
        else if let id = model.createAlbum(title: t, parent: parent, isFolder: request.isFolder, assetIDs: request.assetIDs),
                !request.isFolder { model.selection = .album(id) }
        dismiss()
    }
}

struct AlbumSidebarRow: View {
    @Environment(AppModel.self) private var model
    let node: AlbumNode
    @Binding var newAlbum: NewAlbumRequest?
    @State private var confirmDelete = false
    private var albumID: Int64 { Int64(node.id.dropFirst(4)) ?? 0 }

    var body: some View {
        Label(node.title, systemImage: node.kind == .folder ? "folder" : "rectangle.stack")
            .badge(node.assetKeys.count)
            .tag(SidebarItem.album(albumID))
            .contextMenu {
                Button("Rename…") { newAlbum = NewAlbumRequest(isFolder: node.kind == .folder, renaming: albumID, initialTitle: node.title) }
                if node.kind == .folder {
                    Button("New Album Inside…") { newAlbum = NewAlbumRequest(isFolder: false, parent: albumID) }
                    Button("New Folder Inside…") { newAlbum = NewAlbumRequest(isFolder: true, parent: albumID) }
                }
                Menu("Move To") {
                    Button("Top Level") { try? model.db?.moveAlbum(albumID, toParent: nil); model.reloadAlbums() }
                    ForEach(model.albums.filter { $0.isFolder && $0.id != albumID }) { f in
                        Button(f.title) { try? model.db?.moveAlbum(albumID, toParent: f.id); model.reloadAlbums() }
                    }
                }
                Divider()
                Button(node.kind == .folder ? "Delete Folder…" : "Delete Album…", role: .destructive) { confirmDelete = true }
            }
            .confirmationDialog("Delete “\(node.title)”?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) { model.deleteAlbum(albumID) }
            } message: {
                Text(node.kind == .folder ? "Albums inside it are deleted too. Photos are never deleted." : "The photos stay in your library.")
            }
    }
}

/// "Add to Album" submenu for a set of items.
struct AddToAlbumMenu: View {
    @Environment(AppModel.self) private var model
    let ids: [Int64]
    var onNew: () -> Void

    var body: some View {
        Menu("Add to Album") {
            Button("New Album with \(ids.count == 1 ? "This Item" : "\(ids.count) Items")…", action: onNew)
            if !model.albums.filter({ !$0.isFolder }).isEmpty { Divider() }
            ForEach(model.albums.filter { !$0.isFolder }) { a in
                Button(a.title) { model.addToAlbum(a.id, ids) }
            }
        }
    }
}

// MARK: - Rename

struct RenameRequest: Identifiable {
    var id = UUID()
    var assetIDs: [Int64]
}

struct RenameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: RenameRequest
    @State private var rule = BatchRename()
    @State private var single = ""
    @State private var renameFiles = true
    @State private var writeToPhotos = false

    private var rows: [AssetRow] { request.assetIDs.compactMap { model.assetsByID[$0] } }
    private var isSingle: Bool { rows.count == 1 }

    private var newNames: [String] {
        if isSingle { return [BatchRename.clean(single).isEmpty ? rows[0].displayName : BatchRename.clean(single)] }
        let items = rows.map { BatchRename.Item(currentName: $0.displayName, date: $0.creationDate, camera: nil) }
        return BatchRename.uniqued(rule.apply(to: items))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isSingle ? "Rename" : "Rename \(rows.count.formatted()) Items").font(.title3.bold())
            if isSingle {
                TextField("Name", text: $single).textFieldStyle(.roundedBorder).frame(minWidth: 380).onSubmit(apply)
            } else {
                Picker("", selection: $rule.mode) { ForEach(BatchRename.Mode.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
                switch rule.mode {
                case .pattern:
                    TextField("Pattern", text: $rule.pattern).textFieldStyle(.roundedBorder)
                    Text("Tokens: {name} {n} {date} {year} {month} {day} {time}. Example: “Farm Visit {date} {n}”.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Stepper("Start at \(rule.start)", value: $rule.start, in: 0...1_000_000)
                        Stepper("Digits: \(rule.padding)", value: $rule.padding, in: 1...8)
                    }
                case .findReplace:
                    HStack {
                        TextField("Find", text: $rule.find).textFieldStyle(.roundedBorder)
                        TextField("Replace with", text: $rule.replace).textFieldStyle(.roundedBorder)
                    }
                    Toggle("Match case", isOn: $rule.caseSensitive)
                case .prefixSuffix:
                    HStack {
                        TextField("Prefix", text: $rule.prefix).textFieldStyle(.roundedBorder)
                        TextField("Suffix", text: $rule.suffix).textFieldStyle(.roundedBorder)
                    }
                }
                GroupBox("Preview") {
                    let names = newNames
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(zip(rows.prefix(30), names.prefix(30)).enumerated()), id: \.offset) { _, pair in
                                HStack {
                                    Text(pair.0.displayName).foregroundStyle(.secondary).lineLimit(1)
                                    Image(systemName: "arrow.right").font(.caption)
                                    Text(pair.1).lineLimit(1)
                                }.font(.callout)
                            }
                            if rows.count > 30 { Text("…and \(rows.count - 30) more").font(.caption).foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 180)
                }
            }
            if model.isManagedLibrary {
                Toggle("Also rename the files in the library", isOn: $renameFiles)
            } else if model.isSystemLibrary {
                Toggle("Also set the Title in Apple Photos", isOn: $writeToPhotos)
                Text("PhotoForge always keeps the name. Writing it into Photos uses Photos' own scripting; macOS asks once for permission.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("This library is read-only, so names are kept in PhotoForge (the files aren't renamed).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if !isSingle || !(rows.first?.title ?? "").isEmpty {
                    Button("Clear Names") {
                        Task { try? model.db?.setTitles(rows.map { (assetID: $0.id, title: nil) }); await model.reloadFromDatabase(); dismiss() }
                    }.help("Remove PhotoForge names so file names show again")
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename", action: apply).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 480)
        .onAppear { single = rows.first.map { BatchRename.stripExtension($0.displayName) } ?? "" }
    }

    private func apply() {
        let ids = rows.map(\.id), names = newNames
        let files = model.isManagedLibrary && renameFiles, photos = model.isSystemLibrary && writeToPhotos
        dismiss()
        Task { await model.rename(ids, to: names, renameFiles: files, writeToPhotos: photos) }
    }
}

// MARK: - Copy from Apple Photos into a PhotoForge Library

struct ApplePhotosImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var opts = AppModel.ApplePhotosImportOptions()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Copy from Apple Photos").font(.title3.bold())
            Text("Copies your Apple Photos library into “\(model.activeEntry?.name ?? "this library")”: every photo (as currently edited) and, if you like, videos and albums. What PhotoForge already knows — names, categories, faces and people — is carried over, so nothing is rescanned. Items already copied are skipped, so you can run this again later to top up.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Include videos", isOn: $opts.includeVideos)
            Toggle("Download items that are only in iCloud", isOn: $opts.downloadFromICloud)
            Toggle("Carry over names, categories, faces and people", isOn: $opts.copyAnalysis)
            Toggle("Recreate albums (in My Albums › From Apple Photos)", isOn: $opts.recreateAlbums)
            Text("Make sure the drive has room: this copies the full-size files.").font(.caption).foregroundStyle(.orange)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start Copying") {
                    let o = opts
                    dismiss()
                    model.importTask = Task { await model.importFromApplePhotos(o) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.isManagedLibrary)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
