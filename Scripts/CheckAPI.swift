import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Optional live integration check. Reads public GitHub data and downloads one small checksum file.
@main
struct CheckAPI {
    static func main() async throws {
        let client = GitHubClient()
        let repository = try await client.repository(Repository("cli/cli"))
        let runs = try await client.runs(in: repository)
        let releases = try await client.releases(in: repository)
        guard let release = releases.first(where: { !$0.draft }) else { throw GitHubError("No public release available.") }
        let assets = try await client.assets(in: repository, releaseID: release.id, page: 1)
        guard let asset = assets.first(where: { $0.name.hasSuffix("checksums.txt") && $0.size < 100_000 }) else {
            throw GitHubError("No small checksum asset available for the live check.")
        }
        let specification = DownloadSpec.asset(asset, in: repository)
        let (file, response) = try await client.session.download(for: client.downloadRequest(specification))
        defer { try? FileManager.default.removeItem(at: file) }
        try GitHubClient.validate(response)
        let content = try Data(contentsOf: file)
        guard content.count == asset.size, String(data: content, encoding: .utf8)?.contains(".tar.gz") == true else {
            throw GitHubError("Downloaded content did not match the expected checksum file.")
        }
        print("PASS: \(repository.fullName), \(runs.count) runs decoded, \(assets.count) release assets with real counts.")
        print("PASS: Downloaded \(asset.name), \(content.count) bytes via the app's API client and redirect policy.")
        if let run = runs.first {
            let jobs = try await client.jobs(in: repository, run: run, page: 1)
            let artifacts = try await client.artifacts(in: repository, runID: run.id, page: 1)
            print("PASS: Decoded \(jobs.count) jobs and \(artifacts.count) artifacts from a real Actions run.")
        }
    }
}
