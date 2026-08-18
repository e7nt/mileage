import Foundation

/// One tracked login. Several accounts may share a provider — that is the whole point of mileage.
public struct Account: Codable, Sendable, Identifiable, Equatable {
    /// Where this account's credentials come from, which decides what mileage is allowed to do
    /// with them.
    public enum Source: String, Codable, Sendable {
        /// Read from the CLI's own credential store at poll time. mileage does not own this
        /// grant and must never refresh or rewrite it — see SECURITY.md.
        case cli
        /// An OAuth grant mileage obtained itself and stores in the Keychain. Safe to refresh.
        case oauth
        /// A long-lived platform API key held in the Keychain.
        case apiKey
    }

    public let id: UUID
    public let provider: ProviderID
    public let source: Source
    /// User-supplied name, which always wins so people can call accounts "work" and "personal".
    public var label: String?
    /// Whatever the provider told us this account is — usually an email.
    public var detectedLabel: String?
    public var sortIndex: Int

    public init(
        id: UUID = UUID(),
        provider: ProviderID,
        source: Source,
        label: String? = nil,
        detectedLabel: String? = nil,
        sortIndex: Int = 0
    ) {
        self.id = id
        self.provider = provider
        self.source = source
        self.label = label
        self.detectedLabel = detectedLabel
        self.sortIndex = sortIndex
    }

    public var displayName: String {
        if let label, !label.isEmpty { return label }
        if let detectedLabel, !detectedLabel.isEmpty { return detectedLabel }
        return source == .cli ? "signed in via CLI" : provider.displayName
    }

    /// Only accounts mileage owns may have their tokens refreshed.
    public var isRefreshable: Bool { source == .oauth }
}

/// An OAuth grant mileage owns. Stored as JSON in the Keychain under the account's UUID.
public struct OAuthTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    /// Providers that need an account identifier alongside the bearer token (Codex).
    public var accountID: String?

    public init(accessToken: String, refreshToken: String, expiresAt: Date, accountID: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.accountID = accountID
    }

    /// Refresh a little early so a token cannot expire mid-request.
    public func isExpired(within margin: TimeInterval = 300, now: Date = Date()) -> Bool {
        expiresAt.timeIntervalSince(now) < margin
    }
}
