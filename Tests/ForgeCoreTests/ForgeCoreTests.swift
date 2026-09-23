import XCTest
@testable import ForgeCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ForgeCoreTests: XCTestCase {
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
        let (status, body) = Self.handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
