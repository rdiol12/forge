import SwiftUI
import QuickLook
import UIKit

@MainActor
struct ReleaseDetailView: View {
    let entry: RepositoryRelease
    @Environment(ForgeStore.self) private var store
    @State private var assets: [ReleaseAsset] = []
    @State private var page = 0
    @State private var hasMore = true
    @State private var busy = false
    @State private var error: String?
    @State private var detailError: String?
    @Environment(\.dismiss) private var dismiss
    @State private var updated: Release?
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var canManage = false
    private var release: Release { updated ?? entry.release }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text(entry.repository.fullName).font(.caption).foregroundStyle(.secondary)
                    Text(release.title).font(.title2.bold()).textSelection(.enabled)
                    HStack {
                        Label(release.tagName, systemImage: "tag")
                        if release.prerelease { Text("Pre-release").foregroundStyle(.orange) }
                    }.font(.subheadline)
                    if let date = release.publishedAt {
                        Text(date, format: .dateTime.day().month().year()).font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 8)
                if let detailError { ErrorNotice(message: detailError) }
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
                if let body = release.body, !body.isEmpty {
                    MarkdownDocumentView(text: body)
                } else { Text("No release notes provided.").foregroundStyle(.secondary) }
                ShareLink(item: release.htmlUrl)
            }
        }
        .navigationTitle(release.tagName).navigationBarTitleDisplayMode(.inline)
        .task { store.markRead(entry); await reload() }
        .toolbar {
            if store.hasToken && canManage {
                Menu {
                    Button("Edit release", systemImage: "square.and.pencil") { editing = true }
                    Button("Delete release", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "ellipsis") }.disabled(busy).accessibilityLabel("Manage release")
            }
        }
        .sheet(isPresented: $editing) { ReleaseEditor(repository: entry.repository, release: release) { updated = $0 } }
        .confirmationDialog("Delete release \(release.tagName)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete release and its assets", role: .destructive) { Task { await delete() } }
        } message: { Text("This permanently deletes the release and its uploaded files. The Git tag remains in the repository.") }
        .refreshable { await store.client.clearCache(); await reload() }
    }

    private func reload() async {
        guard !busy else { return }
        busy = true
        detailError = nil; canManage = false
        do {
            updated = try await store.client.get("/repos/\(entry.repository.fullName)/releases/\(release.id)")
            let settings: RepositorySettings = try await store.client.get("/repos/\(entry.repository.fullName)")
            canManage = settings.permissions?.push == true || settings.permissions?.admin == true
        } catch { detailError = error.localizedDescription }
        busy = false
        page = 0
        hasMore = true
        await loadAssets()
    }

    private func delete() async {
        guard !busy, canManage else { return }; busy = true; error = nil
        defer { busy = false }
        do { try await store.client.deleteRelease(in: entry.repository, id: release.id); await store.refresh(); dismiss() }
        catch { self.error = error.localizedDescription }
    }

    private func loadAssets() async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let fetched = try await store.client.assets(in: entry.repository, releaseID: release.id, page: page + 1)
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
        Group {
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
        }.downloadLinkMenu(specification)
    }
}

extension View {
    func downloadLinkMenu(_ specification: DownloadSpec) -> some View {
        contextMenu {
            Button("Copy download link", systemImage: "link") { UIPasteboard.general.string = specification.downloadURL.absoluteString }
        }
    }
}
