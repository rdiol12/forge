import SafariServices
import SwiftUI

struct Octicon: View {
    let name: String
    var size: CGFloat = 22
    init(_ name: String, size: CGFloat = 22) { self.name = name; self.size = size }
    var body: some View {
        Image("octicon-\(name)").resizable().scaledToFit().frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct WorkLabel: View {
    let title: String
    let icon: String
    let color: Color
    init(_ title: String, icon: String, color: Color) { self.title = title; self.icon = icon; self.color = color }
    var body: some View {
        HStack(spacing: 12) {
            Octicon(icon, size: 20).foregroundStyle(.white).frame(width: 30, height: 30)
                .background(color, in: RoundedRectangle(cornerRadius: 6))
            Text(title).foregroundStyle(Color.primary)
        }
    }
}

struct Avatar: View {
    let login: String
    var size: CGFloat = 32
    var body: some View {
        AsyncImage(url: URL(string: "https://github.com/\(login).png?size=128")) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.tertiary)
        }
        .frame(width: size, height: size).clipShape(Circle()).accessibilityHidden(true)
    }
}

struct RepositoryRow: View {
    let repository: Repository
    var body: some View {
        HStack(spacing: 12) {
            Avatar(login: String(repository.fullName.split(separator: "/")[0]))
            VStack(alignment: .leading, spacing: 2) {
                Text(repository.fullName.split(separator: "/")[0]).font(.caption).foregroundStyle(.secondary)
                Text(repository.name).font(.body).foregroundStyle(.primary)
            }.padding(.vertical, 3)
        }
    }
}

struct GitHubBrowser: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

@MainActor
struct GitHubDestination: View {
    let url: URL
    var body: some View {
        switch GitHubRoute(url) {
        case let .profile(login): AccountProfileView(login: login)
        case let .repositories(collection): AccountRepositoriesView(collection: collection)
        case .organizations: OrganizationListView()
        case let .actions(repository): ActionsView(repository: repository)
        case let .releases(repository): ReleasesView(repository: repository)
        case let .repository(repository): RepositoryView(repository: repository)
        case let .conversations(repository, kind): ConversationListView(kind: kind, repository: repository)
        case let .conversation(repository, number, kind): ConversationDetailView(repository: repository, number: number, kind: kind)
        case nil: GitHubBrowser(url: url).ignoresSafeArea()
        }
    }
}

private struct InAppURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct InAppLinks: ViewModifier {
    @State private var selected: InAppURL?
    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                guard ["https", "http"].contains(url.scheme), url.host != nil, url.user == nil, url.password == nil else { return .discarded }
                selected = InAppURL(url: url)
                return .handled
            })
            .sheet(item: $selected) { entry in
                if GitHubRoute(entry.url) != nil { NativeLinkSheet(url: entry.url) }
                else { GitHubBrowser(url: entry.url).ignoresSafeArea() }
            }
    }
}

private struct NativeLinkSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var path: [URL] = []
    @State private var browser: InAppURL?
    var body: some View {
        NavigationStack(path: $path) {
            GitHubDestination(url: url)
                .navigationDestination(for: URL.self) { GitHubDestination(url: $0) }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard ["https", "http"].contains(url.scheme), url.host != nil, url.user == nil, url.password == nil else { return .discarded }
            if GitHubRoute(url) != nil { path.append(url) }
            else { browser = InAppURL(url: url) }
            return .handled
        })
        .sheet(item: $browser) { GitHubBrowser(url: $0.url).ignoresSafeArea() }
    }
}

extension View {
    func inAppLinks() -> some View { modifier(InAppLinks()) }
}

struct GitHubWebRow: View {
    let title: String
    let icon: String
    let color: Color
    let path: String
    @State private var showingBrowser = false
    init(_ title: String, icon: String, color: Color, path: String) {
        self.title = title; self.icon = icon; self.color = color; self.path = path
    }
    var body: some View {
        Button { showingBrowser = true } label: {
            HStack {
                WorkLabel(title, icon: icon, color: color)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingBrowser) { GitHubBrowser(url: URL(string: "https://github.com\(path)")!).ignoresSafeArea() }
    }
}

@MainActor
struct FavoritesView: View {
    @Environment(ForgeStore.self) private var store
    @State private var adding = false
    var body: some View {
        List {
            ForEach(store.repositories) { repository in
                NavigationLink { RepositoryView(repository: repository) } label: { RepositoryRow(repository: repository) }
            }
            if store.repositories.isEmpty {
                ContentUnavailableView("No favorites yet", systemImage: "star", description: Text("Add repositories to follow their Actions and releases."))
            }
            Button("Add a favorite", systemImage: "plus") { adding = true }
        }
        .navigationTitle("Top Repositories")
        .sheet(isPresented: $adding) { AddRepositoryView() }
    }
}

@MainActor
struct RepositoryView: View {
    let repository: Repository
    var summary: RepositorySummary? = nil
    @Environment(ForgeStore.self) private var store
    @State private var busy = false
    @State private var error: String?
    private var isFavorite: Bool { store.repositories.contains { $0.id == repository.id } }
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Avatar(login: String(repository.fullName.split(separator: "/")[0]), size: 24)
                        Text(repository.fullName.split(separator: "/")[0]).foregroundStyle(.secondary)
                    }
                    Text(repository.name).font(.title2.bold())
                    if let description = summary?.description { Text(description).font(.subheadline) }
                    if let summary {
                        HStack {
                            Label(summary.stargazersCount.formatted(), systemImage: "star")
                            if let language = summary.language { Text(language) }
                        }.font(.subheadline).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 10)
                Button {
                    if isFavorite { store.removeRepository(repository) }
                    else {
                        busy = true
                        Task {
                            defer { busy = false }
                            do { try await store.addRepository(repository.fullName); error = nil }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                } label: {
                    HStack {
                        Label(isFavorite ? "Remove from favorites" : "Add to favorites", systemImage: isFavorite ? "star.fill" : "star")
                        Spacer()
                        if busy { ProgressView() }
                    }
                }.disabled(busy)
                if let error { ErrorNotice(message: error) }
            }
            Section {
                NavigationLink { RepositoryFilesView(repository: repository) } label: { WorkLabel("Code", icon: "repo", color: Color(white: 0.28)) }
                NavigationLink { CreateBranchView(repository: repository) } label: { Label("Create branch", systemImage: "arrow.triangle.branch").foregroundStyle(.primary) }
                NavigationLink { ConversationListView(kind: .issue, repository: repository) } label: { WorkLabel("Issues", icon: "issue-opened", color: .green) }
                NavigationLink { ConversationListView(kind: .pullRequest, repository: repository) } label: { WorkLabel("Pull Requests", icon: "git-pull-request", color: .blue) }
                NavigationLink { ConversationListView(kind: .discussion, repository: repository) } label: { WorkLabel("Discussions", icon: "comment-discussion", color: .purple) }
            }
            Section {
                NavigationLink { ActionsView(repository: repository) } label: { WorkLabel("Actions", icon: "workflow", color: .blue) }
                NavigationLink { ReleasesView(repository: repository) } label: { WorkLabel("Releases", icon: "tag", color: .green) }
            }
        }
        .navigationTitle(repository.name).navigationBarTitleDisplayMode(.inline)
        .toolbar { ShareLink(item: URL(string: "https://github.com/\(repository.fullName)")!) }
        .refreshable { await store.refresh() }
    }
}

@MainActor
struct ExploreView: View {
    @Environment(ForgeStore.self) private var store
    @State private var query = ""
    @State private var submittedQuery = "stars:>10000"
    @State private var results: [RepositorySummary] = []
    @State private var page = 0
    @State private var more = false
    @State private var busy = false
    @State private var error: String?
    @State private var requestID = UUID()

    var body: some View {
        List {
            Section {
                ForEach(results) { result in
                    if let repository = try? Repository(result.fullName) {
                        NavigationLink { RepositoryView(repository: repository, summary: result) } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                RepositoryRow(repository: repository)
                                if let description = result.description { Text(description).font(.subheadline).lineLimit(3).foregroundStyle(.secondary) }
                                HStack {
                                    Label(result.stargazersCount.formatted(), systemImage: "star")
                                    if let language = result.language { Text(language) }
                                }.font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 6)
                        }
                    }
                }
                if busy { ProgressView("Searching repositories...") }
                if let error {
                    ErrorNotice(message: error)
                    Button("Retry") { Task { await load(reset: page == 0) } }
                }
                if more && !busy { Button("Load more repositories") { Task { await load(reset: false) } } }
                if results.isEmpty && !busy && error == nil { ContentUnavailableView.search(text: query) }
            } header: { Text(submittedQuery == "stars:>10000" ? "Discover repositories" : "Search results").textCase(nil) }
        }
        .navigationTitle("Explore")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search GitHub repositories")
        .onSubmit(of: .search) {
            let input = query.trimmingCharacters(in: .whitespacesAndNewlines)
            submittedQuery = input.isEmpty ? "stars:>10000" : input
        }
        .task(id: submittedQuery + store.account) { await load(reset: true) }
        .refreshable { await load(reset: true) }
    }

    private func load(reset: Bool) async {
        if !reset && busy { return }
        let id = UUID()
        requestID = id
        busy = true
        error = nil
        if reset { page = 0; results = []; more = false }
        let nextPage = page + 1
        defer { if requestID == id { busy = false } }
        do {
            let fetched = try await store.client.searchRepositories(submittedQuery, page: nextPage)
            guard !Task.isCancelled, requestID == id else { return }
            results += fetched.filter { result in !results.contains { $0.id == result.id } }
            page = nextPage
            more = fetched.count == 30 && page < 34
        } catch { if !Task.isCancelled && requestID == id { self.error = error.localizedDescription } }
    }
}

@MainActor
struct InboxView: View {
    @Binding var showingSettings: Bool
    @Environment(ForgeStore.self) private var store
    @State private var entries: [GitHubNotification] = []
    @State private var unreadOnly = false
    @State private var search = ""
    @State private var page = 0
    @State private var more = false
    @State private var busy = false
    @State private var error: String?
    @State private var requestID = UUID()
    @State private var selected: GitHubNotification?
    @State private var markingRead: Set<String> = []
    @State private var readError: String?

    private var visible: [GitHubNotification] {
        entries.filter {
            (!unreadOnly || $0.unread) && (search.isEmpty || "\($0.repository.fullName) \($0.subject.title)".localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        List {
            if store.hasToken {
                Picker("Notifications", selection: $unreadOnly) {
                    Text("All").tag(false)
                    Text("Unread").tag(true)
                }.pickerStyle(.segmented).listRowBackground(Color.clear)
                ForEach(visible) { entry in
                    Button {
                        selected = entry
                        Task { await markRead(entry) }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Octicon(entry.subject.type == "PullRequest" ? "git-pull-request" : entry.subject.type == "Issue" ? "issue-opened" : "inbox")
                                .foregroundStyle(entry.subject.type == "PullRequest" ? .purple : .green)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(entry.repository.fullName).font(.caption).foregroundStyle(.secondary)
                                Text(entry.subject.title).font(.body.weight(.semibold)).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                Text(entry.updatedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if entry.unread { Circle().fill(.blue).frame(width: 7, height: 7).accessibilityLabel("Unread") }
                        }.padding(.vertical, 6)
                    }.disabled(entry.webURL == nil)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if entry.unread {
                            Button { Task { await markRead(entry) } } label: { Label("Mark read", systemImage: "envelope.open") }
                                .tint(.blue).disabled(markingRead.contains(entry.id))
                        }
                    }
                }
                if let readError { ErrorNotice(message: readError) }
                if busy { ProgressView("Loading notifications...") }
                if let error {
                    Section {
                        ErrorNotice(message: error)
                        Text("GitHub's Inbox API requires OAuth or a classic token with notifications or repo access. Fine-grained tokens still work for Actions and releases.").font(.footnote).foregroundStyle(.secondary)
                        Button("Account settings") { showingSettings = true }
                        Button("Retry") { Task { await load(reset: page == 0) } }
                    }
                }
                if visible.isEmpty && !busy && error == nil {
                    ContentUnavailableView("All caught up", systemImage: "tray", description: Text("No notifications match this view."))
                }
                if more && !busy { Button("Load more notifications") { Task { await load(reset: false) } } }
            } else {
                ContentUnavailableView {
                    Label("Your inbox, in one place", systemImage: "tray")
                } description: {
                    Text("Connect GitHub to see notifications for your repositories and conversations.")
                } actions: {
                    Button("Connect GitHub") { showingSettings = true }.buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("Inbox")
        .searchable(text: $search, prompt: "Filter loaded notifications")
        .task(id: store.account) { await load(reset: true) }
        .refreshable { await load(reset: true) }
        .sheet(item: $selected) { entry in
            if let url = entry.webURL {
                if GitHubRoute(url) != nil { NativeLinkSheet(url: url) }
                else { GitHubBrowser(url: url).ignoresSafeArea() }
            }
        }
    }

    private func markRead(_ entry: GitHubNotification) async {
        guard entry.unread, !markingRead.contains(entry.id) else { return }
        let account = store.account
        readError = nil
        markingRead.insert(entry.id)
        defer { markingRead.remove(entry.id) }
        do {
            try await store.client.markNotificationRead(id: entry.id)
            guard store.account == account else { return }
            if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index].unread = false }
        } catch { if store.account == account { readError = "Couldn't mark this notification as read. Swipe the item to retry. \(error.localizedDescription)" } }
    }

    private func load(reset: Bool) async {
        if !reset && busy { return }
        let id = UUID()
        requestID = id
        error = nil
        if reset { entries = []; page = 0; more = false; readError = nil }
        guard store.hasToken else { busy = false; return }
        busy = true
        let nextPage = page + 1
        defer { if requestID == id { busy = false } }
        do {
            let fetched = try await store.client.notifications(page: nextPage)
            guard !Task.isCancelled, requestID == id else { return }
            entries += fetched.filter { entry in !entries.contains { $0.id == entry.id } }
            page = nextPage
            more = fetched.count == 50
        } catch { if !Task.isCancelled && requestID == id { self.error = error.localizedDescription } }
    }
}

@MainActor
struct ProfileView: View {
    @Binding var showingSettings: Bool
    @Environment(ForgeStore.self) private var store
    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    if store.hasToken { Avatar(login: store.account, size: 64) }
                    else { Image(systemName: "person.crop.circle").font(.system(size: 56)).foregroundStyle(.secondary) }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(store.hasToken ? store.account : "Welcome to Forge").font(.title2.bold())
                        Text(store.hasToken ? "GitHub account" : "Connect your GitHub account").font(.subheadline).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 12)
                if !store.hasToken { Button("Connect GitHub") { showingSettings = true } }
            }
            if store.hasToken {
                Section {
                    NavigationLink { AccountProfileView(login: store.account) } label: { WorkLabel("Your profile", icon: "person", color: .blue) }
                    NavigationLink { AccountRepositoriesView(collection: .owned) } label: { WorkLabel("Repositories", icon: "repo", color: Color(white: 0.28)) }
                    NavigationLink { AccountRepositoriesView(collection: .owned, showsActions: true) } label: { WorkLabel("Your repository Actions", icon: "workflow", color: .blue) }
                    NavigationLink { AccountRepositoriesView(collection: .starred) } label: { WorkLabel("Starred", icon: "star", color: .orange) }
                    NavigationLink { OrganizationListView() } label: { WorkLabel("Organizations", icon: "organization", color: .orange) }
                }
            }
            Section {
                NavigationLink { FavoritesView() } label: { WorkLabel("Favorites", icon: "star", color: .orange) }
                NavigationLink { DownloadsView() } label: { WorkLabel("Downloads", icon: "download", color: .purple) }
                Button { showingSettings = true } label: { Label("Settings", systemImage: "gearshape").foregroundStyle(.primary) }
            }
        }
        .navigationTitle("Profile")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingSettings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Settings")
            }
        }
    }
}
