import SwiftUI

@MainActor
struct PinnedRepositoriesView: View {
    let login: String
    @Environment(ForgeStore.self) private var store
    let highlights: ProfileHighlights?
    var body: some View {
        Section("Pinned") {
            if let highlights {
                ForEach(highlights.pinnedItems.nodes.compactMap { $0 }) { item in
                    if let repo = try? Repository(item.nameWithOwner) {
                        NavigationLink { RepositoryView(repository: repo) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(item.nameWithOwner, image: "octicon-repo").font(.headline)
                                if let description = item.description { Text(description).font(.subheadline).foregroundStyle(.secondary).lineLimit(3) }
                                Label(item.stargazerCount.formatted(), systemImage: "star").font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 8)
                        }
                    }
                }
                if highlights.pinnedItems.nodes.isEmpty { Text("No pinned repositories.").foregroundStyle(.secondary) }
            } else if !store.hasToken { Text("Connect GitHub to see pinned repositories.").foregroundStyle(.secondary) }
            else { Text("Pinned repositories unavailable. Pull to refresh.").foregroundStyle(.secondary) }
        }
    }
}

@MainActor
struct ProfileReadmeView: View {
    let login: String
    @Environment(ForgeStore.self) private var store
    @State private var branch: RepositoryBranch?
    @State private var unavailable = false
    private var repository: Repository? { try? Repository("\(login)/\(login)") }
    var body: some View {
        Section("Profile README") {
            if let repository, let branch { ReadmeCard(repository: repository, branch: branch, canEdit: login.lowercased() == store.account.lowercased()) { Task { await load() } }.listRowInsets(EdgeInsets()) }
            else if unavailable { Text("This profile has no accessible README.").font(.footnote).foregroundStyle(.secondary) }
            else { ProgressView() }
        }.task(id: store.account) { await load() }
    }
    private func load() async {
        guard let repository else { return }
        do {
            let info: RepositoryOverview = try await store.client.get("/repos/\(repository.fullName)")
            let ref: GitReference = try await store.client.get("/repos/\(repository.fullName)/git/ref/heads/\(info.defaultBranch)")
            guard !Task.isCancelled else { return }; branch = RepositoryBranch(name: info.defaultBranch, commit: .init(sha: ref.object.sha)); unavailable = false
        } catch { if !Task.isCancelled { unavailable = true } }
    }
}

@MainActor
struct ProfileEditor: View {
    let original: GitHubAccount
    let onSaved: () -> Void
    @Environment(ForgeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var fields: [String: String] = [:]
    @State private var hireable = false
    @State private var loaded = false
    @State private var busy = false
    @State private var error: String?
    @State private var discard = false
    private let names = [("name", "Name"), ("bio", "Bio"), ("blog", "Website"), ("company", "Company"), ("location", "Location"), ("twitter_username", "Social handle")]
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(names, id: \.0) { key, title in TextField(title, text: Binding(get: { fields[key] ?? "" }, set: { fields[key] = $0 }), axis: key == "bio" ? .vertical : .horizontal).disabled(busy) }
                    Toggle("Available for hire", isOn: $hireable).disabled(busy)
                } footer: { Text("These are public profile details. Editing requires Profile write permission, or the user scope on a classic token.") }
                if let error { ErrorNotice(message: error) }
            }.navigationTitle("Edit profile").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { discard = true }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { busy = true; error = nil; defer { busy = false }; do { try await store.client.editProfile(original: original, fields: fields, hireable: hireable); onSaved(); dismiss() } catch { self.error = error.localizedDescription } } }.disabled(busy) }
            }.interactiveDismissDisabled()
            .confirmationDialog("Discard profile changes?", isPresented: $discard, titleVisibility: .visible) { Button("Discard", role: .destructive) { dismiss() } }
            .onAppear { if !loaded { fields = ["name": original.name ?? "", "bio": original.bio ?? "", "blog": original.blog ?? "", "company": original.company ?? "", "location": original.location ?? "", "twitter_username": original.twitterUsername ?? ""]; hireable = original.hireable ?? false; loaded = true } }
        }
    }
}
