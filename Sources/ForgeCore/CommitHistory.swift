import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct HistoryCommit: Decodable, Identifiable, Sendable {
    struct Metadata: Decodable, Sendable {
        struct Author: Decodable, Sendable { let name: String; let date: String }
        let message: String; let author: Author?
    }
    struct Parent: Decodable, Sendable { let sha: String }
    struct File: Decodable, Identifiable, Sendable {
        let filename: String; let status: String; let additions: Int; let deletions: Int; let patch: String?
        var id: String { filename }
    }
    let sha: String; let commit: Metadata; let parents: [Parent]; let files: [File]?
    var id: String { sha }
}

struct GitTreeEntry: Codable, Equatable, Sendable {
    let path: String; let mode: String; let type: String; let sha: String
}

struct CommitRecovery: Codable, Identifiable, Sendable {
    let id: String
    let repository: String
    let branch: String
    let selected: String
    let oldHead: String
    let newHead: String
    let message: String
    let created: String
    var valid: Bool { (try? Repository(repository)) != nil && GitReference.validBranchName(branch) && [selected, oldHead, newHead].allSatisfy(GitHistory.validSHA) }
}

enum GitHistory {
    static func validSHA(_ sha: String) -> Bool { sha.range(of: "^[a-fA-F0-9]{40}$", options: .regularExpression) != nil }
    // ponytail: whole-file preimage checks; overlapping edits need desktop Git's three-way merge.
    static func apply(from before: [String: GitTreeEntry], to after: [String: GitTreeEntry], onto current: [String: GitTreeEntry]) throws -> [String: GitTreeEntry] {
        var result = current
        for path in Set(before.keys).union(after.keys) where before[path] != after[path] {
            guard current[path] == before[path] else { throw GitHubError("Conflicting changes in \(path). No branch was changed. Resolve this with desktop Git.") }
            result[path] = after[path]
        }
        for path in result.keys {
            var parts = path.split(separator: "/"); parts.removeLast()
            while !parts.isEmpty {
                guard result[parts.joined(separator: "/")] == nil else { throw GitHubError("A file/directory conflict needs desktop Git. No branch was changed.") }; parts.removeLast()
            }
        }
        return result
    }
    static func packet(_ value: String) -> Data { let bytes = Data(value.utf8); return Data(String(format: "%04x", bytes.count + 4).utf8) + bytes }
    static func pushPacket(branch: String, old: String, new: String) throws -> Data {
        guard GitReference.validBranchName(branch), branch.utf8.count <= 1024, validSHA(old), validSHA(new) else { throw GitHubError("Invalid branch update.") }
        // Empty PACK: objects were created in this repository with the Git Data API.
        let pack: [UInt8] = [0x50,0x41,0x43,0x4b,0,0,0,2,0,0,0,0,0x02,0x9d,0x08,0x82,0x3b,0xd8,0xa8,0xea,0xb5,0x10,0xad,0x6a,0xc7,0x5c,0x82,0x3c,0xfd,0x3e,0xd3,0x1e]
        return packet("\(old) \(new) refs/heads/\(branch)\0report-status\n") + Data("0000".utf8) + Data(pack)
    }
    static func validateReport(_ data: Data, branch: String) throws {
        let bytes = [UInt8](data); var offset = 0; var lines: [String] = []
        while offset + 4 <= bytes.count {
            guard let length = Int(String(decoding: bytes[offset..<offset+4], as: UTF8.self), radix: 16) else { throw GitHubError("Invalid Git response. Refresh the branch to check its state.") }
            offset += 4; if length == 0 { break }
            guard length >= 4, offset + length - 4 <= bytes.count else { throw GitHubError("Incomplete Git response. Refresh the branch to check its state.") }
            lines.append(String(decoding: bytes[offset..<offset+length-4], as: UTF8.self).trimmingCharacters(in: .newlines)); offset += length - 4
        }
        guard lines.contains("unpack ok"), lines.contains("ok refs/heads/\(branch)") else {
            throw GitHubError(lines.first(where: { $0.hasPrefix("ng ") }) ?? "GitHub did not confirm the branch update. Refresh and check repository rules.")
        }
    }
}

private struct GitObjectCommit: Decodable {
    struct Object: Decodable { let sha: String }
    struct Author: Codable { let name: String; let email: String; let date: String }
    let sha: String; let tree: Object; let parents: [Object]; let message: String; let author: Author
}

extension GitHubClient {
    func changeHistory(in repository: Repository, branch: RepositoryBranch, selected: String, remove: Bool, saveRecovery: (@Sendable (CommitRecovery) async throws -> Void)? = nil) async throws -> String {
        guard !token.isEmpty, GitReference.validBranchName(branch.name), GitHistory.validSHA(selected), GitHistory.validSHA(branch.commit.sha) else { throw GitHubError("Connect GitHub and select a valid branch and commit.") }
        await clearCache()
        let path = "/repos/\(repository.fullName)"
        let reference: GitReference = try await get("\(path)/git/ref/heads/\(branch.name)")
        guard reference.object.sha == branch.commit.sha else { throw GitHubError("This branch changed. Refresh the commit list before trying again.") }
        let settings: RepositoryOverview = try await get(path)
        guard settings.permissions?.push == true else { throw GitHubError("Repository write access is required.") }
        let chosen: GitObjectCommit = try await get("\(path)/git/commits/\(selected)")
        guard chosen.parents.count == 1 else { throw GitHubError("Root and merge commits need desktop Git. No branch was changed.") }
        var trees: [String: [String: GitTreeEntry]] = [:]
        func tree(_ sha: String) async throws -> [String: GitTreeEntry] {
            if let found = trees[sha] { return found }
            let entries = try await historyTree(path: path, sha: sha)
            guard trees.values.reduce(0, { $0 + $1.count }) + entries.count <= 250_000 else { throw GitHubError("This history is too large for mobile editing. Use desktop Git.") }
            trees[sha] = entries; return entries
        }
        func commit(_ sha: String) async throws -> GitObjectCommit { try await get("\(path)/git/commits/\(sha)") }
        let parent = try await commit(chosen.parents[0].sha)
        let before = try await tree(parent.tree.sha), after = try await tree(chosen.tree.sha)
        var plan: [(GitObjectCommit?, [String: GitTreeEntry])] = []
        var newHead = parent.sha
        if remove {
            var later: [GitObjectCommit] = []; var cursor = branch.commit.sha
            // ponytail: bounded rewrite; more than 200 later commits needs desktop Git.
            while cursor != selected {
                guard later.count < 200 else { throw GitHubError("More than 200 later commits. Use desktop Git to rewrite this history.") }
                let item = try await commit(cursor)
                guard item.parents.count == 1 else { throw GitHubError("This rewrite crosses a merge or the commit is outside this branch. Use desktop Git.") }
                later.append(item); cursor = item.parents[0].sha
            }
            var rebuilt = before; var previous = after
            for item in later.reversed() {
                let next = try await tree(item.tree.sha)
                rebuilt = try GitHistory.apply(from: previous, to: next, onto: rebuilt)
                guard plan.reduce(0, { $0 + $1.1.count }) + rebuilt.count <= 250_000 else { throw GitHubError("This rewrite is too large for mobile editing. Use desktop Git.") }
                plan.append((item, rebuilt)); previous = next
            }
        } else {
            struct Comparison: Decodable { let status: String }
            let comparison: Comparison = try await get("\(path)/compare/\(selected)...\(branch.commit.sha)")
            guard ["ahead", "identical"].contains(comparison.status) else { throw GitHubError("The selected commit is outside this branch.") }
            let head = try await commit(branch.commit.sha)
            let current = try await tree(head.tree.sha)
            let result = try GitHistory.apply(from: after, to: before, onto: current)
            guard result != current else { throw GitHubError("This commit has no file changes to undo.") }
            plan.append((nil, result)); newHead = head.sha
        }
        struct Object: Decodable { let sha: String }
        // Plan all changes before creating any objects; the branch moves only in the final atomic push.
        for (original, entries) in plan {
            try Task.checkCancellation()
            let list = entries.values.sorted { $0.path < $1.path }.map { ["path": $0.path, "mode": $0.mode, "type": $0.type, "sha": $0.sha] }
            let treeData = try await mutationData("\(path)/git/trees", body: ["tree": list])
            let newTree = try Self.decoder().decode(Object.self, from: treeData)
            var fields: [String: Any] = ["tree": newTree.sha, "parents": [newHead], "message": original?.message ?? "Revert \"\(chosen.message.components(separatedBy: .newlines).first ?? selected)\"\n\nThis reverts commit \(selected)."]
            if let author = original?.author { fields["author"] = ["name": author.name, "email": author.email, "date": author.date] }
            let data = try await mutationData("\(path)/git/commits", body: fields)
            newHead = try Self.decoder().decode(Object.self, from: data).sha
        }
        if remove {
            guard let saveRecovery else { throw GitHubError("Save a recovery record before removing history.") }
            let recovery = CommitRecovery(id: UUID().uuidString, repository: repository.fullName, branch: branch.name, selected: selected, oldHead: branch.commit.sha, newHead: newHead, message: chosen.message, created: ISO8601DateFormatter().string(from: .now))
            try await saveRecovery(recovery)
        }
        try await pushBranch(repository: repository, branch: branch.name, old: branch.commit.sha, new: newHead)
        await clearCache(); return newHead
    }

    private func historyTree(path: String, sha: String) async throws -> [String: GitTreeEntry] {
        struct Response: Decodable { let tree: [GitTreeEntry]; let truncated: Bool }
        let result: Response = try await get("\(path)/git/trees/\(sha)", query: [.init(name: "recursive", value: "1")])
        guard !result.truncated else { throw GitHubError("This repository tree is too large for safe mobile editing. Use desktop Git.") }
        return Dictionary(uniqueKeysWithValues: result.tree.filter { $0.type != "tree" }.map { ($0.path, $0) })
    }

    func restoreHistory(in repository: Repository, recovery: CommitRecovery, expected: String, reapply: Bool) async throws {
        guard recovery.valid, recovery.repository == repository.fullName, GitHistory.validSHA(expected) else { throw GitHubError("Invalid recovery point.") }
        await clearCache(); let path = "/repos/\(repository.fullName)"
        let ref: GitReference = try await get("\(path)/git/ref/heads/\(recovery.branch)")
        guard ref.object.sha == expected else { throw GitHubError("The branch changed. Refresh before restoring.") }
        var destination = recovery.oldHead
        if reapply {
            struct Comparison: Decodable { let status: String }
            let comparison: Comparison = try await get("\(path)/compare/\(recovery.selected)...\(expected)")
            guard !["ahead", "identical"].contains(comparison.status) else { throw GitHubError("This commit is already in the branch history.") }
            let chosen: GitObjectCommit = try await get("\(path)/git/commits/\(recovery.selected)")
            guard chosen.parents.count == 1 else { throw GitHubError("This commit needs desktop Git to reapply.") }
            let parent: GitObjectCommit = try await get("\(path)/git/commits/\(chosen.parents[0].sha)")
            let head: GitObjectCommit = try await get("\(path)/git/commits/\(expected)")
            let before = try await historyTree(path: path, sha: parent.tree.sha), after = try await historyTree(path: path, sha: chosen.tree.sha), current = try await historyTree(path: path, sha: head.tree.sha)
            let entries = try GitHistory.apply(from: before, to: after, onto: current)
            struct Object: Decodable { let sha: String }
            let treeData = try await mutationData("\(path)/git/trees", body: ["tree": entries.values.map { ["path": $0.path, "mode": $0.mode, "type": $0.type, "sha": $0.sha] }])
            let tree = try Self.decoder().decode(Object.self, from: treeData)
            let data = try await mutationData("\(path)/git/commits", body: ["tree": tree.sha, "parents": [expected], "message": chosen.message + "\n\nReapplied from \(chosen.sha) by Forge.", "author": ["name": chosen.author.name, "email": chosen.author.email, "date": chosen.author.date]])
            destination = try Self.decoder().decode(Object.self, from: data).sha
        } else {
            guard expected == recovery.newHead else { throw GitHubError("The branch has changed since removal. Use Reapply commit to preserve newer work, or recover the saved SHA with desktop Git.") }
        }
        try await pushBranch(repository: repository, branch: recovery.branch, old: expected, new: destination); await clearCache()
    }

    private func pushBranch(repository: Repository, branch: String, old: String, new: String) async throws {
        var url = URLComponents(); url.scheme = "https"; url.host = "github.com"; url.path = "/\(repository.fullName).git/git-receive-pack"
        var request = URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "POST"; request.httpBody = try GitHistory.pushPacket(branch: branch, old: old, new: new)
        request.setValue("application/x-git-receive-pack-request", forHTTPHeaderField: "Content-Type")
        request.setValue("application/x-git-receive-pack-result", forHTTPHeaderField: "Accept")
        request.setValue("Basic " + Data("x-access-token:\(token)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        let gitSession = URLSession(configuration: .ephemeral, delegate: GitPushRedirectDelegate(), delegateQueue: nil)
        defer { gitSession.invalidateAndCancel() }
        do {
            let (data, response) = try await gitSession.data(for: request)
            try Self.validate(response); try GitHistory.validateReport(data, branch: branch)
        } catch {
            await clearCache()
            if let ref: GitReference = try? await get("/repos/\(repository.fullName)/git/ref/heads/\(branch)"), ref.object.sha == new { return }
            throw GitHubError("\(error.localizedDescription) Refresh the branch before retrying. Git rejects the update if its previous SHA changed.")
        }
    }
}

private final class GitPushRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
