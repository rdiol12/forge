import SwiftUI

@MainActor
struct HomeView: View {
    @Environment(ForgeStore.self) private var store
    @Environment(DownloadManager.self) private var downloads
    @State private var tab = 0
    @State private var addingRepository = false
    @State private var showingSettings = false

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                dashboard
                    .navigationTitle("Home")
                    .toolbar {
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            Button { addingRepository = true } label: { Image(systemName: "plus") }
                                .accessibilityLabel("Add favorite repository")
                            Button { tab = 2 } label: { Image(systemName: "magnifyingglass") }
                                .accessibilityLabel("Search GitHub")
                        }
                    }
            }
            .tabItem { Label("Home", image: "octicon-home") }.tag(0)
            NavigationStack { InboxView(showingSettings: $showingSettings) }
                .tabItem { Label("Inbox", image: "octicon-inbox") }.tag(1)
            NavigationStack { ExploreView() }
                .tabItem { Label("Explore", image: "octicon-telescope") }.tag(2)
            NavigationStack { ProfileView(showingSettings: $showingSettings) }
                .tabItem { Label("Profile", image: "octicon-person") }.tag(3)
        }
        .sheet(isPresented: $addingRepository) { AddRepositoryView() }
        .sheet(isPresented: $showingSettings, onDismiss: { Task { await store.refresh() } }) { SettingsView() }
        .alert("Download", isPresented: Binding(get: { downloads.errorMessage != nil }, set: { if !$0 { downloads.errorMessage = nil } })) {
            Button("OK") { downloads.errorMessage = nil }
        } message: { Text(downloads.errorMessage ?? "") }
    }

    private var dashboard: some View {
        List {
            Section {
                GitHubWebRow("Issues", icon: "issue-opened", color: .green, path: "/issues")
                GitHubWebRow("Pull Requests", icon: "git-pull-request", color: .blue, path: "/pulls")
                GitHubWebRow("Discussions", icon: "comment-discussion", color: .purple, path: "/discussions")
                NavigationLink { FavoritesView() } label: { WorkLabel("Top Repositories", icon: "repo", color: Color(white: 0.28)) }
                GitHubWebRow("Organizations", icon: "organization", color: .orange, path: "/settings/organizations")
            } header: {
                HStack {
                    Text("My Work")
                    Spacer()
                    Menu {
                        Button("Account and settings") { showingSettings = true }
                        Link("Open GitHub dashboard", destination: URL(string: "https://github.com/dashboard")!)
                    } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary).frame(width: 32, height: 24) }
                    .accessibilityLabel("My Work options")
                }
            }

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
                    Text("Favorites")
                    Spacer()
                    Menu {
                        Button("Add a favorite", systemImage: "plus") { addingRepository = true }
                        Button("Manage favorites", systemImage: "slider.horizontal.3") { showingSettings = true }
                    } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary).frame(width: 32, height: 24) }
                    .accessibilityLabel("Favorite repository options")
                }
            }

            Section {
                NavigationLink { ActionsView() } label: {
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
                GitHubWebRow("Copilot", icon: "copilot", color: Color(white: 0.28), path: "/copilot")
            } header: { Text("Shortcuts") }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(22)
        .environment(\.defaultMinListRowHeight, 50)
        .headerProminence(.increased)
        .refreshable { await store.refresh() }
    }
}

@MainActor
struct ActionsView: View {
    var repository: Repository? = nil
    @Environment(ForgeStore.self) private var store
    @State private var filter = "All"
    @State private var search = ""

    private var visible: [RepositoryRun] {
        store.runs.filter { entry in
            (repository == nil || entry.repository.id == repository?.id) &&
            (filter == "All" || (filter == "Failed" && entry.run.state == .failed) ||
             (filter == "Active" && [.running, .queued].contains(entry.run.state))) &&
            (search.isEmpty || "\(entry.repository.fullName) \(entry.run.displayTitle) \(entry.run.headBranch ?? "")".localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        List {
            Picker("Run status", selection: $filter) {
                ForEach(["All", "Failed", "Active"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            if !store.errors.isEmpty { RefreshErrors() }
            Section {
                ForEach(visible) { entry in
                    NavigationLink { RunDetailView(entry: entry) } label: { RunRow(entry: entry) }
                }
                if visible.isEmpty {
                    ContentUnavailableView("No matching runs", systemImage: "play.circle", description: Text(store.isRefreshing ? "Checking your repositories?" : "Add a favorite repository on Home, change the filter, or pull to refresh."))
                }
            } header: { Text(repository?.fullName ?? "Recent activity").textCase(nil) }
              footer: { Text("Latest 30 runs per favorite repository. Pull to refresh.") }
        }
        .navigationTitle("Actions")
        .searchable(text: $search, prompt: "Repository, branch or run")
        .refreshable { await store.refresh() }
    }
}

@MainActor
struct ReleasesView: View {
    var repository: Repository? = nil
    @Environment(ForgeStore.self) private var store
    @State private var unreadOnly = false
    @State private var search = ""

    private var visible: [RepositoryRelease] {
        store.releases.filter {
            (repository == nil || $0.repository.id == repository?.id) &&
            (!unreadOnly || !store.readReleases.contains($0.id)) &&
            (search.isEmpty || "\($0.repository.fullName) \($0.release.title) \($0.release.tagName)".localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        List {
            Toggle("Unread only", isOn: $unreadOnly)
            if !store.errors.isEmpty { RefreshErrors() }
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
                if visible.isEmpty {
                    ContentUnavailableView("No matching releases", systemImage: "tag", description: Text("Add a favorite repository on Home or change the filter."))
                }
            } header: { Text(repository?.fullName ?? "Latest releases").textCase(nil) }
              footer: { Text("Latest 20 releases per favorite repository. Open a release to see file download counts.") }
        }
        .navigationTitle("Releases")
        .searchable(text: $search, prompt: "Repository or version")
        .refreshable { await store.refresh() }
    }
}

private struct RunRow: View {
    let entry: RepositoryRun
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.run.state.symbol).foregroundStyle(entry.run.state.color)
                .frame(width: 24).padding(.top, 3).accessibilityLabel(entry.run.state.rawValue)
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.repository.fullName).font(.caption).foregroundStyle(.secondary)
                Text(entry.run.displayTitle).font(.body.weight(.semibold)).lineLimit(3)
                Text("\(entry.run.name ?? "Workflow") #\(entry.run.runNumber)").font(.caption).foregroundStyle(.secondary)
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
