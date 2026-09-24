import SwiftUI

@MainActor
struct CreateBranchView: View {
    let repository: Repository
    @Environment(ForgeStore.self) private var store
    @State private var name = ""
    @State private var source = ""
    @State private var created: GitReference?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            if !store.hasToken { ConnectGitHubNotice() }
            else if let created {
                Section {
                    Label("Branch created", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(created.ref.replacingOccurrences(of: "refs/heads/", with: "")).font(.headline.monospaced()).textSelection(.enabled)
                    Text("From \(source) at \(created.object.sha.prefix(12))").font(.caption.monospaced()).foregroundStyle(.secondary)
                    Button("Create another branch") { self.created = nil; name = "" }
                } header: { Text(repository.fullName).textCase(nil) }
            } else {
                Section {
                    TextField("New branch name", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Source branch", text: $source).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !name.isEmpty && !GitReference.validBranchName(name) { Text("Use a short Git branch name such as feature/fix. Spaces and reserved Git characters aren't allowed.").font(.caption).foregroundStyle(.secondary) }
                } header: { Text(repository.fullName).textCase(nil) }
                  footer: { Text("The new branch starts at the source branch's current commit. Creating it may start the repository's workflows. You need Contents write access; existing branches are never overwritten.") }
                  .disabled(busy)
                Button("Create branch") { Task { await create() } }.disabled(busy || !GitReference.validBranchName(name) || !GitReference.validBranchName(source))
                if busy { ProgressView("Contacting GitHub...") }
                if let error { ErrorNotice(message: error) }
            }
        }
        .navigationTitle("Create branch").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(busy)
        .task(id: store.account) {
            guard store.hasToken, source.isEmpty else { return }
            busy = true
            defer { busy = false }
            do {
                struct Info: Decodable { let defaultBranch: String }
                let info: Info = try await store.client.get("/repos/\(repository.fullName)")
                source = info.defaultBranch
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }

    private func create() async {
        guard !busy else { return }; busy = true; error = nil
        defer { busy = false }
        do { created = try await store.client.createBranch(in: repository, name: name, source: source) }
        catch { self.error = error.localizedDescription }
    }
}

@MainActor
struct WatchConversation: View {
    let nodeID: String
    let refreshID: UUID
    @Environment(ForgeStore.self) private var store
    @State private var state: SubscriptionState?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Section {
            if let state, state != .unavailable {
                Button { Task { await update() } } label: {
                    Label(state == .subscribed ? "Unwatch conversation" : "Watch conversation", systemImage: state == .subscribed ? "bell.slash" : "bell")
                }.disabled(busy)
                if state == .subscribed { Text("Watching on GitHub").font(.caption).foregroundStyle(.secondary) }
            } else if state == .unavailable { Text("Watching is unavailable for this conversation.").foregroundStyle(.secondary) }
            if busy { ProgressView("Checking subscription...") }
            if let error { ErrorNotice(message: error); Button("Check watch status") { Task { await load() } }.disabled(busy) }
        } footer: { Text("Updates follow your GitHub notification settings. Refresh Forge's Inbox to see them. Phone push alerts aren't available yet.") }
        .task(id: refreshID) { await load() }
    }

    private func load() async {
        guard !busy else { return }; busy = true; error = nil
        defer { busy = false }
        do { state = try await store.client.subscription(id: nodeID) }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    private func update() async {
        guard !busy, let state, state != .unavailable else { return }; busy = true; error = nil
        defer { busy = false }
        do { self.state = try await store.client.setSubscription(id: nodeID, state: state == .subscribed ? .unsubscribed : .subscribed) }
        catch { self.state = nil; self.error = error.localizedDescription }
    }
}

@MainActor
struct PullRequestActionsView: View {
    let repository: Repository
    let number: Int
    @Environment(ForgeStore.self) private var store
    @State private var pull: Conversation?
    @State private var settings: RepositoryMergeSettings?
    @State private var method = MergeMethod.merge
    @State private var review = false
    @State private var confirmMerge = false
    @State private var busy = false
    @State private var merged = false
    @State private var reviewed = false
    @State private var error: String?
    private var canMerge: Bool {
        !busy && !merged && pull?.state == "open" && pull?.draft != true && pull?.mergeable == true && pull?.head?.sha != nil && settings?.permissions?.push == true && (settings?.methods.contains(method) ?? false)
    }

    var body: some View {
        List {
            if !store.hasToken { ConnectGitHubNotice() }
            else {
                if let pull {
                    Section {
                        Text(pull.title).font(.headline)
                        LabeledContent("Status", value: merged ? "Merged" : pull.status)
                        if let head = pull.head, let base = pull.base { Text("\(head.ref) → \(base.ref)").font(.subheadline.monospaced()) }
                        if let sha = pull.head?.sha { LabeledContent("Commit", value: String(sha.prefix(12))).font(.caption.monospaced()) }
                    } header: { Text("\(repository.fullName) #\(String(number))").textCase(nil) }
                    Section("Review") {
                        Button("Submit a review") { review = true }.disabled(busy || merged || pull.state != "open" || pull.head?.sha == nil)
                        NavigationLink("Review conversations") { ReviewThreadsView(repository: repository, number: number) }
                        if reviewed { Label("Review submitted", systemImage: "checkmark.circle").foregroundStyle(.green) }
                    }
                    if !merged && pull.mergedAt == nil {
                        Section {
                            if let settings, !settings.methods.isEmpty {
                                Picker("Merge method", selection: $method) { ForEach(settings.methods, id: \.self) { Text($0.title).tag($0) } }.disabled(busy)
                            }
                            LabeledContent("Merge status", value: (pull.mergeableState ?? "checking").replacingOccurrences(of: "_", with: " ").capitalized)
                            if pull.draft == true { Text("This pull request is still a draft.").foregroundStyle(.secondary) }
                            if pull.mergeable == nil { Text("GitHub is calculating mergeability. Refresh in a moment.").foregroundStyle(.secondary) }
                            if pull.mergeable == false { Text("This pull request has conflicts. Resolve them in the repository before merging.").foregroundStyle(.secondary) }
                            if settings?.permissions?.push != true { Text("Merging requires write access to this repository.").foregroundStyle(.secondary) }
                            Button(method.title) { confirmMerge = true }.disabled(!canMerge)
                        } header: { Text("Merge") }
                          footer: { Text("GitHub enforces repository rules and required checks. Forge merges only the commit shown above; refresh if the branch changes.") }
                    }
                }
                if busy { ProgressView("Updating pull request...") }
                if let error { ErrorNotice(message: error) }
                Button("Refresh status") { Task { await load() } }.disabled(busy)
            }
        }
        .navigationTitle("Review & merge").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(busy)
        .task { await load() }
        .refreshable { await store.client.clearCache(); await load() }
        .sheet(isPresented: $review) {
            if let sha = pull?.head?.sha { ReviewComposer(repository: repository, number: number, sha: sha) { reviewed = true } }
        }
        .confirmationDialog("Merge \(repository.fullName) #\(String(number))?", isPresented: $confirmMerge, titleVisibility: .visible) {
            Button(method.title) { Task { await merge() } }
        } message: { Text("\(pull?.head?.ref ?? "") into \(pull?.base?.ref ?? "") at commit \(String((pull?.head?.sha ?? "").prefix(12))). This changes the repository.") }
    }

    private func load() async {
        guard !busy, store.hasToken else { return }; busy = true; error = nil; settings = nil
        defer { busy = false }
        do {
            pull = try await store.client.conversation(kind: .pullRequest, in: repository, number: number)
            merged = pull?.mergedAt != nil
            let fetched: RepositoryMergeSettings = try await store.client.get("/repos/\(repository.fullName)")
            settings = fetched
            if !fetched.methods.contains(method), let first = fetched.methods.first { method = first }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    private func merge() async {
        guard canMerge, let sha = pull?.head?.sha else { return }; busy = true; error = nil
        defer { busy = false }
        do { try await store.client.mergePullRequest(in: repository, number: number, sha: sha, method: method); merged = true }
        catch { self.error = error.localizedDescription; settings = nil }
    }
}

@MainActor
private struct ReviewComposer: View {
    let repository: Repository
    let number: Int
    let sha: String
    let onSubmitted: () -> Void
    @Environment(ForgeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var event = ReviewEvent.comment
    @State private var text = ""
    @State private var busy = false
    @State private var discard = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("\(repository.fullName) #\(String(number))").font(.subheadline)
                    Text("Reviewing commit \(sha.prefix(12))").font(.caption.monospaced()).foregroundStyle(.secondary)
                    Picker("Review", selection: $event) { ForEach(ReviewEvent.allCases, id: \.self) { Text($0.title).tag($0) } }.disabled(busy)
                    TextEditor(text: $text).frame(minHeight: 180).accessibilityLabel("Review comment").disabled(busy)
                }
                if busy { ProgressView("Submitting review...") }
                if let error { ErrorNotice(message: error) }
            }
            .navigationTitle("Review pull request").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if text.isEmpty { dismiss() } else { discard = true } }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") { Task { await submit() } }.disabled(busy || (event != .approve && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
            .confirmationDialog("Discard this review draft?", isPresented: $discard, titleVisibility: .visible) { Button("Discard draft", role: .destructive) { dismiss() } }
            .interactiveDismissDisabled(busy || !text.isEmpty)
        }
    }
    private func submit() async {
        guard !busy else { return }; busy = true; error = nil
        defer { busy = false }
        do { try await store.client.submitReview(in: repository, number: number, sha: sha, event: event, body: text); onSubmitted(); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

@MainActor
struct ReviewThreadsView: View {
    let repository: Repository
    let number: Int
    @Environment(ForgeStore.self) private var store
    @State private var threads: [ReviewThread] = []
    @State private var cursor: String?
    @State private var more = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        List {
            if !store.hasToken { ConnectGitHubNotice() }
            else {
                ForEach(threads) { thread in
                    NavigationLink { ReviewThreadView(thread: thread) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(thread.path).font(.subheadline.monospaced())
                            HStack {
                                Text(thread.isResolved ? "Resolved" : "Unresolved").foregroundStyle(thread.isResolved ? Color.green : Color.secondary)
                                if let line = thread.line { Text("Line \(line)") }
                            }.font(.caption)
                        }
                    }
                }
                if busy { ProgressView("Loading conversations...") }
                if threads.isEmpty && !busy && error == nil { Text("No review conversations yet.").foregroundStyle(.secondary) }
                if let error { ErrorNotice(message: error); Button("Retry") { Task { await load(reset: false) } } }
                if more && !busy { Button("Load more") { Task { await load(reset: false) } } }
            }
        }.navigationTitle("Review conversations").navigationBarTitleDisplayMode(.inline)
        .task { await load(reset: true) }
        .refreshable { await store.client.clearCache(); await load(reset: true) }
    }

    private func load(reset: Bool) async {
        guard !busy, store.hasToken else { return }; busy = true; error = nil
        defer { busy = false }
        if reset { threads = []; cursor = nil; more = false }
        do {
            let result = try await store.client.reviewThreads(in: repository, number: number, cursor: cursor)
            guard !Task.isCancelled else { return }
            threads += result.items.filter { item in !threads.contains { $0.id == item.id } }
            cursor = result.cursor; more = result.more
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

@MainActor
private struct ReviewThreadView: View {
    let thread: ReviewThread
    @Environment(ForgeStore.self) private var store
    @State private var comments: [ConversationComment] = []
    @State private var status: ReviewThreadState?
    @State private var cursor: String?
    @State private var more = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Text(thread.path).font(.subheadline.monospaced()).textSelection(.enabled)
                if let status {
                    Label(status.isResolved ? "Resolved" : "Unresolved", systemImage: status.isResolved ? "checkmark.circle" : "bubble.left")
                    Button(status.isResolved ? "Unresolve conversation" : "Resolve conversation") { Task { await resolve() } }
                        .disabled(busy || !(status.isResolved ? status.viewerCanUnresolve : status.viewerCanResolve))
                }
            }
            Section("Comments") { ForEach(comments) { CommentView(comment: $0) } }
            if busy { ProgressView("Loading...") }
            if let error { ErrorNotice(message: error); Button("Refresh") { Task { await load(reset: true) } }.disabled(busy) }
            if more && !busy { Button("Load more comments") { Task { await load(reset: false) } } }
        }.navigationTitle("Review conversation").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(busy)
        .task { await load(reset: true) }
        .refreshable { await store.client.clearCache(); await load(reset: true) }
    }

    private func load(reset: Bool) async {
        guard !busy else { return }; busy = true; error = nil
        defer { busy = false }
        if reset { comments = []; cursor = nil; more = false }
        do {
            let result = try await store.client.reviewThreadComments(id: thread.id, cursor: cursor)
            guard !Task.isCancelled else { return }
            status = result.state
            comments += result.comments.items.filter { item in !comments.contains { $0.id == item.id } }
            cursor = result.comments.cursor; more = result.comments.more
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    private func resolve() async {
        guard !busy, let status, status.isResolved ? status.viewerCanUnresolve : status.viewerCanResolve else { return }; busy = true; error = nil
        defer { busy = false }
        do { self.status = try await store.client.setReviewThreadResolved(id: thread.id, resolved: !status.isResolved) }
        catch { self.error = error.localizedDescription; self.status = nil }
    }
}
