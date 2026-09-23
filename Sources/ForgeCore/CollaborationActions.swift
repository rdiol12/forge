import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum ReviewEvent: String, CaseIterable, Sendable {
    case comment = "COMMENT", approve = "APPROVE", requestChanges = "REQUEST_CHANGES"
    var title: String { switch self { case .comment: "Comment"; case .approve: "Approve"; case .requestChanges: "Request changes" } }
}

enum MergeMethod: String, CaseIterable, Sendable {
    case merge, squash, rebase
    var title: String { switch self { case .merge: "Create merge commit"; case .squash: "Squash and merge"; case .rebase: "Rebase and merge" } }
}

struct RepositoryMergeSettings: Decodable, Sendable {
    struct Permissions: Decodable, Sendable { let push: Bool? }
    let permissions: Permissions?
    let allowMergeCommit: Bool?
    let allowSquashMerge: Bool?
    let allowRebaseMerge: Bool?
    var methods: [MergeMethod] {
        MergeMethod.allCases.filter { method in
            switch method { case .merge: allowMergeCommit == true; case .squash: allowSquashMerge == true; case .rebase: allowRebaseMerge == true }
        }
    }
}

enum SubscriptionState: String, Decodable, Sendable {
    case subscribed = "SUBSCRIBED", unsubscribed = "UNSUBSCRIBED", ignored = "IGNORED", unavailable = "UNAVAILABLE"
}

struct ReviewThread: Decodable, Identifiable, Sendable {
    let id: String
    let path: String
    let line: Int?
    let isResolved: Bool
}
struct ReviewThreadState: Decodable, Sendable {
    let isResolved: Bool
    let viewerCanResolve: Bool
    let viewerCanUnresolve: Bool
}
struct ReviewThreadPage: Sendable { let items: [ReviewThread]; let more: Bool; let cursor: String? }
struct ReviewThreadComments: Sendable { let state: ReviewThreadState; let comments: CommentPage }

extension GitHubClient {
    private func mutationData(_ path: String, method: String = "POST", body: [String: Any]) async throws -> Data {
        guard !token.isEmpty else { throw GitHubError("Connect GitHub in Settings before making changes.") }
        var request = try request(path)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw GitHubError("Couldn't confirm the change: \(error.localizedDescription) Refresh the conversation before submitting again; GitHub may already have saved it.") }
        if let status = (response as? HTTPURLResponse)?.statusCode, [400, 405, 409, 422].contains(status) {
            struct Failure: Decodable { let message: String }
            let message = (try? Self.decoder().decode(Failure.self, from: data))?.message ?? "GitHub rejected the change."
            throw GitHubError("\(message) Refresh and check your repository permissions and rules before retrying.")
        }
        try Self.validate(response)
        return data
    }

    func createIssue(in repository: Repository, title: String, body: String) async throws -> Conversation {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw GitHubError("Enter an issue title.") }
        let data = try await mutationData("/repos/\(repository.fullName)/issues", body: ["title": title, "body": body])
        return try Self.decoder().decode(Conversation.self, from: data)
    }

    private func validatePullRevision(number: Int, sha: String) throws {
        guard number > 0, sha.range(of: #"^(?:[a-fA-F0-9]{40}|[a-fA-F0-9]{64})$"#, options: .regularExpression) != nil else {
            throw GitHubError("Refresh the pull request to load its current commit before continuing.")
        }
    }

    func submitReview(in repository: Repository, number: Int, sha: String, event: ReviewEvent, body: String) async throws {
        try validatePullRevision(number: number, sha: sha)
        guard event == .approve || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GitHubError("Add a comment to this review.") }
        _ = try await mutationData("/repos/\(repository.fullName)/pulls/\(number)/reviews", body: ["commit_id": sha, "event": event.rawValue, "body": body])
    }

    func mergePullRequest(in repository: Repository, number: Int, sha: String, method: MergeMethod) async throws {
        try validatePullRevision(number: number, sha: sha)
        let data = try await mutationData("/repos/\(repository.fullName)/pulls/\(number)/merge", method: "PUT", body: ["sha": sha, "merge_method": method.rawValue])
        struct Result: Decodable { let merged: Bool; let message: String? }
        let result = try Self.decoder().decode(Result.self, from: data)
        guard result.merged else { throw GitHubError(result.message ?? "GitHub did not merge this pull request. Refresh to check its status.") }
    }

    func subscription(id: String) async throws -> SubscriptionState {
        struct Result: Decodable {
            struct Node: Decodable { let viewerSubscription: SubscriptionState? }
            let node: Node?
        }
        let result: Result = try await graphQL("query($id:ID!){node(id:$id){... on Subscribable{viewerSubscription}}}", variables: ["id": id])
        guard let state = result.node?.viewerSubscription else { throw GitHubError("Watching is unavailable for this conversation.") }
        return state
    }

    func setSubscription(id: String, state: SubscriptionState) async throws -> SubscriptionState {
        guard !id.isEmpty, state == .subscribed || state == .unsubscribed else { throw GitHubError("Invalid watch setting.") }
        struct Result: Decodable {
            struct Update: Decodable {
                struct Subject: Decodable { let viewerSubscription: SubscriptionState? }
                let subscribable: Subject?
            }
            let updateSubscription: Update?
        }
        let result: Result = try await graphQL("mutation($id:ID!,$state:SubscriptionState!){updateSubscription(input:{subscribableId:$id,state:$state}){subscribable{viewerSubscription}}}", variables: ["id": id, "state": state.rawValue])
        guard let confirmed = result.updateSubscription?.subscribable?.viewerSubscription, confirmed == state else { throw GitHubError("GitHub didn't confirm the watch setting. Refresh to check it.") }
        return confirmed
    }

    func reviewThreads(in repository: Repository, number: Int, cursor: String?) async throws -> ReviewThreadPage {
        struct Result: Decodable {
            struct Repo: Decodable {
                struct Pull: Decodable { let reviewThreads: GraphQLConnection<ReviewThread> }
                let pullRequest: Pull?
            }
            let repository: Repo?
        }
        let parts = repository.fullName.split(separator: "/").map(String.init)
        let result: Result = try await graphQL("query($owner:String!,$name:String!,$number:Int!,$cursor:String){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:30,after:$cursor){nodes{id path line isResolved}pageInfo{hasNextPage endCursor}}}}}", variables: ["owner": parts[0], "name": parts[1], "number": number, "cursor": cursor as Any? ?? NSNull()])
        guard let threads = result.repository?.pullRequest?.reviewThreads else { throw GitHubError("Review conversations are unavailable.") }
        return ReviewThreadPage(items: threads.nodes.compactMap { $0 }, more: threads.pageInfo.hasNextPage, cursor: threads.pageInfo.endCursor)
    }

    func reviewThreadComments(id: String, cursor: String?) async throws -> ReviewThreadComments {
        struct Result: Decodable {
            struct Node: Decodable {
                let isResolved: Bool
                let viewerCanResolve: Bool
                let viewerCanUnresolve: Bool
                let comments: GraphQLConnection<ConversationComment>
            }
            let node: Node?
        }
        let result: Result = try await graphQL("query($id:ID!,$cursor:String){node(id:$id){... on PullRequestReviewThread{isResolved viewerCanResolve viewerCanUnresolve comments(first:30,after:$cursor){nodes{nodeId:id htmlUrl:url body user:author{login} createdAt path diffHunk}pageInfo{hasNextPage endCursor}}}}}", variables: ["id": id, "cursor": cursor as Any? ?? NSNull()])
        guard let thread = result.node else { throw GitHubError("Review conversation not found.") }
        return ReviewThreadComments(state: ReviewThreadState(isResolved: thread.isResolved, viewerCanResolve: thread.viewerCanResolve, viewerCanUnresolve: thread.viewerCanUnresolve), comments: CommentPage(items: thread.comments.nodes.compactMap { $0 }, more: thread.comments.pageInfo.hasNextPage, cursor: thread.comments.pageInfo.endCursor))
    }

    func setReviewThreadResolved(id: String, resolved: Bool) async throws -> ReviewThreadState {
        guard !id.isEmpty else { throw GitHubError("Invalid review conversation.") }
        struct Result: Decodable {
            struct Mutation: Decodable { let thread: ReviewThreadState? }
            let result: Mutation?
        }
        let mutation = resolved ? "resolveReviewThread" : "unresolveReviewThread"
        let result: Result = try await graphQL("mutation($id:ID!){result:\(mutation)(input:{threadId:$id}){thread{isResolved viewerCanResolve viewerCanUnresolve}}}", variables: ["id": id])
        guard let thread = result.result?.thread, thread.isResolved == resolved else { throw GitHubError("GitHub didn't confirm the conversation status. Refresh to check it.") }
        return thread
    }
}
