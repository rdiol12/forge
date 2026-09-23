import SwiftUI

@MainActor
struct ConversationListView: View {
    let kind: ConversationKind
    var repository: Repository? = nil
    @Environment(ForgeStore.self) private var store
    @State private var items: [Conversation] = []
    @State private var search = ""
    @State private var submitted = ""
    @State private var filter = "open"
    @State private var page = 0
    @State private var cursor: String?
    @State private var more = false
    @State private var busy = false
    @State private var error: String?
    @State private var requestID = UUID()
    @State private var compose = false
    @State private var created: Conversation?
    @State private var showCreated = false
    private var needsAccount: Bool { !store.hasToken && (repository == nil || kind == .discussion) }

    var body: some View {
        List {
            if needsAccount { ConnectGitHubNotice() }
            else {
                if kind != .discussion {
                    Picker("State", selection: $filter) {
                        Text("Open").tag("open"); Text("Closed").tag("closed"); Text("All").tag("all")
                    }.pickerStyle(.segmented).listRowBackground(Color.clear)
                }
                Section {
                    ForEach(items) { item in
                        if let repo = item.repository {
                            NavigationLink { ConversationDetailView(repository: repo, number: item.number, kind: kind) } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Octicon(kind.icon).foregroundStyle(item.status == "Open" ? Color.green : Color.purple)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("\(repo.fullName) #\(String(item.number))").font(.caption).foregroundStyle(.secondary)
                                        Text(item.title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                                        HStack {
                                            Text(item.user?.login ?? "Deleted user")
                                            Spacer()
                                            if let date = item.updatedAt { Text(date, style: .relative) }
                                        }.font(.caption).foregroundStyle(.secondary)
                                    }
                                }.padding(.vertical, 5)
                            }
                        }
                    }
                    if busy { ProgressView("Loading \(kind.title.lowercased())...") }
                    if let error {
                        ErrorNotice(message: error)
                        Button("Retry") { Task { await load(reset: page == 0) } }
                    }
                    if items.isEmpty && !busy && error == nil { ContentUnavailableView("No matching \(kind.title.lowercased())", systemImage: "text.bubble") }
                    if more && !busy { Button("Load more") { Task { await load(reset: false) } } }
                } header: { Text(repository?.fullName ?? "Your conversations").textCase(nil) }
                  footer: { Text("Search uses GitHub's search syntax. Narrow the query to find older results beyond GitHub's 1,000-result search limit.") }
            }
        }
        .navigationTitle(kind.title)
        .searchable(text: $search, prompt: "Search \(kind.title.lowercased())")
        .onSubmit(of: .search) { submitted = search.trimmingCharacters(in: .whitespacesAndNewlines) }
        .task(id: submitted + filter + store.account) { await load(reset: true) }
        .refreshable { await load(reset: true) }
        .toolbar { if kind == .issue { Button { compose = true } label: { Label("New issue", systemImage: "square.and.pencil") } } }
        .sheet(isPresented: $compose) { IssueComposer(repository: repository) { created = $0; showCreated = true } }
        .navigationDestination(isPresented: $showCreated) {
            if let created, let repo = created.repository { ConversationDetailView(repository: repo, number: created.number, kind: .issue) }
        }
    }

    private func load(reset: Bool) async {
        if !reset && busy { return }
        let id = UUID(); requestID = id
        error = nil
        if reset { items = []; page = 0; cursor = nil; more = false }
        guard !needsAccount else { busy = false; return }
        busy = true
        defer { if requestID == id { busy = false } }
        do {
            let result = try await store.client.conversations(kind: kind, repository: repository, account: store.account, search: submitted, state: filter, page: page + 1, cursor: cursor)
            guard !Task.isCancelled, requestID == id else { return }
            items += result.items.filter { item in !items.contains { $0.id == item.id } }
            page += 1; cursor = result.cursor; more = result.more
        } catch { if !Task.isCancelled && requestID == id { self.error = error.localizedDescription } }
    }
}

@MainActor
struct ConversationDetailView: View {
    let repository: Repository
    let number: Int
    let kind: ConversationKind
    @Environment(ForgeStore.self) private var store
    @State private var item: Conversation?
    @State private var comments: [ConversationComment] = []
    @State private var page = 0
    @State private var cursor: String?
    @State private var more = false
    @State private var busy = false
    @State private var error: String?
    @State private var watchRefresh = UUID()
    @State private var compose = false
    @State private var edit = false

    var body: some View {
        List {
            if kind == .discussion && !store.hasToken { ConnectGitHubNotice() }
            else {
                if let item {
                    Section {
                        Text(item.title).font(.title2.bold()).textSelection(.enabled)
                        HStack {
                            Text(item.status).font(.subheadline.weight(.semibold)).foregroundStyle(item.status == "Open" ? .green : .purple)
                            if let category = item.category { Text(category.name).font(.subheadline).foregroundStyle(.secondary) }
                        }
                        CommentAuthor(login: item.user?.login, date: item.createdAt)
                        if let head = item.head, let base = item.base { Text("\(head.ref) → \(base.ref)").font(.caption.monospaced()).foregroundStyle(.secondary) }
                        MarkdownText(text: item.body ?? "No description provided.")
                    } header: { Text("\(repository.fullName) #\(String(number))").textCase(nil) }
                    if kind == .pullRequest {
                        Section {
                            NavigationLink("Files changed") { PullFilesView(repository: repository, number: number) }
                            NavigationLink("Reviews") { PullCommentsView(repository: repository, number: number, reviews: true) }
                            NavigationLink("Code review comments") { PullCommentsView(repository: repository, number: number, reviews: false) }
                            NavigationLink("Review & merge") { PullRequestActionsView(repository: repository, number: number) }
                        }
                    }
                    if store.hasToken, let id = item.nodeId { WatchConversation(nodeID: id, refreshID: watchRefresh) }
                    Section("Conversation") {
                        ForEach(comments) { comment in
                            CommentView(comment: comment)
                            if kind == .discussion, let discussionID = item.nodeId, let id = comment.nodeId {
                                NavigationLink("\(comment.replies?.totalCount ?? 0) replies · Reply") { DiscussionRepliesView(discussionID: discussionID, commentID: id) }
                            }
                        }
                        if comments.isEmpty && !busy && error == nil { Text("No comments yet.").foregroundStyle(.secondary) }
                        if more && !busy { Button("Load more comments") { Task { await load(reset: false) } } }
                    }
                }
                if busy { ProgressView("Loading conversation...") }
                if let error {
                    ErrorNotice(message: error)
                    Button("Retry") { Task { await load(reset: item == nil) } }
                }
            }
        }
        .navigationTitle("#\(String(number))").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let item {
                ShareLink(item: item.htmlUrl)
                if store.hasToken {
                    Button { compose = true } label: { Label("Comment", systemImage: "square.and.pencil") }
                    if kind == .issue { Button("Edit") { edit = true } }
                }
            }
        }
        .sheet(isPresented: $compose) {
            CommentComposer(title: kind == .discussion ? "Discussion reply" : "Comment", context: "\(repository.fullName) #\(number)") { body in
                if kind == .discussion, let id = item?.nodeId { try await store.client.replyToDiscussion(id: id, replyTo: nil, body: body) }
                else if kind != .discussion { try await store.client.addComment(in: repository, number: number, body: body) }
                else { throw GitHubError("Refresh this discussion before replying.") }
                await load(reset: true)
            }
        }
        .sheet(isPresented: $edit) { IssueEditor(repository: repository, number: number) { Task { await load(reset: true) } } }
        .task(id: store.account) { await load(reset: true) }
        .refreshable { await load(reset: true) }
    }

    private func load(reset: Bool) async {
        guard !busy, kind != .discussion || store.hasToken else { return }
        busy = true; error = nil
        defer { busy = false }
        if reset { comments = []; page = 0; cursor = nil; more = false }
        do {
            if reset || item == nil {
                let fetched = try await store.client.conversation(kind: kind, in: repository, number: number)
                guard !Task.isCancelled else { return }
                item = fetched
                watchRefresh = UUID()
            }
            let fetched: [ConversationComment]
            if kind == .discussion {
                let result = try await store.client.discussionComments(in: repository, number: number, cursor: cursor)
                guard !Task.isCancelled else { return }
                fetched = result.items; more = result.more; cursor = result.cursor
            } else {
                fetched = try await store.client.get("/repos/\(repository.fullName)/issues/\(number)/comments", page: page + 1, count: 30)
                guard !Task.isCancelled else { return }
                more = fetched.count == 30
            }
            comments += fetched.filter { new in !comments.contains { $0.id == new.id } }; page += 1
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

struct MarkdownText: View {
    let text: String
    var body: some View {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
            .font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CommentAuthor: View {
    let login: String?
    let date: Date?
    var body: some View {
        HStack(spacing: 8) {
            if let login { Avatar(login: login, size: 24) }
            Text(login ?? "Deleted user").font(.subheadline.weight(.semibold))
            Spacer()
            if let date { Text(date, style: .relative).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct CommentView: View {
    let comment: ConversationComment
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CommentAuthor(login: comment.user?.login, date: comment.createdAt ?? comment.submittedAt)
            if comment.isAnswer == true { Label("Accepted answer", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.subheadline) }
            if let state = comment.state { Text(state.replacingOccurrences(of: "_", with: " ").capitalized).font(.caption.weight(.semibold)) }
            if let path = comment.path { Text(path).font(.caption.monospaced()).textSelection(.enabled) }
            if let diff = comment.diffHunk { ScrollView(.horizontal) { Text(diff).font(.caption.monospaced()).textSelection(.enabled).fixedSize() } }
            if let body = comment.body, !body.isEmpty { MarkdownText(text: body) }
        }.padding(.vertical, 8)
    }
}

@MainActor
private struct DiscussionRepliesView: View {
    let discussionID: String
    let commentID: String
    @Environment(ForgeStore.self) private var store
    @State private var comments: [ConversationComment] = []
    @State private var cursor: String?
    @State private var more = false
    @State private var busy = false
    @State private var error: String?
    @State private var compose = false
    var body: some View {
        List {
            ForEach(comments) { CommentView(comment: $0) }
            if busy { ProgressView("Loading replies...") }
            if let error { ErrorNotice(message: error); Button("Retry") { Task { await load() } } }
            if more && !busy { Button("Load more replies") { Task { await load() } } }
        }.navigationTitle("Replies").navigationBarTitleDisplayMode(.inline)
        .task { if comments.isEmpty { await load() } }
        .toolbar { Button("Reply") { compose = true }.disabled(!store.hasToken) }
        .sheet(isPresented: $compose) {
            CommentComposer(title: "Reply", context: "Reply to this discussion comment") { body in
                try await store.client.replyToDiscussion(id: discussionID, replyTo: commentID, body: body)
                comments = []; cursor = nil; more = false; await load()
            }
        }
    }
    private func load() async {
        guard !busy else { return }; busy = true; error = nil
        defer { busy = false }
        do {
            let result = try await store.client.discussionReplies(commentID: commentID, cursor: cursor)
            guard !Task.isCancelled else { return }
            comments += result.items.filter { new in !comments.contains { $0.id == new.id } }
            cursor = result.cursor; more = result.more
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

@MainActor
private struct PullCommentsView: View {
    let repository: Repository
    let number: Int
    let reviews: Bool
    @Environment(ForgeStore.self) private var store
    @State private var comments: [ConversationComment] = []
    @State private var page = 0
    @State private var more = false
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        List {
            ForEach(comments) { CommentView(comment: $0) }
            if comments.isEmpty && !busy && error == nil { Text("No \(reviews ? "reviews" : "review comments") yet.").foregroundStyle(.secondary) }
            if busy { ProgressView("Loading...") }
            if let error { ErrorNotice(message: error); Button("Retry") { Task { await load() } } }
            if more && !busy { Button("Load more") { Task { await load() } } }
        }.navigationTitle(reviews ? "Reviews" : "Review comments").navigationBarTitleDisplayMode(.inline)
        .task { if page == 0 { await load() } }
    }
    private func load() async {
        guard !busy else { return }; busy = true; error = nil
        defer { busy = false }
        do {
            let fetched: [ConversationComment] = try await store.client.get("/repos/\(repository.fullName)/pulls/\(number)/\(reviews ? "reviews" : "comments")", page: page + 1, count: 30)
            guard !Task.isCancelled else { return }
            comments += fetched.filter { new in !comments.contains { $0.id == new.id } }; page += 1; more = fetched.count == 30
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

@MainActor
private struct PullFilesView: View {
    let repository: Repository
    let number: Int
    @Environment(ForgeStore.self) private var store
    @State private var files: [PullFile] = []
    @State private var page = 0
    @State private var more = false
    @State private var busy = false
    @State private var error: String?
    @State private var sha: String?
    var body: some View {
        List {
            ForEach(files) { file in
                NavigationLink {
                    PullDiffView(repository: repository, number: number, file: file, sha: sha)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(file.filename).font(.subheadline.monospaced())
                        HStack { Text(file.status.capitalized).foregroundStyle(.secondary); Text("+\(file.additions)").foregroundStyle(.green); Text("−\(file.deletions)").foregroundStyle(.red) }.font(.caption)
                    }
                }
            }
            if busy { ProgressView("Loading changed files...") }
            if let error { ErrorNotice(message: error); Button("Retry") { Task { await load() } } }
            if more && !busy { Button("Load more files") { Task { await load() } } }
            if files.count >= 3000 { Text("GitHub returns at most 3,000 changed files per pull request.").font(.footnote).foregroundStyle(.secondary) }
        }.navigationTitle("Files changed").navigationBarTitleDisplayMode(.inline)
        .task { if page == 0 { await load() } }
        .refreshable { if !busy { files = []; page = 0; sha = nil; await load() } }
    }
    private func load() async {
        guard !busy else { return }; busy = true; error = nil
        defer { busy = false }
        do {
            let before = try await store.client.conversation(kind: .pullRequest, in: repository, number: number)
            guard let revision = before.head?.sha, sha == nil || sha == revision else { throw GitHubError("This pull request changed. Pull to refresh its files before reviewing.") }
            let fetched: [PullFile] = try await store.client.get("/repos/\(repository.fullName)/pulls/\(number)/files", page: page + 1, count: 100)
            let after = try await store.client.conversation(kind: .pullRequest, in: repository, number: number)
            guard revision == after.head?.sha else { throw GitHubError("This pull request changed while loading. Pull to refresh.") }
            guard !Task.isCancelled else { return }
            sha = revision
            files += fetched.filter { new in !files.contains { $0.id == new.id } }; page += 1; more = fetched.count == 100 && files.count < 3000
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

@MainActor
struct ConnectGitHubNotice: View {
    @State private var settings = false
    var body: some View {
        ContentUnavailableView {
            Label("Connect your GitHub account", systemImage: "person.crop.circle")
        } description: {
            Text("Native conversations use Forge's GitHub connection. Signing into a website in the browser doesn't connect these screens.")
        } actions: { Button("Account settings") { settings = true }.buttonStyle(.borderedProminent) }
        .sheet(isPresented: $settings) { SettingsView() }
    }
}
