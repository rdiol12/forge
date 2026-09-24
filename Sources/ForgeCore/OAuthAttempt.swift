import Foundation

struct OAuthAttempt: Sendable {
    static let callback = "app.forge.github://oauth/callback"
    let state: String
    let verifier: String

    static func clientID(from data: Data, status: Int) throws -> String {
        struct Configuration: Decodable { let clientId: String }
        struct Failure: Decodable { let error: String }
        if status == 503, (try? JSONDecoder().decode(Failure.self, from: data).error) == "GitHub sign-in is not configured yet." {
            throw GitHubError("GitHub sign-in hasn't been enabled for Forge yet. Connect with a personal access token under Advanced.")
        }
        guard status == 200, let configuration = try? JSONDecoder().decode(Configuration.self, from: data), !configuration.clientId.isEmpty else {
            throw GitHubError("GitHub sign-in is temporarily unavailable. Try again later or use a token in Advanced settings.")
        }
        return configuration.clientId
    }

    func authorizationURL(clientID: String, challenge: String) throws -> URL {
        guard !clientID.isEmpty, !state.isEmpty, !challenge.isEmpty else { throw GitHubError("GitHub sign-in is unavailable.") }
        var url = URLComponents(string: "https://github.com/login/oauth/authorize")!
        url.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: Self.callback),
            URLQueryItem(name: "scope", value: "repo notifications user project workflow"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "select_account")
        ]
        guard let result = url.url else { throw GitHubError("Could not start GitHub sign-in.") }
        return result
    }

    func authorizationCode(from callback: URL) throws -> String {
        guard callback.scheme == "app.forge.github", callback.host == "oauth", callback.path == "/callback",
              callback.user == nil, callback.password == nil, callback.port == nil, callback.fragment == nil,
              let query = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
              query.filter({ $0.name == "state" }).count == 1,
              query.first(where: { $0.name == "state" })?.value == state else {
            throw GitHubError("Sign-in could not be verified. Please start again.")
        }
        guard !query.contains(where: { $0.name == "error" }) else { throw GitHubError("GitHub sign-in was declined or cancelled.") }
        guard query.filter({ $0.name == "code" }).count == 1,
              let code = query.first(where: { $0.name == "code" })?.value,
              code.range(of: #"^[A-Za-z0-9_-]{1,512}$"#, options: .regularExpression) != nil else {
            throw GitHubError("GitHub did not return a valid sign-in code.")
        }
        return code
    }
}
