import SwiftUI

@MainActor
struct DownloadsView: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(ForgeStore.self) private var store

    var body: some View {
        List {
            if downloads.entries.isEmpty {
                ContentUnavailableView {
                    Label("Ready when you are", systemImage: "arrow.down.circle")
                } description: {
                    Text("Download a release file or build artifact. Your files will live here, ready to save, share, or use offline.")
                }
            } else {
                Section {
                    ForEach(downloads.entries) { entry in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: entry.relativePath == nil ? "arrow.down.doc" : "doc.zipper")
                                    .font(.title2).foregroundStyle(.orange).padding(.top, 3)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(entry.specification.name).font(.headline).textSelection(.enabled)
                                    Text(entry.specification.repository).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    Text(fileSize(entry.specification.size)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if entry.active {
                                ProgressView(value: entry.progress)
                                HStack {
                                    Text(entry.progress.map { "\(Int($0 * 100))%" } ?? "Downloading…").font(.caption).monospacedDigit()
                                    Spacer()
                                    Button("Cancel", role: .cancel) { downloads.cancel(entry) }.buttonStyle(.borderless)
                                }
                            } else if let url = downloads.fileURL(for: entry) {
                                HStack {
                                    Label("On your iPhone", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                                    Spacer()
                                    ShareLink(item: url) { Label("Save / share", systemImage: "square.and.arrow.up") }
                                        .buttonStyle(.bordered)
                                }
                            } else {
                                Text(entry.message ?? "File unavailable").font(.caption).foregroundStyle(.secondary)
                                Button("Try again") { downloads.start(entry.specification, client: store.client) }.buttonStyle(.borderless)
                            }
                        }
                        .padding(.vertical, 8)
                        .swipeActions {
                            Button("Delete", role: .destructive) { downloads.remove(entry) }
                        }
                    }
                } footer: {
                    Text("Keep Forge open until downloads finish. Use Save / share → Save to Files to choose a folder. Saved files remain available offline. Swipe left to delete a local copy.")
                }
            }
        }
        .navigationTitle("Downloads")
    }
}
