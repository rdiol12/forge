import SwiftUI

@MainActor
struct HomeView: View {
    @Environment(ForgeStore.self) private var store
    @Environment(DownloadManager.self) private var downloads
    @State private var addingRepository = false
    @State private var showingSettings = false

    var body: some View {
        TabView {
            NavigationStack {
                ActionsView(addingRepository: $addingRepository)
                    .toolbar { navigationTools }
            }
            .tabItem { Label("Actions", systemImage: "waveform.path.ecg") }
            NavigationStack {
                ReleasesView(addingRepository: $addingRepository)
                    .toolbar { navigationTools }
            }
            .tabItem { Label("Releases", systemImage: "shippingbox") }
            NavigationStack { DownloadsView() }
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
                .badge(downloads.entries.filter(\.active).count)
        }
        .sheet(isPresented: $addingRepository) { AddRepositoryView() }
        .sheet(isPresented: $showingSettings, onDismiss: { Task { await store.refresh() } }) { SettingsView() }
        .alert("Download", isPresented: Binding(get: { downloads.errorMessage != nil }, set: { if !$0 { downloads.errorMessage = nil } })) {
            Button("OK") { downloads.errorMessage = nil }
        } message: { Text(downloads.errorMessage ?? "") }
    }

    @ToolbarContentBuilder private var navigationTools: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { showingSettings = true } label: { Image(systemName: "person.crop.circle") }
                .accessibilityLabel("Account and settings")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if store.isRefreshing { ProgressView().accessibilityLabel("Refreshing") }
            Button { addingRepository = true } label: { Image(systemName: "plus") }
                .accessibilityLabel("Watch a repository")
        }
    }
}

@MainActor
private struct ActionsView: View {
    @Environment(ForgeStore.self) private var store
    @Binding var addingRepository: Bool
    @State private var filter = "All"
    @State private var search = ""

    private var visible: [RepositoryRun] {
        store.runs.filter { entry in
            (filter == "All" || (filter == "Failed" && entry.run.state == .failed) ||
             (filter == "Active" && [.running, .queued].contains(entry.run.state))) &&
            (search.isEmpty || "\(entry.repository.fullName) \(entry.run.displayTitle) \(entry.run.headBranch ?? "")".localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 20) {
                    Label("FORGE", systemImage: "shippingbox.fill")
                        .font(.caption.weight(.heavy)).tracking(3).foregroundStyle(.orange)
                    Text("Your builds.\nWithin reach.")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Text("Follow the run. Grab the artifact. Keep shipping.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        MetricTile(value: store.repositories.count, title: "Watching", color: .orange)
                        MetricTile(value: store.runs.filter { [.running, .queued].contains($0.run.state) }.count, title: "Active", color: .blue)
                        MetricTile(value: store.runs.filter { $0.run.state == .failed }.count, title: "Failed", color: .red)
                    }
                }
                .padding(.vertical, 8)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))

            if store.repositories.isEmpty {
                WelcomeCard(addingRepository: $addingRepository)
            } else {
                if !store.errors.isEmpty { RefreshErrors() }
                Section {
                    Picker("Run status", selection: $filter) {
                        ForEach(["All", "Failed", "Active"], id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.segmented).listRowBackground(Color.clear)
                    ForEach(visible) { entry in
                        NavigationLink { RunDetailView(entry: entry) } label: { RunRow(entry: entry) }
                    }
                    if visible.isEmpty {
                        ContentUnavailableView("No matching runs", systemImage: "checkmark.circle", description: Text(store.isRefreshing ? "Checking your repositories…" : "Try another filter or pull to refresh."))
                    }
                } header: {
                    HStack {
                        Text("Recent activity")
                        Spacer()
                        if let date = store.refreshedAt { Text(date, style: .time).textCase(nil) }
                    }
                } footer: {
                    Text("Latest 30 runs per repository. Refreshes when you open Forge; pull down to check again. Failed includes older runs in this window.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Actions")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Repository, branch or run")
        .refreshable { await store.refresh() }
    }
}

@MainActor
private struct ReleasesView: View {
    @Environment(ForgeStore.self) private var store
    @Binding var addingRepository: Bool
    @State private var unreadOnly = false
    @State private var search = ""

    private var visible: [RepositoryRelease] {
        store.releases.filter {
            (!unreadOnly || !store.readReleases.contains($0.id)) &&
            (search.isEmpty || "\($0.repository.fullName) \($0.release.title) \($0.release.tagName)".localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Fresh off the build.").font(.system(.title, design: .rounded, weight: .bold))
                    Text("Release notes, real download counts, and every file in one place.").foregroundStyle(.secondary)
                }.padding(.vertical, 8)
            }.listRowBackground(Color.clear)
            if store.repositories.isEmpty {
                WelcomeCard(addingRepository: $addingRepository)
            } else {
                if !store.errors.isEmpty { RefreshErrors() }
                Toggle("Unread only", isOn: $unreadOnly)
                Section {
                    ForEach(visible) { entry in
                        NavigationLink { ReleaseDetailView(entry: entry) } label: {
                            VStack(alignment: .leading, spacing: 9) {
                                HStack {
                                    Text(entry.repository.fullName).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    Spacer()
                                    if !store.readReleases.contains(entry.id) {
                                        Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.orange).accessibilityLabel("Unread")
                                    }
                                }
                                Text(entry.release.title).font(.headline).foregroundStyle(.primary)
                                HStack {
                                    Label(entry.release.tagName, systemImage: "tag")
                                    if entry.release.prerelease { Text("Pre-release").foregroundStyle(.orange) }
                                    Spacer()
                                    if let date = entry.release.publishedAt { Text(date, style: .relative) }
                                }.font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 8)
                        }
                    }
                    if visible.isEmpty {
                        ContentUnavailableView("You're caught up", systemImage: "shippingbox", description: Text("No releases match this view."))
                    }
                } header: { Text("Release inbox") }
                  footer: { Text("Latest 20 releases per repository. Open a release to mark it as read.") }
            }
        }
        .navigationTitle("Releases")
        .searchable(text: $search, prompt: "Repository or version")
        .refreshable { await store.refresh() }
    }
}

private struct MetricTile: View {
    let value: Int
    let title: String
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value, format: .number).font(.system(.title, design: .rounded, weight: .bold)).foregroundStyle(color)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

private struct RunRow: View {
    let entry: RepositoryRun
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(entry.repository.fullName).font(.caption.monospaced()).foregroundStyle(.secondary)
            Text(entry.run.displayTitle).font(.headline).lineLimit(3)
            HStack(spacing: 8) {
                StatusBadge(state: entry.run.state)
                Text(entry.run.name ?? "Workflow").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Text("#\(entry.run.runNumber)").font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
            HStack {
                Label(entry.run.headBranch ?? "Unknown branch", systemImage: "arrow.triangle.branch").lineLimit(1)
                Spacer()
                Text(entry.run.createdAt, style: .relative)
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 8)
    }
}

private struct WelcomeCard: View {
    @Binding var addingRepository: Bool
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "antenna.radiowaves.left.and.right").font(.largeTitle).foregroundStyle(.orange)
                Text("A home for your builds.").font(.title2.bold())
                Text("Watch a repository to follow Actions, explore releases, and download the files you need.").foregroundStyle(.secondary)
                Button { addingRepository = true } label: { Label("Watch a repository", systemImage: "plus").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Text("Public repositories work without an account.").font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 12)
        }
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
