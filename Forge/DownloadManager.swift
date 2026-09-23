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
                    let (temporary, response) = try await foreground.download(for: request, delegate: delegate)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try Task.checkCancellation()
                    if let http = response as? HTTPURLResponse, (300..<400).contains(http.statusCode),
                       let location = http.value(forHTTPHeaderField: "Location"), let url = URL(string: location, relativeTo: response.url)?.absoluteURL {
                        var redirected = request; redirected.url = url
                        guard let safe = DownloadSpec.redirect(redirected) else { throw GitHubError("GitHub returned an unsupported download location.") }
                        if url.host?.lowercased() == "api.github.com" { request = safe; continue }
                        let download = background.downloadTask(with: try DownloadSpec.backgroundRequest(for: url))
                        download.taskDescription = id.uuidString
                        transfers[id] = download
                        if let index = entries.firstIndex(where: { $0.id == id }) { entries[index].message = nil; entries[index].progress = nil }
                        persist(); download.resume(); return
                    }
                    try GitHubClient.validate(response)
                    // Direct API blob responses are streamed to disk here; no token is persisted in a background task.
                    finish(id, temporary: temporary, response: response)
                    return
                }
                throw GitHubError("GitHub redirected this download too many times.")
            } catch { fail(id, message: Task.isCancelled ? "Cancelled" : "\(error.localizedDescription) Tap Try again to reconnect.") }
        }
    }

    fileprivate func progress(_ id: UUID, value: Double?) {
        guard let index = entries.firstIndex(where: { $0.id == id && $0.active }) else { return }
        entries[index].progress = value
    }

    fileprivate func finish(_ id: UUID, temporary: URL, response: URLResponse?) {
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
            try? FileManager.default.removeItem(at: folder)
            fail(id, message: "\(error.localizedDescription) Tap Try again to reconnect.")
        }
    }

    fileprivate func fail(_ id: UUID, message: String) {
        transfers[id] = nil
        guard let index = entries.firstIndex(where: { $0.id == id && $0.active }) else { return }
        entries[index].active = false; entries[index].message = message; persist()
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
        MainActor.assumeIsolated { manager?.fail(id, message: "\(error.localizedDescription) Tap Try again to reconnect.") }
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
