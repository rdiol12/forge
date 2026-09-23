import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct GitHubError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct GitHubClient: Sendable {
    let token: String
    let session: URLSession

    init(token: String = "", session: URLSession? = nil) {
        self.token = token
        self.session = session ?? Self.sharedSession
    }

    // Private repository responses and credentials are never cached to disk.
    private static let sharedSession = URLSession(configuration: .ephemeral, delegate: GitHubRedirectDelegate(), delegateQueue: nil)

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { value in
            let container = try value.singleValueContainer()
            let string = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid GitHub date")
        }
        return decoder
    }

    func request(_ path: String, query: [URLQueryItem] = [], accept: String = "application/vnd.github+json") throws -> URLRequest {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              !path.contains("?"), !path.contains("#"), !path.contains(":") else {
            throw GitHubError("Invalid GitHub API path.")
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw GitHubError("Invalid GitHub URL.") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Forge-iOS", forHTTPHeaderField: "User-Agent")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    func get<T: Decodable>(_ path: String, page: Int? = nil, count: Int = 100, query: [URLQueryItem] = []) async throws -> T {
        let query = query + (page.map { [URLQueryItem(name: "per_page", value: String(count)), URLQueryItem(name: "page", value: String($0))] } ?? [])
        let (data, response) = try await session.data(for: request(path, query: query))
        try Self.validate(response)
        return try Self.decoder().decode(T.self, from: data)
    }

    func repository(_ repository: Repository) async throws -> Repository {
        struct Response: Decodable { let fullName: String }
        let response: Response = try await get("/repos/\(repository.fullName)")
        return try Repository(response.fullName)
    }

    func accountName() async throws -> String {
        struct User: Decodable { let login: String }
        let user: User = try await get("/user")
        return user.login
    }

    func searchRepositories(_ query: String, page: Int) async throws -> [RepositorySummary] {
        struct Response: Decodable { let items: [RepositorySummary] }
        let response: Response = try await get("/search/repositories", page: page, count: 30,
                                              query: [URLQueryItem(name: "q", value: query)])
        return response.items
    }

    func notifications(page: Int) async throws -> [GitHubNotification] {
        try await get("/notifications", page: page, count: 50, query: [URLQueryItem(name: "all", value: "true")])
    }

    func runs(in repository: Repository) async throws -> [WorkflowRun] {
        struct Response: Decodable { let workflowRuns: [WorkflowRun] }
        let response: Response = try await get("/repos/\(repository.fullName)/actions/runs", page: 1, count: 30)
        return response.workflowRuns
    }

    func releases(in repository: Repository, page: Int = 1) async throws -> [Release] {
        try await get("/repos/\(repository.fullName)/releases", page: page, count: 20)
    }

    func jobs(in repository: Repository, run: WorkflowRun, page: Int) async throws -> [WorkflowJob] {
        struct Response: Decodable { let jobs: [WorkflowJob] }
        let response: Response = try await get("/repos/\(repository.fullName)/actions/runs/\(run.id)/attempts/\(run.runAttempt)/jobs", page: page)
        return response.jobs
    }

    func artifacts(in repository: Repository, runID: Int64, page: Int) async throws -> [Artifact] {
        struct Response: Decodable { let artifacts: [Artifact] }
        let response: Response = try await get("/repos/\(repository.fullName)/actions/runs/\(runID)/artifacts", page: page)
        return response.artifacts
    }

    func assets(in repository: Repository, releaseID: Int64, page: Int) async throws -> [ReleaseAsset] {
        try await get("/repos/\(repository.fullName)/releases/\(releaseID)/assets", page: page)
    }

    func downloadRequest(_ specification: DownloadSpec) throws -> URLRequest {
        guard !specification.requiresAuthentication || !token.isEmpty else {
            throw GitHubError("Connect a GitHub token in Settings to download Actions artifacts. It needs Actions read access to this repository.")
        }
        var request = try request(specification.path, accept: specification.accept)
        request.timeoutInterval = 60
        return request
    }

    static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw GitHubError("GitHub returned an invalid response.") }
        guard (200..<300).contains(http.statusCode) else {
            let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, item in
                result[String(describing: item.key)] = String(describing: item.value)
            }
            throw responseError(status: http.statusCode, headers: headers)
        }
    }

    static func responseError(status: Int, headers: [String: String]) -> GitHubError {
        let values = headers.reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
        if status == 429 || (status == 403 && (values["x-ratelimit-remaining"] == "0" || values["retry-after"] != nil)) {
            let retry = values["x-ratelimit-reset"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0).formatted(date: .omitted, time: .shortened) }
            return GitHubError("GitHub rate limit reached. \(retry.map { "Try again after \($0)." } ?? "Wait before refreshing again.") Public access has a lower limit; connect a token in Settings.")
        }
        switch status {
        case 401: return GitHubError("GitHub rejected the token. Replace it in Settings; it may have expired.")
        case 403: return GitHubError("GitHub denied access. Check the token's repository permissions and any organization approval requirements.")
        case 404: return GitHubError("Not found, or your token cannot access this repository or file.")
        case 410: return GitHubError("This artifact has expired and is no longer available to download.")
        default: return GitHubError("GitHub returned HTTP \(status). Try again later.")
        }
    }
}

final class GitHubRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(DownloadSpec.redirect(request))
    }
}
