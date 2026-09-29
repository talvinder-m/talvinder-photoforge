import SwiftUI
import PFCore
import PFDatabase

/// The preview image. With `showFaces` on, detected faces are outlined: click one to say who it is,
/// or drag a box around a face PhotoForge missed. Naming a face starts grouping that person's other photos.
struct FaceTaggingImage: View {
    @Environment(AppModel.self) private var model
    let asset: AssetRow
    let showFaces: Bool
    @State private var editingFace: Int64?
    @State private var dragStart: CGPoint?
    @State private var dragRect: CGRect?
    @State private var busy = false

    private var aspect: CGFloat { CGFloat(max(asset.pixelWidth, 1)) / CGFloat(max(asset.pixelHeight, 1)) }

    var body: some View {
        AssetThumbnail(localIdentifier: asset.localIdentifier, side: 1200, contentMode: .fit)
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                if showFaces {
                    GeometryReader { geo in
                        let size = geo.size
                        ZStack(alignment: .topLeading) {
                            // Drawing surface for missed faces.
                            Color.clear.contentShape(Rectangle())
                                .gesture(drawGesture(size: size))
                            ForEach(model.faces(in: asset.id)) { face in
                                faceBox(face, size: size)
                            }
                            if let r = dragRect {
                                Rectangle().strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                                    .foregroundStyle(.yellow)
                                    .frame(width: r.width, height: r.height)
                                    .offset(x: r.minX, y: r.minY)
                                    .allowsHitTesting(false)
                            }
                            if busy {
                                ProgressView().controlSize(.small).padding(6)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                                    .padding(6)
                            }
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottom) {
                if showFaces && model.faces(in: asset.id).isEmpty && !busy {
                    Text("No faces marked. Drag a box around a face to add one.")
                        .font(.caption).padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6)).padding(8)
                        .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder
    private func faceBox(_ face: StoredFace, size: CGSize) -> some View {
        let r = CGRect(x: face.box.minX * size.width, y: face.box.minY * size.height,
                       width: face.box.width * size.width, height: face.box.height * size.height)
        let owner = model.person(forFace: face.id)
        let named = owner?.name != nil
        RoundedRectangle(cornerRadius: 3)
            .strokeBorder(named ? Color.green : Color.white, lineWidth: 2)
            .shadow(color: .black.opacity(0.6), radius: 1)
            .contentShape(Rectangle())
            .frame(width: r.width, height: r.height)
            .overlay(alignment: .bottom) {
                Text(owner?.name ?? "Who?")
                    .font(.caption2.bold()).lineLimit(1).fixedSize()
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(named ? Color.green.opacity(0.85) : Color.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white)
                    .offset(y: 14)
            }
            .onTapGesture { editingFace = face.id }
            .popover(isPresented: Binding(get: { editingFace == face.id }, set: { if !$0 { editingFace = nil } })) {
                FaceNamePopover(face: face, currentName: owner?.name) { editingFace = nil }
            }
            .help(owner?.name.map { "This is \($0). Click to change." } ?? "Click to say who this is")
            .offset(x: r.minX, y: r.minY)
    }

    private func drawGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { v in
                let s = dragStart ?? v.startLocation
                dragStart = s
                dragRect = CGRect(x: min(s.x, v.location.x), y: min(s.y, v.location.y),
                                  width: abs(v.location.x - s.x), height: abs(v.location.y - s.y))
                    .intersection(CGRect(origin: .zero, size: size))
            }
            .onEnded { _ in
                defer { dragStart = nil; dragRect = nil }
                guard let r = dragRect, size.width > 0, size.height > 0, r.width > 8, r.height > 8 else { return }
                let norm = CGRect(x: r.minX / size.width, y: r.minY / size.height,
                                  width: r.width / size.width, height: r.height / size.height)
                busy = true
                Task {
                    let id = await model.addManualFace(asset: asset, box: norm)
                    busy = false
                    if let id { editingFace = id }
                }
            }
    }
}

/// "Who is this?" — pick an existing name or type a new one.
struct FaceNamePopover: View {
    @Environment(AppModel.self) private var model
    let face: StoredFace
    let currentName: String?
    var done: () -> Void
    @State private var text = ""

    private var matches: [PersonVM] {
        let t = text.trimmingCharacters(in: .whitespaces)
        let all = model.namedPeople
        guard !t.isEmpty else { return Array(all.prefix(8)) }
        return all.filter { ($0.name ?? "").localizedCaseInsensitiveContains(t) }.prefix(8).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(currentName == nil ? "Who is this?" : "This is \(currentName!)").font(.headline)
            TextField("Name", text: $text).textFieldStyle(.roundedBorder).frame(width: 240)
                .onSubmit { save(text) }
            if !matches.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(matches) { p in
                        Button { save(p.name ?? "") } label: {
                            Label("\(p.name ?? "") (\(p.faces.count))", systemImage: "person.crop.circle")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            Text("PhotoForge then finds this person in your other photos.").font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                if currentName != nil {
                    Button("Not \(currentName!)") { Task { await model.unassignFace(face.id); done() } }
                }
                Button("Not a Face") { Task { await model.ignore(face); done() } }
                Spacer()
                Button("Save") { save(text) }.keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
    }

    private func save(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        done()
        Task { await model.identifyFace(face.id, as: n) }
    }
}
