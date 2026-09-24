import Foundation

struct OfflineCopy: Codable, Identifiable, Sendable {
    let repository: String
    let branch: String
    let sha: String
    let saved: Date
    let files: [String: String]
    let omitted: Int
    var id: String { repository }
    var valid: Bool {
        (try? Repository(repository)) != nil && GitReference.validBranchName(branch) && GitHistory.validSHA(sha) && omitted >= 0 && files.count <= 100 &&
        files.values.reduce(0) { $0 + $1.utf8.count } <= 10_485_760 && files.allSatisfy { path, text in
            RepositoryFile(name: "", path: path, sha: sha, type: "file", size: 0).safePath && text.utf8.count <= 1_048_576 && !text.utf8.contains(0)
        }
    }
}

extension GitHubClient {
    func offlineCopy(in repository: Repository, branch: String, sha: String) async throws -> OfflineCopy {
        guard GitReference.validBranchName(branch), GitHistory.validSHA(sha) else { throw GitHubError("Choose a valid branch revision.") }
        struct Entry: Decodable { let path: String; let mode: String; let type: String; let sha: String; let size: Int? }
        struct Tree: Decodable { let tree: [Entry]; let truncated: Bool }
        struct Blob: Decodable { let content: String; let encoding: String; let size: Int }
        let tree: Tree = try await get("/repos/\(repository.fullName)/git/trees/\(sha)", query: [URLQueryItem(name: "recursive", value: "1")])
        guard !tree.truncated else { throw GitHubError("This repository is too large for an offline snapshot. Download individual files from Code.") }
        let entries = tree.tree.filter { $0.type != "tree" }.sorted { $0.path < $1.path }
        var files: [String: String] = [:], total = 0, fetched = 0
        // ponytail: explicit snapshots are capped at 100 text files / 10 MiB; larger repositories can use individual downloads.
        for entry in entries {
            try Task.checkCancellation()
            guard entry.type == "blob", ["100644", "100755"].contains(entry.mode), let size = entry.size, size >= 0, size <= 1_048_576,
                  fetched < 100, total + size <= 10_485_760 else { continue }
            guard GitHistory.validSHA(entry.sha), RepositoryFile(name: "", path: entry.path, sha: sha, type: "file", size: 0).safePath else { throw GitHubError("Invalid repository file metadata.") }
            fetched += 1
            let blob: Blob = try await get("/repos/\(repository.fullName)/git/blobs/\(entry.sha)")
            guard blob.encoding == "base64", blob.size == size, let data = Data(base64Encoded: blob.content.filter { !$0.isWhitespace }), data.count == size else { throw GitHubError("GitHub returned an incomplete file. The previous offline copy is unchanged.") }
            guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { continue }
            files[entry.path] = text; total += data.count
        }
        return OfflineCopy(repository: repository.fullName, branch: branch, sha: sha, saved: Date(), files: files, omitted: entries.count - files.count)
    }
}
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum PeopleCollection: String, CaseIterable, Sendable {
    case followers, following
    var title: String { rawValue.capitalized }
}

struct RepositoryBranch: Decodable, Identifiable, Sendable {
    struct Commit: Decodable, Sendable { let sha: String }
    let name: String
    let commit: Commit
    var id: String { name }
}

enum WorkflowAction: String, Identifiable, Sendable {
    case rerun = "rerun", rerunFailed = "rerun-failed-jobs", cancel = "cancel"
    var id: String { rawValue }
    var title: String { switch self { case .rerun: "Re-run all jobs"; case .rerunFailed: "Re-run failed jobs"; case .cancel: "Cancel run" } }
}

enum DiffSide: String, Sendable { case left = "LEFT", right = "RIGHT" }
struct DiffLine: Identifiable, Sendable {
    let id: Int
    let text: String
    let oldLine: Int?
    let newLine: Int?
    var side: DiffSide { text.hasPrefix("-") ? .left : .right }
    var commentLine: Int? { side == .left ? oldLine : newLine }

    static func parse(_ patch: String) -> [Self] {
        let header = try! NSRegularExpression(pattern: #"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#)
        var old: Int?, new: Int?
        return patch.components(separatedBy: "\n").enumerated().map { index, text in
            let source = text as NSString
            if let match = header.firstMatch(in: text, range: NSRange(location: 0, length: source.length)) {
                old = Int(source.substring(with: match.range(at: 1))); new = Int(source.substring(with: match.range(at: 2)))
                return Self(id: index, text: text, oldLine: nil, newLine: nil)
            }
            let left = text.hasPrefix(" ") || text.hasPrefix("-"), right = text.hasPrefix(" ") || text.hasPrefix("+")
            let line = Self(id: index, text: text, oldLine: left ? old : nil, newLine: right ? new : nil)
            if left, let value = old { old = value + 1 }
            if right, let value = new { new = value + 1 }
            return line
        }
    }
}

struct IssueEditDetails: Decodable, Sendable {
    struct Label: Decodable, Identifiable, Sendable { let name: String; var id: String { name } }
    let title: String
    let body: String?
    let user: GitHubAuthor?
    let updatedAt: Date
    let labels: [Label]
    let assignees: [GitHubAccount]
}

struct RepositorySettings: Decodable, Sendable {
    struct Permissions: Decodable, Sendable { let admin: Bool?; let push: Bool?; let triage: Bool?; let maintain: Bool? }
    let visibility: String
    let defaultBranch: String
    let permissions: Permissions?
    var canManageIssues: Bool { permissions?.push == true || permissions?.triage == true || permissions?.maintain == true || permissions?.admin == true }
}

extension GitHubClient {
    func setVisibility(in repository: Repository, expected: String, makePrivate: Bool) async throws {
        guard !token.isEmpty else { throw GitHubError("Connect GitHub before changing repository visibility.") }
        await clearCache()
        let current: RepositorySettings = try await get("/repos/\(repository.fullName)")
        guard current.permissions?.admin == true else { throw GitHubError("Only a repository administrator can change its visibility.") }
        guard current.visibility == expected, ["public", "private"].contains(expected) else { throw GitHubError("Repository visibility changed. Refresh before continuing.") }
        let data = try await mutationData("/repos/\(repository.fullName)", method: "PATCH", body: ["private": makePrivate])
        let saved = try Self.decoder().decode(RepositorySettings.self, from: data)
        guard saved.visibility == (makePrivate ? "private" : "public") else { throw GitHubError("GitHub did not confirm the visibility change. Refresh to check its state.") }
    }

    func updateFile(in repository: Repository, file: RepositoryFile, branch: String, text: String, message: String) async throws -> String {
        guard file.type == "file", file.safePath, GitReference.validBranchName(branch),
              file.sha.range(of: #"^(?:[a-fA-F0-9]{40}|[a-fA-F0-9]{64})$"#, options: .regularExpression) != nil,
              text.utf8.count <= 1_048_576, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GitHubError("Choose a branch, a valid text file under 1 MiB, and a commit message.") }
        let data = try await mutationData("/repos/\(repository.fullName)/contents/\(file.path)", method: "PUT", body: ["sha": file.sha, "branch": branch, "content": Data(text.utf8).base64EncodedString(), "message": message])
        struct Result: Decodable { struct Content: Decodable { let sha: String }; let content: Content? }
        guard let sha = try Self.decoder().decode(Result.self, from: data).content?.sha,
              sha.range(of: #"^(?:[a-fA-F0-9]{40}|[a-fA-F0-9]{64})$"#, options: .regularExpression) != nil else { throw GitHubError("GitHub did not confirm the saved file. Refresh before retrying.") }
        return sha
    }

    func editRelease(in repository: Repository, release: Release, name: String, notes: String, prerelease: Bool) async throws -> Release {
        guard release.id > 0 else { throw GitHubError("Invalid release.") }
        await clearCache()
        let current: Release = try await get("/repos/\(repository.fullName)/releases/\(release.id)")
        guard current.name == release.name, current.body == release.body, current.prerelease == release.prerelease else { throw GitHubError("This release changed while you were editing. Reopen the editor to load the latest notes.") }
        let data = try await mutationData("/repos/\(repository.fullName)/releases/\(release.id)", method: "PATCH", body: ["name": name, "body": notes, "prerelease": prerelease])
        return try Self.decoder().decode(Release.self, from: data)
    }

    func deleteRelease(in repository: Repository, id: Int64) async throws {
        guard id > 0 else { throw GitHubError("Invalid release.") }
        _ = try await mutationData("/repos/\(repository.fullName)/releases/\(id)", method: "DELETE", body: [:])
    }

    func people(login: String, collection: PeopleCollection, page: Int) async throws -> [GitHubAccount] {
        guard GitHubAccount.validLogin(login), page > 0 else { throw GitHubError("Invalid GitHub account or page.") }
        return try await get("/users/\(login)/\(collection.rawValue)", page: page, count: 30)
    }

    func branches(in repository: Repository, page: Int) async throws -> [RepositoryBranch] {
        try await get("/repos/\(repository.fullName)/branches", page: page, count: 100)
    }

    func files(in repository: Repository, path: String, sha: String) async throws -> [RepositoryFile] {
        guard sha.range(of: #"^(?:[a-fA-F0-9]{40}|[a-fA-F0-9]{64})$"#, options: .regularExpression) != nil,
              path.isEmpty || RepositoryFile(name: "", path: path, sha: sha, type: "dir", size: 0).safePath else { throw GitHubError("Invalid repository path or revision.") }
        return try await get("/repos/\(repository.fullName)/contents/\(path)", query: [URLQueryItem(name: "ref", value: sha)])
    }

    func controlRun(in repository: Repository, runID: Int64, action: WorkflowAction) async throws {
        guard runID > 0 else { throw GitHubError("Invalid workflow run.") }
        _ = try await mutationData("/repos/\(repository.fullName)/actions/runs/\(runID)/\(action.rawValue)", body: [:])
    }

    func jobLog(in repository: Repository, jobID: Int64) async throws -> String {
        guard jobID > 0 else { throw GitHubError("Invalid workflow job.") }
        let (file, response) = try await session.download(for: request("/repos/\(repository.fullName)/actions/jobs/\(jobID)/logs"))
        defer { try? FileManager.default.removeItem(at: file) }
        try Self.validate(response)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        // ponytail: preview the first 2 MiB; the complete log remains downloadable.
        let data = try handle.read(upToCount: 2_097_153) ?? Data()
        let truncated = data.count > 2_097_152
        let text = String(decoding: data.prefix(2_097_152), as: UTF8.self)
        return text.replacingOccurrences(of: #"\x1B\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            + (truncated ? "\n… Preview limited to 2 MiB. Download the full log below." : "")
    }

    func editIssue(in repository: Repository, number: Int, original: IssueEditDetails, title: String, body: String, labels: [String]?, assignees: [String]?) async throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard number > 0, !title.isEmpty, (assignees ?? []).allSatisfy(GitHubAccount.validLogin) else { throw GitHubError("Enter a title and valid GitHub assignees.") }
        await clearCache()
        let current: IssueEditDetails = try await get("/repos/\(repository.fullName)/issues/\(number)")
        guard current.updatedAt == original.updatedAt else { throw GitHubError("This issue changed while you were editing. Reopen the editor to load the latest version.") }
        var changes: [String: Any] = [:]
        if title != original.title { changes["title"] = title }
        if body != (original.body ?? "") { changes["body"] = body }
        if let labels, Set(labels) != Set(original.labels.map(\.name)) { changes["labels"] = labels }
        if let assignees, Set(assignees) != Set(original.assignees.map(\.login)) { changes["assignees"] = assignees }
        guard !changes.isEmpty else { return }
        let data = try await mutationData("/repos/\(repository.fullName)/issues/\(number)", method: "PATCH", body: changes)
        let saved = try Self.decoder().decode(IssueEditDetails.self, from: data)
        guard (changes["title"] == nil || saved.title == title), (changes["body"] == nil || (saved.body ?? "") == body),
              (changes["labels"] == nil || Set(saved.labels.map(\.name)) == Set(labels ?? [])),
              (changes["assignees"] == nil || Set(saved.assignees.map(\.login)) == Set(assignees ?? [])) else {
            throw GitHubError("GitHub saved only part of this edit. Reopen the editor to check the result and your Issues write permissions.")
        }
    }

    func addComment(in repository: Repository, number: Int, body: String) async throws {
        guard number > 0, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GitHubError("Write a comment first.") }
        _ = try await mutationData("/repos/\(repository.fullName)/issues/\(number)/comments", body: ["body": body])
    }

    func replyToDiscussion(id: String, replyTo: String?, body: String) async throws {
        guard !id.isEmpty, replyTo != "", !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GitHubError("Write a reply first.") }
        struct Result: Decodable { struct Added: Decodable { struct Comment: Decodable { let id: String }; let comment: Comment? }; let addDiscussionComment: Added? }
        let result: Result = try await graphQL("mutation($id:ID!,$reply:ID,$body:String!){addDiscussionComment(input:{discussionId:$id,replyToId:$reply,body:$body}){comment{id}}}", variables: ["id": id, "reply": replyTo as Any? ?? NSNull(), "body": body])
        guard result.addDiscussionComment?.comment != nil else { throw GitHubError("GitHub did not confirm the reply. Refresh before submitting again.") }
    }

    func commentOnLine(in repository: Repository, number: Int, sha: String, path: String, line: Int, side: DiffSide, body: String) async throws {
        try validatePullRevision(number: number, sha: sha)
        guard line > 0, RepositoryFile(name: "", path: path, sha: sha, type: "file", size: 0).safePath,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GitHubError("Select a changed line and write a comment.") }
        _ = try await mutationData("/repos/\(repository.fullName)/pulls/\(number)/comments", body: ["commit_id": sha, "path": path, "line": line, "side": side.rawValue, "body": body])
    }
}
