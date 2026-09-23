import QuickLook
import SwiftUI

@MainActor
struct RepositoryFilesView: View {
    let repository: Repository
    var path = ""
    @Environment(ForgeStore.self) private var store
    @State private var files: [RepositoryFile] = []
    @State private var busy = false
    @State private var error: String?
    @State private var search = ""

    private var visible: [RepositoryFile] {
        files.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted { lhs, rhs in
                if (lhs.type == "dir") != (rhs.type == "dir") { return lhs.type == "dir" }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    var body: some View {
        List {
            Section {
                ForEach(visible) { file in
                    if file.safePath {
                        NavigationLink {
                            if file.type == "dir" { RepositoryFilesView(repository: repository, path: file.path) }
                            else { RepositoryFileView(repository: repository, file: file) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: file.type == "dir" ? "folder.fill" : "doc").foregroundStyle(file.type == "dir" ? Color.blue : Color.secondary)
                                Text(file.name).lineLimit(2)
                                Spacer()
                                if file.type == "file" { Text(fileSize(file.size)).font(.caption).foregroundStyle(.secondary) }
                            }.padding(.vertical, 4)
                        }
                    }
                }
                if busy { ProgressView("Loading files...") }
                if let error {
                    ErrorNotice(message: error)
                    Button("Retry") { Task { await load() } }
                }
                if files.isEmpty && !busy && error == nil { ContentUnavailableView("No files", systemImage: "folder") }
            } header: { Text(repository.fullName).textCase(nil) }
              footer: {
                  // ponytail: Contents API lists at most 1,000 entries; use the Git Trees API for larger folders.
                  Text(files.count >= 1000 ? "GitHub returns up to 1,000 items per folder. Open GitHub for the full tree." : "Files on the repository's default branch.")
              }
        }
        .navigationTitle(path.isEmpty ? "Code" : String(path.split(separator: "/").last ?? "Code"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Filter this folder")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let items: [RepositoryFile] = try await store.client.get("/repos/\(repository.fullName)/contents/\(path)")
            guard !Task.isCancelled else { return }
            files = items
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

@MainActor
private struct RepositoryFileView: View {
    let repository: Repository
    let file: RepositoryFile
    var body: some View {
        List {
            Section {
                Label(file.name, systemImage: "doc").font(.headline)
                Text(file.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                LabeledContent("Size", value: fileSize(file.size))
                if let specification = try? DownloadSpec.repositoryFile(file, in: repository) {
                    DownloadControl(specification: specification)
                    Text("Download to preview, save to Files, or share.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("This entry is a link or submodule. Open it on GitHub.").foregroundStyle(.secondary)
                }
            }
            Link("Open repository on GitHub", destination: URL(string: "https://github.com/\(repository.fullName)")!)
        }
        .navigationTitle(file.name).navigationBarTitleDisplayMode(.inline)
    }
}
