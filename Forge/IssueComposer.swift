import SwiftUI

enum IssueField: String, CaseIterable, Identifiable { case assignees = "Assignees", labels = "Labels", milestone = "Milestone", project = "Project"; var id: String { rawValue } }

@MainActor
struct IssueComposer: View {
    let repository: Repository?
    let onCreated: (Conversation) -> Void
    @Environment(ForgeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var destination: Repository?
    @State private var title = ""
    @State private var text = ""
    @State private var picks: [String: [IssueOption]] = [:]
    @State private var choosing: IssueField?
    @State private var busy = false
    @State private var discard = false
    @State private var error: String?
    @State private var created: Conversation?
    @State private var metadataWarning: String?
    var body: some View {
        NavigationStack {
            Group {
                if !store.hasToken { List { ConnectGitHubNotice() } }
                else if let destination {
                    Form {
                        HStack { Avatar(login: store.account, size: 30); Text(destination.fullName).font(.subheadline); Spacer() }
                        Section {
                            TextField("Title", text: $title, axis: .vertical).font(.title3.weight(.semibold)).accessibilityLabel("Issue title")
                            TextEditor(text: $text).frame(minHeight: 220).accessibilityLabel("Leave a comment")
                                .overlay(alignment: .topLeading) { if text.isEmpty { Text("Leave a comment").foregroundStyle(.tertiary).padding(.top, 8).allowsHitTesting(false) } }
                        }.disabled(busy || created != nil)
                        if let created { Label("Issue #\(created.number) created", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                        if let error { ErrorNotice(message: error) }
                        if let metadataWarning { ErrorNotice(message: metadataWarning) }
                        if created != nil && error != nil && picks["Project"]?.isEmpty == false { Button("Retry project assignment") { Task { await submit() } }.disabled(busy) }
                        if busy { ProgressView(created == nil ? "Creating issue…" : "Adding to project…") }
                    }.safeAreaInset(edge: .bottom) {
                        ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 10) {
                            ForEach(IssueField.allCases) { field in
                                Button { choosing = field } label: {
                                    Text(field.rawValue + (picks[field.rawValue]?.isEmpty == false ? " · \(picks[field.rawValue]!.count)" : ""))
                                }.buttonStyle(.bordered).disabled(busy || created != nil)
                            }
                        }.padding(12) }.background(.bar)
                    }
                } else { IssueRepositoryPicker { destination = $0 } }
            }.navigationTitle("Create new issue").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(created == nil ? "Cancel" : "Close") {
                        if created != nil { finish() }
                        else if title.isEmpty && text.isEmpty && picks.values.allSatisfy(\.isEmpty) { dismiss() }
                        else { discard = true }
                    }.disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(created == nil ? "Submit" : "Done") { if created != nil { finish() } else { Task { await submit() } } }
                        .disabled(busy || !store.hasToken || destination == nil || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.onAppear { if destination == nil { destination = repository } }
            .interactiveDismissDisabled(busy || !title.isEmpty || !text.isEmpty || picks.values.contains { !$0.isEmpty })
            .confirmationDialog("Discard this issue draft?", isPresented: $discard, titleVisibility: .visible) { Button("Discard draft", role: .destructive) { dismiss() } }
            .sheet(item: $choosing) { field in
                if let destination { IssueOptionPicker(repository: destination, kind: field, selected: Binding(get: { picks[field.rawValue] ?? [] }, set: { picks[field.rawValue] = $0 })) }
            }
        }
    }
    private func submit() async {
        guard let destination, !busy else { return }; busy = true; error = nil; defer { busy = false }
        do {
            if created == nil {
                let fields = IssueFields(title: title, body: text, assignees: (picks["Assignees"] ?? []).map(\.id), labels: (picks["Labels"] ?? []).map(\.id), milestone: picks["Milestone"]?.first.flatMap { Int($0.id) })
                let result = try await store.client.createIssue(in: destination, fields: fields); created = result.0; metadataWarning = result.1
            }
            if let project = picks["Project"]?.first {
                guard let id = created?.nodeId else { throw GitHubError("The issue exists, but its project identifier is unavailable. Open it to check the project.") }
                try await store.client.addIssueToProject(issueID: id, projectID: project.id)
            }
            if metadataWarning == nil { finish() }
        } catch { self.error = (created == nil ? "" : "The issue was created. Project assignment failed; retrying only updates the project. ") + error.localizedDescription }
    }
    private func finish() { if let created { onCreated(created) }; dismiss() }
}

@MainActor
struct IssueRepositoryPicker: View {
    let select: (Repository) -> Void
    @Environment(ForgeStore.self) private var store
    @State private var repos: [RepositorySummary] = []
    @State private var page = 0
    @State private var more = false
    @State private var busy = false
    @State private var error: String?
    @State private var search = ""
    var body: some View {
        List {
            Section("Your repositories") {
                ForEach(repos.filter { search.isEmpty || $0.fullName.localizedCaseInsensitiveContains(search) }) { item in
                    if let repository = try? Repository(item.fullName) { Button { select(repository) } label: { RepositoryRow(repository: repository) }.foregroundStyle(.primary) }
                }
                if busy { ProgressView() }
                if let error { ErrorNotice(message: error); Button("Retry") { Task { await load() } } }
                if more && !busy { Button("Load more repositories") { Task { await load() } } }
            }
            Section("Favorites") {
                ForEach(store.repositories.filter { search.isEmpty || $0.fullName.localizedCaseInsensitiveContains(search) }) { repo in Button { select(repo) } label: { RepositoryRow(repository: repo) }.foregroundStyle(.primary) }
                if store.repositories.isEmpty { Text("No favorites yet.").foregroundStyle(.secondary) }
            }
        }.searchable(text: $search, prompt: "Choose a repository").task { await load() }
    }
    private func load() async {
        guard !busy else { return }; busy = true; error = nil; defer { busy = false }
        do { let result = try await store.client.accountRepositories(.owned, page: page + 1); repos += result.filter { row in !repos.contains { $0.id == row.id } }; page += 1; more = result.count == 30 }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

@MainActor
struct IssueOptionPicker: View {
    let repository: Repository
    let kind: IssueField
    @Binding var selected: [IssueOption]
    @Environment(ForgeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var items: [IssueOption] = []
    @State private var page = 0
    @State private var cursor: String?
    @State private var more = false
    @State private var busy = false
    @State private var error: String?
    @State private var search = ""
    var body: some View {
        NavigationStack {
            List {
                if !selected.isEmpty { Button("Clear selection") { selected = [] } }
                ForEach(items.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { item in
                    Button { toggle(item) } label: {
                        HStack { VStack(alignment: .leading) { Text(item.title); if !item.detail.isEmpty { Text(item.detail).font(.caption).foregroundStyle(.secondary) } }; Spacer(); if selected.contains(where: { $0.id == item.id }) { Image(systemName: "checkmark") } }
                    }
                }
                if busy { ProgressView() }
                if let error { ErrorNotice(message: error); Button("Retry") { Task { await load() } } }
                if more && !busy { Button("Load more") { Task { await load() } } }
                if items.isEmpty && !busy && error == nil { Text(kind == .project ? "No accessible projects are linked to this repository." : "Nothing available.").foregroundStyle(.secondary) }
            }.navigationTitle(kind.rawValue).navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Filter loaded options")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }.task { await load() }
        }
    }
    private func toggle(_ item: IssueOption) {
        if selected.contains(where: { $0.id == item.id }) { selected.removeAll { $0.id == item.id } }
        else if kind == .assignees || kind == .labels { if kind != .assignees || selected.count < 10 { selected.append(item) } }
        else { selected = [item] }
    }
    private func load() async {
        guard !busy else { return }; busy = true; error = nil; defer { busy = false }
        do { let result = try await store.client.issueOptions(in: repository, kind: kind.rawValue, page: page + 1, cursor: cursor); items += result.items.filter { row in !items.contains { $0.id == row.id } }; more = result.more; cursor = result.cursor; page += 1 }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
