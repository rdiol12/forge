import SwiftUI

@MainActor
struct PeopleListView: View {
    let login: String
    let collection: PeopleCollection
    @Environment(ForgeStore.self) private var store
    @State private var people: [GitHubAccount] = []
    @State private var page = 0
    @State private var more = false
    @State private var busy = false
    @State private var error: String?
    @State private var search = ""
    @State private var requestID = UUID()

    var body: some View {
        List {
            Section {
                ForEach(people.filter { search.isEmpty || "\($0.login) \($0.name ?? "")".localizedCaseInsensitiveContains(search) }) { person in
                    NavigationLink { AccountProfileView(login: person.login) } label: {
                        HStack(spacing: 12) {
                            Avatar(login: person.login, size: 44)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(person.name ?? person.login).font(.headline)
                                if person.name != nil { Text(person.login).font(.subheadline).foregroundStyle(.secondary) }
                            }
                        }.padding(.vertical, 4)
                    }
                }
                if busy { ProgressView("Loading people…") }
                if let error { ErrorNotice(message: error); Button("Retry") { Task { await load(reset: false) } }.disabled(busy) }
                if people.isEmpty && !busy && error == nil { Text("No \(collection.rawValue) yet.").foregroundStyle(.secondary) }
                if more && !busy { Button("Load more people") { Task { await load(reset: false) } } }
            } header: { Text(login).textCase(nil) }
        }.navigationTitle(collection.title)
        .searchable(text: $search, prompt: "Filter loaded people")
        .task(id: store.account) { await load(reset: true) }
        .refreshable { await store.client.clearCache(); await load(reset: true) }
    }

    private func load(reset: Bool) async {
        if !reset && busy { return }
        let id = UUID(); requestID = id; busy = true; error = nil
        if reset { people = []; page = 0; more = false }
        defer { if requestID == id { busy = false } }
        do {
            let result = try await store.client.people(login: login, collection: collection, page: page + 1)
            guard !Task.isCancelled, requestID == id else { return }
            people += result.filter { next in !people.contains { $0.id == next.id } }; page += 1; more = result.count == 30
        } catch { if !Task.isCancelled, requestID == id { self.error = error.localizedDescription } }
    }
}

@MainActor
struct AccountProfileView: View {
    let login: String
    var rootProfile = false
    @Environment(ForgeStore.self) private var store
    @State private var profile: GitHubAccount?
    @State private var highlights: ProfileHighlights?
    @State private var editing = false
    @State private var following: Bool?
    @State private var selectedPeople: PeopleCollection?
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
                    HStack(spacing: 18) {
                        Button { selectedPeople = .followers } label: { Label("\(followers.formatted()) followers", systemImage: "person.2") }
                        Button("\(following.formatted()) following") { selectedPeople = .following }
                    }.buttonStyle(.borderless).font(.subheadline).padding(.vertical, 6)
                }
                if let highlights, !highlights.badges.isEmpty {
                    ScrollView(.horizontal) { HStack { ForEach(highlights.badges, id: \.self) { badge in Label(badge, systemImage: "seal.fill").font(.caption.bold()).padding(8).background(Color.blue.opacity(0.12), in: Capsule()) } } }
                }
                if ownProfile { Button("Edit profile") { editing = true } }
                else if store.hasToken, profile?.type != "Organization", let following {
                    Button(following ? "Unfollow" : "Follow") { Task { busy = true; do { try await store.client.follow(login: login, following: !following); await load() } catch { self.error = error.localizedDescription; busy = false } } }.disabled(busy)
                }
                if busy { ProgressView("Loading profile…") }
                if let error {
                    ErrorNotice(message: error)
                    Button("Retry") { Task { await load() } }
                }
            }
            Section {
                NavigationLink { AccountRepositoriesView(collection: repositories) } label: { WorkLabel("Repositories", icon: "repo", color: Color(white: 0.28)) }
                if ownProfile { NavigationLink { OwnedActionsView() } label: { WorkLabel("Actions", icon: "workflow", color: .blue) } }
                else { NavigationLink { AccountRepositoriesView(collection: repositories, showsActions: true) } label: { WorkLabel("Actions", icon: "workflow", color: .blue) } }
                if profile?.type != "Organization" {
                    NavigationLink { AccountRepositoriesView(collection: ownProfile ? .starred : .stars(login)) } label: { WorkLabel("Starred", icon: "star", color: .orange) }
                    NavigationLink { OrganizationListView(login: ownProfile ? nil : login) } label: { WorkLabel("Organizations", icon: "organization", color: .orange) }
                }
            }
            if profile?.type != "Organization" { PinnedRepositoriesView(login: login, highlights: highlights); ProfileReadmeView(login: login) }
        }
        .navigationTitle(rootProfile ? "Profile" : login).navigationBarTitleDisplayMode(rootProfile ? .large : .inline)
        .task(id: store.account) { await load() }
        .refreshable { await store.client.clearCache(); await load() }
        .navigationDestination(isPresented: Binding(get: { selectedPeople != nil }, set: { if !$0 { selectedPeople = nil } })) { if let selectedPeople { PeopleListView(login: login, collection: selectedPeople) } }
        .sheet(isPresented: $editing) { if let profile { ProfileEditor(original: profile) { Task { await load() } } } }
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
            if result.type != "Organization", store.hasToken {
                do { highlights = try await store.client.profileHighlights(login: login) } catch { self.error = error.localizedDescription }
                if !ownProfile { following = try? await store.client.follows(login: login) }
            }
        } catch { if !Task.isCancelled, requestID == id, account == store.account { self.error = error.localizedDescription } }
    }
}

@MainActor
struct AccountRepositoriesView: View {
    @State private var loadedAccount: String?
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
            if showsActions && collection == .owned && !store.repositories.isEmpty {
                Section("Favorite projects") {
                    ForEach(store.repositories.filter { search.isEmpty || $0.fullName.localizedCaseInsensitiveContains(search) }) { repository in
                        NavigationLink { ActionsView(repository: repository) } label: { RepositoryRow(repository: repository) }
                    }
                }
            }

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
        .navigationTitle(showsActions ? "Actions" : source.title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Filter loaded repositories")
        .task(id: store.account) { if entries.isEmpty || loadedAccount != store.account { await load(reset: true) } }
        .refreshable { await store.client.clearCache(); await load(reset: true) }
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
            loadedAccount = account
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
        .refreshable { await store.client.clearCache(); await load(reset: true) }
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
