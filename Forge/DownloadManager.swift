import Foundation
import Observation
import UIKit

@MainActor @Observable
final class DownloadManager {
    static let shared = DownloadManager()
    static let sessionID = "app.forge.github.downloads"
    private(set) var entries: [DownloadEntry] = []
    var errorMessage: String?
    var backgroundCompletion: (() -> Void)?
    private var preparing: [UUID: Task<Void, Never>] = [:]
    private var transfers: [UUID: URLSessionDownloadTask] = [:]
    private let foreground = URLSession(configuration: .ephemeral)
    private let directory: URL
    private let manifest: URL
    #if DEBUG
    private var downloadCheckTrace: [String] = []
    #endif
    fileprivate func record(_ phase: String, error: Error? = nil) {
        #if DEBUG
        var detail = phase
        if let error {
            let value = error as NSError
            detail += " \(value.domain) \(value.code)"
            if let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError { detail += " underlying \(underlying.domain) \(underlying.code)" }
        }
        downloadCheckTrace.append(detail)
        #endif
    }
    @ObservationIgnored private lazy var background: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: DownloadManager.sessionID)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        let delegate = BackgroundTransferDelegate(manager: self)
        return URLSession(configuration: config, delegate: delegate, delegateQueue: .main)
    }()

    init() {
        let manager = FileManager.default
        directory = manager.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true)
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        manifest = support.appendingPathComponent("downloads.json")
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try manager.createDirectory(at: support, withIntermediateDirectories: true)
            var resource = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try resource.setResourceValues(values)
            if manager.fileExists(atPath: manifest.path) { entries = try JSONDecoder().decode([DownloadEntry].self, from: Data(contentsOf: manifest)) }
        } catch { errorMessage = "Could not load the download library: \(error.localizedDescription)" }
        background.getAllTasks { tasks in
            Task { @MainActor in
                for task in tasks {
                    guard let download = task as? URLSessionDownloadTask, let id = task.taskDescription.flatMap(UUID.init(uuidString:)), self.entries.contains(where: { $0.id == id && $0.active }) else { task.cancel(); continue }
                    self.transfers[id] = download
                }
                for index in self.entries.indices {
                    let id = self.entries[index].id
                    if self.entries[index].active && self.transfers[id] == nil && self.preparing[id] == nil {
                        self.entries[index].active = false
                        self.entries[index].message = "Download interrupted. Tap Try again to reconnect."
                    }
                    if self.entries[index].relativePath != nil && self.fileURL(for: self.entries[index]) == nil {
                        self.entries[index].relativePath = nil
                        self.entries[index].message = "The saved file is missing. Tap Try again to download it."
                    }
                }
                self.persist()
            }
        }
    }

    func fileURL(for entry: DownloadEntry) -> URL? {
        let expected = entry.id.uuidString + "/" + DownloadSpec.safeFilename(entry.specification.name)
        guard entry.relativePath == expected else { return nil }
        let url = directory.appendingPathComponent(expected).standardizedFileURL
        return url.path.hasPrefix(directory.standardizedFileURL.path + "/") && FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func start(_ specification: DownloadSpec, client: GitHubClient) {
        guard !entries.contains(where: { $0.specification.id == specification.id && $0.active }) else { return }
        let initial: URLRequest
        do { initial = try client.downloadRequest(specification) }
        catch { errorMessage = error.localizedDescription; return }
        // A retry gets a new task identity, so a late cancellation callback cannot cancel its replacement.
        entries.removeAll { $0.specification.id == specification.id && !$0.active && $0.relativePath == nil }
        let id = UUID()
        entries.insert(DownloadEntry(id: id, specification: specification, createdAt: .now, message: "Connecting to GitHub…", active: true), at: 0)
        persist()
        preparing[id] = Task {
            defer { preparing[id] = nil }
            do {
                var request = initial
                // Resolve API redirects in the foreground, where credentials can be stripped before handing storage URLs to iOS.
                for _ in 0..<5 {
                    let delegate = PreparationDelegate { [weak self] progress in Task { @MainActor in self?.progress(id, value: progress) } }
                    // GitHub's redirect can have no body. A download task then fails before returning its Location.
                    var headers = request; headers.httpMethod = "HEAD"
                    record("Resolve headers")
                    let (_, response) = try await foreground.data(for: headers, delegate: delegate)
                    record("Headers HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                    try Task.checkCancellation()
                    if let http = response as? HTTPURLResponse, (300..<400).contains(http.statusCode),
                       let location = http.value(forHTTPHeaderField: "Location"), let url = URL(string: location, relativeTo: response.url)?.absoluteURL {
                        var redirected = request; redirected.url = url
                        guard let safe = DownloadSpec.redirect(redirected) else { throw GitHubError("GitHub returned an unsupported download location.") }
                        if url.host?.lowercased() == "api.github.com" { request = safe; continue }
                        let download = background.downloadTask(with: try DownloadSpec.backgroundRequest(for: url))
                        record("Background transfer")
                        download.taskDescription = id.uuidString
                        transfers[id] = download
                        if let index = entries.firstIndex(where: { $0.id == id }) { entries[index].message = nil; entries[index].progress = nil }
                        persist(); download.resume(); return
                    }
                    try GitHubClient.validate(response)
                    // Direct API blob responses are streamed to disk here; no token is persisted in a background task.
                    let (temporary, fileResponse) = try await foreground.download(for: request, delegate: delegate)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try Task.checkCancellation()
                    finish(id, temporary: temporary, response: fileResponse)
                    return
                }
                throw GitHubError("GitHub redirected this download too many times.")
            } catch { record("Preparation failed", error: error); fail(id, message: Task.isCancelled ? "Cancelled" : "\(error.localizedDescription) Tap Try again to reconnect.") }
        }
    }

    fileprivate func progress(_ id: UUID, value: Double?) {
        guard let index = entries.firstIndex(where: { $0.id == id && $0.active }) else { return }
        entries[index].progress = value
    }

    fileprivate func finish(_ id: UUID, temporary: URL, response: URLResponse?) {
        record("Save HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        guard let index = entries.firstIndex(where: { $0.id == id && $0.acceptsCompletion }) else { return }
        let folder = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        do {
            guard let response else { throw GitHubError("Missing download response.") }
            try GitHubClient.validate(response)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(DownloadSpec.safeFilename(entries[index].specification.name))
            try FileManager.default.moveItem(at: temporary, to: destination)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
            entries[index].relativePath = id.uuidString + "/" + destination.lastPathComponent
            entries[index].progress = 1; entries[index].active = false; entries[index].message = nil
            transfers[id] = nil; persist()
        } catch {
            record("Save failed", error: error)
            try? FileManager.default.removeItem(at: folder)
            fail(id, message: "\(error.localizedDescription) Tap Try again to reconnect.")
        }
    }

    fileprivate func fail(_ id: UUID, message: String) {
        transfers[id] = nil
        guard let index = entries.firstIndex(where: { $0.id == id && $0.active }) else { return }
        entries[index].active = false; entries[index].message = message; persist()
    }
    fileprivate func backgroundFailed(_ id: UUID, request: URLRequest?, error: Error) {
        record("Background failed", error: error)
        let code = (error as NSError)
        guard entries.contains(where: { $0.id == id && $0.active }), UIApplication.shared.applicationState == .active,
              code.domain == NSURLErrorDomain, [URLError.unknown.rawValue, URLError.cannotCreateFile.rawValue].contains(code.code),
              let request, request.value(forHTTPHeaderField: "Authorization") == nil else {
            fail(id, message: "\(error.localizedDescription) Tap Try again to reconnect."); return
        }
        // A sideloaded app or simulator may not have a working background transfer service.
        // Stream the same credential-free request once while the app is open.
        transfers[id] = nil
        preparing[id] = Task {
            defer { preparing[id] = nil }
            do {
                record("Foreground recovery")
                let (file, response) = try await foreground.download(for: request, delegate: GitHubRedirectDelegate())
                defer { try? FileManager.default.removeItem(at: file) }
                try Task.checkCancellation()
                finish(id, temporary: file, response: response)
            } catch { record("Foreground recovery failed", error: error); fail(id, message: Task.isCancelled ? "Cancelled" : "\(error.localizedDescription) Tap Try again to reconnect.") }
        }
    }
    func cancel(_ entry: DownloadEntry) {
        preparing[entry.id]?.cancel(); transfers[entry.id]?.cancel()
        fail(entry.id, message: "Cancelled")
    }
    func cancelAll() { for entry in entries where entry.active { cancel(entry) } }
    func remove(_ entry: DownloadEntry) {
        cancel(entry)
        do {
            if let url = fileURL(for: entry) { try FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            entries.removeAll { $0.id == entry.id }; persist()
        } catch { errorMessage = "Could not delete this download: \(error.localizedDescription)" }
    }
    private func persist() {
        do { try JSONEncoder().encode(entries).write(to: manifest, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        catch { errorMessage = "Could not update the download library: \(error.localizedDescription)" }
    }
}

#if DEBUG
extension DownloadManager {
    // Exercise the actual iOS transfer and sandbox, rather than a desktop API-only download.
    func checkReleaseDownload() async {
        let tokenFile = FileManager.default.temporaryDirectory.appendingPathComponent("download-check-token")
        let resultFile = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("download-check.json")
        var result: [String: String]
        do {
            let token = try String(contentsOf: tokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            try FileManager.default.removeItem(at: tokenFile)
            guard !token.isEmpty else { throw GitHubError("The simulator check needs its temporary read token.") }
            let client = GitHubClient(token: token), repository = try Repository("rdiol12/forge")
            guard let release = try await client.releases(in: repository).first else { throw GitHubError("No release to check.") }
            guard let asset = try await client.assets(in: repository, releaseID: release.id, page: 1).first(where: { $0.name == "SHA256SUMS" }) else { throw GitHubError("Release checksums missing.") }
            guard let run = try await client.runs(in: repository, status: "success").first,
                  let artifact = try await client.artifacts(in: repository, runID: run.id, page: 1).first(where: { !$0.isExpired() && $0.name.hasPrefix("Forge-unsigned-") }) else { throw GitHubError("No workflow artifact to check.") }
            let readme: RepositoryFile = try await client.get("/repos/\(repository.fullName)/contents/Sources/ForgeCore/Models.swift")
            let cases: [(DownloadSpec, (Data) -> Bool)] = [
                (.asset(asset, in: repository), { String(decoding: $0, as: UTF8.self).contains("Forge-unsigned.ipa") }),
                (try .artifact(artifact, in: repository), { $0.starts(with: [0x50, 0x4b, 0x03, 0x04]) }),
                (try .repositoryFile(readme, in: repository), { String(decoding: $0, as: UTF8.self).contains("struct Repository") })
            ]
            for (specification, valid) in cases {
                start(specification, client: client)
                let deadline = Date().addingTimeInterval(60)
                while entries.contains(where: { $0.specification.id == specification.id && $0.active }), Date() < deadline {
                    try await Task.sleep(for: .milliseconds(200))
                }
                guard let entry = entries.first(where: { $0.specification.id == specification.id }), let file = fileURL(for: entry) else {
                    throw GitHubError("\(specification.name): \(entries.first(where: { $0.specification.id == specification.id })?.message ?? errorMessage ?? "Download did not finish.")")
                }
                guard valid(try Data(contentsOf: file)) else { throw GitHubError("Unexpected contents in \(specification.name).") }
            }
            let failed = DownloadEntry(id: UUID(), specification: cases[0].0, createdAt: Date(), message: "Failed transfer", active: false)
            entries.append(failed); persist(); remove(failed)
            let restored = try JSONDecoder().decode([DownloadEntry].self, from: Data(contentsOf: manifest))
            guard !entries.contains(where: { $0.id == failed.id }), !restored.contains(where: { $0.id == failed.id }) else { throw GitHubError("A removed failed download returned to the library.") }
            result = ["status": "passed", "check": "Release, Actions artifact and repository file saved; failed download removed and persisted"]
        } catch { result = ["status": "failed", "error": error.localizedDescription, "trace": downloadCheckTrace.joined(separator: " | ")] }
        try? JSONEncoder().encode(result).write(to: resultFile, options: .atomic)
    }
}
#endif

private final class PreparationDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Double?) -> Void
    init(onProgress: @escaping @Sendable (Double?) -> Void) { self.onProgress = onProgress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesExpectedToWrite > 0 ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

private final class BackgroundTransferDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    weak var manager: DownloadManager?
    init(manager: DownloadManager) { self.manager = manager }
    // URLSession uses OperationQueue.main. Move temporary files before returning from the delegate callback.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        MainActor.assumeIsolated { manager?.finish(id, temporary: location, response: downloadTask.response) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        MainActor.assumeIsolated { manager?.progress(id, value: totalBytesExpectedToWrite > 0 ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : nil) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        MainActor.assumeIsolated { manager?.backgroundFailed(id, request: task.originalRequest, error: error) }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated { let completion = manager?.backgroundCompletion; manager?.backgroundCompletion = nil; completion?() }
    }
}

final class ForgeAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == DownloadManager.sessionID else { completionHandler(); return }
        DownloadManager.shared.backgroundCompletion = completionHandler
    }
}
