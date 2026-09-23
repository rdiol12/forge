import Foundation

@main
struct CheckNative {
    static func main() async throws {
        // Optional developer token comes from stdin, never arguments, files, or logs.
        let token = CommandLine.arguments.contains("--authenticated") ? (readLine() ?? "") : ""
        let client = GitHubClient(token: token)
        if CommandLine.arguments.contains("--forge-build") {
            guard !token.isEmpty else { throw GitHubError("The private build check needs --authenticated and a developer token on stdin.") }
            try await checkForgeBuild(client)
            return
        }
        let repository = try Repository("cli/cli")
        let files: [RepositoryFile] = try await client.get("/repos/cli/cli/contents/")
        guard let readme = files.first(where: { $0.name == "README.md" }) else { fatalError("README missing") }
        let text = try await client.codeText(in: repository, file: readme)
        precondition(!text.isEmpty)
        print("Native code reader: \(text.utf8.count) bytes")
        for kind in [ConversationKind.issue, .pullRequest] {
            let page = try await client.conversations(kind: kind, repository: repository, account: "", search: "", state: "all", page: 1, cursor: nil)
            guard let item = page.items.first else { fatalError("Public conversation missing") }
            let detail = try await client.conversation(kind: kind, in: repository, number: item.number)
            precondition(detail.number == item.number)
            if !token.isEmpty, let id = detail.nodeId {
                _ = try await client.subscription(id: id)
                print("\(kind.title): watch status decoded (no changes made)")
            }
            let comments: [ConversationComment] = try await client.get("/repos/cli/cli/issues/\(item.number)/comments", page: 1, count: 30)
            print("\(kind.title): \(page.items.count) results; detail and \(comments.count) comments decoded")
            if kind == .pullRequest {
                let changes: [PullFile] = try await client.get("/repos/cli/cli/pulls/\(item.number)/files", page: 1, count: 100)
                let reviews: [ConversationComment] = try await client.get("/repos/cli/cli/pulls/\(item.number)/reviews", page: 1, count: 30)
                let reviewComments: [ConversationComment] = try await client.get("/repos/cli/cli/pulls/\(item.number)/comments", page: 1, count: 30)
                print("Pull request: \(changes.count) files, \(reviews.count) reviews, \(reviewComments.count) code comments")
                let settings: RepositoryMergeSettings = try await client.get("/repos/cli/cli")
                print("Merge methods: \(settings.methods.map(\.rawValue).joined(separator: ", "))")
                precondition(detail.head?.sha?.count == 40)
                if !token.isEmpty {
                    let threads = try await client.reviewThreads(in: repository, number: item.number, cursor: nil)
                    if let thread = threads.items.first {
                        _ = try await client.reviewThreadComments(id: thread.id, cursor: nil)
                    }
                    print("Review threads: \(threads.items.count), with permissions and comments decoded")
                }
            }
        }
        if !token.isEmpty {
            let community = try Repository("community/community")
            let page = try await client.conversations(kind: .discussion, repository: community, account: "", search: "", state: "all", page: 1, cursor: nil)
            precondition(!page.items.isEmpty)
            precondition(page.items.allSatisfy { $0.repository != nil }, "Every discussion must have a native repository destination")
            _ = try await client.conversations(kind: .discussion, repository: community, account: "", search: "", state: "all", page: 2, cursor: page.cursor)
            let detail = try await client.conversation(kind: .discussion, in: community, number: 28572)
            let comments = try await client.discussionComments(in: community, number: detail.number, cursor: nil)
            if let thread = comments.items.first(where: { ($0.replies?.totalCount ?? 0) > 0 }), let id = thread.nodeId {
                let replies = try await client.discussionReplies(commentID: id, cursor: nil)
                precondition(!replies.items.isEmpty)
                print("Discussion replies: \(replies.items.count)")
            }
            print("Discussions: search, cursor pagination, detail, and \(comments.items.count) comments decoded")
        } else { print("Discussion live check needs --authenticated and a developer token on stdin") }
    }

    private static func checkForgeBuild(_ client: GitHubClient) async throws {
        let repository = try Repository("rdiol12/forge-ios")
        let runs = try await client.runs(in: repository)
        guard let run = runs.first(where: { $0.conclusion == "success" }) else { throw GitHubError("No successful Forge build found.") }
        let jobs = try await client.jobs(in: repository, run: run, page: 1)
        let steps = jobs.flatMap { $0.steps ?? [] }
        guard steps.contains(where: { $0.name == "Test the shared Swift core" && $0.conclusion == "success" }) else { throw GitHubError("The workflow's passing Swift test step was not found.") }
        let artifacts = try await client.artifacts(in: repository, runID: run.id, page: 1)
        guard let artifact = artifacts.first(where: { $0.name.hasPrefix("Forge-unsigned-") && !$0.isExpired() }) else { throw GitHubError("No current IPA artifact found.") }
        let releases = try await client.releases(in: repository)
        guard let release = releases.first(where: { $0.tagName == "build-\(run.runNumber)-\(run.runAttempt)" && !$0.draft }) else { throw GitHubError("The build release was not found.") }
        let assets = try await client.assets(in: repository, releaseID: release.id, page: 1)
        guard assets.contains(where: { $0.name == "Forge-unsigned.ipa" }), assets.contains(where: { $0.name == "SHA256SUMS" }) else { throw GitHubError("IPA or checksum missing from release.") }
        let folder = URL(fileURLWithPath: "dist/api-check-build-\(run.runNumber)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var downloads = [(try DownloadSpec.artifact(artifact, in: repository), "Forge-actions-artifact.zip")]
        downloads += assets.filter { $0.name == "Forge-unsigned.ipa" || $0.name == "SHA256SUMS" }.map { (DownloadSpec.asset($0, in: repository), $0.name) }
        for (specification, name) in downloads {
            let (file, response) = try await client.session.download(for: client.downloadRequest(specification))
            defer { try? FileManager.default.removeItem(at: file) }
            try GitHubClient.validate(response)
            let data = try Data(contentsOf: file)
            guard !data.isEmpty else { throw GitHubError("Empty download: \(name)") }
            if name != "SHA256SUMS" { precondition(data.starts(with: [0x50, 0x4b, 0x03, 0x04])) }
            try data.write(to: folder.appendingPathComponent(name), options: .atomic)
            print("Downloaded \(name): \(data.count) bytes using Forge's authenticated API client")
        }
        print("Private Forge build \(run.runNumber): \(jobs.count) jobs, \(steps.count) steps, \(artifacts.count) artifacts, \(assets.count) release assets; test step passed")
    }
}
