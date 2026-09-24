import SwiftUI

@MainActor
struct CommitListView: View {
    let repository: Repository
    let branch: RepositoryBranch
    @Environment(ForgeStore.self) private var store
    @State private var head = ""
    @State private var commits: [HistoryCommit] = []
    @State private var page = 0
    @State private var more = false
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        List {
            Section { Label(branch.name, systemImage: "arrow.triangle.branch"); Text(repository.fullName).font(.caption).foregroundStyle(.secondary) }
            ForEach(commits) { item in
                NavigationLink {
                    CommitDetailView(repository: repository, branch: .init(name: branch.name, commit: .init(sha: head)), sha: item.sha) { Task { await load(reset: true) } }
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.commit.message.components(separatedBy: .newlines).first ?? item.sha).lineLimit(3)
                        Text("\(item.sha.prefix(7)) · \(item.commit.author?.name ?? "Unknown author")").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
            }
            if busy { ProgressView() }
            if let error { ErrorNotice(message: error); Button("Retry") { Task { await load(reset: page == 0) } } }
            if more && !busy { Button("Load more commits") { Task { await load(reset: false) } } }
        }.navigationTitle("Commits").task { await load(reset: true) }
        .refreshable { await store.client.clearCache(); await load(reset: true) }
    }
    private func load(reset: Bool) async {
        guard !busy else { return }; busy = true; error = nil; defer { busy = false }
        do {
            if reset {
                let ref: GitReference = try await store.client.get("/repos/\(repository.fullName)/git/ref/heads/\(branch.name)")
                head = ref.object.sha; page = 0; commits = []
            }
            let rows: [HistoryCommit] = try await store.client.get("/repos/\(repository.fullName)/commits", page: page + 1, count: 30, query: [.init(name: "sha", value: head)])
            guard !Task.isCancelled else { return }; commits += rows.filter { row in !commits.contains { $0.sha == row.sha } }; page += 1; more = rows.count == 30
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

@MainActor
struct CommitDetailView: View {
    let repository: Repository
    let branch: RepositoryBranch
    let sha: String
    let onChanged: () -> Void
    @Environment(ForgeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var commit: HistoryCommit?
    @State private var files: [HistoryCommit.File] = []
    @State private var page = 0
    @State private var more = false
    @State private var canWrite = false
    @State private var busy = false
    @State private var error: String?
    @State private var action: String?
    @State private var typed = ""
    @State private var conflict: HistoryConflict?
    @State private var resolutions: [String: HistoryResolution] = [:]
    var body: some View {
        List {
            if let commit {
                Section {
                    Text(commit.commit.message).textSelection(.enabled)
                    Text(sha).font(.caption.monospaced()).textSelection(.enabled)
                    Label(branch.name, systemImage: "arrow.triangle.branch")
                }
                Section {
                    ForEach(files) { file in
                        DisclosureGroup {
                            if let patch = file.patch {
                                ScrollView(.horizontal) { Text(patch).font(.system(.caption, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: true, vertical: false) }
                            } else { Text("GitHub has no text diff for this file.").foregroundStyle(.secondary) }
                        } label: { VStack(alignment: .leading) { Text(file.filename); Text("\(file.status) · +\(file.additions) −\(file.deletions)").font(.caption).foregroundStyle(.secondary) } }
                    }
                    if more { Button("Load more changed files") { Task { await load() } }.disabled(busy) }
                } header: { Text("Changed files") }
                if canWrite {
                    Section {
                        Button("Undo changes", systemImage: "arrow.uturn.backward") { resolutions = [:]; action = "Undo changes" }
                        Button("Remove from history", systemImage: "trash", role: .destructive) { resolutions = [:]; action = "Remove from history" }
                    } footer: { Text("Undo adds a new commit. Removing rewrites later commits. Separate text edits merge automatically. Overlapping files open a conflict editor. Root commits and merge rewrites require desktop Git. Repository rules still apply.") }
                    .disabled(busy || commit.parents.count != 1)
                }
            }
            if busy { ProgressView("Working…") }
            if let error { ErrorNotice(message: error) }
        }.navigationTitle(String(sha.prefix(7))).task { await load() }
        .sheet(isPresented: Binding(get: { action != nil }, set: { if !$0 && !busy { action = nil } })) {
            NavigationStack {
                Form {
                    Text(action == "Remove from history" ? "Remove \(sha.prefix(7)) from \(branch.name) and replay up to 200 later commits. Later commit IDs change and their original signatures are lost. Collaborators must reconcile their local branches. This does not erase copies in other branches, tags, forks, or GitHub storage." : "Create a new commit on \(branch.name) that undoes \(sha.prefix(7)). Existing history stays available.")
                    Text("If the branch changed or files conflict, Forge stops without moving the branch.")
                    if action == "Remove from history" { TextField("Type \(branch.name) to confirm", text: $typed).textInputAutocapitalization(.never).autocorrectionDisabled() }
                    if let error { ErrorNotice(message: error) }
                    if busy { ProgressView("Updating history…") }
                }.navigationTitle(action ?? "Commit action").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { action = nil; typed = "" }.disabled(busy) }
                    ToolbarItem(placement: .confirmationAction) { Button("Confirm", role: .destructive) { Task { await change() } }.disabled(busy || (action == "Remove from history" && typed != branch.name)) }
                }.interactiveDismissDisabled(busy)
                .sheet(item: $conflict) { item in
                    HistoryConflictEditor(conflict: item) { resolutions[item.id] = $0; error = "Resolution saved. Confirm again to continue; your branch has not changed." }
                }
            }
        }
    }
    private func load() async {
        guard !busy else { return }; busy = true; error = nil; defer { busy = false }
        do {
            let item: HistoryCommit = try await store.client.get("/repos/\(repository.fullName)/commits/\(sha)", page: page + 1, count: 30)
            let info: RepositoryOverview = try await store.client.get("/repos/\(repository.fullName)")
            guard !Task.isCancelled else { return }; commit = item; canWrite = info.permissions?.push == true
            files += (item.files ?? []).filter { file in !files.contains { $0.id == file.id } }; page += 1; more = item.files?.count == 30
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private func change() async {
        busy = true; error = nil; defer { busy = false }
        let account = store.account
        do { _ = try await store.client.changeHistory(in: repository, branch: branch, selected: sha, remove: action == "Remove from history", resolutions: resolutions, saveRecovery: { entry in try await store.saveRecovery(entry, account: account) }); action = nil; onChanged(); dismiss() }
        catch let item as HistoryConflict { conflict = item; error = item.localizedDescription }
        catch { self.error = error.localizedDescription }
    }
}

@MainActor
struct DeletedCommitsView: View {
    var repository: Repository? = nil
    @Environment(ForgeStore.self) private var store
    private var groups: [String] { Array(Set(store.recoveries.filter { repository == nil || $0.repository == repository?.fullName }.map(\.repository))).sorted() }
    var body: some View {
        List {
            Section { Text("Local records from this account's removal attempts. Forge keeps commit IDs, not a permanent backup. Recovery works only while GitHub retains the objects. Removing the app removes these records.").font(.footnote).foregroundStyle(.secondary) }
            ForEach(groups, id: \.self) { name in
                Section(name) {
                    ForEach(store.recoveries.filter { $0.repository == name }.sorted { $0.created > $1.created }) { entry in
                        NavigationLink { CommitRecoveryView(entry: entry) } label: {
                            VStack(alignment: .leading, spacing: 6) { Text(entry.message.components(separatedBy: .newlines).first ?? entry.selected); Text("\(entry.selected.prefix(7)) · \(entry.branch) · \(entry.created.prefix(10))").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            if groups.isEmpty { ContentUnavailableView("No saved commits", systemImage: "clock.arrow.circlepath", description: Text("Commits removed through Forge on this device appear here.")) }
        }.navigationTitle("Deleted commits")
    }
}

@MainActor
private struct CommitRecoveryView: View {
    let entry: CommitRecovery
    @Environment(ForgeStore.self) private var store
    @State private var conflict: HistoryConflict?
    @State private var resolutions: [String: HistoryResolution] = [:]
    @State private var head: String?
    @State private var available = false
    @State private var busy = false
    @State private var message: String?
    @State private var action: String?
    var body: some View {
        List {
            Section {
                Text(entry.message).textSelection(.enabled)
                Text(entry.repository + " · " + entry.branch)
                Text(entry.selected).font(.caption.monospaced()).textSelection(.enabled)
                if busy { ProgressView("Checking recovery…") }
                if let message { Text(message).foregroundStyle(.secondary) }
            }
            if available, head != nil {
                Section {
                    Button("Restore saved history") { action = "Restore saved history" }.disabled(head != entry.newHead || busy)
                    Button("Reapply commit") { action = "Reapply commit" }.disabled(head == entry.oldHead || busy)
                } footer: { Text("Restore returns the branch to its saved history only if it has not moved since removal. Reapply creates a new commit. Separate text edits merge automatically; overlapping files open a conflict editor.") }
            }
            Button("Check again") { Task { await check() } }.disabled(busy)
        }.navigationTitle("Restore commit").task { await check() }
        .sheet(item: $conflict) { item in HistoryConflictEditor(conflict: item) { resolutions[item.id] = $0; message = "Resolution saved. Tap Reapply commit and confirm again to continue." } }
        .confirmationDialog(action ?? "Restore commit", isPresented: Binding(get: { action != nil }, set: { if !$0 { action = nil } }), titleVisibility: .visible) {
            if let selectedAction = action { Button("Confirm") { Task { await restore(reapply: selectedAction == "Reapply commit") } } }
        } message: { Text("This changes \(entry.branch) in \(entry.repository). GitHub permissions and branch rules apply.") }
    }
    private func check() async {
        busy = true; message = nil; available = false; head = nil; defer { busy = false }
        do {
            await store.client.clearCache()
            let _: HistoryCommit = try await store.client.get("/repos/\(entry.repository)/commits/\(entry.selected)")
            available = true
            let ref: GitReference = try await store.client.get("/repos/\(entry.repository)/git/ref/heads/\(entry.branch)")
            head = ref.object.sha
            message = head == entry.oldHead ? "The branch already has its saved history; removal did not finish or it was restored." : "GitHub still has this commit."
        } catch { message = "Recovery unavailable: \(error.localizedDescription) The commit or branch may be gone, or your access may have changed." }
    }
    private func restore(reapply: Bool) async {
        guard let head else { return }; busy = true
        do { try await store.client.restoreHistory(in: Repository(entry.repository), recovery: entry, expected: head, reapply: reapply, resolutions: resolutions); await check(); message = reapply ? "Commit reapplied." : "Saved branch history restored." }
        catch let item as HistoryConflict { conflict = item; message = item.localizedDescription }
        catch { message = error.localizedDescription }; busy = false
    }
}


@MainActor
struct HistoryConflictEditor: View {
    let conflict: HistoryConflict
    let resolved: (HistoryResolution) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var version = 0
    @State private var choice = ""
    @State private var text: String
    init(conflict: HistoryConflict, resolved: @escaping (HistoryResolution) -> Void) {
        self.conflict = conflict; self.resolved = resolved
        _text = State(initialValue: conflict.currentText ?? "")
    }
    private var entry: GitTreeEntry? { version == 0 ? conflict.current : version == 1 ? conflict.requested : conflict.before }
    private var source: String? { version == 0 ? conflict.currentText : version == 1 ? conflict.requestedText : conflict.baseText }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(conflict.path).font(.headline).textSelection(.enabled)
                    Text("No branch was changed. Current is the result built so far; Requested is the complete file from the change being applied. Choosing a whole version can retain changes from the removed commit or discard other edits. Review the file before continuing.").font(.footnote)
                }
                Section("Compare versions") {
                    Picker("Version", selection: $version) { Text("Current").tag(0); Text("Requested").tag(1); Text("Base").tag(2) }.pickerStyle(.segmented)
                    if let source { CodeTextView(text: source, filename: conflict.path).frame(height: 260) }
                    else if let entry { Text("Preview unavailable for this file type or size. Revision: \(entry.sha)").font(.caption).textSelection(.enabled) }
                    else { Text("This version does not contain the file.").foregroundStyle(.secondary) }
                }
                Section("Final result") {
                    Picker("Resolution", selection: $choice) {
                        Text("Choose a resolution").tag("")
                        Text(conflict.current == nil ? "Keep file deleted" : "Keep current file").tag("current")
                        Text(conflict.requested == nil ? "Delete file as requested" : "Use requested file").tag("requested")
                        if conflict.canEdit { Text("Edit final file").tag("edit") }
                    }
                    if choice == "edit" { TextEditor(text: $text).font(.system(.body, design: .monospaced)).frame(minHeight: 260).accessibilityLabel("Final file contents") }
                    Text("The branch is updated only after all conflicts are resolved and you confirm again.").font(.footnote).foregroundStyle(.secondary)
                }
            }.navigationTitle("Resolve file conflict").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Use resolution") {
                    resolved(choice == "current" ? .current : choice == "requested" ? .requested : .edited(text)); dismiss()
                }.disabled(choice.isEmpty || (choice == "edit" && (text.utf8.count > 1_048_576 || text.utf8.contains(0)))) }
            }
        }
    }
}
