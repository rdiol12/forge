import XCTest
@testable import ForgeCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class HistoryMergeTests: XCTestCase {
    func testRemovingCommitMergesSeparateReadmeEditsAndKeepsUnrelatedFiles() async throws {
        let fixture = HistoryMergeFixture(overlapping: false)
        let session = fixture.session()
        defer { session.invalidateAndCancel(); URLProtocol.unregisterClass(ExperienceURLProtocol.self) }
        let client = GitHubClient(token: "test-only", session: session)
        do {
            _ = try await client.changeHistory(in: Repository("owner/repo"), branch: .init(name: "main", commit: .init(sha: fixture.head)), selected: fixture.selected, remove: true, saveRecovery: fixture.stopBeforePush)
            XCTFail("The test must stop at the recovery checkpoint before updating the branch")
        } catch HistoryMergeFixture.Stop.beforePush {
            // Inspect the real API's completed rewrite plan without changing any remote branch.
        } catch {
            XCTFail("Edits to separate README sections should merge: \(error.localizedDescription)")
            return
        }
        let result = fixture.snapshot()
        XCTAssertEqual(result.readme, fixture.expected, "Only the selected installation change should be undone")
        XCTAssertEqual(Set(result.tree.keys), ["README.md", "Sources/Keep.txt", "docs/later.txt"])
        XCTAssertEqual(result.tree["Sources/Keep.txt"]?["sha"] as? String, fixture.keptBlob)
        XCTAssertEqual(result.tree["docs/later.txt"]?["sha"] as? String, fixture.laterBlob)
        XCTAssertEqual(result.commit["parents"] as? [String], [fixture.base])
        XCTAssertEqual(result.commit["message"] as? String, "Update usage and add later documentation")
        XCTAssertEqual(result.recovery?.selected, fixture.selected)
        XCTAssertEqual(result.recovery?.oldHead, fixture.head)
        XCTAssertEqual(result.recovery?.newHead, fixture.rewritten)
        XCTAssertTrue(result.branchWrites.isEmpty)
    }

    func testRemovingCommitWithOverlappingReadmeEditsStopsBeforeBranchPush() async throws {
        let fixture = HistoryMergeFixture(overlapping: true)
        let session = fixture.session()
        defer { session.invalidateAndCancel(); URLProtocol.unregisterClass(ExperienceURLProtocol.self) }
        let client = GitHubClient(token: "test-only", session: session)
        do {
            _ = try await client.changeHistory(in: Repository("owner/repo"), branch: .init(name: "main", commit: .init(sha: fixture.head)), selected: fixture.selected, remove: true, saveRecovery: fixture.stopBeforePush)
            XCTFail("Overlapping edits require the user's resolution")
        } catch HistoryMergeFixture.Stop.beforePush {
            XCTFail("Overlapping edits must not silently produce a rewritten branch")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("README.md"), "The conflict should identify its file: \(error)")
        }
        let result = fixture.snapshot()
        XCTAssertNil(result.recovery, "No completed rewrite should reach the branch update checkpoint")
        XCTAssertTrue(result.tree.isEmpty)
        XCTAssertTrue(result.commit.isEmpty)
        XCTAssertTrue(result.branchWrites.isEmpty)
    }

    func testEditedReadmeResolutionRequiresTheMatchingConflictAndPreservesExactBytes() async throws {
        let fixture = HistoryMergeFixture(overlapping: true)
        let session = fixture.session()
        defer { session.invalidateAndCancel(); URLProtocol.unregisterClass(ExperienceURLProtocol.self) }
        let client = GitHubClient(token: "test-only", session: session)
        let repository = try Repository("owner/repo")
        let branch = RepositoryBranch(name: "main", commit: .init(sha: fixture.head))
        let conflict: HistoryConflict
        do {
            _ = try await client.changeHistory(in: repository, branch: branch, selected: fixture.selected, remove: true, saveRecovery: fixture.stopBeforePush)
            XCTFail("Overlapping changes must first ask the user to resolve README.md")
            return
        } catch let found as HistoryConflict { conflict = found }
        XCTAssertEqual(conflict.path, "README.md")
        XCTAssertTrue(conflict.canEdit)

        // Preserve the user's line endings, trailing spaces, and decomposed Unicode exactly.
        let chosenText = "# Forge\r\n\r\n## Installation\r\nUse the maintainer's chosen build.  \r\n\r\n## Notes\r\nCafe\u{301}: reviewed resolution.\r\n"
        let current = try XCTUnwrap(conflict.current)
        let staleID = conflict.id.replacingOccurrences(of: current.sha, with: String(repeating: "0", count: 40))
        XCTAssertNotEqual(staleID, conflict.id)
        do {
            _ = try await client.changeHistory(in: repository, branch: branch, selected: fixture.selected, remove: true, resolutions: [staleID: .edited(chosenText)], saveRecovery: fixture.stopBeforePush)
            XCTFail("A resolution for a different file revision must not be applied")
        } catch let unresolved as HistoryConflict {
            XCTAssertEqual(unresolved.id, conflict.id)
        }
        let unresolved = fixture.snapshot()
        XCTAssertNil(unresolved.recovery)
        XCTAssertTrue(unresolved.tree.isEmpty)
        XCTAssertTrue(unresolved.commit.isEmpty)
        XCTAssertTrue(unresolved.branchWrites.isEmpty)

        do {
            _ = try await client.changeHistory(in: repository, branch: branch, selected: fixture.selected, remove: true, resolutions: [conflict.id: .edited(chosenText)], saveRecovery: fixture.stopBeforePush)
            XCTFail("The test must stop at the recovery checkpoint before updating the branch")
        } catch HistoryMergeFixture.Stop.beforePush { }
        let resolved = fixture.snapshot()
        XCTAssertEqual(resolved.readme.map { Data($0.utf8) }, Data(chosenText.utf8))
        XCTAssertEqual(resolved.commit["parents"] as? [String], [fixture.base])
        XCTAssertEqual(resolved.recovery?.branch, branch.name)
        XCTAssertEqual(resolved.recovery?.oldHead, branch.commit.sha, "Resolving a file must not replace the original expected branch revision")
        XCTAssertEqual(resolved.recovery?.newHead, fixture.rewritten)
        XCTAssertTrue(resolved.branchWrites.isEmpty)
    }
}

private final class HistoryMergeFixture: @unchecked Sendable {
    enum Stop: Error { case beforePush }
    private static func sha(_ digit: Character) -> String { String(repeating: String(digit), count: 40) }
    let base = sha("1"), selected = sha("2"), head = sha("3"), rewritten = sha("f")
    let keptBlob = sha("a"), laterBlob = sha("b")
    private let baseTree = sha("4"), selectedTree = sha("5"), headTree = sha("6")
    private let originalBlob = sha("7"), selectedBlob = sha("8"), headBlob = sha("9")
    private let selectedOnlyBlob = sha("c"), mergedBlob = sha("d"), rebuiltTree = sha("e")
    private let lock = NSLock()
    private var responses: [String: [String: Any]] = [:]
    private var createdBlobs: [String: Data] = [:]
    private var createdTree: [String: [String: Any]] = [:]
    private var createdCommit: [String: Any] = [:]
    private var recovery: CommitRecovery?
    private var branchWrites: [String] = []
    let expected: String

    init(overlapping: Bool) {
        let original = "# Forge\n\n## Installation\nInstall the stable build.\n\n## Usage\nOpen a repository.\n\n## Support\nRead the documentation.\n"
        let chosen = original.replacingOccurrences(of: "stable", with: "preview")
        let latest = overlapping ? chosen.replacingOccurrences(of: "preview", with: "nightly") : chosen.replacingOccurrences(of: "Open a repository.", with: "Open a repository and check its workflows.")
        expected = original.replacingOccurrences(of: "Open a repository.", with: "Open a repository and check its workflows.")
        func entry(_ path: String, _ sha: String, _ text: String) -> [String: Any] { ["path": path, "mode": "100644", "type": "blob", "sha": sha, "size": text.utf8.count] }
        let keep = entry("Sources/Keep.txt", keptBlob, "Keep this unrelated file.\n")
        let addedBySelected = entry("selected-only.txt", selectedOnlyBlob, "Remove this along with the selected commit.\n")
        let addedLater = entry("docs/later.txt", laterBlob, "Preserve this later addition.\n")
        let trees: [(String, [[String: Any]])] = [
            (baseTree, [entry("README.md", originalBlob, original), keep]),
            (selectedTree, [entry("README.md", selectedBlob, chosen), keep, addedBySelected]),
            (headTree, [entry("README.md", headBlob, latest), keep, addedBySelected, addedLater])
        ]
        for (sha, entries) in trees { responses["/repos/owner/repo/git/trees/\(sha)"] = ["sha": sha, "truncated": false, "tree": entries] }
        for (sha, text) in [(originalBlob, original), (selectedBlob, chosen), (headBlob, latest)] {
            responses["/repos/owner/repo/git/blobs/\(sha)"] = ["sha": sha, "encoding": "base64", "content": Data(text.utf8).base64EncodedString(), "size": text.utf8.count]
        }
        for (sha, tree, parents, message) in [
            (base, baseTree, [String](), "Original repository"),
            (selected, selectedTree, [base], "Use the preview installation"),
            (head, headTree, [selected], "Update usage and add later documentation")
        ] {
            responses["/repos/owner/repo/git/commits/\(sha)"] = ["sha": sha, "tree": ["sha": tree], "parents": parents.map { ["sha": $0] }, "message": message, "author": ["name": "Test", "email": "test@example.invalid", "date": "2026-09-24T00:00:00Z"]]
        }
        responses["/repos/owner/repo/git/ref/heads/main"] = ["ref": "refs/heads/main", "object": ["type": "commit", "sha": head]]
        responses["/repos/owner/repo"] = ["full_name": "owner/repo", "default_branch": "main", "stargazers_count": 0, "forks_count": 0, "open_issues_count": 0, "permissions": ["push": true]]
    }

    func session() -> URLSession {
        ExperienceURLProtocol.handler = { [self] in respond(to: $0) }
        // Also intercept an accidental request from the final Git transport's separate session.
        _ = URLProtocol.registerClass(ExperienceURLProtocol.self)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ExperienceURLProtocol.self]
        return URLSession(configuration: config)
    }

    @Sendable func stopBeforePush(_ entry: CommitRecovery) async throws {
        lock.withLock { recovery = entry }
        throw Stop.beforePush
    }

    struct Snapshot {
        let readme: String?
        let tree: [String: [String: Any]]
        let commit: [String: Any]
        let recovery: CommitRecovery?
        let branchWrites: [String]
    }
    func snapshot() -> Snapshot {
        lock.withLock {
            let readme = createdTree["README.md"]
            let text = (readme?["content"] as? String) ?? (readme?["sha"] as? String).flatMap { createdBlobs[$0] }.flatMap { String(data: $0, encoding: .utf8) }
            return Snapshot(readme: text, tree: createdTree, commit: createdCommit, recovery: recovery, branchWrites: branchWrites)
        }
    }

    private func respond(to request: URLRequest) -> (Int, [String: String], String) {
        lock.withLock {
            let path = request.url!.path
            func response(_ object: [String: Any], status: Int = 200) -> (Int, [String: String], String) {
                (status, ["Content-Type": "application/json"], String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self))
            }
            if request.httpMethod == "GET", let object = responses[path] { return response(object) }
            if path.contains("/git/refs") || path.contains("git-receive-pack") {
                branchWrites.append(path)
                XCTFail("A test must never update a branch")
                return response(["message": "Branch updates blocked by the test"], status: 500)
            }
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
            if request.httpMethod == "POST", path == "/repos/owner/repo/git/blobs", let content = body["content"] as? String {
                createdBlobs[mergedBlob] = body["encoding"] as? String == "base64" ? Data(base64Encoded: content) : Data(content.utf8)
                return response(["sha": mergedBlob], status: 201)
            }
            if request.httpMethod == "POST", path == "/repos/owner/repo/git/trees", let entries = body["tree"] as? [[String: Any]] {
                createdTree = Dictionary(uniqueKeysWithValues: entries.map { ($0["path"] as! String, $0) })
                return response(["sha": rebuiltTree], status: 201)
            }
            if request.httpMethod == "POST", path == "/repos/owner/repo/git/commits" {
                createdCommit = body
                XCTAssertEqual(body["tree"] as? String, rebuiltTree)
                return response(["sha": rewritten], status: 201)
            }
            XCTFail("Unexpected request: \(request.httpMethod ?? "") \(path)")
            return response(["message": "Unexpected request"], status: 500)
        }
    }
}
