import Foundation
import Testing

@testable import MileageCore

private func makeJWT(payload: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: payload)
    return "header.\(data.base64URLEncodedString()).signature"
}

// MARK: - PKCE

@Suite("PKCE")
struct PKCETests {
    @Test("Challenge matches the RFC 7636 test vector")
    func rfcVector() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("Generated verifiers are base64url with no padding, and are not reused")
    func generatesUrlSafeVerifiers() {
        let first = PKCE()
        let second = PKCE()

        #expect(first.verifier != second.verifier)
        for verifier in [first.verifier, second.verifier] {
            #expect(!verifier.contains("+"))
            #expect(!verifier.contains("/"))
            #expect(!verifier.contains("="))
        }
    }
}

// MARK: - Claude

@Suite("Claude OAuth")
struct ClaudeOAuthTests {
    @Test("Authorization URL carries the parameters the server requires")
    func authorizationURL() throws {
        let pkce = PKCE(verifier: "test-verifier")
        let url = ClaudeOAuth.authorizationURL(pkce: pkce)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })

        #expect(url.host == "claude.ai")
        // Without code=true the page redirects instead of showing a pasteable code.
        #expect(values["code"] == "true")
        #expect(values["client_id"] == ClaudeOAuth.clientID)
        #expect(values["code_challenge_method"] == "S256")
        #expect(values["code_challenge"] == pkce.challenge)
        // Claude Code reuses the verifier as the state value; the server expects that.
        #expect(values["state"] == pkce.verifier)
    }

    @Test("Splits a pasted code#state value and exchanges the code")
    func exchangesPastedCode() async throws {
        let http = StubHTTP(json: """
        {"access_token":"at","refresh_token":"rt","expires_in":3600}
        """)
        let pkce = PKCE(verifier: "verifier-abc")

        let tokens = try await ClaudeOAuth.exchange(
            pastedCode: "  the-code#verifier-abc  ",
            pkce: pkce,
            http: http,
            now: Date(timeIntervalSince1970: 0)
        )

        #expect(tokens.accessToken == "at")
        #expect(tokens.refreshToken == "rt")
        #expect(tokens.expiresAt == Date(timeIntervalSince1970: 3600))

        let body = try #require(http.lastRequest?.httpBody)
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(sent["code"] == "the-code")
        #expect(sent["code_verifier"] == "verifier-abc")
        #expect(sent["grant_type"] == "authorization_code")
    }

    @Test("A code pasted without its state is still accepted")
    func acceptsBareCode() async throws {
        let http = StubHTTP(json: """
        {"access_token":"at","refresh_token":"rt","expires_in":3600}
        """)
        let tokens = try await ClaudeOAuth.exchange(
            pastedCode: "just-the-code",
            pkce: PKCE(verifier: "v"),
            http: http
        )
        #expect(tokens.accessToken == "at")
    }

    @Test("A mismatched state is rejected before any token is requested")
    func rejectsStateMismatch() async {
        let http = StubHTTP(json: "{}")
        await #expect(throws: OAuthError.stateMismatch) {
            try await ClaudeOAuth.exchange(
                pastedCode: "code#someone-elses-state",
                pkce: PKCE(verifier: "mine"),
                http: http
            )
        }
        #expect(http.lastRequest == nil)
    }

    @Test("Refresh keeps the old refresh token when the server does not rotate it")
    func refreshKeepsToken() async throws {
        let http = StubHTTP(json: """
        {"access_token":"new-at","expires_in":1800}
        """)
        let existing = OAuthTokens(
            accessToken: "old",
            refreshToken: "keep-me",
            expiresAt: .distantPast
        )

        let refreshed = try await ClaudeOAuth.refresh(existing, http: http, now: Date(timeIntervalSince1970: 0))

        #expect(refreshed.accessToken == "new-at")
        #expect(refreshed.refreshToken == "keep-me")
        #expect(refreshed.expiresAt == Date(timeIntervalSince1970: 1800))
    }

    @Test("An OAuth error is surfaced with the server's own wording")
    func surfacesServerError() async {
        let http = StubHTTP(status: 400, json: """
        {"error":"invalid_grant","error_description":"Authorization code expired"}
        """)
        await #expect(throws: OAuthError.server("Authorization code expired")) {
            try await ClaudeOAuth.exchange(
                pastedCode: "code#v",
                pkce: PKCE(verifier: "v"),
                http: http
            )
        }
    }
}

// MARK: - Codex

@Suite("Codex OAuth")
struct CodexOAuthTests {
    @Test("Authorization URL includes the OpenAI-specific parameters")
    func authorizationURL() throws {
        let pkce = PKCE(verifier: "v")
        let url = CodexOAuth.authorizationURL(pkce: pkce, state: "state-123")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })

        #expect(url.host == "auth.openai.com")
        #expect(values["client_id"] == CodexOAuth.clientID)
        #expect(values["redirect_uri"] == "http://localhost:1455/auth/callback")
        #expect(values["scope"] == "openid profile email offline_access")
        // Without this the id_token omits the account id we need as a request header.
        #expect(values["id_token_add_organizations"] == "true")
        #expect(values["state"] == "state-123")
    }

    @Test("Token exchange is form-encoded, not JSON")
    func exchangeUsesFormEncoding() async throws {
        let http = StubHTTP(json: """
        {"access_token":"at","refresh_token":"rt","expires_in":3600}
        """)
        _ = try await CodexOAuth.exchange(code: "the-code", pkce: PKCE(verifier: "v"), http: http)

        let request = try #require(http.lastRequest)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")

        let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("code_verifier=v"))
    }

    @Test("Reads the account id from a top-level claim")
    func accountIDTopLevel() {
        let token = makeJWT(payload: ["chatgpt_account_id": "acct-top"])
        #expect(CodexOAuth.accountID(fromIDToken: token) == "acct-top")
    }

    @Test("Falls back to the namespaced auth claim")
    func accountIDNested() {
        let token = makeJWT(payload: [
            "https://api.openai.com/auth": ["chatgpt_account_id": "acct-nested"],
        ])
        #expect(CodexOAuth.accountID(fromIDToken: token) == "acct-nested")
    }

    @Test("Falls back again to the first organization")
    func accountIDFromOrganization() {
        let token = makeJWT(payload: [
            "https://api.openai.com/auth": ["organizations": [["id": "org-first"], ["id": "org-second"]]],
        ])
        #expect(CodexOAuth.accountID(fromIDToken: token) == "org-first")
    }

    @Test("A token with no account claim yields nil rather than a wrong id")
    func accountIDMissing() {
        #expect(CodexOAuth.accountID(fromIDToken: makeJWT(payload: ["sub": "x"])) == nil)
        #expect(CodexOAuth.accountID(fromIDToken: "not-a-jwt") == nil)
    }

    @Test("Extracts the email for labelling accounts")
    func readsEmail() {
        let token = makeJWT(payload: ["email": "someone@example.com"])
        #expect(CodexOAuth.email(fromIDToken: token) == "someone@example.com")
    }
}

// MARK: - Token expiry

@Suite("OAuth token expiry")
struct OAuthTokenTests {
    @Test("Tokens are considered expired slightly before they actually are")
    func refreshesEarly() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let tokens = OAuthTokens(
            accessToken: "a",
            refreshToken: "r",
            expiresAt: now.addingTimeInterval(120)
        )

        // Two minutes of life left is not enough to safely start a request.
        #expect(tokens.isExpired(now: now))
        #expect(!tokens.isExpired(within: 60, now: now))
    }
}
