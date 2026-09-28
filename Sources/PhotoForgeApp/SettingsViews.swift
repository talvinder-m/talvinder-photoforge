import SwiftUI
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
                            if !editing { Task { await model.rebuildPeople() } }
                        })
                        Text("Strict").font(.caption)
                    }
                }
                Button("Delete All Face Data…", role: .destructive) { confirmFaceWipe = true }
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
                LabeledContent("Face & scene similarity", value: "Apple Vision feature prints · on-device")
                LabeledContent("Duplicate matching", value: "Perceptual hashes (pHash/dHash) + SHA-256")
                LabeledContent("Editing", value: "Core Image · on-device")
                Text("No third-party AI models or cloud services are used in this version.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Your data") {
                LabeledContent("Stored at") {
                    Button(AppModel.supportDir.path) { NSWorkspace.shared.activateFileViewerSelecting([AppModel.supportDir]) }
                        .buttonStyle(.link).lineLimit(1).truncationMode(.middle)
                }
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
