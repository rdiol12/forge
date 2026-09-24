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
    var size: Int? = nil
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.path == rhs.path && lhs.mode == rhs.mode && lhs.type == rhs.type && lhs.sha == rhs.sha }
}

enum HistoryResolution: Sendable { case current, requested, edited(String) }

struct HistoryConflict: LocalizedError, Identifiable, Sendable {
    let path: String
    let before: GitTreeEntry?; let requested: GitTreeEntry?; let current: GitTreeEntry?
    let baseText: String?; let requestedText: String?; let currentText: String?
    var id: String { ([path] + [before, requested, current].map { $0.map { "\($0.mode):\($0.type):\($0.sha)" } ?? "absent" }).joined(separator: "\0") }
    var canEdit: Bool { baseText != nil && requestedText != nil && currentText != nil && before?.mode == requested?.mode && requested?.mode == current?.mode }
    var errorDescription: String? { "Review conflicting changes in \(path). No branch was changed. Choose or edit the final file, then confirm again." }
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
    // The API caller resolves text conflicts first; this guard protects all unresolved tree changes.
    static func apply(from before: [String: GitTreeEntry], to after: [String: GitTreeEntry], onto current: [String: GitTreeEntry]) throws -> [String: GitTreeEntry] {
        var result = current
        for path in Set(before.keys).union(after.keys) where before[path] != after[path] {
            if current[path] == after[path] { continue }
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
    static func mergeText(base: String, current: String, changed: String) -> String? {
        func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
        if same(base, current) { return changed }; if same(base, changed) || same(current, changed) { return current }
        let original = base.components(separatedBy: "\n")
        // ponytail: merge one changed span per side; complex overlapping spans go to the native conflict editor.
        func edit(_ text: String) -> (start: Int, end: Int, lines: [String]) {
            let lines = text.components(separatedBy: "\n"); var start = 0
            while start < min(original.count, lines.count), same(original[start], lines[start]) { start += 1 }
            var end = original.count, tail = lines.count
            while end > start, tail > start, same(original[end - 1], lines[tail - 1]) { end -= 1; tail -= 1 }
            return (start, end, Array(lines[start..<tail]))
        }
        let a = edit(current), b = edit(changed)
        guard !(a.start < b.end && b.start < a.end),
              !(a.start == a.end && a.start >= b.start && a.start <= b.end),
              !(b.start == b.end && b.start >= a.start && b.start <= a.end) else { return nil }
        var result = original
        for change in [a, b].sorted(by: { $0.start > $1.start }) { result.replaceSubrange(change.start..<change.end, with: change.lines) }
        return result.joined(separator: "\n")
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
    private func mergeHistory(path: String, before: [String: GitTreeEntry], after: [String: GitTreeEntry], current: [String: GitTreeEntry], resolutions: [String: HistoryResolution]) async throws -> [String: GitTreeEntry] {
        var expected = before, desired = after
        for file in Set(before.keys).union(after.keys).sorted() where before[file] != after[file] && current[file] != before[file] && current[file] != after[file] {
            func text(_ entry: GitTreeEntry?) async throws -> String? {
                guard let entry, entry.type == "blob", ["100644", "100755"].contains(entry.mode), let size = entry.size, (0...1_048_576).contains(size) else { return nil }
                guard GitHistory.validSHA(entry.sha) else { throw GitHubError("Invalid conflict file revision.") }
                struct Blob: Decodable { let content: String; let encoding: String; let size: Int }
                let blob: Blob = try await get("\(path)/git/blobs/\(entry.sha)")
                guard blob.encoding == "base64", blob.size == size, let data = Data(base64Encoded: blob.content.filter { !$0.isWhitespace }), data.count == size else { throw GitHubError("Incomplete conflict file. No branch was changed.") }
                return data.contains(0) ? nil : String(data: data, encoding: .utf8)
            }
            let baseText = try await text(before[file]), requestedText = try await text(after[file]), currentText = try await text(current[file])
            let conflict = HistoryConflict(path: file, before: before[file], requested: after[file], current: current[file], baseText: baseText, requestedText: requestedText, currentText: currentText)
            var resolution = resolutions[conflict.id]
            if resolution == nil, conflict.canEdit, let baseText, let currentText, let requestedText,
               let merged = GitHistory.mergeText(base: baseText, current: currentText, changed: requestedText) { resolution = .edited(merged) }
            guard let resolution else { throw conflict }
            expected[file] = current[file]
            switch resolution {
            case .current: desired[file] = current[file]
            case .requested: desired[file] = after[file]
            case .edited(let content):
                guard conflict.canEdit, let entry = after[file], content.utf8.count <= 1_048_576, !content.utf8.contains(0) else { throw GitHubError("Choose a file version or enter UTF-8 text under 1 MiB.") }
                struct Object: Decodable { let sha: String }
                let data = try await mutationData("\(path)/git/blobs", body: ["content": Data(content.utf8).base64EncodedString(), "encoding": "base64"])
                let blob = try Self.decoder().decode(Object.self, from: data)
                guard GitHistory.validSHA(blob.sha) else { throw GitHubError("GitHub did not confirm the merged file.") }
                desired[file] = GitTreeEntry(path: file, mode: entry.mode, type: "blob", sha: blob.sha, size: content.utf8.count)
            }
        }
        return try GitHistory.apply(from: expected, to: desired, onto: current)
    }

    func changeHistory(in repository: Repository, branch: RepositoryBranch, selected: String, remove: Bool, resolutions: [String: HistoryResolution] = [:], saveRecovery: (@Sendable (CommitRecovery) async throws -> Void)? = nil) async throws -> String {
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
                rebuilt = try await mergeHistory(path: path, before: previous, after: next, current: rebuilt, resolutions: resolutions)
                guard plan.reduce(0, { $0 + $1.1.count }) + rebuilt.count <= 250_000 else { throw GitHubError("This rewrite is too large for mobile editing. Use desktop Git.") }
                plan.append((item, rebuilt)); previous = next
            }
        } else {
            struct Comparison: Decodable { let status: String }
            let comparison: Comparison = try await get("\(path)/compare/\(selected)...\(branch.commit.sha)")
            guard ["ahead", "identical"].contains(comparison.status) else { throw GitHubError("The selected commit is outside this branch.") }
            let head = try await commit(branch.commit.sha)
            let current = try await tree(head.tree.sha)
            let result = try await mergeHistory(path: path, before: after, after: before, current: current, resolutions: resolutions)
            guard result != current else { throw GitHubError("This commit has no file changes to undo.") }
            plan.append((nil, result)); newHead = head.sha
        }
        struct Object: Decodable { let sha: String }
        // Resolved text can create unreferenced blobs; only the final expected-SHA push moves the branch.
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

    func restoreHistory(in repository: Repository, recovery: CommitRecovery, expected: String, reapply: Bool, resolutions: [String: HistoryResolution] = [:]) async throws {
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
            let entries = try await mergeHistory(path: path, before: before, after: after, current: current, resolutions: resolutions)
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
