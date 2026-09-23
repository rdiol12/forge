import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum ConversationKind: String, CaseIterable, Sendable {
    case issue, pullRequest, discussion
    var title: String { switch self { case .issue: "Issues"; case .pullRequest: "Pull Requests"; case .discussion: "Discussions" } }
    var icon: String { switch self { case .issue: "issue-opened"; case .pullRequest: "git-pull-request"; case .discussion: "comment-discussion" } }
    var path: String { switch self { case .issue: "issues"; case .pullRequest: "pull"; case .discussion: "discussions" } }
}

enum GitHubRoute: Equatable, Sendable {
    case profile(String)
    case repositories(RepositoryCollection)
    case organizations
    case actions(Repository)
    case releases(Repository)
    case repository(Repository)
    case conversations(Repository, ConversationKind)
    case conversation(Repository, Int, ConversationKind)

    init?(_ url: URL) {
        guard url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        if parts == ["settings", "organizations"] { self = .organizations; return }
        if parts.count == 3, parts[0] == "orgs", parts[2] == "repositories", GitHubAccount.validLogin(parts[1]) {
            self = .repositories(.organization(parts[1])); return
        }
        let reserved = ["settings", "orgs", "organizations", "login", "logout", "join", "account", "apps", "site", "features", "sponsors", "dashboard", "explore", "marketplace", "notifications", "issues", "pulls", "search", "copilot", "topics", "trending", "collections", "security", "pricing", "about", "contact", "enterprise", "new"]
        guard let owner = parts.first, !reserved.contains(owner.lowercased()), GitHubAccount.validLogin(owner) else { return nil }
        if parts.count == 1 {
            let tabs = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "tab" } ?? []
            guard tabs.count <= 1 else { return nil }
            switch tabs.first?.value {
            case nil, "overview": self = .profile(owner)
            case "repositories": self = .repositories(.user(owner))
            case "stars": self = .repositories(.stars(owner))
            default: return nil
            }
            return
        }
        guard parts.count >= 2,
              let repo = try? Repository(parts[0] + "/" + parts[1]) else { return nil }
        if parts.count == 2 { self = .repository(repo); return }
        if parts.count == 3, parts[2] == "actions" { self = .actions(repo); return }
        if parts.count == 3, parts[2] == "releases" { self = .releases(repo); return }
        let kind: ConversationKind
        switch parts[2] {
        case "issues": kind = .issue
        case "pull", "pulls": kind = .pullRequest
        case "discussions": kind = .discussion
        default: return nil
        }
        if parts.count == 3 { self = .conversations(repo, kind); return }
        guard let number = Int(parts[3]), number > 0 else { return nil }
        self = .conversation(repo, number, kind)
    }
}

struct GitHubAuthor: Decodable, Sendable { let login: String }
struct Conversation: Decodable, Identifiable, Sendable {
    struct Branch: Decodable, Sendable { let ref: String; let sha: String? }
    struct Category: Decodable, Sendable { let name: String }
    struct RepositoryInfo: Decodable, Sendable { let nameWithOwner: String }
    let number: Int
    let nodeId: String?
    let title: String
    let body: String?
    let htmlUrl: URL
    let user: GitHubAuthor?
    let state: String?
    let createdAt: Date?
    let updatedAt: Date?
    let mergedAt: Date?
    let closed: Bool?
    let isAnswered: Bool?
    let category: Category?
    let repositoryInfo: RepositoryInfo?
    let head: Branch?
    let base: Branch?
    let draft: Bool?
    let mergeable: Bool?
    let mergeableState: String?
    var id: String { htmlUrl.absoluteString }
    var status: String { mergedAt != nil ? "Merged" : isAnswered == true ? "Answered" : closed == true ? "Closed" : (state ?? "Open").capitalized }
    var repository: Repository? {
        // Organization Discussions use /orgs/... URLs; their repository comes from GraphQL.
        if let name = repositoryInfo?.nameWithOwner { return try? Repository(name) }
        guard case let .conversation(repo, _, _) = GitHubRoute(htmlUrl) else { return nil }
        return repo
    }
}

struct ConversationComment: Decodable, Identifiable, Sendable {
    let nodeId: String?
    let htmlUrl: URL
    let body: String?
    let user: GitHubAuthor?
    let createdAt: Date?
    let submittedAt: Date?
    let state: String?
    let path: String?
    let diffHunk: String?
    let isAnswer: Bool?
    let replies: ReplyCount?
    struct ReplyCount: Decodable, Sendable { let totalCount: Int }
    var id: String { htmlUrl.absoluteString }
}

struct PullFile: Decodable, Identifiable, Sendable {
    let filename: String
    let status: String
    let additions: Int
    let deletions: Int
    let patch: String?
    var id: String { filename }
}

struct ConversationPage: Sendable { let items: [Conversation]; let more: Bool; let cursor: String? }
struct CommentPage: Sendable { let items: [ConversationComment]; let more: Bool; let cursor: String? }
struct GraphQLConnection<Node: Decodable>: Decodable {
    struct PageInfo: Decodable { let hasNextPage: Bool; let endCursor: String? }
    let nodes: [Node?]
    let pageInfo: PageInfo
}
private struct GraphQLResponse<Value: Decodable>: Decodable {
    struct Failure: Decodable { let message: String }
    let data: Value?
    let errors: [Failure]?
    private enum CodingKeys: String, CodingKey { case data, errors }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        errors = try values.decodeIfPresent([Failure].self, forKey: .errors)
        data = (errors ?? []).isEmpty ? try values.decodeIfPresent(Value.self, forKey: .data) : nil
    }
}

extension GitHubClient {
    func codeText(in repository: Repository, file: RepositoryFile) async throws -> String {
        // ponytail: inline text is capped at 1 MiB; larger or binary files use the existing download/Quick Look flow.
        guard file.type == "file", file.safePath else { throw GitHubError("This entry is a link or submodule, not a regular file.") }
        guard file.size >= 0, file.size <= 1_048_576 else { throw GitHubError("This file is too large for the code reader. Download it to preview or save it.") }
        guard file.sha.range(of: #"^(?:[a-fA-F0-9]{40}|[a-fA-F0-9]{64})$"#, options: .regularExpression) != nil else { throw GitHubError("GitHub returned an invalid file revision.") }
        struct Blob: Decodable { let content: String; let encoding: String; let size: Int }
        let blob: Blob = try await get("/repos/\(repository.fullName)/git/blobs/\(file.sha)")
        guard blob.encoding == "base64", blob.size <= 1_048_576,
              let data = Data(base64Encoded: blob.content.filter { !$0.isWhitespace }), data.count == blob.size,
              !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw GitHubError("This file is binary or isn't UTF-8 text. Download it for a native preview.")
        }
        return text
    }

    func graphQLRequest(_ query: String, variables: [String: Any]) throws -> URLRequest {
        guard !token.isEmpty else { throw GitHubError("Connect GitHub in Settings to use this feature. Website sign-in doesn't connect the native API.") }
        var request = try request("/graphql")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        return request
    }

    func graphQL<T: Decodable>(_ query: String, variables: [String: Any]) async throws -> T {
        let (data, response) = try await session.data(for: graphQLRequest(query, variables: variables))
        try Self.validate(response)
        let result = try Self.decoder().decode(GraphQLResponse<T>.self, from: data)
        if let failure = result.errors?.first { throw GitHubError("GitHub: \(failure.message)") }
        guard let result = result.data else { throw GitHubError("GitHub didn't return the requested information.") }
        return result
    }

    private static let discussionFields = "nodeId:id number title body htmlUrl:url user:author{login} createdAt updatedAt closed isAnswered category{name} repositoryInfo:repository{nameWithOwner}"
    private static let commentFields = "nodeId:id htmlUrl:url body user:author{login} createdAt isAnswer replies{totalCount}"

    func conversations(kind: ConversationKind, repository: Repository?, account: String, search: String, state: String, page: Int, cursor: String?) async throws -> ConversationPage {
        guard repository != nil || (!token.isEmpty && !account.isEmpty) else { throw GitHubError("Connect GitHub in Settings to see your conversations, or open a public repository from Favorites.") }
        let scope = repository.map { "repo:\($0.fullName)" } ?? "involves:\(account)"
        if kind == .discussion {
            struct Result: Decodable { let search: GraphQLConnection<Conversation> }
            let result: Result = try await graphQL("""
            query($q:String!,$cursor:String){search(query:$q,type:DISCUSSION,first:30,after:$cursor){nodes{... on Discussion{\(Self.discussionFields)}}pageInfo{hasNextPage endCursor}}}
            """, variables: ["q": "\(scope) \(search) sort:updated", "cursor": cursor as Any? ?? NSNull()])
            return ConversationPage(items: result.search.nodes.compactMap { $0 }, more: result.search.pageInfo.hasNextPage, cursor: result.search.pageInfo.endCursor)
        }
        struct Result: Decodable { let items: [Conversation] }
        let filter = state == "open" || state == "closed" ? "is:\(state)" : ""
        let query = "is:\(kind == .issue ? "issue" : "pr") \(scope) \(filter) \(search)"
        let result: Result = try await get("/search/issues", page: page, count: 30, query: [URLQueryItem(name: "q", value: query), URLQueryItem(name: "sort", value: "updated"), URLQueryItem(name: "order", value: "desc")])
        // ponytail: GitHub search caps results at 1,000; narrow the search to find older conversations.
        return ConversationPage(items: result.items, more: result.items.count == 30 && page < 34, cursor: nil)
    }

    func conversation(kind: ConversationKind, in repository: Repository, number: Int) async throws -> Conversation {
        guard number > 0 else { throw GitHubError("Invalid conversation number.") }
        if kind != .discussion { return try await get("/repos/\(repository.fullName)/\(kind == .issue ? "issues" : "pulls")/\(number)") }
        struct Result: Decodable {
            struct Repo: Decodable { let discussion: Conversation? }
            let repository: Repo?
        }
        let parts = repository.fullName.split(separator: "/").map(String.init)
        let result: Result = try await graphQL("query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){discussion(number:$number){\(Self.discussionFields)}}}", variables: ["owner": parts[0], "name": parts[1], "number": number])
        guard let conversation = result.repository?.discussion else { throw GitHubError("Discussion not found, or your account cannot access it.") }
        return conversation
    }

    func discussionComments(in repository: Repository, number: Int, cursor: String?) async throws -> CommentPage {
        struct Result: Decodable {
            struct Repo: Decodable {
                struct Discussion: Decodable { let comments: GraphQLConnection<ConversationComment> }
                let discussion: Discussion?
            }
            let repository: Repo?
        }
        let parts = repository.fullName.split(separator: "/").map(String.init)
        let result: Result = try await graphQL("query($owner:String!,$name:String!,$number:Int!,$cursor:String){repository(owner:$owner,name:$name){discussion(number:$number){comments(first:30,after:$cursor){nodes{\(Self.commentFields)}pageInfo{hasNextPage endCursor}}}}}", variables: ["owner":parts[0],"name":parts[1],"number":number,"cursor":cursor as Any? ?? NSNull()])
        guard let comments = result.repository?.discussion?.comments else { throw GitHubError("Discussion comments are unavailable.") }
        return CommentPage(items: comments.nodes.compactMap { $0 }, more: comments.pageInfo.hasNextPage, cursor: comments.pageInfo.endCursor)
    }

    func discussionReplies(commentID: String, cursor: String?) async throws -> CommentPage {
        struct Result: Decodable {
            struct Node: Decodable { let replies: GraphQLConnection<ConversationComment> }
            let node: Node?
        }
        let result: Result = try await graphQL("query($id:ID!,$cursor:String){node(id:$id){... on DiscussionComment{replies(first:30,after:$cursor){nodes{\(Self.commentFields)}pageInfo{hasNextPage endCursor}}}}}", variables: ["id":commentID,"cursor":cursor as Any? ?? NSNull()])
        guard let replies = result.node?.replies else { throw GitHubError("Discussion replies are unavailable.") }
        return CommentPage(items: replies.nodes.compactMap { $0 }, more: replies.pageInfo.hasNextPage, cursor: replies.pageInfo.endCursor)
    }
}
