import Foundation

/// Claude Code's OAuth flow, used to add accounts beyond whatever the CLI is signed into.
///
/// The redirect goes to a console.anthropic.com page we do not control, so there is no callback
/// to intercept: the page displays a `code#state` value the user pastes back. That is also the
/// fallback path Claude Code itself offers, so it is a well-trodden route rather than a hack.
public enum ClaudeOAuth {
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    static let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!

    /// Matches the CLI's scope set. Narrower sets are rejected by this client, so mileage asks
    /// for what the client is registered for — see SECURITY.md for why that includes
    /// `org:create_api_key`, which mileage never exercises.
    static let scopes = "org:create_api_key user:profile user:inference"

    public static func authorizationURL(pkce: PKCE) -> URL {
        var components = URLComponents(string: "https://claude.ai/oauth/authorize")!
        components.queryItems = [
            // Asks the server to show a pasteable code instead of redirecting silently.
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            // Claude Code reuses the verifier as the state value; the server expects that.
            URLQueryItem(name: "state", value: pkce.verifier),
        ]
        return components.url!
    }

    /// Accepts what the user pastes, which may be `code#state` or just the code.
    public static func exchange(
        pastedCode: String,
        pkce: PKCE,
        http: HTTPFetching = URLSessionHTTPClient(),
        now: Date = Date()
    ) async throws -> OAuthTokens {
        let trimmed = pastedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OAuthError.cancelled }

        let parts = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let code = String(parts[0])
        let state = parts.count > 1 ? String(parts[1]) : pkce.verifier

        guard state == pkce.verifier else { throw OAuthError.stateMismatch }

        let body = try JSONSerialization.data(withJSONObject: [
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": pkce.verifier,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "state": state,
        ])

        let response = try await TokenEndpoint.post(
            url: tokenURL,
            body: body,
            contentType: "application/json",
            http: http
        )
        guard let refreshToken = response.refresh_token else { throw OAuthError.malformedResponse }

        return OAuthTokens(
            accessToken: response.access_token,
            refreshToken: refreshToken,
            expiresAt: now.addingTimeInterval(response.expires_in ?? 3600)
        )
    }

    public static func refresh(
        _ tokens: OAuthTokens,
        http: HTTPFetching = URLSessionHTTPClient(),
        now: Date = Date()
    ) async throws -> OAuthTokens {
        let body = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": tokens.refreshToken,
            "client_id": clientID,
        ])

        let response = try await TokenEndpoint.post(
            url: tokenURL,
            body: body,
            contentType: "application/json",
            http: http
        )

        return OAuthTokens(
            accessToken: response.access_token,
            // Rotation is not guaranteed on every refresh; keep the old token when none comes back.
            refreshToken: response.refresh_token ?? tokens.refreshToken,
            expiresAt: now.addingTimeInterval(response.expires_in ?? 3600),
            accountID: tokens.accountID
        )
    }
}
