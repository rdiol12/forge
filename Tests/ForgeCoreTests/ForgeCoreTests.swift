import XCTest
@testable import ForgeCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ForgeCoreTests: XCTestCase {
    func testProfileAndRepositoryActivityLinksHaveNativeDestinations() throws {
        let repo = try Repository("owner/repo")
        let destinations: [(String, GitHubRoute)] = [
            ("/octocat", .profile("octocat")), ("/octocat?tab=repositories", .repositories(.user("octocat"))),
            ("/octocat?tab=stars", .repositories(.stars("octocat"))), ("/settings/organizations", .organizations),
            ("/orgs/github/repositories", .repositories(.organization("github"))),
            ("/owner/repo/actions", .actions(repo)), ("/owner/repo/releases", .releases(repo))
        ]
        for (path, destination) in destinations {
            XCTAssertEqual(GitHubRoute(URL(string: "https://github.com" + path)!), destination, path)
        }
        for path in ["/settings/tokens", "/login", "/dashboard", "/octocat?tab=unknown", "/octocat?tab=stars&tab=repositories"] {
            XCTAssertNil(GitHubRoute(URL(string: "https://github.com" + path)!), path)
        }
    }

    func testOwnRepositoriesIncludePrivateReposAndUseAuthenticatedPagination() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/user/repos")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "affiliation" }?.value, "owner")
            XCTAssertEqual(query.first { $0.name == "visibility" }?.value, "all")
            XCTAssertEqual(query.first { $0.name == "page" }?.value, "2")
            XCTAssertEqual(query.first { $0.name == "per_page" }?.value, "30")
            return (200, "[{\"id\":1,\"full_name\":\"owner/private-repo\",\"private\":true,\"stargazers_count\":0}]")
        }
        let result = try await GitHubClient(token: "test-only", session: session).accountRepositories(.owned, page: 2)
        XCTAssertEqual(result.first?.fullName, "owner/private-repo")
        StubURLProtocol.handler = { _ in XCTFail("A disconnected account must not request private repositories"); return (200, "[]") }
        do { _ = try await GitHubClient(session: session).accountRepositories(.owned, page: 1); XCTFail() } catch {}
    }

    func testNativeProfileStarsAndOrganizationsUseGitHubData() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = GitHubClient(token: "test-only", session: session)
        StubURLProtocol.handler = { request in
            switch request.url!.path {
            case "/user": return (200, "{\"id\":1,\"login\":\"owner\",\"name\":\"Owner\",\"bio\":null,\"followers\":2,\"public_repos\":5}")
            case "/user/starred": return (200, "[{\"id\":9,\"full_name\":\"org/starred\",\"stargazers_count\":7}]")
            case "/user/orgs": return (200, "[{\"id\":2,\"login\":\"org\",\"description\":\"Our team\"}]")
            case "/orgs/org/repos": return (200, "[{\"id\":8,\"full_name\":\"org/project\",\"stargazers_count\":0}]")
            default: XCTFail("Unexpected account endpoint"); return (404, "{}")
            }
        }
        let profile = try await client.profile()
        XCTAssertEqual(profile.login, "owner")
        XCTAssertEqual(profile.name, "Owner")
        XCTAssertNil(profile.bio)
        let stars = try await client.accountRepositories(.starred, page: 1)
        XCTAssertEqual(stars.first?.fullName, "org/starred")
        let organizations = try await client.organizations(page: 1)
        XCTAssertEqual(organizations.first?.login, "org")
        let repos = try await client.accountRepositories(.organization("org"), page: 1)
        XCTAssertEqual(repos.first?.fullName, "org/project")
        StubURLProtocol.handler = { _ in XCTFail("Invalid account paths must not reach GitHub"); return (200, "[]") }
        do { _ = try await client.accountRepositories(.organization("../user"), page: 1); XCTFail() } catch {}
    }

    func testActionsCanPageThroughAnyAccessibleRepository() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/repos/owner/unfavorited/actions/runs")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "page" }?.value, "2")
            return (200, "{\"workflow_runs\":[{\"id\":42,\"display_title\":\"Build\",\"head_sha\":\"abc\",\"status\":\"completed\",\"conclusion\":\"success\",\"run_number\":12,\"run_attempt\":1,\"html_url\":\"https://github.com/owner/unfavorited/actions/runs/42\",\"created_at\":\"2026-09-23T09:00:00Z\",\"updated_at\":\"2026-09-23T09:01:00Z\"}]}")
        }
        let runs = try await GitHubClient(token: "test-only", session: session).runs(in: Repository("owner/unfavorited"), page: 2)
        XCTAssertEqual(runs.first?.id, 42)
        XCTAssertEqual(runs.first?.state, .passed)
    }

    func testNotificationReadSyncRequiresSuccessAndAValidThreadID() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = GitHubClient(token: "test-only", session: session)
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(request.url?.path, "/notifications/threads/123")
            return (205, "")
        }
        try await client.markNotificationRead(id: "123")
        StubURLProtocol.handler = { _ in (403, "{}") }
        do { try await client.markNotificationRead(id: "123"); XCTFail("Denied updates must stay unread") } catch {}
        StubURLProtocol.handler = { _ in XCTFail("Invalid IDs must never reach the API"); return (205, "") }
        do { try await client.markNotificationRead(id: "../1"); XCTFail() } catch {}
    }

    func testBranchCreationUsesTheNamedSourceCommitAndNeverOverwritesARef() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = GitHubClient(token: "test-only", session: session)
        let sha = String(repeating: "c", count: 40)
        StubURLProtocol.handler = { request in
            if request.httpMethod == "GET" {
                XCTAssertEqual(request.url?.path, "/repos/owner/repo/git/ref/heads/release/stable")
                return (200, "{\"ref\":\"refs/heads/release/stable\",\"object\":{\"type\":\"commit\",\"sha\":\"\(sha)\"}}")
            }
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/repos/owner/repo/git/refs")
            let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String:String]
            XCTAssertEqual(body["ref"], "refs/heads/feature/fix")
            XCTAssertEqual(body["sha"], sha)
            XCTAssertNil(body["force"])
            return (201, "{\"ref\":\"refs/heads/feature/fix\",\"object\":{\"type\":\"commit\",\"sha\":\"\(sha)\"}}")
        }
        let result = try await client.createBranch(in: Repository("owner/repo"), name: "feature/fix", source: "release/stable")
        XCTAssertEqual(result.object.sha, sha)
        StubURLProtocol.handler = { _ in XCTFail("An invalid destination must not be submitted"); return (200, "{}") }
        for invalid in ["", "../bad", "refs/tags/v1", "feature//bad", "a.lock", "has space"] {
            do { _ = try await client.createBranch(in: Repository("owner/repo"), name: invalid, source: "main"); XCTFail(invalid) } catch {}
        }
    }

    func testWatchingUsesGitHubSubscriptionAndDoesNotTreatErrorsAsSuccess() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = GitHubClient(token: "test-only", session: session)
        StubURLProtocol.handler = { request in
            let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String:Any]
            XCTAssertTrue((body["query"] as! String).contains("updateSubscription"))
            let variables = body["variables"] as! [String:String]
            XCTAssertEqual(variables["id"], "issue-node")
            XCTAssertEqual(variables["state"], "SUBSCRIBED")
            return (200, "{\"data\":{\"updateSubscription\":{\"subscribable\":{\"viewerSubscription\":\"SUBSCRIBED\"}}}}")
        }
        let state = try await client.setSubscription(id: "issue-node", state: .subscribed)
        XCTAssertEqual(state, .subscribed)
        StubURLProtocol.handler = { _ in (200, "{\"data\":null,\"errors\":[{\"message\":\"Access denied\"}]}") }
        do { _ = try await client.setSubscription(id: "issue-node", state: .unsubscribed); XCTFail() }
        catch let error as GitHubError { XCTAssertTrue(error.message.contains("Access denied")) }
    }

    func testIssueCreationAndReviewsSendOnlyExplicitUserContent() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = GitHubClient(token: "test-only", session: session)
        let repo = try Repository("owner/repo")
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/repos/owner/repo/issues")
            let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String:Any]
            XCTAssertEqual(body["title"] as? String, "New issue")
            XCTAssertEqual(body["body"] as? String, "User-written details")
            return (201, "{\"number\":8,\"title\":\"New issue\",\"html_url\":\"https://github.com/owner/repo/issues/8\"}")
        }
        let issue = try await client.createIssue(in: repo, title: " New issue ", body: "User-written details")
        XCTAssertEqual(issue.number, 8)
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/repos/owner/repo/pulls/8/reviews")
            let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String:Any]
            XCTAssertEqual(body["event"] as? String, "REQUEST_CHANGES")
            XCTAssertEqual(body["commit_id"] as? String, String(repeating: "a", count: 40))
            return (200, "{}")
        }
        try await client.submitReview(in: repo, number: 8, sha: String(repeating: "a", count: 40), event: .requestChanges, body: "Please fix the test")
        StubURLProtocol.handler = { _ in XCTFail("Missing review text must fail before sending"); return (200, "{}") }
        do { try await client.submitReview(in: repo, number: 8, sha: String(repeating: "a", count: 40), event: .requestChanges, body: " "); XCTFail() } catch {}
    }

    func testMergePinsTheReviewedSHAAndRejectsChangedOrUnmergedResponses() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = GitHubClient(token: "test-only", session: session)
        let repo = try Repository("owner/repo")
        let sha = String(repeating: "b", count: 40)
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/repos/owner/repo/pulls/4/merge")
            let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String:String]
            XCTAssertEqual(body["sha"], sha)
            XCTAssertEqual(body["merge_method"], "squash")
            return (409, "{\"message\":\"Head changed\"}")
        }
        do { try await client.mergePullRequest(in: repo, number: 4, sha: sha, method: .squash); XCTFail() }
        catch let error as GitHubError { XCTAssertTrue(error.message.contains("changed")) }
        StubURLProtocol.handler = { _ in (200, "{\"merged\":false,\"message\":\"Branch protection blocked this merge\"}") }
        do { try await client.mergePullRequest(in: repo, number: 4, sha: sha, method: .merge); XCTFail() }
        catch let error as GitHubError { XCTAssertTrue(error.message.contains("blocked")) }
        StubURLProtocol.handler = { _ in (200, "{\"merged\":true,\"message\":\"Merged\"}") }
        try await client.mergePullRequest(in: repo, number: 4, sha: sha, method: .rebase)
        StubURLProtocol.handler = { _ in XCTFail("Writes need an API connection"); return (200, "{}") }
        do { try await GitHubClient(session: session).mergePullRequest(in: repo, number: 4, sha: sha, method: .merge); XCTFail() } catch {}
    }

    func testResolveReviewThreadUsesItsNodeIDAndReturnedPermissions() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        StubURLProtocol.handler = { request in
            let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String:Any]
            XCTAssertTrue((body["query"] as! String).contains("resolveReviewThread"))
            XCTAssertEqual((body["variables"] as! [String:String])["id"], "thread-id")
            return (200, "{\"data\":{\"result\":{\"thread\":{\"isResolved\":true,\"viewerCanResolve\":false,\"viewerCanUnresolve\":true}}}}")
        }
        let result = try await GitHubClient(token: "test-only", session: session).setReviewThreadResolved(id: "thread-id", resolved: true)
        XCTAssertTrue(result.isResolved)
        XCTAssertTrue(result.viewerCanUnresolve)
    }

    func testNativeRoutesValidateHostsAndKeepConversationDestinations() throws {
        let repo = try Repository("owner/repo")
        XCTAssertEqual(GitHubRoute(URL(string: "https://github.com/owner/repo/pull/42/files")!), .conversation(repo, 42, .pullRequest))
        XCTAssertEqual(GitHubRoute(URL(string: "https://github.com/owner/repo/discussions/7#discussioncomment-1")!), .conversation(repo, 7, .discussion))
        XCTAssertEqual(GitHubRoute(URL(string: "https://github.com/owner/repo")!), .repository(repo))
        for url in ["https://github.com.evil.example/owner/repo", "https://user@github.com/owner/repo", "https://github.com:444/owner/repo", "http://github.com/owner/repo", "https://github.com/owner/repo/issues/nope", "https://github.com/settings/tokens"] {
            XCTAssertNil(GitHubRoute(URL(string: url)!))
        }
    }

    func testSignInDistinguishesMissingSetupFromTemporaryOutages() throws {
        let setup = Data("{\"error\":\"GitHub sign-in is not configured yet.\"}".utf8)
        XCTAssertThrowsError(try OAuthAttempt.clientID(from: setup, status: 503)) {
            XCTAssertTrue($0.localizedDescription.contains("hasn't been enabled"))
        }
        XCTAssertThrowsError(try OAuthAttempt.clientID(from: Data("unavailable".utf8), status: 503)) {
            XCTAssertTrue($0.localizedDescription.contains("temporarily"))
        }
        XCTAssertEqual(try OAuthAttempt.clientID(from: Data("{\"clientId\":\"client-123\"}".utf8), status: 200), "client-123")
        XCTAssertThrowsError(try OAuthAttempt.clientID(from: Data("{\"clientId\":\"\"}".utf8), status: 200))
    }

    func testCodeReaderUsesImmutableBlobAndRejectsBinaryAndLargeFiles() async throws {
        let sha = String(repeating: "a", count: 40)
        let file = RepositoryFile(name: "main.swift", path: "src/main.swift", sha: sha, type: "file", size: 3)
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/repos/owner/repo/git/blobs/\(sha)")
            return (200, "{\"encoding\":\"base64\",\"size\":3,\"content\":\"aGkK\"}")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = GitHubClient(session: session)
        let text = try await client.codeText(in: Repository("owner/repo"), file: file)
        XCTAssertEqual(text, "hi\n")
        StubURLProtocol.handler = { _ in (200, "{\"encoding\":\"base64\",\"size\":3,\"content\":\"YQBi\"}") }
        do { _ = try await client.codeText(in: Repository("owner/repo"), file: file); XCTFail("Binary files must not become code") } catch {}
        StubURLProtocol.handler = { _ in XCTFail("Oversized previews must not be fetched"); return (200, "{}") }
        let large = RepositoryFile(name: "large", path: "large", sha: sha, type: "file", size: 2_000_000)
        do { _ = try await client.codeText(in: Repository("owner/repo"), file: large); XCTFail("Large preview must fail") } catch {}
    }

    func testNativeIssueSearchPagesWithoutMixingPullRequests() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/search/issues")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "page" }?.value, "2")
            XCTAssertTrue(query.first { $0.name == "q" }!.value!.contains("is:issue repo:owner/repo is:open crash"))
            return (200, """
            {"items":[{"number":7,"title":"Crash","body":"details","html_url":"https://github.com/owner/repo/issues/7","user":null,"state":"open"}]}
            """)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let page = try await GitHubClient(session: session).conversations(kind: .issue, repository: Repository("owner/repo"), account: "", search: "crash", state: "open", page: 2, cursor: nil)
        XCTAssertEqual(page.items.first?.number, 7)
        XCTAssertNil(page.items.first?.user)
        XCTAssertFalse(page.more)
    }

    func testDiscussionGraphQLUsesVariablesPaginationAndFailsOnPartialErrors() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/graphql")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only")
            // URLProtocol can move HTTP bodies into a stream; inspect the request builder separately below.
            return (200, """
            {"data":{"search":{"nodes":[{"number":3,"title":"Ideas","body":"text","htmlUrl":"https://github.com/orgs/owner/discussions/3","repositoryInfo":{"nameWithOwner":"owner/repo"},"user":{"login":"octocat"}}],"pageInfo":{"hasNextPage":true,"endCursor":"next"}}}}
            """)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = GitHubClient(token: "test-only", session: session)
        let request = try client.graphQLRequest("query Test($q: String!) { search(query: $q, type: DISCUSSION, first: 1) { discussionCount } }", variables: ["q":"quote\" & text"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String:Any])
        XCTAssertEqual((body["variables"] as? [String:String])?["q"], "quote\" & text")
        let page = try await client.conversations(kind: .discussion, repository: Repository("owner/repo"), account: "", search: "", state: "all", page: 1, cursor: "previous")
        XCTAssertEqual(page.items.first?.title, "Ideas")
        XCTAssertEqual(page.items.first?.repository, try Repository("owner/repo"))
        XCTAssertEqual(page.cursor, "next")
        XCTAssertTrue(page.more)
        StubURLProtocol.handler = { _ in (200, "{\"data\":{\"search\":null},\"errors\":[{\"message\":\"Access denied\"}]}") }
        do {
            _ = try await client.conversations(kind: .discussion, repository: Repository("owner/repo"), account: "", search: "", state: "all", page: 1, cursor: nil)
            XCTFail("GraphQL errors must not become an empty successful screen")
        } catch let error as GitHubError { XCTAssertTrue(error.message.contains("Access denied")) }
    }

    func testOAuthUsesPKCEAndRejectsMismatchedOrAmbiguousCallbacks() throws {
        let login = OAuthAttempt(state: "random-state", verifier: String(repeating: "a", count: 43))
        let authorization = try login.authorizationURL(clientID: "client-123", challenge: "test-challenge")
        let query = URLComponents(url: authorization, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(authorization.host, "github.com")
        XCTAssertEqual(query.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertEqual(query.first { $0.name == "redirect_uri" }?.value, OAuthAttempt.callback)
        XCTAssertFalse(query.contains { $0.name == "client_secret" })
        XCTAssertEqual(try login.authorizationCode(from: URL(string: "app.forge.github://oauth/callback?state=random-state&code=abc123")!), "abc123")
        for invalid in [
            "app.forge.github://oauth/callback?state=wrong&code=abc123",
            "app.forge.github://oauth/callback?state=random-state&state=random-state&code=abc123",
            "app.forge.github://other/callback?state=random-state&code=abc123",
            "app.forge.github://oauth/callback?state=random-state&code=abc123&code=other",
            "https://oauth/callback?state=random-state&code=abc123",
            "app.forge.github://oauth/callback?state=random-state&error=access_denied"
        ] { XCTAssertThrowsError(try login.authorizationCode(from: URL(string: invalid)!)) }
    }

    func testRepositoryFilesUseRawContentWithoutChangingTheAPIHost() throws {
        let file = RepositoryFile(name: "hello #1?.txt", path: "docs/hello #1?.txt", sha: "abc", type: "file", size: 123)
        let spec = try DownloadSpec.repositoryFile(file, in: Repository("owner/repo"))
        let request = try GitHubClient(token: "test-only").downloadRequest(spec)
        XCTAssertEqual(request.url?.host, "api.github.com")
        XCTAssertEqual(request.url?.path, "/repos/owner/repo/contents/docs/hello #1?.txt")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github.raw+json")
        XCTAssertEqual(spec.name, file.name)
        let traversal = RepositoryFile(name: "file", path: "../file", sha: "abc", type: "file", size: 0)
        XCTAssertThrowsError(try DownloadSpec.repositoryFile(traversal, in: Repository("owner/repo")))
    }

    func testRepositorySearchEncodesQueriesAndDecodesResults() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/search/repositories")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first(where: { $0.name == "q" })?.value, "swift language:swift & tools")
            XCTAssertEqual(query?.first(where: { $0.name == "page" })?.value, "2")
            return (200, """
            {"items":[{"id":1,"full_name":"owner/repo","description":null,"stargazers_count":42,"language":"Swift"}]}
            """)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let result = try await GitHubClient(session: session).searchRepositories("swift language:swift & tools", page: 2)
        XCTAssertEqual(result.first?.fullName, "owner/repo")
        XCTAssertEqual(result.first?.stargazersCount, 42)
        XCTAssertNil(result.first?.description)
    }

    func testInboxPaginationAndLinksUseValidatedGitHubDestinations() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/notifications")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first(where: { $0.name == "all" })?.value, "true")
            XCTAssertEqual(query?.first(where: { $0.name == "per_page" })?.value, "50")
            return (200, """
            [{"id":"7","unread":true,"updated_at":"2026-09-23T09:41:00Z",
            "subject":{"title":"Fix build","type":"PullRequest","url":"https://api.github.com/repos/owner/repo/pulls/42"},
            "repository":{"full_name":"owner/repo"}}]
            """)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let result = try await GitHubClient(token: "test-only", session: session).notifications(page: 2)
        XCTAssertEqual(result.first?.webURL?.absoluteString, "https://github.com/owner/repo/pull/42")
        XCTAssertEqual(result.first?.unread, true)
        let malicious = GitHubNotification(id: "8", unread: false, updatedAt: .now,
            subject: .init(title: "Untrusted URL", type: "Issue", url: URL(string: "https://evil.example/repos/owner/repo/issues/5")),
            repository: .init(fullName: "owner/repo"))
        XCTAssertEqual(malicious.webURL?.absoluteString, "https://github.com/owner/repo")
        let invalid = GitHubNotification(id: "9", unread: false, updatedAt: .now,
            subject: malicious.subject, repository: .init(fullName: "../../evil.example"))
        XCTAssertNil(invalid.webURL)
    }

    func testRepositoryInputCannotEscapeItsAPIPath() throws {
        let repository = try Repository("  Apple/swift  ")
        XCTAssertEqual(repository.fullName, "Apple/swift")
        XCTAssertEqual(repository.id, "apple/swift")
        for invalid in ["", "owner", "owner/repo/extra", "../repo", "owner/..", "owner/a?token=x", "owner/a#fragment", "owner/a b", "https://github.com/owner/repo"] {
            XCTAssertThrowsError(try Repository(invalid), invalid)
        }
    }

    func testReleaseAssetCountsComeFromGitHubAndActionsDoNotInventThem() throws {
        let asset = try GitHubClient.decoder().decode(ReleaseAsset.self, from: Data("""
        {"id":42,"name":"app.ipa","size":2048,"download_count":9876,"content_type":"application/octet-stream"}
        """.utf8))
        XCTAssertEqual(asset.downloadCount, 9876)
        let repository = try Repository("owner/repo")
        let releaseFile = DownloadSpec.asset(asset, in: repository)
        XCTAssertEqual(releaseFile.path, "/repos/owner/repo/releases/assets/42")
        XCTAssertEqual(releaseFile.accept, "application/octet-stream")

        let artifact = try GitHubClient.decoder().decode(Artifact.self, from: Data("""
        {"id":7,"name":"nightly","size_in_bytes":1234,"expired":false,"expires_at":"2030-01-01T00:00:00Z"}
        """.utf8))
        let archive = try DownloadSpec.artifact(artifact, in: repository, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(archive.name, "nightly.zip")
        XCTAssertEqual(archive.path, "/repos/owner/repo/actions/artifacts/7/zip")
        XCTAssertTrue(archive.requiresAuthentication)
        XCTAssertThrowsError(try DownloadSpec.artifact(artifact, in: repository, now: Date(timeIntervalSince1970: 2_000_000_000)))
    }

    func testDownloadNamesStayInsideTheirDirectory() {
        for name in ["../../secret", "..\\..\\secret", ".", "..", "", "a\u{0}b", "a/b:c"] {
            let safe = DownloadSpec.safeFilename(name)
            XCTAssertFalse(safe.isEmpty)
            XCTAssertFalse(safe.contains("/"))
            XCTAssertFalse(safe.contains("\\"))
            XCTAssertFalse(safe.contains(":"))
            XCTAssertNotEqual(safe, ".")
            XCTAssertNotEqual(safe, "..")
        }
        XCTAssertEqual(DownloadSpec.safeFilename("Forge-1.2.ipa"), "Forge-1.2.ipa")
    }

    func testCredentialsAreRemovedBeforeFollowingStorageRedirects() throws {
        var redirected = URLRequest(url: URL(string: "https://release-assets.githubusercontent.com/file?signature=abc")!)
        redirected.setValue("Bearer test-only", forHTTPHeaderField: "Authorization")
        redirected.setValue("secret=test-only", forHTTPHeaderField: "Cookie")
        let safe = try XCTUnwrap(DownloadSpec.redirect(redirected))
        XCTAssertNil(safe.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(safe.value(forHTTPHeaderField: "Cookie"))
        for invalid in ["http://api.github.com/file", "https://example.com/file", "https://api.github.com.evil.example/file", "file:///tmp/file", "https://token@api.github.com/file"] {
            XCTAssertNil(DownloadSpec.redirect(URLRequest(url: URL(string: invalid)!)))
        }
    }

    func testRunStatesDistinguishFailuresFromCancellationAndQueueing() {
        XCTAssertEqual(RunState(status: "completed", conclusion: "failure"), .failed)
        XCTAssertEqual(RunState(status: "completed", conclusion: "timed_out"), .failed)
        XCTAssertEqual(RunState(status: "completed", conclusion: "cancelled"), .cancelled)
        XCTAssertEqual(RunState(status: "completed", conclusion: nil), .unknown)
        XCTAssertEqual(RunState(status: "in_progress", conclusion: nil), .running)
        XCTAssertEqual(RunState(status: "waiting", conclusion: nil), .queued)
        XCTAssertEqual(RunState(status: "completed", conclusion: "success"), .passed)
    }

    func testDatesAcceptFractionalSecondsInJobSteps() throws {
        let plain = try GitHubClient.decoder().decode(Date.self, from: Data("\"2026-09-23T12:00:00Z\"".utf8))
        let fractional = try GitHubClient.decoder().decode(Date.self, from: Data("\"2026-09-23T12:00:00.000Z\"".utf8))
        XCTAssertEqual(plain, fractional)
    }

    func testRateLimitAndExpiredArtifactsHaveActionableErrors() {
        let rate = GitHubClient.responseError(status: 403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "2000000000"])
        XCTAssertTrue(rate.localizedDescription.lowercased().contains("rate limit"))
        XCTAssertTrue(GitHubClient.responseError(status: 410, headers: [:]).localizedDescription.lowercased().contains("expired"))
        XCTAssertTrue(GitHubClient.responseError(status: 401, headers: [:]).localizedDescription.lowercased().contains("token"))
    }

    func testRepositoryWithConsecutiveDotsStillBuildsAValidRequest() throws {
        let repository = try Repository("owner/tool..kit")
        let request = try GitHubClient().request("/repos/\(repository.fullName)/releases")
        XCTAssertEqual(request.url?.path, "/repos/owner/tool..kit/releases")
        XCTAssertThrowsError(try GitHubClient().request("/repos/owner/../user"))
    }

    func testActionsDownloadRequiresATokenAndReleaseDownloadNegotiatesBinaryContent() throws {
        let artifact = DownloadSpec(id: "test", name: "test.zip", repository: "owner/repo", path: "/repos/owner/repo/actions/artifacts/1/zip", accept: "application/vnd.github+json", size: 42, requiresAuthentication: true)
        XCTAssertThrowsError(try GitHubClient().downloadRequest(artifact))
        let authorized = try GitHubClient(token: "test-only").downloadRequest(artifact)
        XCTAssertEqual(authorized.value(forHTTPHeaderField: "Authorization"), "Bearer test-only")
        let asset = DownloadSpec(id: "test", name: "test.zip", repository: "owner/repo", path: "/repos/owner/repo/releases/assets/1", accept: "application/octet-stream", size: 42, requiresAuthentication: false)
        let publicRequest = try GitHubClient().downloadRequest(asset)
        XCTAssertNil(publicRequest.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(publicRequest.value(forHTTPHeaderField: "Accept"), "application/octet-stream")
    }

    func testAssetPaginationDecodesExactCountsAndUsesTheRequestedPage() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/repos/owner/repo/releases/9/assets")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first(where: { $0.name == "page" })?.value, "2")
            XCTAssertEqual(query?.first(where: { $0.name == "per_page" })?.value, "100")
            return (200, """
            [{"id":99,"name":"file.zip","size":300,"download_count":1234567,"content_type":"application/zip"}]
            """)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let result = try await GitHubClient(session: session).assets(in: Repository("owner/repo"), releaseID: 9, page: 2)
        XCTAssertEqual(result.map(\.downloadCount), [1234567])
    }

    func testHTTPFailureDoesNotGetDecodedAsASuccessfulResponse() async throws {
        StubURLProtocol.handler = { _ in (401, "{}") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await GitHubClient(session: session).accountName()
            XCTFail("A rejected token must fail before decoding the response.")
        } catch let error as GitHubError {
            XCTAssertTrue(error.message.contains("token"))
        }
    }
}

private final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, String))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var request = request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            request.httpBody = data
        }
        let (status, body) = Self.handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
