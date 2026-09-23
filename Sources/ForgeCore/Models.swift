import Foundation

struct Repository: Codable, Hashable, Identifiable, Sendable {
    let fullName: String
    var id: String { fullName.lowercased() }
    var name: String { String(fullName.split(separator: "/").last ?? "") }

    init(_ input: String) throws {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}$"#
        guard value.range(of: pattern, options: .regularExpression) != nil,
              let name = value.split(separator: "/").last, name != ".", name != ".." else {
            throw GitHubError("Enter a repository as owner/name, for example cli/cli.")
        }
        fullName = value
    }
}

enum RunState: String, CaseIterable, Sendable {
    case passed = "Passed", failed = "Failed", running = "Running", queued = "Queued"
    case cancelled = "Cancelled", skipped = "Skipped", unknown = "Unknown"

    init(status: String, conclusion: String?) {
        switch status {
        case "in_progress": self = .running
        case "queued", "waiting", "pending", "requested": self = .queued
        case "completed":
            switch conclusion {
            case "success": self = .passed
            case "failure", "timed_out", "action_required", "startup_failure": self = .failed
            case "cancelled": self = .cancelled
            case "skipped", "neutral": self = .skipped
            default: self = .unknown
            }
        default: self = .unknown
        }
    }
}

struct WorkflowRun: Decodable, Identifiable, Sendable {
    let id: Int64
    let name: String?
    let displayTitle: String
    let headBranch: String?
    let headSha: String
    let status: String
    let conclusion: String?
    let runNumber: Int
    let runAttempt: Int
    let htmlUrl: URL
    let createdAt: Date
    let updatedAt: Date
    var state: RunState { RunState(status: status, conclusion: conclusion) }
}

struct WorkflowJob: Decodable, Identifiable, Sendable {
    let id: Int64
    let name: String
    let status: String
    let conclusion: String?
    let htmlUrl: URL?
    let steps: [JobStep]?
    var state: RunState { RunState(status: status, conclusion: conclusion) }
}

struct JobStep: Decodable, Identifiable, Sendable {
    let number: Int
    let name: String
    let status: String
    let conclusion: String?
    var id: Int { number }
    var state: RunState { RunState(status: status, conclusion: conclusion) }
}

struct Artifact: Decodable, Identifiable, Sendable {
    let id: Int64
    let name: String
    let sizeInBytes: Int64
    let expired: Bool
    let expiresAt: Date?
    func isExpired(at date: Date = .now) -> Bool { expired || (expiresAt.map { $0 <= date } ?? false) }
}

struct Release: Decodable, Identifiable, Sendable {
    let id: Int64
    let tagName: String
    let name: String?
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let publishedAt: Date?
    let htmlUrl: URL
    var title: String { name.flatMap { $0.isEmpty ? nil : $0 } ?? tagName }
}

struct ReleaseAsset: Decodable, Identifiable, Sendable {
    let id: Int64
    let name: String
    let size: Int64
    let downloadCount: Int64
    let contentType: String
}

struct RepositoryRun: Identifiable, Sendable {
    let repository: Repository
    let run: WorkflowRun
    var id: String { "\(repository.id)/\(run.id)" }
}

struct RepositoryRelease: Identifiable, Sendable {
    let repository: Repository
    let release: Release
    var id: String { "\(repository.id)/\(release.id)" }
}

struct RepositorySummary: Decodable, Identifiable, Sendable {
    let id: Int64
    let fullName: String
    let description: String?
    let stargazersCount: Int
    let language: String?
}

struct RepositoryFile: Decodable, Identifiable, Sendable {
    let name: String
    let path: String
    let sha: String
    let type: String
    let size: Int64
    var id: String { path }
    var safePath: Bool { !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." } }
}

struct GitHubNotification: Decodable, Identifiable, Sendable {
    struct Subject: Decodable, Sendable {
        let title: String
        let type: String
        let url: URL?
    }
    struct NotificationRepository: Decodable, Sendable { let fullName: String }
    let id: String
    var unread: Bool
    let updatedAt: Date
    let subject: Subject
    let repository: NotificationRepository

    var webURL: URL? {
        guard let repo = try? Repository(repository.fullName) else { return nil }
        let base = "https://github.com/\(repo.fullName)"
        guard let url = subject.url, url.scheme == "https", url.host == "api.github.com",
              url.path.hasPrefix("/repos/\(repo.fullName)/") else { return URL(string: base) }
        let parts = url.path.split(separator: "/")
        guard parts.count == 5, let number = Int64(parts[4]), number > 0 else { return URL(string: base) }
        switch parts[3] {
        case "pulls": return URL(string: "\(base)/pull/\(number)")
        case "issues": return URL(string: "\(base)/issues/\(number)")
        case "discussions": return URL(string: "\(base)/discussions/\(number)")
        default: return URL(string: base)
        }
    }
}
