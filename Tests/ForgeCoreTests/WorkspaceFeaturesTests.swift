import XCTest
@testable import ForgeCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class WorkspaceFeaturesTests: XCTestCase {
    func testMarkdownKeepsFencedCodeOutOfHeadings() {
        let blocks = MarkdownBlock.parse("# Title\n\n- one\n> quote\n```swift\n# not a heading\nlet x = 1\n```\nAfter")
        XCTAssertEqual(blocks.count, 5)
        if case .code(let language) = blocks[3].kind { XCTAssertEqual(language, "swift"); XCTAssertTrue(blocks[3].text.contains("# not a heading")) } else { XCTFail() }
    }

    func testBranchFilesUseSHAAndLatestBuildQueriesOnlySuccessfulRuns() async throws {
        let sha = String(repeating: "a", count: 40)
        let session = stub { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            if request.url!.path.hasSuffix("/actions/runs") { XCTAssertEqual(query.first { $0.name == "status" }?.value, "success"); return (200, "{\"workflow_runs\":[]}") }
            XCTAssertEqual(query.first { $0.name == "ref" }?.value, sha)
            XCTAssertEqual(request.url?.path, "/repos/owner/repo/contents/src")
            return (200, "[]")
        }
        defer { session.invalidateAndCancel() }
        let client = GitHubClient(session: session), repo = try Repository("owner/repo")
        _ = try await client.files(in: repo, path: "src", sha: sha)
        _ = try await client.runs(in: repo, status: "success")
    }

    func testIssueEditingDoesNotSilentlyAcceptRejectedLabelsOrOverwriteNewerChanges() async throws {
        let json = "{\"title\":\"Issue\",\"body\":\"text\",\"updated_at\":\"2026-01-01T00:00:00Z\",\"labels\":[],\"assignees\":[]}"
        let original = try GitHubClient.decoder().decode(IssueEditDetails.self, from: Data(json.utf8))
        let session = stub { request in
            if request.httpMethod == "PATCH" {
                let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                XCTAssertEqual(body.count, 1)
                XCTAssertEqual(body["labels"] as? [String], ["bug"])
            }
            return (200, json)
        }
        defer { session.invalidateAndCancel() }
        let client = GitHubClient(token: "test-only", session: session), repo = try Repository("owner/repo")
        do { try await client.editIssue(in: repo, number: 1, original: original, title: "Issue", body: "text", labels: ["bug"], assignees: nil); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("part")) }
        FeatureURLProtocol.handler = { request in XCTAssertEqual(request.httpMethod, "GET"); return (200, json.replacingOccurrences(of: "2026-01-01", with: "2026-01-02")) }
        do { try await client.editIssue(in: repo, number: 1, original: original, title: "Changed", body: "text", labels: nil, assignees: nil); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
    }

    func testReleaseEditingPreservesTagAndPublicationStateAndDiscussionReplyUsesNodeIDs() async throws {
        let originalJSON = "{\"id\":44,\"tag_name\":\"v1\",\"name\":\"Version 1\",\"body\":\"Original\",\"draft\":false,\"prerelease\":false,\"html_url\":\"https://github.com/owner/repo/releases/tag/v1\"}"
        let original = try GitHubClient.decoder().decode(Release.self, from: Data(originalJSON.utf8))
        let session = stub { request in
            if request.httpMethod == "GET" { return (200, originalJSON) }
            let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(body["body"] as? String, "Updated notes")
            XCTAssertNil(body["tag_name"]); XCTAssertNil(body["draft"])
            return (200, originalJSON.replacingOccurrences(of: "Original", with: "Updated notes"))
        }
        defer { session.invalidateAndCancel() }
        let client = GitHubClient(token: "test-only", session: session)
        _ = try await client.editRelease(in: Repository("owner/repo"), release: original, name: "Version 1", notes: "Updated notes", prerelease: false)
        FeatureURLProtocol.handler = { request in
            let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let variables = body["variables"] as! [String: String]
            XCTAssertEqual(variables["id"], "discussion"); XCTAssertEqual(variables["reply"], "comment"); XCTAssertEqual(variables["body"], "My reply")
            return (200, "{\"data\":{\"addDiscussionComment\":{\"comment\":{\"id\":\"new-comment\"}}}}")
        }
        try await client.replyToDiscussion(id: "discussion", replyTo: "comment", body: "My reply")
    }

    func testVisibilityChangesNeedAdminAccessAndOnlyChangeVisibility() async throws {
        let session = stub { request in
            XCTAssertEqual(request.url?.path, "/repos/owner/repo")
            if request.httpMethod == "GET" { return (200, "{\"visibility\":\"private\",\"default_branch\":\"main\",\"permissions\":{\"admin\":true}}") }
            XCTAssertEqual(request.httpMethod, "PATCH")
            let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertEqual(body.count, 1)
            XCTAssertEqual(body["private"] as? Bool, false)
            return (200, "{\"visibility\":\"public\",\"default_branch\":\"main\",\"permissions\":{\"admin\":true}}")
        }
        defer { session.invalidateAndCancel() }
        try await GitHubClient(token: "test-only", session: session).setVisibility(in: Repository("owner/repo"), expected: "private", makePrivate: false)
        FeatureURLProtocol.handler = { _ in (200, "{\"visibility\":\"private\",\"default_branch\":\"main\",\"permissions\":{\"admin\":false}}") }
        do { try await GitHubClient(token: "test-only", session: session).setVisibility(in: Repository("owner/repo"), expected: "private", makePrivate: false); XCTFail() } catch {}
    }

    func testReadmeSavePinsOriginalBlobAndBranchAndEncodesText() async throws {
        let sha = String(repeating: "a", count: 40), replacement = String(repeating: "b", count: 40)
        let file = RepositoryFile(name: "README.md", path: "docs/README.md", sha: sha, type: "file", size: 3)
        let session = stub { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/repos/owner/repo/contents/docs/README.md")
            let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
            XCTAssertEqual(body["sha"], sha)
            XCTAssertEqual(body["branch"], "feature/docs")
            XCTAssertEqual(String(data: Data(base64Encoded: body["content"]!)!, encoding: .utf8), "# Hello 🐙")
            return (200, "{\"content\":{\"sha\":\"\(replacement)\"}}")
        }
        defer { session.invalidateAndCancel() }
        let result = try await GitHubClient(token: "test-only", session: session).updateFile(in: Repository("owner/repo"), file: file, branch: "feature/docs", text: "# Hello 🐙", message: "Update README")
        XCTAssertEqual(result, replacement)
        FeatureURLProtocol.handler = { _ in (409, "{\"message\":\"File changed\"}") }
        do { _ = try await GitHubClient(token: "test-only", session: session).updateFile(in: Repository("owner/repo"), file: file, branch: "feature/docs", text: "new", message: "Update"); XCTFail() } catch {}
    }

    func testDeletingAReleaseNeverDeletesItsGitTag() async throws {
        let session = stub { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/repos/owner/repo/releases/44")
            return (204, "")
        }
        defer { session.invalidateAndCancel() }
        try await GitHubClient(token: "test-only", session: session).deleteRelease(in: Repository("owner/repo"), id: 44)
    }

    func testBackgroundTransfersUseOnlyTrustedStorageWithoutAccountCredentials() throws {
        let request = try DownloadSpec.backgroundRequest(for: URL(string: "https://release-assets.githubusercontent.com/file?sig=short-lived")!)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(request.httpShouldHandleCookies)
        for value in ["https://api.github.com/user", "http://release-assets.githubusercontent.com/file", "https://example.com/file", "https://user:password@github.com/file"] {
            XCTAssertThrowsError(try DownloadSpec.backgroundRequest(for: URL(string: value)!))
        }
    }

    func testFollowersHaveNativeRoutesAndPaginatedAPI() async throws {
        XCTAssertEqual(GitHubRoute(URL(string: "https://github.com/octocat?tab=followers")!), .people("octocat", .followers))
        XCTAssertEqual(GitHubRoute(URL(string: "https://github.com/octocat?tab=following")!), .people("octocat", .following))
        let session = stub { request in
            XCTAssertEqual(request.url?.path, "/users/octocat/followers")
            XCTAssertTrue(request.url!.query!.contains("page=2"))
            return (200, "[{\"id\":1,\"login\":\"hubot\"}]")
        }
        defer { session.invalidateAndCancel() }
        let people = try await GitHubClient(session: session).people(login: "octocat", collection: .followers, page: 2)
        XCTAssertEqual(people.first?.login, "hubot")
        do { _ = try await GitHubClient(session: session).people(login: "../user", collection: .followers, page: 1); XCTFail() } catch {}
    }

    func testSyntaxPreservesUnicodeAndDoesNotColorWordsInsideStringsAsKeywords() {
        let code = "let emoji = \"🐙 return\" // hello\n/* multiline\ncomment */\nreturn 42"
        let tokens = CodeSyntax.tokens(in: code, filename: "example.swift")
        let source = code as NSString
        XCTAssertTrue(tokens.contains { $0.kind == .string && source.substring(with: $0.range) == "\"🐙 return\"" })
        XCTAssertTrue(tokens.contains { $0.kind == .comment && source.substring(with: $0.range).contains("multiline\ncomment") })
        XCTAssertEqual(tokens.filter { $0.kind == .keyword }.map { source.substring(with: $0.range) }, ["let", "return"])
        for (left, right) in zip(tokens, tokens.dropFirst()) { XCTAssertLessThanOrEqual(NSMaxRange(left.range), right.range.location) }
        XCTAssertEqual(CodeSyntax.language(filename: "build.yml"), "YAML")
        XCTAssertTrue(CodeSyntax.tokens(in: "a normal sentence", filename: "README.txt").isEmpty)
    }

    func testBranchDownloadsUseTheSameImmutableRevisionAsTheReader() throws {
        let repository = try Repository("owner/repo"), sha = String(repeating: "b", count: 40)
        let file = RepositoryFile(name: "test.swift", path: "src/test.swift", sha: sha, type: "file", size: 20)
        let spec = try DownloadSpec.repositoryFile(file, in: repository)
        XCTAssertEqual(spec.path, "/repos/owner/repo/git/blobs/\(sha)")
        let archive = try DownloadSpec.repositoryArchive(in: repository, sha: sha, name: "feature/fix")
        XCTAssertEqual(archive.path, "/repos/owner/repo/zipball/\(sha)")
        XCTAssertFalse(archive.name.contains("/"))
        XCTAssertNotNil(DownloadSpec.redirect(URLRequest(url: URL(string: "https://codeload.github.com/owner/repo/zip/\(sha)")!)))
        XCTAssertThrowsError(try DownloadSpec.repositoryArchive(in: repository, sha: "../main", name: "bad"))
    }

    func testWorkflowControlsUseExplicitOperationsAndRejectAnonymousWrites() async throws {
        let session = stub { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/repos/owner/repo/actions/runs/42/rerun-failed-jobs")
            return (201, "")
        }
        defer { session.invalidateAndCancel() }
        let repo = try Repository("owner/repo")
        try await GitHubClient(token: "test-only", session: session).controlRun(in: repo, runID: 42, action: .rerunFailed)
        do { try await GitHubClient(session: session).controlRun(in: repo, runID: 42, action: .cancel); XCTFail() } catch {}
        do { try await GitHubClient(token: "test-only", session: session).controlRun(in: repo, runID: -1, action: .cancel); XCTFail() } catch {}
    }

    func testDiffLinesKeepLeftAndRightLineNumbersAcrossHunks() {
        let lines = DiffLine.parse("@@ -10,2 +10,3 @@ function\n context\n-old\n+new\n+extra\n@@ -40 +41 @@\n-last\n+next\n\\ No newline at end of file")
        XCTAssertEqual(lines.first { $0.text == "-old" }?.oldLine, 11)
        XCTAssertEqual(lines.first { $0.text == "+extra" }?.newLine, 12)
        XCTAssertEqual(lines.first { $0.text == "+next" }?.newLine, 41)
        XCTAssertNil(lines.last?.newLine)
    }

    func testInlineCommentsPinCommitPathAndDiffSide() async throws {
        let sha = String(repeating: "a", count: 40)
        let session = stub { request in
            XCTAssertEqual(request.url?.path, "/repos/owner/repo/pulls/7/comments")
            let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertEqual(body["commit_id"] as? String, sha)
            XCTAssertEqual(body["path"] as? String, "src/main.swift")
            XCTAssertEqual(body["line"] as? Int, 12)
            XCTAssertEqual(body["side"] as? String, "LEFT")
            return (201, "{}")
        }
        defer { session.invalidateAndCancel() }
        try await GitHubClient(token: "test-only", session: session).commentOnLine(in: Repository("owner/repo"), number: 7, sha: sha, path: "src/main.swift", line: 12, side: .left, body: "Please keep this")
    }

    private func stub(_ handler: @escaping (URLRequest) -> (Int, String)) -> URLSession {
        FeatureURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FeatureURLProtocol.self]
        return URLSession(configuration: config)
    }
}

private final class FeatureURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var copy = request
        if copy.httpBody == nil, let stream = copy.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
            copy.httpBody = data
        }
        let (status, body) = Self.handler(copy)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: copy.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
