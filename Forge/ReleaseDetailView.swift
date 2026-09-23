import SwiftUI
import QuickLook

@MainActor
struct ReleaseDetailView: View {
    let entry: RepositoryRelease
    @Environment(ForgeStore.self) private var store
    @State private var assets: [ReleaseAsset] = []
    @State private var page = 0
    @State private var hasMore = true
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text(entry.repository.fullName).font(.caption).foregroundStyle(.secondary)
                    Text(entry.release.title).font(.title2.bold()).textSelection(.enabled)
                    HStack {
                        Label(entry.release.tagName, systemImage: "tag")
                        if entry.release.prerelease { Text("Pre-release").foregroundStyle(.orange) }
                    }.font(.subheadline)
                    if let date = entry.release.publishedAt {
                        Text(date, format: .dateTime.day().month().year()).font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 8)
            }

            Section {
                if !assets.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(assets.reduce(Int64(0)) { $0 + $1.downloadCount }, format: .number)
                            .font(.title2.bold()).foregroundStyle(.primary)
                        Text(hasMore ? "Downloads across loaded files" : "Total release file downloads")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 8).accessibilityElement(children: .combine)
                }
                ForEach(assets) { asset in
                    VStack(alignment: .leading, spacing: 12) {
                        Label(asset.name, systemImage: "doc.zipper").font(.headline).textSelection(.enabled)
                        ViewThatFits(in: .horizontal) {
                            HStack {
                                Label("\(asset.downloadCount.formatted()) downloads", systemImage: "arrow.down")
                                Spacer()
                                Text(fileSize(asset.size))
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Label("\(asset.downloadCount.formatted()) downloads", systemImage: "arrow.down")
                                Text(fileSize(asset.size))
                            }
                        }.font(.subheadline).foregroundStyle(.secondary)
                        DownloadControl(specification: .asset(asset, in: entry.repository))
                    }.padding(.vertical, 8)
                }
                if let error { ErrorNotice(message: error) }
                if busy { ProgressView("Loading files…") }
                if hasMore && !busy {
                    Button(error == nil ? "Load more files" : "Retry") { Task { await loadAssets() } }
                }
                if assets.isEmpty && !busy && error == nil && !hasMore {
                    Text("This release has no uploaded files. Source archives are available on GitHub.").foregroundStyle(.secondary)
                }
            } header: { Text("Release files") }
              footer: { Text("Counts are GitHub's cumulative download counts, not unique users. Pull to refresh them. Download a file to save it to Files or share it.") }

            Section("Release notes") {
                if let body = entry.release.body, !body.isEmpty {
                    Text(body).font(.subheadline).textSelection(.enabled)
                } else { Text("No release notes provided.").foregroundStyle(.secondary) }
                Link(destination: entry.release.htmlUrl) { Label("View release on GitHub", systemImage: "arrow.up.right.square") }
            }
        }
        .navigationTitle(entry.release.tagName).navigationBarTitleDisplayMode(.inline)
        .task { store.markRead(entry); await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        guard !busy else { return }
        page = 0
        hasMore = true
        await loadAssets()
    }

    private func loadAssets() async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let fetched = try await store.client.assets(in: entry.repository, releaseID: entry.release.id, page: page + 1)
            if page == 0 { assets = [] }
            assets += fetched.filter { item in !assets.contains(where: { $0.id == item.id }) }
            page += 1
            hasMore = fetched.count == 100
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor
struct DownloadControl: View {
    let specification: DownloadSpec
    @State private var previewURL: URL?
    @Environment(ForgeStore.self) private var store
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        if let active = downloads.entries.first(where: { $0.specification.id == specification.id && $0.active }) {
            HStack {
                ProgressView(value: active.progress).frame(maxWidth: 120)
                Text("Downloading…").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { downloads.cancel(active) }.font(.caption)
            }
        } else if let saved = downloads.entries.first(where: { $0.specification.id == specification.id && $0.relativePath != nil }), let url = downloads.fileURL(for: saved) {
            HStack {
                Button { previewURL = url } label: { Label("Preview", systemImage: "doc.text.magnifyingglass") }
                    .buttonStyle(.bordered)
                ShareLink(item: url) { Label("Save or share", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.bordered)
            }.quickLookPreview($previewURL)
        } else {
            Button {
                downloads.start(specification, client: store.client)
            } label: {
                Label("Download", systemImage: "arrow.down.circle.fill")
            }.buttonStyle(.bordered).controlSize(.regular)
                .accessibilityLabel("Download \(specification.name)")
        }
    }
}
