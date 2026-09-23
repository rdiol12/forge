import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct DownloadSpec: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let repository: String
    let path: String
    let accept: String
    let size: Int64
    let requiresAuthentication: Bool

    static func asset(_ asset: ReleaseAsset, in repository: Repository) -> Self {
        Self(id: "asset-\(repository.id)-\(asset.id)", name: safeFilename(asset.name), repository: repository.fullName,
             path: "/repos/\(repository.fullName)/releases/assets/\(asset.id)", accept: "application/octet-stream",
             size: asset.size, requiresAuthentication: false)
    }

    static func artifact(_ artifact: Artifact, in repository: Repository, now: Date = .now) throws -> Self {
        guard !artifact.isExpired(at: now) else { throw GitHubError("This artifact has expired and cannot be downloaded.") }
        return Self(id: "artifact-\(repository.id)-\(artifact.id)", name: safeFilename(artifact.name + ".zip"), repository: repository.fullName,
                    path: "/repos/\(repository.fullName)/actions/artifacts/\(artifact.id)/zip", accept: "application/vnd.github+json",
                    size: artifact.sizeInBytes, requiresAuthentication: true)
    }

    static func safeFilename(_ input: String) -> String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let value = String(String.UnicodeScalarView(input.unicodeScalars.map { forbidden.contains($0) ? UnicodeScalar(95)! : $0 }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // ponytail: cap remote names at 180 UTF-8 bytes to fit iOS filesystem limits.
        var shortened = value
        while shortened.utf8.count > 180 { shortened.removeLast() }
        return shortened.isEmpty || shortened == "." || shortened == ".." ? "download" : shortened
    }

    static func redirect(_ incoming: URLRequest) -> URLRequest? {
        guard let url = incoming.url, url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return nil }
        let trusted = host == "api.github.com" || host == "github.com" || host.hasSuffix(".githubusercontent.com") || host.hasSuffix(".blob.core.windows.net")
        guard trusted else { return nil }
        var request = incoming
        if host != "api.github.com" {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
            request.setValue(nil, forHTTPHeaderField: "Cookie")
        }
        return request
    }
}
