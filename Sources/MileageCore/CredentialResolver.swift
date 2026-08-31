import Foundation

/// Turns an `Account` into the credential a provider needs, refreshing owned grants when they
/// are close to expiry.
///
/// The asymmetry between sources is deliberate: grants mileage obtained itself are refreshed
/// freely, while CLI-owned grants are read and never touched.
@MainActor
public struct CredentialResolver {
    private let store: AccountStore
    private let http: HTTPFetching

    public init(store: AccountStore, http: HTTPFetching = URLSessionHTTPClient()) {
        self.store = store
        self.http = http
    }

    public struct Resolved: Sendable {
        public let credential: ProviderCredential
        /// A label the source revealed, e.g. the plan from the CLI file.
        public let detectedLabel: String?
    }

    public func resolve(_ account: Account) async throws -> Resolved {
        switch account.source {
        case .cli:
            return try resolveCLI(account)

        case .oauth:
            guard var tokens = try store.tokens(for: account.id) else {
                throw ProviderError.missingCredentials("Sign in again to restore this account")
            }
            if tokens.isExpired() {
                tokens = try await refresh(tokens, for: account)
            }
            return Resolved(
                credential: .oauth(accessToken: tokens.accessToken, accountID: tokens.accountID),
                detectedLabel: nil
            )

        case .apiKey:
            guard let key = try store.apiKey(for: account.id) else {
                throw ProviderError.missingCredentials("Add an API key for this account")
            }
            return Resolved(credential: .apiKey(key), detectedLabel: nil)
        }
    }

    /// Forces a refresh after a 401, so one stale access token costs a retry rather than an
    /// error the user has to act on.
    public func refreshAfterUnauthorized(_ account: Account) async throws -> Resolved {
        guard account.isRefreshable, let tokens = try store.tokens(for: account.id) else {
            throw ProviderError.unauthorized
        }
        let refreshed = try await refresh(tokens, for: account)
        return Resolved(
            credential: .oauth(accessToken: refreshed.accessToken, accountID: refreshed.accountID),
            detectedLabel: nil
        )
    }

    // MARK: - Private

    private func resolveCLI(_ account: Account) throws -> Resolved {
        let discovered: LocalCLICredentials.Discovered
        switch account.provider {
        case .claude:
            discovered = try LocalCLICredentials.claude()
            // Only Claude's file records an expiry; an expired one cannot be refreshed here.
            guard !discovered.isExpired else { throw ProviderError.unauthorized }
        case .codex:
            discovered = try LocalCLICredentials.codex()
        case .deepseek, .openrouter:
            throw ProviderError.missingCredentials("\(account.provider.displayName) has no CLI to read")
        }
        return Resolved(credential: discovered.credential, detectedLabel: discovered.label)
    }

    private func refresh(_ tokens: OAuthTokens, for account: Account) async throws -> OAuthTokens {
        let refreshed: OAuthTokens
        do {
            switch account.provider {
            case .claude:
                refreshed = try await ClaudeOAuth.refresh(tokens, http: http)
            case .codex:
                refreshed = try await CodexOAuth.refresh(tokens, http: http)
            case .deepseek, .openrouter:
                throw ProviderError.unauthorized
            }
        } catch {
            // A refresh token the provider has revoked means the account must be re-added;
            // there is nothing a retry can fix.
            throw ProviderError.unauthorized
        }

        // Persist before returning, and never swallow the failure. The provider has already
        // rotated the grant by this point, so the old refresh token may be dead: if the new one
        // does not reach the Keychain, the account is stranded and no retry can recover it.
        // Reporting it is the only thing that tells the user to re-add the account rather than
        // leaving them with an inexplicable "sign-in expired" days later.
        do {
            try store.setTokens(refreshed, for: account.id)
        } catch {
            throw ProviderError.credentialsNotSaved(
                "mileage refreshed this sign-in but could not save it (\(error.localizedDescription)). "
                    + "Remove and add the account again."
            )
        }
        return refreshed
    }
}
