import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// One cache per signed-in account. Replacing it also isolates late responses after sign-out.
actor APIMemoryCache {
    struct Value: Sendable {
        let data: Data
        let response: HTTPURLResponse
        let expires: Date
        let stored: Date
        var fresh: Bool { expires > .now }
    }
    private var values: [String: Value] = [:]
    private let capacity: Int
    private let lifetime: TimeInterval
    private(set) var epoch = 0
    init(capacity: Int = 16_777_216, lifetime: TimeInterval = 30) { self.capacity = capacity; self.lifetime = lifetime }
    private func key(_ request: URLRequest) -> String {
        [request.url!.absoluteString, request.value(forHTTPHeaderField: "Authorization") ?? "", request.value(forHTTPHeaderField: "Accept") ?? "", request.httpBody?.base64EncodedString() ?? ""].joined(separator: "\n")
    }
    func value(for request: URLRequest) -> Value? { values[key(request)] }
    func clear() { epoch += 1; values.removeAll() }
    func store(_ data: Data, response: HTTPURLResponse, for request: URLRequest, epoch: Int) {
        let control = response.value(forHTTPHeaderField: "Cache-Control")?.lowercased() ?? ""
        guard epoch == self.epoch else { return }
        if control.contains("no-store") { values[key(request)] = nil; return }
        guard response.statusCode == 200, data.count <= capacity else { return }
        if request.httpMethod == "POST", let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], json["errors"] != nil { return }
        let key = key(request); values[key] = nil
        while values.count >= 100 || values.values.reduce(0, { $0 + $1.data.count }) + data.count > capacity {
            guard let oldest = values.min(by: { $0.value.stored < $1.value.stored })?.key else { break }; values[oldest] = nil
        }
        let maxAge = control.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.hasPrefix("max-age=") }.flatMap { Double($0.dropFirst(8).replacingOccurrences(of: "\"", with: "")) }
        let ttl = control.contains("no-cache") ? 0 : max(0, min(lifetime, maxAge ?? lifetime))
        values[key] = Value(data: data, response: response, expires: .now.addingTimeInterval(ttl), stored: .now)
    }
}

extension GitHubClient {
    func cachedData(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let cache else { return try await session.data(for: request) }
        let epoch = await cache.epoch
        let old = await cache.value(for: request)
        if let old, old.fresh { return (old.data, old.response) }
        var conditional = request
        if let etag = old?.response.value(forHTTPHeaderField: "ETag") { conditional.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await session.data(for: conditional)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 304, let old {
                var headers = old.response.allHeaderFields as? [String: String] ?? [:]
                for (key, value) in http.allHeaderFields { if let key = key as? String, let value = value as? String { headers.keys.filter { $0.lowercased() == key.lowercased() }.forEach { headers[$0] = nil }; headers[key] = value } }
                let combined = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers) ?? old.response
                await cache.store(old.data, response: combined, for: request, epoch: epoch); return (old.data, combined)
            }
            await cache.store(data, response: http, for: request, epoch: epoch)
        }
        return (data, response)
    }
    func clearCache() async { await cache?.clear() }
}
