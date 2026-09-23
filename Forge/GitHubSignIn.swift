import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

@MainActor
final class GitHubSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var browser: ASWebAuthenticationSession?
    private let backend = URL(string: "https://forge-github-signin.j239pt2mgegnt9dxw7.chatgpt.site")!
    private let network = URLSession(configuration: .ephemeral, delegate: LoginRedirectPolicy(), delegateQueue: nil)

    func signIn() async throws -> String {
        struct Configuration: Decodable { let clientId: String }
        struct Token: Decodable { let accessToken: String; let tokenType: String }
        let (configurationData, configurationResponse) = try await network.data(from: backend.appendingPathComponent("oauth/config"))
        guard (configurationResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw GitHubError("GitHub sign-in is temporarily unavailable. Try again later or use a token in Advanced settings.")
        }
        let configuration = try JSONDecoder().decode(Configuration.self, from: configurationData)
        let attempt = OAuthAttempt(state: try Self.randomValue(), verifier: try Self.randomValue())
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(attempt.verifier.utf8))))
        let authorizationURL = try attempt.authorizationURL(clientID: configuration.clientId, challenge: challenge)
        let callback = try await authorize(authorizationURL)
        let code = try attempt.authorizationCode(from: callback)
        try Task.checkCancellation()
        var request = URLRequest(url: backend.appendingPathComponent("oauth/token"), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(["code": code, "codeVerifier": attempt.verifier])
        let (data, response) = try await network.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GitHubError("GitHub could not complete sign-in. Please start again.")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let token = try decoder.decode(Token.self, from: data)
        guard token.tokenType == "bearer", !token.accessToken.isEmpty else { throw GitHubError("GitHub returned an invalid sign-in response.") }
        return token.accessToken
    }

    private func authorize(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "app.forge.github") { callback, error in
                Task { @MainActor in self.browser = nil }
                if let callback { continuation.resume(returning: callback) }
                else { continuation.resume(throwing: error ?? GitHubError("GitHub sign-in was cancelled.")) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            browser = session
            if !session.start() {
                browser = nil
                continuation.resume(throwing: GitHubError("Could not open GitHub sign-in."))
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }

    private static func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw GitHubError("Could not securely start sign-in. Please try again.")
        }
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

private final class LoginRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // OAuth codes, verifiers, and tokens must never follow a backend redirect.
        completionHandler(nil)
    }
}
