import XCTest
@testable import ForgeCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class RepositoryExperienceTests: XCTestCase {
    func testETagRevalidationAndReleaseDeletionInvalidateCachedLists() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ExperienceURLProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let cache = APIMemoryCache(); let client = GitHubClient(token: "test-only", session: session, cache: cache)
        let request = try client.request("/repos/owner/repo/releases")
        ExperienceURLProtocol.handler = { request in
            if request.httpMethod == "DELETE" { XCTAssertEqual(request.url?.path, "/repos/owner/repo/releases/4"); return (204, [:], "") }
            if request.value(forHTTPHeaderField: "If-None-Match") == "v1" { return (304, ["Cache-Control": "max-age=30"], "") }
            return (200, ["ETag": "v1", "Cache-Control": "max-age=0"], "[]")
        }
        _ = try await client.cachedData(for: request)
        let first = await cache.value(for: request); XCTAssertFalse(first!.fresh)
        let (body, response) = try await client.cachedData(for: request)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "[]"); XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let revalidated = await cache.value(for: request); XCTAssertTrue(revalidated!.fresh)
        try await client.deleteRelease(in: Repository("owner/repo"), id: 4)
        let deleted = await cache.value(for: request); XCTAssertNil(deleted)
    }

    func testProfileEditsUseAllowlistAndRejectChangedFields() async throws {
        let originalJSON = "{\"id\":1,\"login\":\"octocat\",\"html_url\":\"https://github.com/octocat\",\"name\":\"Original\",\"type\":\"User\"}"
        let original = try GitHubClient.decoder().decode(GitHubAccount.self, from: Data(originalJSON.utf8))
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ExperienceURLProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let client = GitHubClient(token: "test-only", session: session)
        ExperienceURLProtocol.handler = { request in
            if request.httpMethod == "PATCH" {
                let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                XCTAssertEqual(body["name"] as? String, "Updated"); XCTAssertEqual(body.count, 1)
            }
            return (200, [:], originalJSON)
        }
        try await client.editProfile(original: original, fields: ["name": "Updated"], hireable: false)
        ExperienceURLProtocol.handler = { request in XCTAssertEqual(request.httpMethod, "GET"); return (200, [:], originalJSON.replacingOccurrences(of: "Original", with: "Other edit")) }
        do { try await client.editProfile(original: original, fields: ["name": "Updated"], hireable: false); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("changed elsewhere")) }
        do { try await client.editProfile(original: original, fields: ["login": "newname"], hireable: false); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("supported")) }
    }
    func testMemoryCacheIsAccountIsolatedBoundedAndRejectsResponsesFromBeforeRefresh() async throws {
        let cache = APIMemoryCache(capacity: 8, lifetime: 30)
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.setValue("Bearer first", forHTTPHeaderField: "Authorization")
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["ETag": "one"])!
        let epoch = await cache.epoch
        await cache.store(Data("first".utf8), response: response, for: request, epoch: epoch)
        let hit = await cache.value(for: request)
        XCTAssertEqual(hit?.data, Data("first".utf8))
        request.setValue("Bearer second", forHTTPHeaderField: "Authorization")
        let otherAccount = await cache.value(for: request); XCTAssertNil(otherAccount)
        await cache.clear()
        await cache.store(Data("stale".utf8), response: response, for: request, epoch: epoch)
        let stale = await cache.value(for: request); XCTAssertNil(stale)
        await cache.store(Data(repeating: 1, count: 9), response: response, for: request, epoch: await cache.epoch)
        let oversized = await cache.value(for: request); XCTAssertNil(oversized)
    }
    func testReadmeImagesResolveInsideSelectedRepositoryWithoutExposingCredentials() throws {
        let document = try ReadmeDocument(html: "<img src=\"../images/a%20b.png\"><img src=\"https://example.com/badge.svg\"><img src=\"javascript:alert(1)\">", repository: Repository("owner/repo"), sha: String(repeating: "a", count: 40), path: "docs/README.md")
        XCTAssertTrue(document.html.contains("forge-readme://image/images/a%20b.png"))
        XCTAssertTrue(document.html.contains("https://example.com/badge.svg"))
        XCTAssertFalse(document.html.contains("javascript:alert"))
        XCTAssertEqual(document.imagePath(URL(string: "forge-readme://image/images/a%20b.png")!), "images/a b.png")
        XCTAssertNil(document.imagePath(URL(string: "forge-readme://other/private")!))
        XCTAssertNil(document.imagePath(URL(string: "https://api.github.com/user")!))
        XCTAssertTrue(document.page(dark: false).contains("script-src 'none'"))
    }

    func testIssueFieldsIncludeOnlySelectedMetadataAndRejectEmptyTitles() throws {
        let body = try IssueFields(title: "  Example  ", body: "Details", assignees: ["octocat"], labels: ["bug"], milestone: 4).payload()
        XCTAssertEqual(body["title"] as? String, "Example")
        XCTAssertEqual(body["assignees"] as? [String], ["octocat"])
        XCTAssertEqual(body["labels"] as? [String], ["bug"])
        XCTAssertEqual(body["milestone"] as? Int, 4)
        XCTAssertNil(body["project"])
        XCTAssertThrowsError(try IssueFields(title: " ", body: "").payload())
        XCTAssertThrowsError(try IssueFields(title: "Issue", body: "", assignees: ["../bad"]).payload())
    }
}

final class ExperienceURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], String))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var copy = request
        if copy.httpBody == nil, let stream = copy.httpBodyStream {
            stream.open(); defer { stream.close() }; var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let size = stream.read(&buffer, maxLength: buffer.count); if size <= 0 { break }; data.append(buffer, count: size) }; copy.httpBody = data
        }
        let (status, headers, body) = Self.handler(copy)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: copy.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
