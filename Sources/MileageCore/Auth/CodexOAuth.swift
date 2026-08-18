import Foundation

/// Codex's OAuth flow. Unlike Claude, the redirect target is a loopback URL we can listen on,
/// so sign-in completes without the user copying anything.
public enum CodexOAuth {
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    /// Fixed by the client registration — it cannot be moved to a free port.
    public static let callbackPort: UInt16 = 1455
    static let callbackPath = "/auth/callback"
    static let redirectURI = "http://localhost:1455/auth/callback"
    static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!

    public static func authorizationURL(pkce: PKCE, state: String) -> URL {
        var components = URLComponents(string: "https://auth.openai.com/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "openid profile email offline_access"),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // Needed for the id_token to carry the ChatGPT account id we send back as a header.
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: "mileage"),
        ]
        return components.url!
    }

    /// Runs the whole flow: opens nothing itself (the caller owns the browser), waits on the
    /// loopback callback, then exchanges the code.
    public static func awaitCallback(
        state: String,
        server: LoopbackCallbackServer,
        timeout: TimeInterval = 300
    ) async throws -> String {
        let items = try await server.waitForCallback(timeout: timeout)

        if let error = items["error"] {
            throw OAuthError.server(items["error_description"] ?? error)
        }
        guard items["state"] == state else { throw OAuthError.stateMismatch }
        guard let code = items["code"] else { throw OAuthError.malformedResponse }
        return code
    }

    public static func exchange(
        code: String,
        pkce: PKCE,
        http: HTTPFetching = URLSessionHTTPClient(),
        now: Date = Date()
    ) async throws -> OAuthTokens {
        let response = try await TokenEndpoint.post(
            url: tokenURL,
            body: TokenEndpoint.formEncoded([
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": redirectURI,
                "client_id": clientID,
                "code_verifier": pkce.verifier,
            ]),
            contentType: "application/x-www-form-urlencoded",
            http: http
        )
        guard let refreshToken = response.refresh_token else { throw OAuthError.malformedResponse }

        return OAuthTokens(
            accessToken: response.access_token,
            refreshToken: refreshToken,
            expiresAt: now.addingTimeInterval(response.expires_in ?? 3600),
            accountID: response.id_token.flatMap(accountID(fromIDToken:))
        )
    }

    public static func refresh(
        _ tokens: OAuthTokens,
        http: HTTPFetching = URLSessionHTTPClient(),
        now: Date = Date()
    ) async throws -> OAuthTokens {
        let response = try await TokenEndpoint.post(
            url: tokenURL,
            body: TokenEndpoint.formEncoded([
                "grant_type": "refresh_token",
                "refresh_token": tokens.refreshToken,
                "client_id": clientID,
                "scope": "openid profile email offline_access",
            ]),
            contentType: "application/x-www-form-urlencoded",
            http: http
        )

        return OAuthTokens(
            accessToken: response.access_token,
            refreshToken: response.refresh_token ?? tokens.refreshToken,
            expiresAt: now.addingTimeInterval(response.expires_in ?? 3600),
            accountID: response.id_token.flatMap(accountID(fromIDToken:)) ?? tokens.accountID
        )
    }

    /// The account id lives in one of three places depending on the account type.
    /// Read unverified — it only identifies which account to query, never grants anything.
    static func accountID(fromIDToken token: String) -> String? {
        guard let claims = JWT.claims(from: token) else { return nil }

        if let direct = claims["chatgpt_account_id"] as? String { return direct }
        if let auth = claims["https://api.openai.com/auth"] as? [String: Any] {
            if let nested = auth["chatgpt_account_id"] as? String { return nested }
            if let organizations = auth["organizations"] as? [[String: Any]],
               let first = organizations.first?["id"] as? String
            {
                return first
            }
        }
        return nil
    }

    static func email(fromIDToken token: String) -> String? {
        JWT.email(from: token)
    }
}
