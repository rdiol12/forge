import XCTest
@testable import ForgeCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class CommitHistoryTests: XCTestCase {
    func testFailedRecoverySaveStopsBeforeChangingTheBranch() async throws {
        let old = String(repeating: "a", count: 40), parent = String(repeating: "b", count: 40)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ExperienceURLProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        ExperienceURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET", "A failed recovery write must not change GitHub")
            let path = request.url!.path
            if path.hasSuffix("/git/ref/heads/main") { return (200, [:], "{\"ref\":\"refs/heads/main\",\"object\":{\"type\":\"commit\",\"sha\":\"\(old)\"}}") }
            if path == "/repos/owner/repo" { return (200, [:], "{\"full_name\":\"owner/repo\",\"default_branch\":\"main\",\"stargazers_count\":0,\"forks_count\":0,\"open_issues_count\":0,\"permissions\":{\"push\":true}}") }
            if path.contains("/git/commits/") { return (200, [:], "{\"sha\":\"\(path.hasSuffix(old) ? old : parent)\",\"tree\":{\"sha\":\"\(parent)\"},\"parents\":[{\"sha\":\"\(parent)\"}],\"message\":\"Example\",\"author\":{\"name\":\"Test\",\"email\":\"test@example.invalid\",\"date\":\"2026-09-24T00:00:00Z\"}}") }
            if path.contains("/git/trees/") { return (200, [:], "{\"truncated\":false,\"tree\":[]}") }
            XCTFail("Unexpected request"); return (500, [:], "")
        }
        let client = GitHubClient(token: "test-only", session: session)
        do {
            _ = try await client.changeHistory(in: Repository("owner/repo"), branch: .init(name: "main", commit: .init(sha: old)), selected: old, remove: true) { entry in
                let saved = try JSONDecoder().decode(CommitRecovery.self, from: JSONEncoder().encode(entry))
                XCTAssertTrue(saved.valid); XCTAssertEqual(saved.repository, "owner/repo"); XCTAssertEqual(saved.oldHead, old); XCTAssertEqual(saved.newHead, parent)
                throw GitHubError("Storage full")
            }; XCTFail()
        } catch { XCTAssertEqual(error.localizedDescription, "Storage full") }
    }
    #if os(Linux) || os(macOS)
    func testRealGitRejectsAStaleBranchUpdate() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func git(_ arguments: [String], _ input: Data = Data()) throws -> Data {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "-C", folder.path] + arguments
            process.environment = ProcessInfo.processInfo.environment.merging(["GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.invalid", "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.invalid"]) { _, new in new }
            let stdin = Pipe(), stdout = Pipe(); process.standardInput = stdin; process.standardOutput = stdout; process.standardError = Pipe()
            try process.run(); stdin.fileHandleForWriting.write(input); try stdin.fileHandleForWriting.close()
            let data = stdout.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); return data
        }
        func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        _ = try git(["init", "--bare", "-q"])
        let tree = text(try git(["hash-object", "-t", "tree", "-w", "--stdin"]))
        let old = text(try git(["commit-tree", tree, "-m", "Original"]))
        let new = text(try git(["commit-tree", tree, "-p", old, "-m", "Next"]))
        _ = try git(["update-ref", "refs/heads/main", old])
        let success = try git(["receive-pack", "--stateless-rpc", folder.path], GitHistory.pushPacket(branch: "main", old: old, new: new))
        try GitHistory.validateReport(success, branch: "main")
        let stale = try git(["receive-pack", "--stateless-rpc", folder.path], GitHistory.pushPacket(branch: "main", old: old, new: old))
        XCTAssertThrowsError(try GitHistory.validateReport(stale, branch: "main"))
        XCTAssertEqual(text(try git(["rev-parse", "refs/heads/main"])), new)
    }
    #endif
    func testRevertAndReplayPreserveUnrelatedFilesAndRejectConflicts() throws {
        let a = GitTreeEntry(path: "a.txt", mode: "100644", type: "blob", sha: String(repeating: "a", count: 40))
        let b = GitTreeEntry(path: "a.txt", mode: "100644", type: "blob", sha: String(repeating: "b", count: 40))
        let extra = GitTreeEntry(path: "extra.txt", mode: "100755", type: "blob", sha: a.sha)
        let before = [a.path: a]; let after = [b.path: b]
        let reverted = try GitHistory.apply(from: after, to: before, onto: [b.path: b, extra.path: extra])
        XCTAssertEqual(reverted, [a.path: a, extra.path: extra])
        XCTAssertThrowsError(try GitHistory.apply(from: before, to: after, onto: [:]))
        XCTAssertEqual(try GitHistory.apply(from: before, to: [:], onto: before), [:])
    }
    func testGitPushUsesExpectedOldSHAAndRequiresExplicitSuccess() throws {
        let old = String(repeating: "a", count: 40), new = String(repeating: "b", count: 40)
        let packet = try GitHistory.pushPacket(branch: "feature/test", old: old, new: new)
        XCTAssertTrue(packet.starts(with: GitHistory.packet("\(old) \(new) refs/heads/feature/test\0report-status\n")))
        XCTAssertEqual(packet.suffix(32).prefix(4), Data("PACK".utf8))
        try GitHistory.validateReport(GitHistory.packet("unpack ok\n") + GitHistory.packet("ok refs/heads/feature/test\n") + Data("0000".utf8), branch: "feature/test")
        XCTAssertThrowsError(try GitHistory.validateReport(GitHistory.packet("unpack ok\n") + GitHistory.packet("ng refs/heads/feature/test stale info\n") + Data("0000".utf8), branch: "feature/test"))
        XCTAssertThrowsError(try GitHistory.pushPacket(branch: "main\nrefs/heads/other", old: old, new: new))
        XCTAssertThrowsError(try GitHistory.validateReport(Data("0000".utf8), branch: "main"))
    }
}
