import SwiftUI
import PFCore
import PFDatabase

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmFaceWipe = false
    @State private var confirmAllWipe = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Label("Everything runs on this Mac. PhotoForge never uploads photos, faces, file names, or locations, and has no analytics.",
                      systemImage: "lock.shield.fill")
                    .foregroundStyle(.green)
            }

            LibrariesSettingsSection()
            MachineSettingsSection()

            Section("Face grouping") {
                Toggle("Group photos by person (face analysis)", isOn: $model.faceAnalysisEnabled)
                Toggle("Keep face thumbnails", isOn: $model.storeFaceCrops)
                    .disabled(!model.faceAnalysisEnabled)
                Text("Face data is stored encrypted on this Mac and is only used to group your own photos. It's never used to identify anyone.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Grouping strictness") {
                    HStack {
                        Text("Loose").font(.caption)
                        Slider(value: $model.faceStrictness, in: 0...1, onEditingChanged: { editing in
                            if !editing { Task { await model.rebuildPeople(reloadFaces: false) } }
                        })
                        Text("Strict").font(.caption)
                    }
                }
                Button("Delete All Face Data…", role: .destructive) { confirmFaceWipe = true }
            }

            FaceDataSettingsSection()
            SharingSettingsSection()

            Section("Categories") {
                Toggle("Sort photos into categories (documents, receipts, screenshots, WhatsApp, …)", isOn: $model.classifyEnabled)
                Text("Uses Apple's on-device image classification, text recognition and barcode detection, plus file names and camera data. Text found in photos becomes searchable. Nothing leaves this Mac. You can correct any photo's categories and PhotoForge remembers.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Duplicates & similar photos") {
                Toggle("Find similar shots (visual similarity)", isOn: $model.sceneSimilarityEnabled)
                LabeledContent("Matching strictness") {
                    HStack {
                        Text("Loose").font(.caption)
                        Slider(value: $model.duplicateStrictness, in: 0...1, onEditingChanged: { editing in
                            if !editing { Task { await model.rebuildDuplicates() } }
                        })
                        Text("Strict").font(.caption)
                    }
                }
                Text("Stricter settings show fewer groups, with more certainty.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("iCloud") {
                Toggle("Download iCloud photos for analysis", isOn: $model.allowICloudDownloads)
                Text("When your Mac keeps only small versions (“Optimize Mac Storage”), turning this on downloads originals from iCloud during analysis. That uses bandwidth and disk space.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Activity log") {
                Toggle("Keep a local activity log", isOn: $model.activityLogEnabled)
                Text("Records scans, edits, exports and deletions on this Mac so you can see what the app did. It never contains images, faces or locations.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Models in use") {
                LabeledContent("Face detection", value: "Apple Vision · on-device")
                LabeledContent("Face grouping", value: model.faceModel.summary)
                LabeledContent("Scene similarity", value: "Apple Vision feature prints · on-device")
                LabeledContent("Duplicate matching", value: "Perceptual hashes (pHash/dHash) + SHA-256")
                LabeledContent("Editing", value: "Core Image · on-device")
                LabeledContent("Upscaling", value: "FSRCNN (Apache-2.0) and Real-ESRGAN compact (BSD-3) · Core ML on the GPU via Metal")
                Text(model.faceModel.isDedicatedFaceModel
                     ? "The only third-party model is SFace (Apache-2.0), bundled and run locally. No cloud services are used."
                     : "No third-party AI models or cloud services are used in this version.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Your data") {
                LabeledContent("This library's data") {
                    let dir = model.activeEntry?.dataURL ?? AppModel.supportDir
                    Button(dir.path) { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
                        .buttonStyle(.link).lineLimit(1).truncationMode(.middle)
                }
                Text("PhotoForge's data is kept outside the app, so installing a new version never needs a rescan. A backup is made automatically before every upgrade that changes the database.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Delete All PhotoForge Data…", role: .destructive) { confirmAllWipe = true }
                Text("Removes everything PhotoForge has stored: analysis, face groups, names, the removal queue and the log. Your photos in Apple Photos are not affected.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings & Privacy")
        .confirmationDialog("Delete all face data?", isPresented: $confirmFaceWipe, titleVisibility: .visible) {
            Button("Delete Face Data", role: .destructive) { Task { await model.deleteAllFaceData() } }
        } message: {
            Text("Removes every detected face, face thumbnail, person name and grouping, and turns face analysis off. This can't be undone.")
        }
        .confirmationDialog("Delete all PhotoForge data?", isPresented: $confirmAllWipe, titleVisibility: .visible) {
            Button("Delete Everything", role: .destructive) { Task { await model.deleteAllAppData() } }
        } message: {
            Text("PhotoForge will start fresh. Your Apple Photos library is not touched.")
        }
    }
}

struct ActivityView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if model.activity.isEmpty {
                ContentUnavailableView("No activity yet", systemImage: "list.bullet.rectangle",
                                       description: Text(model.activityLogEnabled ? "Scans, edits, exports and deletions will be listed here." : "The activity log is turned off in Settings."))
            } else {
                Table(model.activity) {
                    TableColumn("When") { e in Text(e.date.formatted(date: .abbreviated, time: .shortened)) }.width(160)
                    TableColumn("Type") { e in Text(e.category.capitalized) }.width(80)
                    TableColumn("What happened", value: \.message)
                }
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            Button("Refresh") { Task { await model.refreshActivity() } }
            Button("Clear Log", role: .destructive) { Task { await model.clearActivity() } }.disabled(model.activity.isEmpty)
        }
        .task { await model.refreshActivity() }
    }
}

// MARK: - Libraries

struct LibrariesSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var forgetting: LibraryEntry?

    var body: some View {
        Section("Libraries") {
            ForEach(model.libraries) { lib in
                HStack {
                    Image(systemName: lib.kind == .applePhotos ? "photo.stack" : lib.kind == .photoForge ? "books.vertical" : "externaldrive")
                    VStack(alignment: .leading) {
                        Text(lib.name)
                        Text("\(lib.kindLabel) · \(lib.assetCount.formatted()) items\(lib.sourcePath.map { " · " + $0 } ?? "")")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Text("Data: \(lib.dataPath)").font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if lib.id == model.activeEntry?.id {
                        Text("In use").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Switch") { Task { await model.switchLibrary(lib.id) } }
                    }
                    Menu {
                        Button("Show Data in Finder") { NSWorkspace.shared.activateFileViewerSelecting([lib.dataURL]) }
                        if lib.kind != .photoForge {
                            Button("Move Data to Another Drive…") { Task { await model.moveLibraryDataWithPanel(lib) } }
                        }
                        if lib.kind != .applePhotos {
                            Divider()
                            Button("Forget…", role: .destructive) { forgetting = lib }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
            HStack {
                Button("New PhotoForge Library…") { Task { await model.newPhotoForgeLibraryWithPanel() } }
                Button("Open Library or Folder…") { Task { await model.chooseLibraryWithPanel() } }
            }
            HStack {
                Button("Back Up Now") { model.backupNow() }
                Button("Restore from Backup…") { Task { await model.restoreBackupWithPanel() } }
            }
            Text("Each library has its own database. A PhotoForge Library keeps its photos, videos and database together in one package you can put on any drive. Apple Photos and other libraries are read directly and never modified.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("Forget “\(forgetting?.name ?? "")”?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }), titleVisibility: .visible) {
            if let lib = forgetting {
                Button("Remove from List") { Task { await model.forgetLibrary(lib.id, deleteData: false) } }
                if lib.kind == .external {
                    Button("Remove and Delete PhotoForge's Data", role: .destructive) { Task { await model.forgetLibrary(lib.id, deleteData: true) } }
                }
            }
        } message: {
            Text(forgetting?.kind == .photoForge
                 ? "The library package stays on disk with all its photos and data. You can open it again later."
                 : "The photos themselves are never touched.")
        }
    }
}

// MARK: - This Mac

struct MachineSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let m = model.machine
        Section("This Mac") {
            LabeledContent("Processor", value: m.chip.replacingOccurrences(of: "(R)", with: "").replacingOccurrences(of: "(TM)", with: ""))
            LabeledContent("Model", value: m.model)
            LabeledContent("Cores · Memory", value: "\(m.cores) cores (\(m.performanceCores) performance) · \(m.memoryGB) GB")
            LabeledContent("Graphics", value: m.gpu)
            LabeledContent("macOS", value: m.macOS)
            LabeledContent("Class", value: m.tier.label + (m.hasNeuralEngine ? " · Neural Engine" : ""))
            if m.isTranslated {
                Label("PhotoForge is running under Rosetta. Quit, select it in Finder, Get Info, and turn off “Open using Rosetta” for full speed.",
                      systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Picker("Performance", selection: $model.performanceMode) {
                ForEach(PerformanceMode.allCases) { Text($0.label).tag($0) }
            }
            LabeledContent("Tuned settings", value: "\(model.analysisConcurrency) parallel analyses · \(m.ocrAccurate ? "accurate" : "fast") text reading · \(m.thumbnailCacheMB) MB thumbnail cache · AI on \(m.computeUnits == "all" ? "CPU, GPU and Neural Engine" : "CPU and GPU")")
            Text("PhotoForge checks this Mac when it first starts (and again if the hardware changes) and tunes itself. It runs natively on Intel Macs and on every Apple silicon Mac (M1 to M5).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Face data

struct FaceDataSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var summaries: [PersonSummary] = []
    @State private var renaming: PersonSummary?
    @State private var newName = ""
    @State private var deleting: PersonSummary?
    @State private var confirmRedetect = false

    var body: some View {
        Section("Face data") {
            if summaries.isEmpty {
                Text("No named people yet. Open a photo, turn on “Show & tag faces”, and click a face to say who it is.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(summaries) { p in
                HStack {
                    Image(systemName: "person.crop.circle")
                    VStack(alignment: .leading) {
                        Text(p.name ?? "Unnamed person")
                        Text("\(p.faceCount) faces · \(p.photoCount) photos\(p.isHidden ? " · hidden" : "")").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button("Rename…") { newName = p.name ?? ""; renaming = p }
                        Menu("Merge Into") {
                            ForEach(summaries.filter { $0.id != p.id && $0.name != nil }) { other in
                                Button(other.name ?? "") { Task { await model.mergePeople(p.id, into: other.id); reload() } }
                            }
                        }
                        Divider()
                        Button("Delete…", role: .destructive) { deleting = p }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
            Button("Look for Faces Again…") { confirmRedetect = true }
                .help("Detect faces again in every photo. Names you've given are kept.")
        }
        .task(id: model.people.count) { reload() }
        .sheet(item: $renaming) { p in
            VStack(alignment: .leading, spacing: 12) {
                Text("Rename").font(.title3.bold())
                TextField("Name", text: $newName).textFieldStyle(.roundedBorder).frame(width: 300)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { renaming = nil }
                    Button("Rename") { let n = newName; renaming = nil; Task { await model.renamePerson(p.id, n); reload() } }
                        .keyboardShortcut(.defaultAction)
                }
            }.padding(20)
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "this person")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            if let p = deleting {
                Button("Remove Name Only (keep faces)") { Task { await model.deletePerson(p.id, deleteFaces: false); reload() } }
                Button("Delete Name and Face Data", role: .destructive) { Task { await model.deletePerson(p.id, deleteFaces: true); reload() } }
            }
        } message: {
            Text("Photos are never deleted.")
        }
        .confirmationDialog("Look for faces again?", isPresented: $confirmRedetect, titleVisibility: .visible) {
            Button("Look Again") { Task { await model.redetectFaces() } }
        } message: {
            Text("Faces are detected again in every photo. Faces you added by hand and the names you've given are kept.")
        }
    }

    private func reload() { summaries = model.personSummaries() }
}

// MARK: - Sharing with other apps

struct SharingSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var tokenName = ""
    @State private var scopes: Set<APIToken.Scope> = [.read, .thumbnails]
    @State private var newSecret: String?
    @State private var portText = ""

    var body: some View {
        let api = model.apiServer
        Section("Sharing with other apps") {
            Toggle("Let other apps on this Mac read this library", isOn: Binding(
                get: { api.isRunning },
                set: { $0 ? api.start(model: model) : api.stop(persist: true) }))
            HStack {
                TextField("Port", text: $portText).frame(width: 80).textFieldStyle(.roundedBorder)
                Button("Use Port") { if let p = UInt16(portText) { api.stop(); api.start(model: model, port: p) } }
                    .disabled(UInt16(portText) == nil)
                Spacer()
                Text(api.isRunning ? "Running at http://127.0.0.1:\(api.port) · \(api.requestsServed) requests" : "Off")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let e = api.lastError { Text(e).font(.caption).foregroundStyle(.red) }
            Text("Read-only, and only reachable from this Mac. Every app needs its own access token; you choose what it may see and can revoke it at any time. The database format is documented, so tools can also open a copy of it directly.")
                .font(.caption).foregroundStyle(.secondary)

            ForEach(api.tokens) { t in
                HStack {
                    Image(systemName: "key")
                    VStack(alignment: .leading) {
                        Text(t.name)
                        Text(t.scopes.map(\.rawValue).joined(separator: ", ") + (t.lastUsed.map { " · last used " + $0.formatted(.relative(presentation: .named)) } ?? " · never used"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Revoke", role: .destructive) { api.revoke(t.id) }
                }
            }
            DisclosureGroup("New access token") {
                TextField("App name (for your reference)", text: $tokenName).textFieldStyle(.roundedBorder)
                ForEach(APIToken.Scope.allCases) { s in
                    Toggle(s.label, isOn: Binding(get: { scopes.contains(s) }, set: { if $0 { scopes.insert(s) } else { scopes.remove(s) } }))
                }
                Button("Create Token") {
                    newSecret = api.createToken(name: tokenName.isEmpty ? "App" : tokenName, scopes: APIToken.Scope.allCases.filter { scopes.contains($0) })
                    tokenName = ""
                }
                .disabled(scopes.isEmpty)
            }
            if let secret = newSecret {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Copy this token now. It won't be shown again.").font(.caption.bold())
                    HStack {
                        Text(secret).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(secret, forType: .string)
                        }
                        Button("Done") { newSecret = nil }
                    }
                }
                .padding(8).background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
            Link("How other apps connect (API guide)", destination: URL(string: "https://github.com/talvinder-m/talvinder-photoforge/blob/main/docs/API.md")!)
        }
        .onAppear { portText = String(api.port) }
    }
}
