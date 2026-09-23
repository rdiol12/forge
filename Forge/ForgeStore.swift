import Foundation
import Observation
import Security

@MainActor @Observable
final class ForgeStore {
    private(set) var repositories: [Repository] = []
    private(set) var runs: [RepositoryRun] = []
    private(set) var releases: [RepositoryRelease] = []
    private(set) var readReleases: Set<String> = []
    private(set) var isRefreshing = false
    private(set) var refreshedAt: Date?
    private(set) var account = ""
    private(set) var hasToken = false
    var errors: [String] = []
    private var token = ""
    private var generation = 0
    private var refreshPending = false
    var client: GitHubClient { GitHubClient(token: token) }

    init() {
        let defaults = UserDefaults.standard
        repositories = (defaults.stringArray(forKey: "repositories") ?? []).compactMap { try? Repository($0) }
        readReleases = Set(defaults.stringArray(forKey: "readReleases") ?? [])
        do {
            token = try TokenKeychain.read() ?? ""
            hasToken = !token.isEmpty
            account = hasToken ? defaults.string(forKey: "account") ?? "Connected" : ""
        } catch { errors = [error.localizedDescription] }
    }

    func addRepository(_ input: String) async throws {
        let version = generation
        let repository = try await client.repository(Repository(input))
        guard version == generation else { throw CancellationError() }
        if !repositories.contains(where: { $0.id == repository.id }) {
            repositories.append(repository)
            saveRepositories()
        }
        await refresh()
    }

    func removeRepository(_ repository: Repository) {
        repositories.removeAll { $0.id == repository.id }
        runs.removeAll { $0.repository.id == repository.id }
        releases.removeAll { $0.repository.id == repository.id }
        saveRepositories()
    }

    private func saveRepositories() {
        UserDefaults.standard.set(repositories.map(\.fullName), forKey: "repositories")
    }

    func markRead(_ release: RepositoryRelease) {
        readReleases.insert(release.id)
        UserDefaults.standard.set(Array(readReleases), forKey: "readReleases")
    }

    func connect(_ input: String) async throws {
        let candidate = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, !candidate.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw GitHubError("Enter a valid personal access token.")
        }
        let account = try await GitHubClient(token: candidate).accountName()
        try TokenKeychain.save(candidate)
        generation += 1
        token = candidate
        hasToken = true
        self.account = account
        UserDefaults.standard.set(account, forKey: "account")
        runs = []
        releases = []
    }

    func disconnect() throws {
        try TokenKeychain.delete()
        generation += 1
        token = ""
        hasToken = false
        account = ""
        runs = []
        releases = []
        errors = []
        refreshedAt = nil
        UserDefaults.standard.removeObject(forKey: "account")
    }

    func refresh() async {
        guard !repositories.isEmpty else { return }
        guard !isRefreshing else { refreshPending = true; return }
        isRefreshing = true
        defer {
            isRefreshing = false
            if refreshPending {
                refreshPending = false
                Task { await self.refresh() }
            }
        }
        let version = generation
        let client = self.client
        errors = []
        for repository in repositories {
            if Task.isCancelled || version != generation { return }
            do {
                let fetched = try await client.runs(in: repository)
                guard !Task.isCancelled, version == generation else { return }
                if repositories.contains(where: { $0.id == repository.id }) {
                    runs.removeAll { $0.repository.id == repository.id }
                    runs += fetched.map { RepositoryRun(repository: repository, run: $0) }
                }
            } catch {
                if Task.isCancelled || version != generation { return }
                errors.append("\(repository.fullName) · Actions: \(error.localizedDescription)")
            }
            do {
                let fetched = try await client.releases(in: repository)
                guard !Task.isCancelled, version == generation else { return }
                if repositories.contains(where: { $0.id == repository.id }) {
                    releases.removeAll { $0.repository.id == repository.id }
                    releases += fetched.filter { !$0.draft }.map { RepositoryRelease(repository: repository, release: $0) }
                }
            } catch {
                if Task.isCancelled || version != generation { return }
                errors.append("\(repository.fullName) · Releases: \(error.localizedDescription)")
            }
        }
        runs.sort { $0.run.createdAt > $1.run.createdAt }
        releases.sort { ($0.release.publishedAt ?? .distantPast) > ($1.release.publishedAt ?? .distantPast) }
        if errors.isEmpty { refreshedAt = .now }
    }
}

enum TokenKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "app.forge.github-token",
         kSecAttrAccount as String: "github.com"]
    }

    static func read() throws -> String? {
        var query = Self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            throw GitHubError("The saved token could not be read from Keychain (\(status)). Unlock your iPhone and try again.")
        }
        return token
    }

    static func save(_ token: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8),
                                        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw GitHubError("Could not securely save the token (\(status)).") }
    }

    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GitHubError("Could not remove the token from Keychain (\(status)).")
        }
    }
}
