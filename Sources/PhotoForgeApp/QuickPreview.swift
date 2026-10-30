import SwiftUI
import PFCore
import PFDatabase
import PFPhotosBridge

/// Space-bar preview, like Quick Look in Finder and Photos: the photo fills the window,
/// ← → step through the photos in view, Space or Esc closes. Videos play in place.
struct QuickPreview: View {
    @Environment(AppModel.self) private var model
    let sel: GridSelection
    @Binding var current: AssetRow?
    @FocusState private var focused: Bool

    var body: some View {
        if let row = current {
            ZStack {
                Color.black.opacity(0.92).ignoresSafeArea()
                    .onTapGesture { close() }
                VStack(spacing: 10) {
                    HStack {
                        Text(row.displayName).font(.headline).lineLimit(1)
                        if let d = row.creationDate {
                            Text(d.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.white.opacity(0.6))
                        }
                        Spacer()
                        Text(position(of: row)).monospacedDigit().foregroundStyle(.white.opacity(0.6))
                        Button { close() } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                            .buttonStyle(.plain).help("Close (Space or Esc)")
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.top, 12)

                    ZStack {
                        if row.isVideo {
                            VideoPlayerScreen(asset: row).id(row.id)
                        } else {
                            AssetThumbnail(localIdentifier: row.localIdentifier, side: 2400, contentMode: .fit)
                                .aspectRatio(CGFloat(max(row.pixelWidth, 1)) / CGFloat(max(row.pixelHeight, 1)), contentMode: .fit)
                                .id(row.id)
                                .onTapGesture(count: 2) { model.editingAsset = row; close() }
                        }
                        HStack {
                            navButton("chevron.left", enabled: step(-1) != nil) { go(-1) }
                            Spacer()
                            navButton("chevron.right", enabled: step(1) != nil) { go(1) }
                        }
                        .padding(.horizontal, 10)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 12)

                    HStack(spacing: 18) {
                        if !row.isVideo {
                            Button { model.editingAsset = row; close() } label: { Label("Edit", systemImage: "slider.horizontal.3") }
                        }
                        Button { model.playRequest = row; close() } label: { Label("Open in Window", systemImage: "macwindow") }
                            .opacity(row.isVideo ? 1 : 0).disabled(!row.isVideo)
                        Text("← → to browse · Space or Esc to close").font(.caption).foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(.borderless).foregroundStyle(.white)
                    .padding(.bottom, 12)
                }
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onAppear { focused = true }
            .onKeyPress(.space) { close(); return .handled }
            .onKeyPress(.escape) { close(); return .handled }
            .onKeyPress(.return) {
                if row.isVideo { model.playRequest = row } else { model.editingAsset = row }
                close(); return .handled
            }
            .onKeyPress(keys: [.leftArrow, .upArrow], phases: [.down, .repeat]) { _ in go(-1); return .handled }
            .onKeyPress(keys: [.rightArrow, .downArrow], phases: [.down, .repeat]) { _ in go(1); return .handled }
            .transition(.opacity)
        }
    }

    private func navButton(_ symbol: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 22, weight: .semibold))
                .frame(width: 44, height: 64)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain).foregroundStyle(.white)
        .opacity(enabled ? 1 : 0.2).disabled(!enabled)
    }

    /// Browses the selected photos when several are selected, otherwise everything in view.
    private var browseOrder: [Int64] {
        let picked = sel.order.filter { sel.ids.contains($0) }
        return picked.count > 1 ? picked : sel.order
    }

    private func step(_ d: Int) -> AssetRow? {
        guard let id = current?.id, let i = browseOrder.firstIndex(of: id) else { return nil }
        let j = i + d
        guard browseOrder.indices.contains(j) else { return nil }
        return sel.rowsByID[browseOrder[j]]
    }

    private func go(_ d: Int) {
        guard let next = step(d) else { return }
        current = next
        sel.focused = next
        sel.scrollTarget = next.id
        if sel.order.filter({ sel.ids.contains($0) }).count <= 1 { sel.ids = [next.id]; sel.anchor = next.id }
    }

    private func position(of row: AssetRow) -> String {
        guard let i = browseOrder.firstIndex(of: row.id) else { return "" }
        return "\(i + 1) of \(browseOrder.count.formatted())"
    }

    private func close() {
        current = nil
        sel.focusRequest &+= 1
    }
}
