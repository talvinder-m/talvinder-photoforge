import SwiftUI
import AppKit
import PFCore
import PFDatabase
import PFPeople

struct PeopleView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedID: String?
    @State private var showHidden = false
    @State private var showReview = false

    var body: some View {
        @Bindable var model = model
        let visible = model.people.filter { showHidden || !$0.isHidden }
        Group {
            if !model.faceAnalysisEnabled && model.people.isEmpty {
                ContentUnavailableView {
                    Label("Face grouping is off", systemImage: "person.crop.circle.badge.xmark")
                } description: {
                    Text("Turn on face analysis in Settings & Privacy to group photos by person. Face data never leaves this Mac.")
                } actions: {
                    Button("Open Settings") { model.selection = .settings }
                }
            } else if model.people.isEmpty {
                ContentUnavailableView("No people yet", systemImage: "person.2",
                                       description: Text("Run Analyze Photos from the Dashboard. Groups appear once faces are found."))
            } else {
                HSplitView {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 14)], spacing: 16) {
                            ForEach(visible) { p in
                                PersonCard(person: p, selected: selectedID == p.id)
                                    .onTapGesture { selectedID = p.id; showReview = false }
                            }
                        }.padding()
                    }
                    .frame(minWidth: 360)

                    Group {
                        if showReview {
                            ReviewQueueView()
                        } else if let p = visible.first(where: { $0.id == selectedID }) {
                            PersonDetailView(person: p).id(p.id)
                        } else {
                            ContentUnavailableView("Select a person", systemImage: "person.crop.square",
                                                   description: Text("Name groups to confirm them. Unnamed groups are only suggestions."))
                        }
                    }
                    .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("People")
        .navigationSubtitle("\(model.people.filter { $0.name != nil }.count) named · \(model.people.filter { $0.name == nil }.count) possible")
        .toolbar {
            ToolbarItemGroup {
                Button { showReview = true; selectedID = nil } label: {
                    Label("Review Faces (\(model.reviewFaces.count))", systemImage: "questionmark.square.dashed")
                }
                Toggle("Show Hidden", isOn: $showHidden)
                HStack(spacing: 4) {
                    Text("Loose").font(.caption)
                    Slider(value: $model.faceStrictness, in: 0...1, onEditingChanged: { editing in
                        if !editing { Task { await model.rebuildPeople() } }
                    }).frame(width: 110)
                    Text("Strict").font(.caption)
                }
                .help("How similar faces must be to be grouped together")
            }
        }
    }
}

struct PersonCard: View {
    let person: PersonVM
    let selected: Bool
    var body: some View {
        VStack(spacing: 6) {
            FaceThumb(face: person.faces.first, size: 110)
                .clipShape(Circle())
                .overlay(Circle().stroke(selected ? Color.accentColor : .clear, lineWidth: 3))
            Text(person.title).font(.callout.bold()).lineLimit(1)
                .foregroundStyle(person.name == nil ? .secondary : .primary)
            Text("\(person.faces.count) photo\(person.faces.count == 1 ? "" : "s") · \(person.confidence.displayLabel)")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .opacity(person.isHidden ? 0.5 : 1)
        .contentShape(Rectangle())
    }
}

struct PersonDetailView: View {
    @Environment(AppModel.self) private var model
    let person: PersonVM
    @State private var name = ""
    @State private var focusedFace: StoredFace?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                FaceThumb(face: person.faces.first, size: 72).clipShape(Circle())
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField(person.name == nil ? "Who is this?" : "Name", text: $name)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                            .onSubmit { Task { await model.name(person, name) } }
                        Button(person.name == nil ? "Name & Confirm" : "Rename") { Task { await model.name(person, name) } }
                            .buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text(person.name == nil
                         ? "Possible Person · \(person.confidence.displayLabel). Naming confirms these \(person.faces.count) faces."
                         : "Confirmed by you · \(person.faces.count) photos")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu("Merge Into…") {
                    ForEach(model.people.filter { $0.id != person.id && $0.name != nil }) { other in
                        Button(other.title) { Task { await model.merge(person, into: other) } }
                    }
                }
                .fixedSize()
                .disabled(!model.people.contains { $0.id != person.id && $0.name != nil })
                if person.personID != nil {
                    Button(person.isHidden ? "Unhide" : "Hide") { Task { await model.setHidden(person, !person.isHidden) } }
                }
            }
            Text("Wrong face? Use “Not this person” on it. PhotoForge remembers, and won't group them together again.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                    ForEach(person.faces) { f in
                        VStack(spacing: 4) {
                            FaceThumb(face: f, size: 100).clipShape(RoundedRectangle(cornerRadius: 8))
                            Menu {
                                Button("Not \(person.name ?? "this person")") { Task { await model.notThisPerson(f, in: person) } }
                                Button("Not a face / ignore") { Task { await model.ignore(f) } }
                                if let a = model.assetsByID[f.assetID] {
                                    Button("Open Photo in Editor") { model.editingAsset = a }
                                }
                            } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).fixedSize()
                        }
                    }
                }
            }
        }
        .padding(20)
        .onAppear { name = person.name ?? "" }
    }
}

struct ReviewQueueView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Faces to Review").font(.title2.bold())
            Text("These faces weren't grouped automatically: they're blurry, small, or could belong to more than one person. Assign them yourself, or ignore them.")
                .font(.callout).foregroundStyle(.secondary)
            if model.reviewFaces.isEmpty {
                ContentUnavailableView("Nothing to review", systemImage: "checkmark.circle")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 12) {
                        ForEach(model.reviewFaces) { r in
                            VStack(spacing: 4) {
                                FaceThumb(face: r.face, size: 100).clipShape(RoundedRectangle(cornerRadius: 8))
                                Text(Self.reason(r.reason)).font(.caption2).foregroundStyle(.secondary)
                                Menu("Assign") {
                                    ForEach(model.people.filter { $0.name != nil }) { p in
                                        Button(p.title) { Task { await model.assign(r.face, to: p) } }
                                    }
                                    Divider()
                                    Button("Ignore") { Task { await model.ignore(r.face) } }
                                }
                                .fixedSize()
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
    }

    static func reason(_ r: ReviewItem.Reason) -> String {
        switch r {
        case .lowQuality: "Low quality"
        case .belowClusterThreshold: "Unsure"
        case .constraintConflict: "Conflicts with your feedback"
        case .ambiguousBetweenClusters: "Could be two people"
        }
    }
}

/// Face crop from the private face-thumbnail store, or cut from the photo thumbnail
/// when face thumbnails are turned off.
struct FaceThumb: View {
    @Environment(AppModel.self) private var model
    let face: StoredFace?
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary.opacity(0.5))
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { Image(systemName: "person.fill").font(.system(size: size * 0.4)).foregroundStyle(.tertiary) }
        }
        .frame(width: size, height: size)
        .clipped()
        .task(id: face?.id) { image = await load() }
    }

    private func load() async -> NSImage? {
        guard let face else { return nil }
        if let p = face.cropPath {
            let url = AppModel.faceCropDir.appendingPathComponent(p)
            if let img = NSImage(contentsOf: url) { return img }
        }
        guard let thumb = await model.thumbnail(for: face.localIdentifier, side: 800),
              let cg = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        // Box is normalized, top-left origin; pad it a little for context.
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        let b = face.box.insetBy(dx: -face.box.width * 0.25, dy: -face.box.height * 0.25)
        let r = CGRect(x: b.minX * W, y: b.minY * H, width: b.width * W, height: b.height * H)
            .intersection(CGRect(x: 0, y: 0, width: W, height: H))
        guard !r.isEmpty, let crop = cg.cropping(to: r) else { return nil }
        return NSImage(cgImage: crop, size: NSSize(width: crop.width, height: crop.height))
    }
}
