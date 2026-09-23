import SwiftUI

@MainActor
struct AccountProfileView: View {
    let login: String
    @Environment(ForgeStore.self) private var store
    @State private var profile: GitHubAccount?
    @State private var busy = false
    @State private var error: String?
    @State private var requestID = UUID()

    private var ownProfile: Bool { store.hasToken && login.lowercased() == store.account.lowercased() }
    private var repositories: RepositoryCollection {
        profile?.type == "Organization" ? .organization(login) : ownProfile ? .owned : .user(login)
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    Avatar(login: login, size: 64)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(profile?.name ?? login).font(.title2.bold())
                        Text(login).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 8)
                if let bio = profile?.bio ?? profile?.description, !bio.isEmpty { Text(bio).textSelection(.enabled) }
                if let company = profile?.company, !company.isEmpty { Label(company, systemImage: "building.2") }
                if let location = profile?.location, !location.isEmpty { Label(location, systemImage: "mappin.and.ellipse") }
                if let followers = profile?.followers, let following = profile?.following {
                    Text("\(followers.formatted()) followers · \(following.formatted()) following").font(.subheadline).foregroundStyle(.secondary)
                }
                if busy { ProgressView("Loading profile…") }
                if let error {
                    ErrorNotice(message: error)
                    Button("Retry") { Task { await load() } }
                }
            }
            Section {
                NavigationLink { AccountRepositoriesView(collection: repositories) } label: { WorkLabel("Repositories", icon: "repo", color: Color(white: 0.28)) }
                NavigationLink { AccountRepositoriesView(collection: repositories, showsActions: true) } label: { WorkLabel("Actions", icon: "workflow", color: .blue) }
                if profile?.type != "Organization" {
                    NavigationLink { AccountRepositoriesView(collection: ownProfile ? .starred : .stars(login)) } label: { WorkLabel("Starred", icon: "star", color: .orange) }
                    NavigationLink { OrganizationListView(login: ownProfile ? nil : login) } label: { WorkLabel("Organizations", icon: "organization", color: .orange) }
                }
            }
        }
        .navigationTitle(login).navigationBarTitleDisplayMode(.inline)
        .task(id: store.account) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        let id = UUID(), account = store.account
        requestID = id
        busy = true
        error = nil
        defer { if requestID == id { busy = false } }
        do {
            let result = try await store.client.profile(login: ownProfile ? nil : login)
            guard !Task.isCancelled, requestID == id, account == store.account else { return }
            profile = result
        } catch { if !Task.isCancelled, requestID == id, account == store.account { self.error = error.localizedDescription } }
    }
}

@MainActor
struct AccountRepositoriesView: View {
    let collection: RepositoryCollection
    var showsActions = false
    @Environment(ForgeStore.self) private var store
    @State private var entries: [RepositorySummary] = []
    @State private var search = ""
    @State private var page = 0
    @State private var more = false
    @State private var busy = false
    @State private var error: String?
    @State private var requestID = UUID()
    @State private var showingSettings = false

    private var source: RepositoryCollection {
        switch collection {
        case .user(let login) where store.hasToken && login.lowercased() == store.account.lowercased(): return .owned
        case .stars(let login) where store.hasToken && login.lowercased() == store.account.lowercased(): return .starred
        default: return collection
        }
    }
    private var visible: [RepositorySummary] {
        entries.filter { search.isEmpty || "\($0.fullName) \($0.description ?? "")".localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            Section {
                ForEach(visible) { entry in
                    if let repository = try? Repository(entry.fullName) {
                        NavigationLink {
                            if showsActions { ActionsView(repository: repository) }
                            else { RepositoryView(repository: repository, summary: entry) }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                RepositoryRow(repository: repository)
                                if let description = entry.description, !description.isEmpty {
                                    Text(description).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }.padding(.vertical, 3)
                        }
                    }
                }
                if busy { ProgressView("Loading repositories…") }
                if let error {
                    ErrorNotice(message: error)
                    Button("Retry") { Task { await load(reset: page == 0) } }
                    Button("Account settings") { showingSettings = true }
                }
                if visible.isEmpty && !busy && error == nil {
                    ContentUnavailableView("No matching repositories", systemImage: "folder", description: Text(search.isEmpty ? "GitHub hasn't returned any repositories for this list. Check your connection's repository access if something is missing." : "Try a different filter or load more repositories."))
                }
                if more && !busy { Button("Load more repositories") { Task { await load(reset: false) } } }
            } footer: {
                if showsActions { Text("Choose a repository to see its workflow runs, jobs, and artifacts.") }
            }
        }
        .navigationTitle(showsActions ? "Repository Actions" : source.title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Filter loaded repositories")
        .task(id: store.account) { await load(reset: true) }
        .refreshable { await load(reset: true) }
        .sheet(isPresented: $showingSettings, onDismiss: { Task { await load(reset: true) } }) { SettingsView() }
    }

    private func load(reset: Bool) async {
        if !reset && busy { return }
        let id = UUID(), account = store.account
        requestID = id
        busy = true
        error = nil
        if reset { entries = []; page = 0; more = false }
        let nextPage = page + 1
        defer { if requestID == id { busy = false } }
        do {
            let result = try await store.client.accountRepositories(source, page: nextPage)
            guard !Task.isCancelled, requestID == id, account == store.account else { return }
            entries += result.filter { item in !entries.contains { $0.id == item.id } }
            page = nextPage
            more = result.count == 30
        } catch { if !Task.isCancelled, requestID == id, account == store.account { self.error = error.localizedDescription } }
    }
}

@MainActor
struct OrganizationListView: View {
    var login: String? = nil
    @Environment(ForgeStore.self) private var store
    @State private var entries: [GitHubAccount] = []
    @State private var page = 0
    @State private var more = false
    @State private var busy = false
    @State private var error: String?
    @State private var requestID = UUID()
    @State private var showingSettings = false

    var body: some View {
        List {
            Section {
                ForEach(entries) { organization in
                    NavigationLink { AccountRepositoriesView(collection: .organization(organization.login)) } label: {
                        HStack(spacing: 12) {
                            Avatar(login: organization.login)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(organization.login)
                                if let description = organization.description {
                                    Text(description).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }.padding(.vertical, 4)
                    }
                }
                if busy { ProgressView("Loading organizations…") }
                if let error {
                    ErrorNotice(message: error)
                    Button("Retry") { Task { await load(reset: page == 0) } }
                    Button("Account settings") { showingSettings = true }
                }
                if entries.isEmpty && !busy && error == nil {
                    ContentUnavailableView("No organizations to show", systemImage: "person.3", description: Text("No memberships are visible to this GitHub connection."))
                }
                if more && !busy { Button("Load more organizations") { Task { await load(reset: false) } } }
            } footer: { Text("Only memberships and repositories visible to your GitHub connection are shown.") }
        }
        .navigationTitle("Organizations").navigationBarTitleDisplayMode(.inline)
        .task(id: store.account) { await load(reset: true) }
        .refreshable { await load(reset: true) }
        .sheet(isPresented: $showingSettings, onDismiss: { Task { await load(reset: true) } }) { SettingsView() }
    }

    private func load(reset: Bool) async {
        if !reset && busy { return }
        let id = UUID(), account = store.account
        requestID = id
        busy = true
        error = nil
        if reset { entries = []; page = 0; more = false }
        let nextPage = page + 1
        defer { if requestID == id { busy = false } }
        do {
            let result = try await store.client.organizations(login: login, page: nextPage)
            guard !Task.isCancelled, requestID == id, account == store.account else { return }
            entries += result.filter { item in !entries.contains { $0.id == item.id } }
            page = nextPage
            more = result.count == 30
        } catch { if !Task.isCancelled, requestID == id, account == store.account { self.error = error.localizedDescription } }
    }
}
