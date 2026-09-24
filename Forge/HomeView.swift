import SwiftUI

@MainActor
struct HomeView: View {
    @Environment(ForgeStore.self) private var store
    @Environment(DownloadManager.self) private var downloads
    @State private var tab = 0
    @AppStorage("showCopilot") private var showCopilot = false
    @State private var addingRepository = false
    @State private var showingSettings = false
    @State private var creatingIssue = false
    @State private var createdIssue: Conversation?
    @State private var showingCreated = false

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                dashboard
                    .navigationTitle("Home")
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                Button("New issue", systemImage: "square.and.pencil") { creatingIssue = true }
                                Button("Add favorite", systemImage: "star") { addingRepository = true }
                            } label: { Image(systemName: "plus").foregroundStyle(Color.primary) }.accessibilityLabel("Create or add")
                        }
                        if #available(iOS 26.0, *) { ToolbarSpacer(.fixed, placement: .topBarTrailing) }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { tab = 3 } label: { Avatar(login: store.account, size: 30) }.accessibilityLabel("Your profile")
                        }
                    }
                    .navigationDestination(isPresented: $showingCreated) { if let createdIssue, let repo = createdIssue.repository { ConversationDetailView(repository: repo, number: createdIssue.number, kind: .issue) } }
            }
            .tabItem { Label("Home", image: "octicon-home") }.tag(0)
            NavigationStack { InboxView(showingSettings: $showingSettings) }
                .tabItem { Label("Inbox", image: "octicon-inbox") }.tag(1)
            NavigationStack { ExploreView() }
                .tabItem { Label("Explore", image: "octicon-telescope") }.tag(2)
            NavigationStack { ProfileView(showingSettings: $showingSettings) }
                .tabItem { Label("Profile", image: "octicon-person") }.tag(3)
        }
        .id(store.account)
        .inAppLinks()
        .sheet(isPresented: $addingRepository) { AddRepositoryView() }
        .sheet(isPresented: $creatingIssue) { IssueComposer(repository: nil) { createdIssue = $0; showingCreated = true } }
        .sheet(isPresented: $showingSettings, onDismiss: { Task { await store.refresh() } }) { SettingsView() }
        .alert("Download", isPresented: Binding(get: { downloads.errorMessage != nil }, set: { if !$0 { downloads.errorMessage = nil } })) {
            Button("OK") { downloads.errorMessage = nil }
        } message: { Text(downloads.errorMessage ?? "") }
    }

    private var dashboard: some View {
        List {
            Section {
                NavigationLink { ConversationListView(kind: .issue) } label: { WorkLabel("Issues", icon: "issue-opened", color: .green) }
                NavigationLink { ConversationListView(kind: .pullRequest) } label: { WorkLabel("Pull Requests", icon: "git-pull-request", color: .blue) }
                NavigationLink { ConversationListView(kind: .discussion) } label: { WorkLabel("Discussions", icon: "comment-discussion", color: .purple) }
                NavigationLink { AccountRepositoriesView(collection: .owned) } label: { WorkLabel("Repositories", icon: "repo", color: Color(white: 0.28)) }
                NavigationLink { OrganizationListView() } label: { WorkLabel("Organizations", icon: "organization", color: .orange) }
                NavigationLink { AccountRepositoriesView(collection: .starred) } label: { WorkLabel("Starred", icon: "star", color: .yellow) }
            } header: {
                HStack {
                    Text("My Work").font(.headline)
                    Spacer()
                    Menu {
                        Button("Account and settings") { showingSettings = true }
                        Link("Open GitHub dashboard", destination: URL(string: "https://github.com/dashboard")!)
                    } label: { Image(systemName: "ellipsis").foregroundStyle(Color.secondary).frame(width: 32, height: 24) }
                    .accessibilityLabel("My Work options")
                }.padding(.horizontal, -16)
            }.listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

            Section {
                if store.repositories.isEmpty {
                    VStack(spacing: 12) {
                        Text("Keep your favorite repositories close.").foregroundStyle(.secondary)
                        Button("Add a favorite") { addingRepository = true }.buttonStyle(.bordered)
                    }.frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                ForEach(store.repositories) { repository in
                    NavigationLink { RepositoryView(repository: repository) } label: { RepositoryRow(repository: repository) }
                }
            } header: {
                HStack {
                    Text("Favorites").font(.headline)
                    Spacer()
                    Menu {
                        Button("Add a favorite", systemImage: "plus") { addingRepository = true }
                        Button("Manage favorites", systemImage: "slider.horizontal.3") { showingSettings = true }
                    } label: { Image(systemName: "ellipsis").foregroundStyle(Color.secondary).frame(width: 32, height: 24) }
                    .accessibilityLabel("Favorite repository options")
                }.padding(.horizontal, -16)
            }.listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

            Section {
                NavigationLink { OwnedActionsView() } label: {
                    HStack {
                        WorkLabel("Actions", icon: "workflow", color: .blue)
                        Spacer()
                        if store.isRefreshing { ProgressView() }
                        else { Text(store.runs.filter { [.running, .queued].contains($0.run.state) }.count, format: .number).foregroundStyle(.secondary) }
                    }
                }
                NavigationLink { ReleasesView() } label: {
                    HStack {
                        WorkLabel("Releases", icon: "tag", color: .green)
                        Spacer()
                        Text(store.releases.filter { !store.readReleases.contains($0.id) }.count, format: .number).foregroundStyle(.secondary)
                    }
                }
                NavigationLink { DownloadsView() } label: {
                    HStack {
                        WorkLabel("Downloads", icon: "download", color: .purple)
                        Spacer()
                        Text(downloads.entries.count, format: .number).foregroundStyle(.secondary)
                    }
                }
                NavigationLink { DeletedCommitsView() } label: { Label("Deleted commits", systemImage: "clock.arrow.circlepath") }
                if showCopilot { GitHubWebRow("Copilot", icon: "copilot", color: Color(white: 0.28), path: "/copilot") }
            } header: { Text("Shortcuts").font(.headline).padding(.leading, -16) }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(22)
        .environment(\.defaultMinListRowHeight, 50)
        .headerProminence(.increased)
        .refreshable { await store.refresh(force: true) }
    }
}

@MainActor
struct ActionsView: View {
    var repository: Repository? = nil
    @Environment(ForgeStore.self) private var store
    @State private var filter = "All"
    @State private var search = ""
    @State private var repositoryRuns: [RepositoryRun] = []
    @State private var page = 0
    @State private var more = false
    @State private var busy = false
    @State private var error: String?
    @State private var requestID = UUID()
    @Environment(\.scenePhase) private var scenePhase

    private var visible: [RepositoryRun] {
        (repository == nil ? store.runs : repositoryRuns).filter { entry in
            (filter == "All" || (filter == "Failed" && entry.run.state == .failed) ||
             (filter == "Active" && [.running, .queued].contains(entry.run.state))) &&
            (search.isEmpty || "\(entry.repository.fullName) \(entry.run.displayTitle) \(entry.run.headBranch ?? "")".localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        List {
            if repository == nil && store.hasToken {
                NavigationLink { OwnedActionsView() } label: {
                    WorkLabel("All your repository Actions", icon: "repo", color: .blue)
                }
            }
            Picker("Run status", selection: $filter) {
                ForEach(["All", "Failed", "Active"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            if let repository { NavigationLink { LatestBuildView(repository: repository) } label: { Label("Latest successful build", systemImage: "arrow.down.circle") } }
            if repository == nil && !store.errors.isEmpty { RefreshErrors() }
            Section {
                ForEach(visible) { entry in
                    NavigationLink { RunDetailView(entry: entry) } label: { RunRow(entry: entry) }
                }
                if busy { ProgressView("Loading workflow runs…") }
                if let error {
                    ErrorNotice(message: error)
                    Button("Retry") { Task { await load(reset: page == 0) } }
                }
                if more && !busy { Button("Load more runs") { Task { await load(reset: false) } } }
                if visible.isEmpty && !busy && error == nil {
                    ContentUnavailableView("No matching runs", systemImage: "play.circle", description: Text(repository == nil ? "Open Your repository Actions, add a favorite, or change the filter." : "No runs match the current filter. Pull to refresh or load more runs."))
                }
            } header: { Text(repository?.fullName ?? "Recent activity").textCase(nil) }
              footer: { Text(repository == nil ? "Latest 30 runs per favorite repository. Open Your repository Actions to browse your other repositories." : "Runs for this repository. Open a run to see jobs, test steps, and artifacts.") }
        }
        .navigationTitle("Actions")
        .searchable(text: $search, prompt: "Repository, branch or run")
        .task(id: store.account) { await load(reset: true) }
        .refreshable { await store.client.clearCache(); await load(reset: true) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await load(reset: true) } }
        }
    }

    private func load(reset: Bool) async {
        guard let repository else { await store.refresh(); return }
        if !reset && busy { return }
        let id = UUID(), account = store.account
        requestID = id
        busy = true
        error = nil
        if reset { repositoryRuns = []; page = 0; more = false }
        let nextPage = page + 1
        defer { if requestID == id { busy = false } }
        do {
            let result = try await store.client.runs(in: repository, page: nextPage)
            guard !Task.isCancelled, requestID == id, account == store.account else { return }
            repositoryRuns += result.filter { run in !repositoryRuns.contains { $0.run.id == run.id } }.map { RepositoryRun(repository: repository, run: $0) }
            page = nextPage
            more = result.count == 30
        } catch { if !Task.isCancelled, requestID == id, account == store.account { self.error = error.localizedDescription } }
    }
}

@MainActor
struct ReleasesView: View {
    var repository: Repository? = nil
    @Environment(ForgeStore.self) private var store
    @State private var unreadOnly = false
    @State private var search = ""
    @State private var repositoryReleases: [RepositoryRelease] = []
    @State private var page = 0
    @State private var more = false
    @State private var busy = false
    @State private var error: String?
    @State private var requestID = UUID()

    private var visible: [RepositoryRelease] {
        (repository == nil ? store.releases : repositoryReleases).filter {
            (!unreadOnly || !store.readReleases.contains($0.id)) &&
            (search.isEmpty || "\($0.repository.fullName) \($0.release.title) \($0.release.tagName)".localizedCaseInsensitiveContains(search))
        }.sorted { ($0.release.publishedAt ?? .distantPast) > ($1.release.publishedAt ?? .distantPast) }
    }

    var body: some View {
        List {
            Toggle("Unread only", isOn: $unreadOnly)
            if repository == nil && !store.errors.isEmpty { RefreshErrors() }
            Section {
                ForEach(visible) { entry in
                    NavigationLink { ReleaseDetailView(entry: entry) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Octicon("tag").foregroundStyle(.green).padding(.top, 3)
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(entry.repository.fullName).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    if !store.readReleases.contains(entry.id) {
                                        Circle().fill(.blue).frame(width: 7, height: 7).accessibilityLabel("Unread")
                                    }
                                }
                                Text(entry.release.title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                                HStack {
                                    Text(entry.release.tagName)
                                    if entry.release.prerelease { Text("Pre-release").foregroundStyle(.orange) }
                                    Spacer()
                                    if let date = entry.release.publishedAt { Text(date, style: .relative) }
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 6)
                    }
                }
                if busy { ProgressView("Loading releases…") }
                if let error {
                    ErrorNotice(message: error)
                    Button("Retry") { Task { await load(reset: page == 0) } }
                }
                if more && !busy { Button("Load more releases") { Task { await load(reset: false) } } }
                if visible.isEmpty && !busy && error == nil {
                    ContentUnavailableView("No matching releases", systemImage: "tag", description: Text(repository == nil ? "Add a favorite repository on Home or change the filter." : "No published releases match this filter. Pull to refresh or load more releases."))
                }
            } header: { Text(repository?.fullName ?? "Latest releases").textCase(nil) }
              footer: { Text(repository == nil ? "Latest 20 releases per favorite repository. Open a release to see file download counts." : "Open a release to download its files and see download counts.") }
        }
        .navigationTitle("Releases")
        .searchable(text: $search, prompt: "Repository or version")
        .task(id: store.account) { await load(reset: true) }
        .refreshable { await store.client.clearCache(); await load(reset: true) }
    }

    private func load(reset: Bool) async {
        guard let repository else { await store.refresh(); return }
        if !reset && busy { return }
        let id = UUID(), account = store.account
        requestID = id
        busy = true
        error = nil
        if reset { repositoryReleases = []; page = 0; more = false }
        let nextPage = page + 1
        defer { if requestID == id { busy = false } }
        do {
            let result = try await store.client.releases(in: repository, page: nextPage)
            guard !Task.isCancelled, requestID == id, account == store.account else { return }
            repositoryReleases += result.filter { release in !release.draft && !repositoryReleases.contains { $0.release.id == release.id } }.map { RepositoryRelease(repository: repository, release: $0) }
            page = nextPage
            more = result.count == 20
        } catch { if !Task.isCancelled, requestID == id, account == store.account { self.error = error.localizedDescription } }
    }
}

struct RunRow: View {
    let entry: RepositoryRun
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.run.state.symbol).foregroundStyle(entry.run.state.color)
                .frame(width: 24).padding(.top, 3).accessibilityLabel(entry.run.state.rawValue)
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.repository.fullName).font(.caption).foregroundStyle(.secondary)
                Text(entry.run.displayTitle).font(.body.weight(.semibold)).lineLimit(3)
                Text("\(entry.run.name ?? "Workflow") #\(String(entry.run.runNumber))").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Label(entry.run.headBranch ?? "Unknown branch", systemImage: "arrow.triangle.branch").lineLimit(1)
                    Spacer()
                    Text(entry.run.createdAt, style: .relative)
                }.font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 6)
    }
}

@MainActor
private struct RefreshErrors: View {
    @Environment(ForgeStore.self) private var store
    var body: some View {
        Section {
            DisclosureGroup {
                ForEach(store.errors, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
            } label: {
                Label("Some data couldn't refresh", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Text("Previously loaded data may be out of date.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct StatusBadge: View {
    let state: RunState
    var body: some View {
        Label(state.rawValue, systemImage: state.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(state.color)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(state.color.opacity(0.12), in: Capsule())
    }
}

extension RunState {
    var color: Color {
        switch self {
        case .passed: return .green
        case .failed: return .red
        case .running: return .blue
        case .queued: return .orange
        default: return .secondary
        }
    }
    var symbol: String {
        switch self {
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .running: return "arrow.triangle.2.circlepath"
        case .queued: return "clock"
        case .cancelled: return "stop.circle"
        case .skipped: return "forward.end"
        case .unknown: return "questionmark.circle"
        }
    }
}

struct ErrorNotice: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.subheadline).foregroundStyle(.orange).textSelection(.enabled)
    }
}

func fileSize(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
