import XCTest
@testable import ForgeCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class CommunityFeaturesTests: XCTestCase {
    func testOfflineCopyPinsRevisionAndReportsSkippedFiles() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ExperienceURLProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let revision = String(repeating: "a", count: 40), blob = String(repeating: "b", count: 40)
        ExperienceURLProtocol.handler = { request in
            if request.url!.path.contains("/trees/") {
                XCTAssertTrue(request.url!.path.hasSuffix(revision))
                return (200, [:], "{\"truncated\":false,\"tree\":[{\"path\":\"docs/README.md\",\"mode\":\"100644\",\"type\":\"blob\",\"sha\":\"\(blob)\",\"size\":5},{\"path\":\"large.txt\",\"mode\":\"100644\",\"type\":\"blob\",\"sha\":\"\(blob)\",\"size\":2000000}]}")
            }
            return (200, [:], "{\"content\":\"SGVsbG8=\",\"encoding\":\"base64\",\"size\":5}")
        }
        let copy = try await GitHubClient(token: "test-only", session: session).offlineCopy(in: Repository("owner/repo"), branch: "main", sha: revision)
        XCTAssertEqual(copy.files, ["docs/README.md": "Hello"]); XCTAssertEqual(copy.omitted, 1); XCTAssertTrue(copy.valid)
        let invalid = OfflineCopy(repository: copy.repository, branch: "main", sha: revision, saved: Date(), files: ["../escape": "secret"], omitted: 0)
        XCTAssertFalse(invalid.valid)
    }
    func testReadmeOutlineHandlesDuplicateHeadingsAndEscapesLabels() throws {
        let doc = try ReadmeDocument(html: "<h1>Build &amp; test</h1><h2><code>Install</code></h2><h2>Install</h2>", repository: Repository("owner/repo"), sha: String(repeating: "a", count: 40), path: "README.md")
        XCTAssertEqual(doc.headings.map(\.title), ["Build & test", "Install", "Install"])
        XCTAssertEqual(doc.headings.map(\.id), ["forge-section-0", "forge-section-1", "forge-section-2"])
        XCTAssertTrue(doc.page(dark: false, outline: true).contains("href=\"#forge-section-2\""))
        XCTAssertTrue(doc.page(dark: false, outline: true).contains("Build &amp; test"))
    }
    func testDeploymentReviewRequiresCurrentEligibilityAndConfirmsResponse() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ExperienceURLProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let client = GitHubClient(token: "test-only", session: session)
        var eligible = true
        ExperienceURLProtocol.handler = { request in
            if request.httpMethod == "POST" {
                let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                XCTAssertEqual(body["environment_ids"] as? [Int], [7])
                XCTAssertEqual(body["state"] as? String, "approved")
                return (200, [:], "[{\"id\":8}]")
            }
            return (200, [:], "[{\"environment\":{\"id\":7,\"name\":\"production\"},\"current_user_can_approve\":\(eligible)}]")
        }
        try await client.reviewDeployment(in: Repository("owner/repo"), runID: 3, environmentID: 7, approved: true, comment: "Reviewed")
        eligible = false
        do { try await client.reviewDeployment(in: Repository("owner/repo"), runID: 3, environmentID: 7, approved: true, comment: "Reviewed"); XCTFail("Ineligible reviewer must not submit") }
        catch { XCTAssertTrue(error.localizedDescription.contains("eligible")) }
    }

    func testDraftTransitionChecksTheReturnedState() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ExperienceURLProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let client = GitHubClient(token: "test-only", session: session)
        ExperienceURLProtocol.handler = { request in
            let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertTrue((body["query"] as! String).contains("convertPullRequestToDraft"))
            return (200, [:], "{\"data\":{\"result\":{\"pullRequest\":{\"isDraft\":false}}}}")
        }
        do { try await client.setPullDraft(id: "PR_test", draft: true); XCTFail("Unconfirmed change must not appear saved") }
        catch { XCTAssertTrue(error.localizedDescription.contains("confirm")) }
    }
}
