import SwiftUI

@MainActor
struct CommentComposer: View {
    let title: String
    let context: String
    let submit: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var busy = false
    @State private var error: String?
    @State private var discard = false
    var body: some View {
        NavigationStack {
            Form {
                Section { Text(context).font(.caption).textSelection(.enabled); TextEditor(text: $text).frame(minHeight: 200).accessibilityLabel("Comment").disabled(busy) }
                if busy { ProgressView("Sending…") }
                if let error { ErrorNotice(message: error) }
            }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if text.isEmpty { dismiss() } else { discard = true } }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { Task { busy = true; error = nil; defer { busy = false }; do { try await submit(text); dismiss() } catch { self.error = error.localizedDescription } } }
                        .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.interactiveDismissDisabled(busy || !text.isEmpty)
            .confirmationDialog("Discard comment draft?", isPresented: $discard, titleVisibility: .visible) { Button("Discard", role: .destructive) { dismiss() } }
        }
    }
}

@MainActor
struct IssueEditor: View {
    let repository: Repository
    let number: Int
    let onSaved: () -> Void
    @Environment(ForgeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var original: IssueEditDetails?
    @State private var title = ""
    @State private var text = ""
    @State private var labels: Set<String> = []
    @State private var assignees: Set<String> = []
    @State private var availableLabels: [IssueEditDetails.Label] = []
    @State private var availableAssignees: [GitHubAccount] = []
    @State private var manage = false
    @State private var canEdit = false
    @State private var busy = false
    @State private var error: String?
    @State private var discard = false
    var body: some View {
        NavigationStack {
            Form {
                if original != nil {
                    Section("Issue") { TextField("Title", text: $title, axis: .vertical); TextEditor(text: $text).frame(minHeight: 180).accessibilityLabel("Issue description") }.disabled(!canEdit || busy)
                    if manage {
                        Section("Labels") { ForEach(availableLabels) { label in Toggle(label.name, isOn: Binding(get: { labels.contains(label.name) }, set: { if $0 { labels.insert(label.name) } else { labels.remove(label.name) } })) } }.disabled(busy)
                        Section("Assignees") { ForEach(availableAssignees) { person in Toggle(person.login, isOn: Binding(get: { assignees.contains(person.login) }, set: { if $0 { assignees.insert(person.login) } else { assignees.remove(person.login) } })) } }.disabled(busy)
                    }
                    if !canEdit && !manage { Text("GitHub requires the issue author or a repository collaborator to edit this issue.").foregroundStyle(.secondary) }
                }
                if busy { ProgressView("Updating issue…") }
                if let error { ErrorNotice(message: error) }
                if original == nil && !busy { Button("Retry") { Task { await load() } } }
            }.navigationTitle("Edit issue #\(number)").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { discard = true }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(busy || original == nil || (!canEdit && !manage) || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }.interactiveDismissDisabled()
            .confirmationDialog("Discard issue edits?", isPresented: $discard, titleVisibility: .visible) { Button("Discard", role: .destructive) { dismiss() } }
            .task { await load() }
        }
    }
    private func load() async {
        guard !busy else { return }; busy = true; error = nil
        defer { busy = false }
        do {
            let item: IssueEditDetails = try await store.client.get("/repos/\(repository.fullName)/issues/\(number)")
            let settings: RepositorySettings = try await store.client.get("/repos/\(repository.fullName)")
            original = item; title = item.title; text = item.body ?? ""; labels = Set(item.labels.map(\.name)); assignees = Set(item.assignees.map(\.login))
            manage = settings.canManageIssues
            canEdit = manage || item.user?.login.lowercased() == store.account.lowercased()
            availableLabels = item.labels; availableAssignees = item.assignees
            if manage {
                var page = 1
                while true {
                    let result: [IssueEditDetails.Label] = try await store.client.get("/repos/\(repository.fullName)/labels", page: page)
                    availableLabels += result.filter { next in !availableLabels.contains { $0.id == next.id } }; page += 1
                    if result.count < 100 { break }; try Task.checkCancellation()
                }
                page = 1
                while true {
                    let result: [GitHubAccount] = try await store.client.get("/repos/\(repository.fullName)/assignees", page: page)
                    availableAssignees += result.filter { next in !availableAssignees.contains { $0.id == next.id } }; page += 1
                    if result.count < 100 { break }; try Task.checkCancellation()
                }
            }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private func save() async {
        guard let original, !busy else { return }; busy = true; error = nil
        defer { busy = false }
        do { try await store.client.editIssue(in: repository, number: number, original: original, title: title, body: text, labels: manage ? labels.sorted() : nil, assignees: manage ? assignees.sorted() : nil); onSaved(); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

@MainActor
struct PullDiffView: View {
    let repository: Repository
    let number: Int
    let file: PullFile
    let sha: String?
    @Environment(ForgeStore.self) private var store
    @State private var selected: DiffLine?
    @State private var sent = false
    private var lines: [DiffLine] { DiffLine.parse(file.patch ?? "") }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("+\(file.additions)").foregroundStyle(.green); Text("−\(file.deletions)").foregroundStyle(.red); Spacer(); if sent { Label("Comment sent", systemImage: "checkmark.circle").foregroundStyle(.green) } }.font(.caption).padding()
            if let sha { Text("Commit \(sha.prefix(12)) · Tap + beside a line to comment").font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        HStack(alignment: .top, spacing: 10) {
                            if line.commentLine != nil && sha != nil && store.hasToken {
                                Button { selected = line } label: { Image(systemName: "plus.bubble") }.frame(width: 24)
                                    .accessibilityLabel("Comment on \(line.side == .left ? "old" : "new") line \(line.commentLine ?? 0)")
                            } else { Color.clear.frame(width: 24, height: 16) }
                            Text(line.oldLine.map(String.init) ?? "").frame(width: 38, alignment: .trailing).foregroundStyle(.secondary)
                            Text(line.newLine.map(String.init) ?? "").frame(width: 38, alignment: .trailing).foregroundStyle(.secondary)
                            Text(line.text).textSelection(.enabled).fixedSize().frame(maxWidth: .infinity, alignment: .leading)
                        }.font(.system(.caption, design: .monospaced)).padding(.vertical, 4).padding(.horizontal, 8)
                            .background(line.text.hasPrefix("+") ? Color.green.opacity(0.12) : line.text.hasPrefix("-") ? Color.red.opacity(0.12) : line.text.hasPrefix("@@") ? Color.blue.opacity(0.12) : Color.clear)
                    }
                }
            }
            if file.patch == nil { ContentUnavailableView("No text diff", systemImage: "doc", description: Text("GitHub omitted this patch. Binary and some large changes have no text preview.")) }
        }.navigationTitle(file.filename).navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selected) { line in
            if let sha, let position = line.commentLine {
                CommentComposer(title: "Line comment", context: "\(file.filename):\(position)\n\(line.text)") { body in
                    try await store.client.commentOnLine(in: repository, number: number, sha: sha, path: file.filename, line: position, side: line.side, body: body); sent = true
                }
            }
        }
    }
}
