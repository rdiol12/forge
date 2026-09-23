import Foundation
import Observation

struct DownloadEntry: Identifiable, Codable {
    let id: UUID
    let specification: DownloadSpec
    let createdAt: Date
    var relativePath: String?
    var progress: Double?
    var message: String?
    var active = false
}

@MainActor @Observable
final class DownloadManager {
    private(set) var entries: [DownloadEntry] = []
    var errorMessage: String?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let session = URLSession(configuration: .ephemeral)
    private let directory: URL
    private let manifest: URL

    init() {
        let manager = FileManager.default
        directory = manager.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true)
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        manifest = support.appendingPathComponent("downloads.json")
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try manager.createDirectory(at: support, withIntermediateDirectories: true)
            var resource = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try resource.setResourceValues(values)
            if manager.fileExists(atPath: manifest.path) {
                entries = try JSONDecoder().decode([DownloadEntry].self, from: Data(contentsOf: manifest))
                entries = entries.filter { fileURL(for: $0) != nil }
            }
        } catch { errorMessage = "Could not load the download library: \(error.localizedDescription)" }
    }

    func fileURL(for entry: DownloadEntry) -> URL? {
        let expected = entry.id.uuidString + "/" + DownloadSpec.safeFilename(entry.specification.name)
        guard entry.relativePath == expected else { return nil }
        let url = directory.appendingPathComponent(expected).standardizedFileURL
        return url.path.hasPrefix(directory.standardizedFileURL.path + "/") && FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func start(_ specification: DownloadSpec, client: GitHubClient) {
        guard !entries.contains(where: { $0.specification.id == specification.id && $0.active }) else { return }
        let request: URLRequest
        do { request = try client.downloadRequest(specification) }
        catch { errorMessage = error.localizedDescription; return }
        let id = UUID()
        entries.insert(DownloadEntry(id: id, specification: specification, createdAt: .now, active: true), at: 0)
        tasks[id] = Task {
            defer { tasks[id] = nil }
            let delegate = TransferDelegate { [weak self] progress in
                Task { @MainActor in
                    guard let self, let index = self.entries.firstIndex(where: { $0.id == id && $0.active }) else { return }
                    self.entries[index].progress = progress
                }
            }
            do {
                // URLSession streams to disk; large ZIPs never become an in-memory Data object.
                let (temporary, response) = try await session.download(for: request, delegate: delegate)
                defer { try? FileManager.default.removeItem(at: temporary) }
                try Task.checkCancellation()
                try GitHubClient.validate(response)
                let folder = directory.appendingPathComponent(id.uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let destination = folder.appendingPathComponent(DownloadSpec.safeFilename(specification.name))
                try FileManager.default.moveItem(at: temporary, to: destination)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
                guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
                entries[index].relativePath = id.uuidString + "/" + destination.lastPathComponent
                entries[index].progress = 1
                entries[index].active = false
                persist()
            } catch {
                guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
                entries[index].active = false
                entries[index].message = Task.isCancelled || (error as? URLError)?.code == .cancelled ? "Cancelled" : error.localizedDescription
            }
        }
    }

    func cancel(_ entry: DownloadEntry) { tasks[entry.id]?.cancel() }
    func cancelAll() { for task in tasks.values { task.cancel() } }

    func remove(_ entry: DownloadEntry) {
        cancel(entry)
        do {
            if let url = fileURL(for: entry) {
                try FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
            entries.removeAll { $0.id == entry.id }
            persist()
        } catch { errorMessage = "Could not delete this download: \(error.localizedDescription)" }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(entries.filter { $0.relativePath != nil })
            try data.write(to: manifest, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { errorMessage = "The file is saved, but the download index could not be updated: \(error.localizedDescription)" }
    }
}

private final class TransferDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Double?) -> Void
    init(onProgress: @escaping @Sendable (Double?) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesExpectedToWrite > 0 ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(DownloadSpec.redirect(request))
    }
}
