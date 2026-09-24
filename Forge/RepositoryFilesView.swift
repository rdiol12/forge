import QuickLook
import SwiftUI

@MainActor
struct RepositoryFilesView: View {
    let repository: Repository
    var path = ""
    var revision: RepositoryBranch? = nil
    @Environment(ForgeStore.self) private var store
    @State private var branch: RepositoryBranch?
    @State private var choosingBranch = false
    @State private var files: [RepositoryFile] = []
    @State private var busy = false
    @State private var error: String?
    @State private var search = ""

    private var visible: [RepositoryFile] {
        files.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }.sorted {
            if ($0.type == "dir") != ($1.type == "dir") { return $0.type == "dir" }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        List {
            Section {
                if path.isEmpty {
                    Button { choosingBranch = true } label: {
                        HStack { Label(branch?.name ?? "Choose branch", systemImage: "arrow.triangle.branch"); Spacer(); Image(systemName: "chevron.down") }
                    }.disabled(busy)
                } else if let branch { Label(branch.name, systemImage: "arrow.triangle.branch").font(.subheadline).foregroundStyle(.secondary) }
                if let branch {
                    Text("Commit \(branch.commit.sha.prefix(12))").font(.caption.monospaced()).foregroundStyle(.secondary)
                    if path.isEmpty, let spec = try? DownloadSpec.repositoryArchive(in: repository, sha: branch.commit.sha, name: branch.name) {
                        VStack(alignment: .leading, spacing: 10) { Text("Repository ZIP").font(.headline); DownloadControl(specification: spec) }
                    }
                }
            }
            Section {
                ForEach(visible) { file in
                    if file.safePath {
                        NavigationLink {
                            if file.type == "dir" { RepositoryFilesView(repository: repository, path: file.path, revision: branch) }
                            else { RepositoryFileView(repository: repository, file: file, branch: branch?.name) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: file.type == "dir" ? "folder.fill" : "doc.text").foregroundStyle(file.type == "dir" ? Color.blue : Color.secondary)
                                Text(file.name).lineLimit(2)
                                Spacer()
                                if file.type == "file" { Text(fileSize(file.size)).font(.caption).foregroundStyle(.secondary) }
                            }.padding(.vertical, 4)
                        }
                    }
                }
                if busy { ProgressView("Loading files…") }
                if let error { ErrorNotice(message: error); Button("Retry") { Task { await load() } }.disabled(busy) }
                if files.isEmpty && !busy && error == nil { ContentUnavailableView("No files", systemImage: "folder") }
            } header: { Text(path.isEmpty ? repository.fullName : path).textCase(nil) }
              footer: {
                  // ponytail: Contents API lists at most 1,000 entries; the ZIP contains the complete tree.
                  if files.count >= 1000 { Text("GitHub returns up to 1,000 entries per folder. Download the repository ZIP for the complete tree.") }
              }
        }
        .navigationTitle(path.isEmpty ? "Code" : String(path.split(separator: "/").last ?? "Code"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Filter this folder")
        .task(id: store.account) { await load() }
        .refreshable { await store.client.clearCache(); await load(refreshBranch: true) }
        .sheet(isPresented: $choosingBranch) {
            BranchPicker(repository: repository) { branch = $0; Task { await load() } }
        }
    }

    private func load(refreshBranch: Bool = false) async {
        guard !busy else { return }; busy = true; error = nil; files = []
        defer { busy = false }
        do {
            if let revision { branch = revision }
            else if branch == nil || refreshBranch {
                let name: String
                if let branch { name = branch.name }
                else { struct Info: Decodable { let defaultBranch: String }; let info: Info = try await store.client.get("/repos/\(repository.fullName)"); name = info.defaultBranch }
                let reference: GitReference = try await store.client.get("/repos/\(repository.fullName)/git/ref/heads/\(name)")
                guard reference.object.type == "commit" else { throw GitHubError("This branch has no commit yet.") }
                branch = RepositoryBranch(name: name, commit: .init(sha: reference.object.sha))
            }
            guard let branch else { return }
            let items = try await store.client.files(in: repository, path: path, sha: branch.commit.sha)
            guard !Task.isCancelled else { return }; files = items
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

@MainActor
struct BranchPicker: View {
    let repository: Repository
    let select: (RepositoryBranch) -> Void
    @Environment(ForgeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var branches: [RepositoryBranch] = []
    @State private var page = 0
    @State private var more = false
    @State private var busy = false
    @State private var error: String?
    @State private var search = ""
    var body: some View {
        NavigationStack {
            List {
                ForEach(branches.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { branch in
                    Button { select(branch); dismiss() } label: { Label(branch.name, systemImage: "arrow.triangle.branch") }
                }
                if busy { ProgressView("Loading branches…") }
                if let error { ErrorNotice(message: error); Button("Retry") { Task { await load() } } }
                if more && !busy { Button("Load more branches") { Task { await load() } } }
            }.navigationTitle("Branches").searchable(text: $search, prompt: "Filter loaded branches")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
        }
    }
    private func load() async {
        guard !busy else { return }; busy = true; error = nil
        defer { busy = false }
        do {
            let result = try await store.client.branches(in: repository, page: page + 1)
            guard !Task.isCancelled else { return }
            branches += result.filter { next in !branches.contains { $0.id == next.id } }; page += 1; more = result.count == 100
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

@MainActor
struct RepositoryFileView: View {
    let repository: Repository
    let file: RepositoryFile
    var branch: String? = nil
    @Environment(ForgeStore.self) private var store
    @State private var code: String?
    @State private var busy = false
    @State private var error: String?
    @State private var editedFile: RepositoryFile?
    @State private var edit = false
    @State private var source = false
    private var currentFile: RepositoryFile { editedFile ?? file }
    private var markdown: Bool { ["md", "markdown"].contains((file.name as NSString).pathExtension.lowercased()) }
    private var prettyJSON: String? {
        guard file.name.lowercased().hasSuffix(".json"), let code, let object = try? JSONSerialization.jsonObject(with: Data(code.utf8), options: .fragmentsAllowed),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .fragmentsAllowed]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(file.path).lineLimit(2); Spacer(); Text(fileSize(currentFile.size)) }.font(.caption).foregroundStyle(.secondary).padding()
            Divider()
            if busy { Spacer(); ProgressView("Loading code…"); Spacer() }
            else if let code {
                if markdown || prettyJSON != nil {
                    Picker("Display", selection: $source) { Text(markdown ? "Preview" : "Formatted").tag(false); Text("Source").tag(true) }.pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8)
                }
                if markdown && !source { ScrollView { MarkdownDocumentView(text: code).padding() } }
                else { CodeTextView(text: !source ? prettyJSON ?? code : code, filename: file.name) }
            }
            else if let error {
                ContentUnavailableView { Label("Preview unavailable", systemImage: "doc") } description: { Text(error) }
                    actions: { Button("Retry") { Task { await load() } } }
            }
            HStack {
                if let specification = try? DownloadSpec.repositoryFile(currentFile, in: repository) { DownloadControl(specification: specification) }
                Spacer()
                if let code { ShareLink(item: code) { Label("Share text", systemImage: "square.and.arrow.up") } }
            }.padding().background(.bar)
        }.navigationTitle(file.name).navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .toolbar {
            if store.hasToken, branch != nil, code != nil, file.name.lowercased().hasPrefix("readme") { Button("Edit") { edit = true } }
        }
        .sheet(isPresented: $edit) {
            if let branch, let code {
                FileEditor(repository: repository, file: currentFile, branch: branch, initialText: code) { sha, text in
                    editedFile = RepositoryFile(name: file.name, path: file.path, sha: sha, type: "file", size: Int64(text.utf8.count)); self.code = text
                }
            }
        }
    }
    private func load() async {
        guard !busy else { return }; busy = true; error = nil
        defer { busy = false }
        do { let text = try await store.client.codeText(in: repository, file: currentFile); guard !Task.isCancelled else { return }; code = text }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
