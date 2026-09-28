import SwiftUI
import PFCore
import PFDatabase
import PFSimilarity

struct DuplicatesView: View {
    @Environment(AppModel.self) private var model
    @State private var typeFilter: DuplicateGroupType? = nil
    @State private var selectedGroupID: String?

    private var groups: [DuplicateGroupVM] {
        model.duplicateGroups.filter { typeFilter == nil || $0.type == typeFilter }
    }

    var body: some View {
        let list = groups
        HSplitView {
            VStack(spacing: 0) {
                Picker("Type", selection: $typeFilter) {
                    Text("All (\(model.duplicateGroups.count))").tag(DuplicateGroupType?.none)
                    ForEach(DuplicateGroupType.allCases, id: \.self) { t in
                        Text("\(t.pluralLabel) (\(model.duplicateGroups.filter { $0.type == t }.count))").tag(Optional(t))
                    }
                }
                .labelsHidden().padding(8)
                List(list, selection: $selectedGroupID) { g in
                    HStack(spacing: 8) {
                        if let first = g.members.first {
                            AssetThumbnail(localIdentifier: first.localIdentifier, side: 120)
                                .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        VStack(alignment: .leading) {
                            Text(g.type.label).font(.callout.bold())
                            Text("\(g.members.count) photos · \(g.members.first?.creationDate?.formatted(date: .abbreviated, time: .omitted) ?? "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(g.id)
                }
            }
            .frame(minWidth: 240, idealWidth: 280, maxWidth: 340)

            Group {
                if let g = list.first(where: { $0.id == selectedGroupID }) ?? list.first {
                    GroupDetailView(group: g).id(g.id)
                } else {
                    ContentUnavailableView {
                        Label("No duplicates found", systemImage: "checkmark.seal")
                    } description: {
                        Text(model.stats.hashed == 0
                             ? "Run Analyze Photos from the Dashboard first."
                             : "Nothing to clean up at the current strictness. You can change it in Settings.")
                    }
                }
            }
            .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Duplicates & Similar Photos")
    }
}

struct GroupDetailView: View {
    @Environment(AppModel.self) private var model
    let group: DuplicateGroupVM
    @State private var keep: Set<Int64> = []
    @State private var zoomed: AssetRow?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.type.label + "s").font(.title2.bold())
                    Text(Self.describe(group.type)).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Similarity \(Int(group.similarity * 100))%").font(.caption).padding(6)
                    .background(.quaternary, in: Capsule())
            }
            if !group.explanation.isEmpty {
                Label(group.explanation, systemImage: "star.fill").font(.callout).foregroundStyle(.orange)
            }

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(group.members) { m in
                        MemberCard(asset: m, isRecommended: m.id == group.recommended,
                                   score: group.scores[m.id] ?? 0, keep: keep.contains(m.id)) {
                            if keep.contains(m.id) { keep.remove(m.id) } else { keep.insert(m.id) }
                        } onZoom: { zoomed = m }
                    }
                }.padding(.vertical, 4)
            }

            HStack {
                Button {
                    Task { await model.keep(keep, in: group) }
                } label: {
                    Label("Keep \(keep.count), queue \(group.members.count - keep.count) for removal", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(keep.isEmpty || keep.count == group.members.count)
                Button("Keep All") {
                    Task { await model.markNotSimilar(group) }
                }.help("Keep every photo and stop showing this group")
                Button("Not Similar") { Task { await model.markNotSimilar(group) } }
                    .help("These aren't duplicates. PhotoForge will remember that.")
                Button("Exclude from Scans") { Task { await model.excludeFromScans(group.members.map(\.id)) } }
                Spacer()
            }
            Text("Nothing is deleted here. Photos you don't keep go to the Removal Queue, where you can review them before deleting.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(20)
        .onAppear { keep = group.recommended.map { [$0] } ?? [] }
        .sheet(item: $zoomed) { a in
            VStack {
                AssetThumbnail(localIdentifier: a.localIdentifier, side: 2400)
                    .aspectRatio(CGFloat(max(a.pixelWidth, 1)) / CGFloat(max(a.pixelHeight, 1)), contentMode: .fit)
                Button("Close") { zoomed = nil }.keyboardShortcut(.cancelAction)
            }
            .padding().frame(minWidth: 800, minHeight: 600)
        }
    }

    static func describe(_ t: DuplicateGroupType) -> String {
        switch t {
        case .exact: "Byte-for-byte identical files."
        case .near: "The same picture, resized, re-saved, cropped slightly or edited."
        case .burst: "Shots taken seconds apart of the same moment."
        case .similar: "Different shots of the same scene."
        }
    }
}

struct MemberCard: View {
    let asset: AssetRow
    let isRecommended: Bool
    let score: Double
    let keep: Bool
    let onToggle: () -> Void
    let onZoom: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AssetThumbnail(localIdentifier: asset.localIdentifier, side: 520)
                .frame(width: 240, height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(keep ? Color.green : Color.red.opacity(0.6), lineWidth: 3))
                .overlay(alignment: .topLeading) {
                    if isRecommended {
                        Label("Best", systemImage: "star.fill").font(.caption.bold()).padding(5)
                            .background(.orange, in: Capsule()).foregroundStyle(.white).padding(6)
                    }
                }
                .onTapGesture(count: 2, perform: onZoom)
            Toggle(keep ? "Keep" : "Remove", isOn: Binding(get: { keep }, set: { _ in onToggle() }))
                .toggleStyle(.switch)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                InfoRow("Size", "\(asset.pixelWidth)×\(asset.pixelHeight)")
                InfoRow("Taken", asset.creationDate?.formatted(date: .abbreviated, time: .standard) ?? "—")
                InfoRow("Sharpness", asset.sharpness.map(InspectorView.pct) ?? "—")
                InfoRow("Exposure", asset.exposure.map(InspectorView.pct) ?? "—")
                InfoRow("Low noise", asset.noise.map(InspectorView.pct) ?? "—")
                InfoRow("Favorite", asset.favorite ? "Yes" : "No")
                InfoRow("Score", InspectorView.pct(score))
            }.font(.caption)
            Button("Compare at full size", action: onZoom).buttonStyle(.link).font(.caption)
        }
        .frame(width: 240)
    }
}

struct RemovalQueueView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDelete = false
    @State private var selection: Set<Int64> = []

    var body: some View {
        let queued: [QueuedItem] = model.removalQueue.compactMap { q in
            model.assetsByID[q.assetID].map { QueuedItem(asset: $0, reason: q.reason) }
        }
        VStack(alignment: .leading, spacing: 12) {
            if queued.isEmpty {
                ContentUnavailableView("The Removal Queue is empty", systemImage: "tray",
                                       description: Text("Photos you don't keep when reviewing duplicates wait here until you decide."))
            } else {
                Text("\(queued.count) photos waiting for your decision. Deleting moves them to Recently Deleted in Photos, where they stay for 30 days.")
                    .foregroundStyle(.secondary)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                        ForEach(queued) { item in
                            let asset = item.asset
                            VStack(alignment: .leading, spacing: 4) {
                                AssetThumbnail(localIdentifier: asset.localIdentifier, side: 320)
                                    .frame(height: 150).clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6)
                                        .stroke(selection.contains(asset.id) ? Color.accentColor : .clear, lineWidth: 3))
                                    .onTapGesture {
                                        if selection.contains(asset.id) { selection.remove(asset.id) } else { selection.insert(asset.id) }
                                    }
                                Text(item.reason).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                HStack {
                    Button("Restore Selected") { Task { await model.restoreFromQueue(Array(selection)); selection = [] } }
                        .disabled(selection.isEmpty)
                    Button("Restore All") { Task { await model.restoreFromQueue(queued.map { $0.asset.id }) } }
                    Spacer()
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label(selection.isEmpty ? "Delete All \(queued.count)…" : "Delete \(selection.count) Selected…", systemImage: "trash")
                    }
                    .buttonStyle(.borderedProminent).tint(.red)
                }
            }
        }
        .padding(20)
        .navigationTitle("Removal Queue")
        .confirmationDialog(deleteTitle(queued.count), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Move to Recently Deleted", role: .destructive) {
                let ids = selection.isEmpty ? queued.map { $0.asset.id } : Array(selection)
                Task { if await model.delete(assetIDs: ids) { selection = [] } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Photos will also ask you to confirm. You can recover them from Recently Deleted for 30 days.")
        }
    }

    private func deleteTitle(_ total: Int) -> String {
        let n = selection.isEmpty ? total : selection.count
        return "Delete \(n) photo\(n == 1 ? "" : "s") from your library?"
    }
}

struct QueuedItem: Identifiable {
    let asset: AssetRow
    let reason: String
    var id: Int64 { asset.id }
}
