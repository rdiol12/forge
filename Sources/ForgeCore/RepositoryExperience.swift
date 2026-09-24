import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct RepositoryOverview: Decodable, Sendable {
    struct License: Decodable, Sendable { let name: String; let spdxId: String? }
    let fullName: String
    let description: String?
    let defaultBranch: String
    let stargazersCount: Int
    let forksCount: Int
    let subscribersCount: Int?
    let openIssuesCount: Int
    let permissions: RepositorySettings.Permissions?
    let license: License?
}

struct PinnedRepository: Decodable, Identifiable, Sendable {
    let nameWithOwner: String
    let description: String?
    let stargazerCount: Int
    var id: String { nameWithOwner }
}

struct ProfileHighlights: Decodable, Sendable {
    struct Pins: Decodable, Sendable { let nodes: [PinnedRepository?] }
    let pinnedItems: Pins
    let isEmployee: Bool
    let isDeveloperProgramMember: Bool
    let isGitHubStar: Bool
    let isCampusExpert: Bool
    var badges: [String] {
        [(isEmployee, "GitHub Staff"), (isDeveloperProgramMember, "Developer Program"),
         (isGitHubStar, "GitHub Star"), (isCampusExpert, "Campus Expert")].filter(\.0).map(\.1)
    }
}

struct IssueFields {
    var title: String
    var body: String
    var assignees: [String] = []
    var labels: [String] = []
    var milestone: Int? = nil
    func payload() throws -> [String: Any] {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 256, assignees.allSatisfy(GitHubAccount.validLogin), assignees.count <= 10,
              milestone == nil || milestone! > 0 else { throw GitHubError("Enter a title and valid issue metadata.") }
        var value: [String: Any] = ["title": title, "body": body]
        if !assignees.isEmpty { value["assignees"] = assignees }
        if !labels.isEmpty { value["labels"] = labels }
        if let milestone { value["milestone"] = milestone }
        return value
    }
}

struct IssueOption: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    var detail = ""
}

struct IssueOptionPage: Sendable { let items: [IssueOption]; let more: Bool; var cursor: String? = nil }

struct ReadmeDocument: Sendable {
    struct Heading: Identifiable, Sendable { let id: String; let title: String; let level: Int }
    let repository: Repository
    let sha: String
    let path: String
    let html: String
    let headings: [Heading]
    var baseURL: URL { var c = URLComponents(); c.scheme = "https"; c.host = "github.com"; c.path = "/\(repository.fullName)/blob/\(sha)/\(path)"; return c.url! }

    init(html: String, repository: Repository, sha: String, path: String) throws {
        guard sha.range(of: "^[a-fA-F0-9]{40}$", options: .regularExpression) != nil,
              RepositoryFile(name: "", path: path, sha: sha, type: "file", size: 0).safePath else { throw GitHubError("Invalid README revision or path.") }
        self.repository = repository; self.sha = sha; self.path = path
        var source = html.replacingOccurrences(of: #"\s+srcset\s*=\s*(?:"[^"]*"|'[^']*')"#, with: "", options: [.regularExpression, .caseInsensitive])
        let regex = try NSRegularExpression(pattern: #"\bsrc\s*=\s*(["'])(.*?)\1"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
        var base = URLComponents(); base.scheme = "https"; base.host = "raw.githubusercontent.com"; base.path = "/\(repository.fullName)/\(sha)/\(path)"
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            let raw = (source as NSString).substring(with: match.range(at: 2)).replacingOccurrences(of: "&amp;", with: "&")
            var replacement = ""
            if let url = URL(string: raw, relativeTo: base.url)?.absoluteURL.standardized, url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443 {
                let rawPrefix = "/\(repository.fullName)/\(sha)/", webPrefix = "/\(repository.fullName)/raw/\(sha)/"
                let imagePath: String?
                if url.host == "raw.githubusercontent.com", url.path.hasPrefix(rawPrefix) { imagePath = String(url.path.dropFirst(rawPrefix.count)) }
                else if url.host == "github.com", url.path.hasPrefix(webPrefix) { imagePath = String(url.path.dropFirst(webPrefix.count)) }
                else { imagePath = nil }
                if let imagePath {
                    var local = URLComponents(); local.scheme = "forge-readme"; local.host = "image"; local.path = "/" + imagePath
                    replacement = local.url!.absoluteString
                } else { replacement = url.absoluteString }
            }
            source = (source as NSString).replacingCharacters(in: match.range, with: "src=\"\(Self.escape(replacement))\"")
        }
        let pattern = try NSRegularExpression(pattern: #"<h([1-6])\b[^>]*>(.*?)</h\1>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
        let matches = pattern.matches(in: source, range: NSRange(source.startIndex..., in: source))
        headings = matches.enumerated().map { index, match in
            var title = (source as NSString).substring(with: match.range(at: 2)).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            for (entity, value) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&")] { title = title.replacingOccurrences(of: entity, with: value) }
            return Heading(id: "forge-section-\(index)", title: title.trimmingCharacters(in: .whitespacesAndNewlines), level: Int((source as NSString).substring(with: match.range(at: 1))) ?? 1)
        }
        for (index, match) in matches.enumerated().reversed() { source = (source as NSString).replacingCharacters(in: NSRange(location: match.range.location, length: 0), with: "<span id=\"forge-section-\(index)\"></span>") }
        self.html = source
    }

    func imagePath(_ url: URL) -> String? {
        guard url.scheme == "forge-readme", url.host == "image", url.user == nil, url.port == nil, url.query == nil else { return nil }
        let path = String(url.path.dropFirst())
        return RepositoryFile(name: "", path: path, sha: sha, type: "file", size: 0).safePath ? path : nil
    }

    static func escape(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
    func page(dark: Bool, outline: Bool = false) -> String {
        let contents = outline && !headings.isEmpty ? "<nav aria-label=\"Contents\"><details open><summary>Contents</summary>" + headings.map { "<p style=\"margin:6px 0 6px \(($0.level - 1) * 12)px\"><a href=\"#\($0.id)\">\(Self.escape($0.title))</a></p>" }.joined() + "</details></nav>" : ""
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; img-src https: forge-readme:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"><style>
        :root{color-scheme:\(dark ? "dark" : "light")}body{margin:0;padding:16px;font:16px -apple-system,BlinkMacSystemFont,Roboto,sans-serif;line-height:1.55;overflow-wrap:anywhere;color:\(dark ? "#e6edf3" : "#1f2328");background:\(dark ? "#0d1117" : "white")}img,video{max-width:100%;height:auto}h1,h2{border-bottom:1px solid \(dark ? "#30363d" : "#d0d7de");padding-bottom:.3em}a{color:\(dark ? "#58a6ff" : "#0969da")}pre{overflow:auto;padding:12px;background:\(dark ? "#161b22" : "#f6f8fa");border-radius:8px}code{font-family:ui-monospace,monospace;font-size:.86em}table{display:block;overflow:auto;border-collapse:collapse}td,th{border:1px solid #8886;padding:6px 12px}blockquote{margin-left:0;border-left:3px solid #8886;padding-left:16px;color:#888}svg{max-width:100%}.anchor{display:none}input{pointer-events:none}
        </style></head><body>\(contents)\(html)</body></html>
        """
    }
}

extension GitHubClient {
    func editProfile(original: GitHubAccount, fields: [String: String], hireable: Bool) async throws {
        let allowed: Set<String> = ["name", "bio", "blog", "company", "location", "twitter_username"]
        guard Set(fields.keys).isSubset(of: allowed), (fields["bio"] ?? "").count <= 160 else { throw GitHubError("Use the supported profile fields and a bio of up to 160 characters.") }
        await clearCache()
        let current = try await profile()
        guard current.login == original.login else { throw GitHubError("The connected account changed. Reopen your profile.") }
        func values(_ user: GitHubAccount) -> [String: String] { ["name": user.name ?? "", "bio": user.bio ?? "", "blog": user.blog ?? "", "company": user.company ?? "", "location": user.location ?? "", "twitter_username": user.twitterUsername ?? ""] }
        let old = values(original), now = values(current)
        var payload: [String: Any] = [:]
        for (key, value) in fields where value != old[key] {
            guard now[key] == old[key] else { throw GitHubError("Your \(key) changed elsewhere. Reopen the editor to avoid overwriting it.") }
            payload[key] = value
        }
        if hireable != (original.hireable ?? false) {
            guard (current.hireable ?? false) == (original.hireable ?? false) else { throw GitHubError("Your availability changed elsewhere. Refresh your profile.") }
            payload["hireable"] = hireable
        }
        if !payload.isEmpty { _ = try await mutationData("/user", method: "PATCH", body: payload) }
    }
    func follows(login: String) async throws -> Bool {
        guard GitHubAccount.validLogin(login), !token.isEmpty else { return false }
        let (_, response) = try await session.data(for: request("/user/following/\(login)"))
        if (response as? HTTPURLResponse)?.statusCode == 404 { return false }; try Self.validate(response); return true
    }
    func follow(login: String, following: Bool) async throws {
        guard GitHubAccount.validLogin(login) else { throw GitHubError("Invalid account.") }
        _ = try await mutationData("/user/following/\(login)", method: following ? "PUT" : "DELETE", body: [:])
    }
    func readme(in repository: Repository, sha: String) async throws -> (RepositoryFile, ReadmeDocument) {
        let query = [URLQueryItem(name: "ref", value: sha)]
        let file: RepositoryFile = try await get("/repos/\(repository.fullName)/readme", query: query)
        guard file.size <= 1_048_576 else { throw GitHubError("This README is over 1 MiB. Open it in Code to download the complete file.") }
        let (data, response) = try await cachedData(for: request("/repos/\(repository.fullName)/readme", query: query, accept: "application/vnd.github.html+json"))
        try Self.validate(response)
        guard data.count <= 4_194_304 else { throw GitHubError("This rendered README is too large to preview.") }
        return (file, try ReadmeDocument(html: String(decoding: data, as: UTF8.self), repository: repository, sha: sha, path: file.path))
    }

    func readmeImage(_ url: URL, document: ReadmeDocument) async throws -> Data {
        guard let path = document.imagePath(url) else { throw GitHubError("Unsupported README image.") }
        let request = try request("/repos/\(document.repository.fullName)/contents/\(path)", query: [URLQueryItem(name: "ref", value: document.sha)], accept: "application/vnd.github.raw+json")
        let epoch = await cache?.epoch ?? 0
        if let entry = await cache?.value(for: request), entry.fresh { return entry.data }
        let (file, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }; try Self.validate(response)
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        let data = try handle.read(upToCount: 8_388_609) ?? Data()
        guard data.count <= 8_388_608 else { throw GitHubError("README images must be under 8 MiB.") }
        if let response = response as? HTTPURLResponse { await cache?.store(data, response: response, for: request, epoch: epoch) }; return data
    }

    func profileHighlights(login: String) async throws -> ProfileHighlights {
        guard GitHubAccount.validLogin(login) else { throw GitHubError("Invalid profile.") }
        struct Result: Decodable { let user: ProfileHighlights? }
        let result: Result = try await graphQL("query($login:String!){user(login:$login){isEmployee isDeveloperProgramMember isGitHubStar isCampusExpert pinnedItems(first:6,types:[REPOSITORY]){nodes{... on Repository{nameWithOwner description stargazerCount}}}}}", variables: ["login": login])
        guard let user = result.user else { throw GitHubError("Pinned repositories are unavailable for this account.") }; return user
    }

    func setStar(in repository: Repository, starred: Bool) async throws {
        _ = try await mutationData("/user/starred/\(repository.fullName)", method: starred ? "PUT" : "DELETE", body: [:])
    }
    func isStarred(_ repository: Repository) async throws -> Bool {
        guard !token.isEmpty else { return false }
        let (_, response) = try await session.data(for: request("/user/starred/\(repository.fullName)"))
        if (response as? HTTPURLResponse)?.statusCode == 404 { return false }; try Self.validate(response); return true
    }
    func editDescription(in repository: Repository, original: String, description: String) async throws {
        await clearCache()
        let current: RepositoryOverview = try await get("/repos/\(repository.fullName)")
        guard current.permissions?.admin == true, (current.description ?? "") == original else { throw GitHubError("Only an administrator can edit the description. Refresh if it changed elsewhere.") }
        _ = try await mutationData("/repos/\(repository.fullName)", method: "PATCH", body: ["description": description])
    }

    func issueOptions(in repository: Repository, kind: String, page: Int, cursor: String? = nil) async throws -> IssueOptionPage {
        let prefix = "/repos/\(repository.fullName)"
        switch kind {
        case "Assignees":
            let rows: [GitHubAccount] = try await get(prefix + "/assignees", page: page, count: 30)
            return IssueOptionPage(items: rows.map { IssueOption(id: $0.login, title: $0.login) }, more: rows.count == 30)
        case "Labels":
            struct Label: Decodable { let name: String; let description: String? }
            let rows: [Label] = try await get(prefix + "/labels", page: page, count: 30)
            return IssueOptionPage(items: rows.map { IssueOption(id: $0.name, title: $0.name, detail: $0.description ?? "") }, more: rows.count == 30)
        case "Milestone":
            struct Milestone: Decodable { let number: Int; let title: String; let description: String? }
            let rows: [Milestone] = try await get(prefix + "/milestones", page: page, count: 30, query: [URLQueryItem(name: "state", value: "open")])
            return IssueOptionPage(items: rows.map { IssueOption(id: String($0.number), title: $0.title, detail: $0.description ?? "") }, more: rows.count == 30)
        case "Project":
            struct Project: Decodable { let id: String; let title: String; let closed: Bool }
            struct Result: Decodable { struct Repo: Decodable { let projectsV2: GraphQLConnection<Project> }; let repository: Repo? }
            let parts = repository.fullName.split(separator: "/").map(String.init)
            let result: Result = try await graphQL("query($owner:String!,$name:String!,$cursor:String){repository(owner:$owner,name:$name){projectsV2(first:30,after:$cursor){nodes{id title closed}pageInfo{hasNextPage endCursor}}}}", variables: ["owner": parts[0], "name": parts[1], "cursor": cursor as Any? ?? NSNull()])
            guard let connection = result.repository?.projectsV2 else { throw GitHubError("No linked projects are accessible. Check Projects permission.") }
            return IssueOptionPage(items: connection.nodes.compactMap { $0 }.filter { !$0.closed }.map { IssueOption(id: $0.id, title: $0.title) }, more: connection.pageInfo.hasNextPage, cursor: connection.pageInfo.endCursor)
        default: throw GitHubError("Unknown issue field.")
        }
    }
    func createIssue(in repository: Repository, fields: IssueFields) async throws -> (Conversation, String?) {
        let data = try await mutationData("/repos/\(repository.fullName)/issues", body: fields.payload())
        let issue = try Self.decoder().decode(Conversation.self, from: data)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let labels = (object["labels"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        let assignees = (object["assignees"] as? [[String: Any]] ?? []).compactMap { $0["login"] as? String }
        let milestone = (object["milestone"] as? [String: Any])?["number"] as? Int
        let missing = !Set(fields.labels).isSubset(of: Set(labels)) || !Set(fields.assignees).isSubset(of: Set(assignees)) || (fields.milestone != nil && fields.milestone != milestone)
        return (issue, missing ? "The issue was created, but GitHub did not apply all selected metadata. Check your repository and token permissions." : nil)
    }
    func addIssueToProject(issueID: String, projectID: String) async throws {
        struct Result: Decodable { struct Added: Decodable { struct Item: Decodable { let id: String }; let item: Item? }; let addProjectV2ItemById: Added? }
        let result: Result = try await graphQL("mutation($project:ID!,$issue:ID!){addProjectV2ItemById(input:{projectId:$project,contentId:$issue}){item{id}}}", variables: ["project": projectID, "issue": issueID])
        guard result.addProjectV2ItemById?.item != nil else { throw GitHubError("GitHub did not confirm the project assignment.") }
    }
}
