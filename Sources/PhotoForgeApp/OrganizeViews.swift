import SwiftUI
import PFCore
import PFDatabase
import PFPhotosBridge
import PFClassify

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
    @Binding var smartAlbum: SmartAlbumRequest?
    @State private var confirmDelete = false
    @State private var dropTargeted = false
    private var albumID: Int64 { Int64(node.id.dropFirst(4)) ?? 0 }
    private var album: PFAlbum? { model.albums.first { $0.id == albumID } }

    var body: some View {
        Label(node.title, systemImage: node.kind == .folder ? "folder" : node.kind == .smartAlbum ? "gearshape" : "rectangle.stack")
            .badge(node.assetKeys.count)
            .tag(SidebarItem.album(albumID))
            .help(album?.rule.map { "Smart album: " + $0.summary(personName: model.personName) } ?? "")
            .listRowBackground(dropTargeted ? Color.accentColor.opacity(0.25) : nil)
            .dropDestination(for: String.self) { items, _ in
                let ids = AssetDrag.ids(items)
                guard !ids.isEmpty, node.kind == .album else { return false }
                model.addToAlbum(albumID, ids)
                model.banner = "Added \(ids.count) item\(ids.count == 1 ? "" : "s") to “\(node.title)”."
                return true
            } isTargeted: { dropTargeted = $0 && node.kind == .album }
            .contextMenu {
                if let a = album, let rule = a.rule {
                    Button("Edit Smart Album…") { smartAlbum = SmartAlbumRequest(editing: a.id, title: a.title, rule: rule) }
                    Button("Convert to Ordinary Album") { model.freezeSmartAlbum(a.id) }
                        .help("Keep the photos it has now and stop adding new ones automatically")
                } else {
                    Button("Rename…") { newAlbum = NewAlbumRequest(isFolder: node.kind == .folder, renaming: albumID, initialTitle: node.title) }
                }
                if node.kind == .folder {
                    Button("New Album Inside…") { newAlbum = NewAlbumRequest(isFolder: false, parent: albumID) }
                    Button("New Smart Album Inside…") { smartAlbum = SmartAlbumRequest(parent: albumID) }
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
            if !model.albums.filter({ !$0.isFolder && !$0.isSmart }).isEmpty { Divider() }
            ForEach(model.albums.filter { !$0.isFolder && !$0.isSmart }) { a in
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

// MARK: - Smart albums

struct SmartAlbumRequest: Identifiable {
    var id = UUID()
    var editing: Int64? = nil
    var title = ""
    var rule = AlbumRule()
    var parent: Int64? = nil
}

/// Create or edit a smart album: photos are chosen by who is in them, their names, tags and categories.
struct SmartAlbumSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: SmartAlbumRequest
    @State private var title = ""
    @State private var rule = AlbumRule()
    @State private var count = 0
    @State private var newTag = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.editing == nil ? "New Smart Album" : "Edit Smart Album").font(.title3.bold())
            Text("A smart album fills itself: when PhotoForge recognises someone in more photos, or you name or tag photos, they're added automatically.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Album name", text: $title).textFieldStyle(.roundedBorder)
            Form {
                Picker("Include photos that match", selection: $rule.match) {
                    Text("all of these").tag(AlbumRule.Match.all)
                    Text("any of these").tag(AlbumRule.Match.any)
                }
                Section("People") {
                    if model.namedPeople.isEmpty {
                        Text("Name people first (People, or click a face in the preview).").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(model.namedPeople) { p in
                                    if let pid = p.personID {
                                        Toggle("\(p.name ?? "") (\(Set(p.faces.map(\.assetID)).count))", isOn: Binding(
                                            get: { rule.people.contains(pid) },
                                            set: { on in if on { rule.people.append(pid) } else { rule.people.removeAll { $0 == pid } } }))
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 140)
                        if rule.people.count > 1 {
                            Picker("", selection: $rule.peopleMatch) {
                                Text("Any of them").tag(AlbumRule.Match.any)
                                Text("All of them together").tag(AlbumRule.Match.all)
                            }.pickerStyle(.segmented).labelsHidden()
                        }
                    }
                }
                Section("Name") {
                    TextField("Name contains", text: $rule.nameContains, prompt: Text("e.g. Farm Visit"))
                }
                Section("Tags") {
                    if !model.tagNames.isEmpty {
                        FlowTags(names: model.tagNames, selected: Set(rule.tags.map { $0.lowercased() })) { t in
                            if let i = rule.tags.firstIndex(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) { rule.tags.remove(at: i) }
                            else { rule.tags.append(t) }
                        }
                    }
                    TextField("Add a tag to match", text: $newTag)
                        .onSubmit { let t = newTag.trimmingCharacters(in: .whitespaces); if !t.isEmpty { rule.tags.append(t) }; newTag = "" }
                }
                Section("Categories") {
                    FlowTags(names: PhotoCategory.allCases.map(\.title), selected: Set(rule.categories.compactMap { PhotoCategory(rawValue: $0)?.title.lowercased() })) { title in
                        guard let c = PhotoCategory.allCases.first(where: { $0.title == title }) else { return }
                        if rule.categories.contains(c.rawValue) { rule.categories.removeAll { $0 == c.rawValue } } else { rule.categories.append(c.rawValue) }
                    }
                }
                Section("Always") {
                    Picker("Show", selection: $rule.media) {
                        Text("Photos and videos").tag(AlbumRule.Media.any)
                        Text("Photos only").tag(AlbumRule.Media.photos)
                        Text("Videos only").tag(AlbumRule.Media.videos)
                    }
                    Toggle("Favorites only", isOn: $rule.favoritesOnly)
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 380)
            HStack {
                Label("\(count.formatted()) item\(count == 1 ? "" : "s") match now", systemImage: "sparkles")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.editing == nil ? "Create" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { title = request.title; rule = request.rule }
        .task(id: rule) { count = model.preview(rule).count }
    }

    private func save() {
        let t = title.trimmingCharacters(in: .whitespaces)
        if let id = request.editing {
            if t != request.title { model.renameAlbum(id, t) }
            model.updateSmartAlbum(id, rule: rule)
        } else if let id = model.createSmartAlbum(title: t, rule: rule, parent: request.parent) {
            model.selection = .album(id)
        }
        dismiss()
    }
}

/// Wrapping row of toggleable chips.
struct FlowTags: View {
    let names: [String]
    let selected: Set<String>          // lower-cased
    var toggle: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(names, id: \.self) { n in
                let on = selected.contains(n.lowercased())
                Button { toggle(n) } label: {
                    Text(n).font(.callout).padding(.horizontal, 9).padding(.vertical, 4)
                        .background(on ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(on ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > width { x = 0; y += row + spacing; row = 0 }
            x += sz.width + spacing; row = max(row, sz.height)
        }
        return CGSize(width: width, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; row = max(row, sz.height)
        }
    }
}

// MARK: - Tags

struct TagRequest: Identifiable {
    var id = UUID()
    var assetIDs: [Int64]
}

/// Add or remove tags on one or many items.
struct TagSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: TagRequest
    @State private var text = ""

    var body: some View {
        let ids = request.assetIDs
        VStack(alignment: .leading, spacing: 12) {
            Text(ids.count == 1 ? "Tags" : "Tag \(ids.count.formatted()) Items").font(.title3.bold())
            HStack {
                TextField("New tag, e.g. Strawberry beds", text: $text).textFieldStyle(.roundedBorder).onSubmit(add)
                Button("Add", action: add).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !model.tagNames.isEmpty {
                Text("Click a tag to add it to \(ids.count == 1 ? "this item" : "all of them"), or to remove it.")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    FlowLayout(spacing: 6) {
                        ForEach(model.tagNames, id: \.self) { t in
                            let members = model.userTags[t] ?? []
                            let n = ids.filter { members.contains($0) }.count
                            Button {
                                Task { n == ids.count ? await model.removeTag(t, from: ids) : await model.addTag(t, to: ids) }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: n == ids.count ? "checkmark.circle.fill" : n > 0 ? "minus.circle.fill" : "circle")
                                    Text(t)
                                }
                                .font(.callout).padding(.horizontal, 9).padding(.vertical, 4)
                                .background(n > 0 ? Color.accentColor.opacity(n == ids.count ? 1 : 0.5) : Color.secondary.opacity(0.15), in: Capsule())
                                .foregroundStyle(n > 0 ? Color.white : Color.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func add() {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        text = ""
        Task { await model.addTag(t, to: request.assetIDs) }
    }
}

/// Payload for dragging photos from the grid onto an album or tag in the sidebar.
enum AssetDrag {
    static let prefix = "photoforge-items:"
    static func payload(_ ids: [Int64]) -> String { prefix + ids.map(String.init).joined(separator: ",") }
    static func ids(_ strings: [String]) -> [Int64] {
        strings.flatMap { s -> [Int64] in
            guard s.hasPrefix(prefix) else { return [] }
            return s.dropFirst(prefix.count).split(separator: ",").compactMap { Int64($0) }
        }
    }
}

struct TagSidebarRow: View {
    @Environment(AppModel.self) private var model
    let tag: String
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false
    @State private var dropTargeted = false

    var body: some View {
        Label(tag, systemImage: "tag")
            .badge(model.userTags[tag]?.count ?? 0)
            .tag(SidebarItem.tag(tag))
            .listRowBackground(dropTargeted ? Color.accentColor.opacity(0.25) : nil)
            .dropDestination(for: String.self) { items, _ in
                let ids = AssetDrag.ids(items)
                guard !ids.isEmpty else { return false }
                Task { await model.addTag(tag, to: ids) }
                return true
            } isTargeted: { dropTargeted = $0 }
            .contextMenu {
                Button("Rename Tag…") { newName = tag; renaming = true }
                Button("Make Smart Album") {
                    var r = AlbumRule(); r.tags = [tag]
                    if let id = model.createSmartAlbum(title: tag, rule: r) { model.selection = .album(id) }
                }
                Divider()
                Button("Delete Tag…", role: .destructive) { confirmDelete = true }
            }
            .sheet(isPresented: $renaming) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Rename Tag").font(.title3.bold())
                    TextField("Tag", text: $newName).textFieldStyle(.roundedBorder).frame(width: 280)
                    HStack {
                        Spacer()
                        Button("Cancel", role: .cancel) { renaming = false }
                        Button("Rename") { let n = newName; renaming = false; Task { await model.renameTag(tag, to: n) } }
                            .keyboardShortcut(.defaultAction)
                    }
                }.padding(20)
            }
            .confirmationDialog("Delete the tag “\(tag)”?", isPresented: $confirmDelete) {
                Button("Delete Tag", role: .destructive) { Task { await model.deleteTag(tag) } }
            } message: { Text("The tag is removed from every item. Photos are not deleted.") }
    }
}
