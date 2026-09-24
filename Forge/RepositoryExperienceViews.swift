import SwiftUI

@MainActor
struct RepositoryView: View {
    let repository: Repository
    var summary: RepositorySummary? = nil
    @Environment(ForgeStore.self) private var store
    @State private var info: RepositoryOverview?
    @State private var branch: RepositoryBranch?
    @State private var choosingBranch = false
    @State private var more = false
    @State private var starred = false
    @State private var busy = false
    @State private var error: String?
    @State private var editingDescription = false
    @State private var description = ""
    @State private var showingCode = false
    @State private var showingIssues = false
    @State private var showingForks = false
    private var favorite: Bool { store.repositories.contains { $0.id == repository.id } }
    @ViewBuilder
    var body: some View {
        if #available(iOS 26.0, *) { repositoryList.listStyle(.insetGrouped) }
        else { repositoryList.listStyle(.grouped) }
    }
    private var repositoryList: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Avatar(login: repository.fullName.components(separatedBy: "/")[0], size: 40); Text(repository.fullName.components(separatedBy: "/")[0]).foregroundStyle(.secondary); Spacer() }
                    Text(repository.name).font(.title.bold())
                    if let text = info?.description ?? summary?.description, !text.isEmpty { Text(text).multilineTextAlignment(.leading).textSelection(.enabled) }
                    HStack(spacing: 20) {
                        Button { Task { await star() } } label: { Label((info?.stargazersCount ?? summary?.stargazersCount).map { $0.formatted() } ?? "—", systemImage: starred ? "star.fill" : "star") }
                            .accessibilityLabel(starred ? "Unstar repository" : "Star and add to favorites").disabled(busy || !store.hasToken)
                        Button { showingForks = true } label: { Label(info.map { $0.forksCount.formatted() } ?? "—", systemImage: "arrow.triangle.branch") }.accessibilityLabel("Forks")
                    }.font(.subheadline).buttonStyle(.borderless)
                    if busy { ProgressView() }
                    if let error { ErrorNotice(message: error) }
                }.padding(.vertical, 8)
            }.listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
            Section {
                HStack {
                    Menu {
                        ShareLink(item: URL(string: "https://github.com/\(repository.fullName)")!) { Label("Share", systemImage: "square.and.arrow.up") }
                        Button("Edit description", systemImage: "pencil") { description = info?.description ?? ""; editingDescription = true }.disabled(info?.permissions?.admin != true)
                        Button(favorite ? "Remove from favorites" : "Add to favorites", systemImage: favorite ? "star.slash" : "star") { store.favorite(repository) }
                        NavigationLink { CreateBranchView(repository: repository) } label: { Label("Create branch", systemImage: "arrow.triangle.branch") }
                        NavigationLink { RepositorySettingsView(repository: repository) } label: { Label("Repository settings", systemImage: "gearshape") }
                    } label: { Image(systemName: "ellipsis").frame(width: 40, height: 34) }.accessibilityLabel("Repository options")
                    Button("Code") { showingCode = true }
                    Button("Issues") { showingIssues = true }
                }.buttonStyle(.borderless)
                NavigationLink { ConversationListView(kind: .issue, repository: repository) } label: { WorkLabel("Issues", icon: "issue-opened", color: .green) }
                NavigationLink { ConversationListView(kind: .pullRequest, repository: repository) } label: { WorkLabel("Pull Requests", icon: "git-pull-request", color: .blue) }
                NavigationLink { ActionsView(repository: repository) } label: { WorkLabel("Actions", icon: "workflow", color: .blue) }
                NavigationLink { ReleasesView(repository: repository) } label: { WorkLabel("Releases", icon: "tag", color: .green) }
                DisclosureGroup("More", isExpanded: $more) {
                    NavigationLink { OfflineRepositoryView(repository: repository, branch: branch) } label: { Label("Offline copy", systemImage: "arrow.down.doc") }
                    Link(destination: URL(string: "https://github.com/\(repository.fullName)/wiki")!) { Label("Wiki", systemImage: "book") }
                    NavigationLink { RepositoryCommunityView(repository: repository, kind: "Contributors") } label: { Label("Contributors", systemImage: "person.2") }
                    NavigationLink { RepositoryCommunityView(repository: repository, kind: "Watchers") } label: { Label("Watchers\(info?.subscribersCount.map { " · \($0.formatted())" } ?? "")", systemImage: "eye") }
                    NavigationLink { RepositoryLicenseView(repository: repository) } label: { Label(info?.license?.name ?? "License", systemImage: "doc.text") }
                    NavigationLink { ConversationListView(kind: .discussion, repository: repository) } label: { WorkLabel("Discussions", icon: "comment-discussion", color: .purple) }
                    NavigationLink { LatestBuildView(repository: repository) } label: { Label("Latest successful build", systemImage: "arrow.down.circle") }
                    NavigationLink { DeletedCommitsView(repository: repository) } label: { Label("Deleted commits", systemImage: "clock.arrow.circlepath") }
                }
            }
            Section {
                HStack { Button { choosingBranch = true } label: { Label(branch?.name ?? "Choose branch", systemImage: "arrow.triangle.branch"); Image(systemName: "chevron.down").font(.caption) }; Spacer() }.buttonStyle(.borderless)
                    .listRowSeparator(.hidden)
                NavigationLink { RepositoryFilesView(repository: repository, revision: branch) } label: { WorkLabel("Code", icon: "repo", color: .gray) }
                    .listRowSeparator(.hidden, edges: .top)
                if let branch { NavigationLink { CommitListView(repository: repository, branch: branch) } label: { Label("Commits", systemImage: "clock.arrow.circlepath") } }
            }
            if let branch { Section { ReadmeCard(repository: repository, branch: branch, canEdit: info?.permissions?.push == true) { Task { await load(fresh: true) } } }.readmeSectionLayout() }
        }.listSectionSpacing(16)
        .navigationTitle(repository.name).navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showingCode) { RepositoryFilesView(repository: repository, revision: branch) }
        .navigationDestination(isPresented: $showingIssues) { ConversationListView(kind: .issue, repository: repository) }
        .navigationDestination(isPresented: $showingForks) { RepositoryCommunityView(repository: repository, kind: "Forks") }
        .task(id: store.account) { await load() }
        .refreshable { await load(fresh: true) }
        .sheet(isPresented: $choosingBranch) { BranchPicker(repository: repository) { branch = $0 } }
        .sheet(isPresented: $editingDescription) {
            NavigationStack { Form { TextField("Description", text: $description, axis: .vertical); if let error { ErrorNotice(message: error) } }
                .navigationTitle("Edit description").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editingDescription = false }.disabled(busy) }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await saveDescription() } }.disabled(busy) }
                }.interactiveDismissDisabled(busy)
            }
        }
    }
    private func load(fresh: Bool = false) async {
        busy = true; error = nil; defer { busy = false }
        do {
            let client = store.client; if fresh { await client.clearCache() }
            async let details: RepositoryOverview = client.get("/repos/\(repository.fullName)")
            async let star = client.isStarred(repository)
            let result = try await details
            info = result
            let ref: GitReference = try await client.get("/repos/\(repository.fullName)/git/ref/heads/\(branch?.name ?? result.defaultBranch)")
            guard !Task.isCancelled else { return }; info = result
            branch = RepositoryBranch(name: branch?.name ?? result.defaultBranch, commit: .init(sha: ref.object.sha))
            do { starred = try await star } catch { self.error = error.localizedDescription }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private func star() async {
        busy = true; error = nil
        do { try await store.client.setStar(in: repository, starred: !starred); if !starred && !favorite { store.favorite(repository) }; starred.toggle(); busy = false; await load(fresh: true) }
        catch { self.error = error.localizedDescription; busy = false }
    }
    private func saveDescription() async {
        busy = true; error = nil
        do { try await store.client.editDescription(in: repository, original: info?.description ?? "", description: description); editingDescription = false; busy = false; await load(fresh: true) }
        catch { self.error = error.localizedDescription; busy = false }
    }
}

@MainActor
struct RepositoryCommunityView: View {
    let repository: Repository
    let kind: String
    @Environment(ForgeStore.self) private var store
    @State private var people: [GitHubAccount] = []
    @State private var forks: [RepositorySummary] = []
    @State private var page = 0
    @State private var more = false
    @State private var busy = false
    @State private var error: String?
    @State private var search = ""
    var body: some View {
        List {
            ForEach(people.filter { search.isEmpty || $0.login.localizedCaseInsensitiveContains(search) }) { person in
                NavigationLink { AccountProfileView(login: person.login) } label: { HStack { Avatar(login: person.login, size: 36); Text(person.login) } }
            }
            ForEach(forks.filter { search.isEmpty || $0.fullName.localizedCaseInsensitiveContains(search) }) { fork in
                if let repo = try? Repository(fork.fullName) { NavigationLink { RepositoryView(repository: repo, summary: fork) } label: { RepositoryRow(repository: repo) } }
            }
            if busy { ProgressView() }
            if let error { ErrorNotice(message: error); Button("Retry") { Task { await load(reset: false) } } }
            if !busy && people.isEmpty && forks.isEmpty && error == nil { Text("No \(kind.lowercased()) yet.").foregroundStyle(.secondary) }
            if more && !busy { Button("Load more") { Task { await load(reset: false) } } }
        }.navigationTitle(kind).searchable(text: $search, prompt: "Filter loaded \(kind.lowercased())")
        .task { await load(reset: true) }.refreshable { await store.client.clearCache(); await load(reset: true) }
    }
    private func load(reset: Bool) async {
        guard !busy else { return }; busy = true; error = nil; defer { busy = false }
        if reset { page = 0; people = []; forks = [] }
        do {
            if kind == "Forks" { let rows: [RepositorySummary] = try await store.client.get("/repos/\(repository.fullName)/forks", page: page + 1, count: 30); forks += rows.filter { row in !forks.contains { $0.id == row.id } }; more = rows.count == 30 }
            else { let rows: [GitHubAccount] = try await store.client.get("/repos/\(repository.fullName)/\(kind == "Watchers" ? "subscribers" : "contributors")", page: page + 1, count: 30); people += rows.filter { row in !people.contains { $0.id == row.id } }; more = rows.count == 30 }
            page += 1
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

@MainActor
struct RepositoryLicenseView: View {
    let repository: Repository
    @Environment(ForgeStore.self) private var store
    @State private var file: RepositoryFile?
    @State private var error: String?
    var body: some View {
        Group {
            if let file { RepositoryFileView(repository: repository, file: file) }
            else if let error { ContentUnavailableView("License unavailable", systemImage: "doc.text", description: Text(error)) }
            else { ProgressView("Loading license…") }
        }.navigationTitle("License").task { do { file = try await store.client.get("/repos/\(repository.fullName)/license") } catch { self.error = error.localizedDescription } }
    }
}
