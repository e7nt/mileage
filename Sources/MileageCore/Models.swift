import Foundation

/// The providers mileage tracks. Ordering here is the ordering used in the menu bar.
public enum ProviderID: String, Codable, Sendable, CaseIterable, Identifiable {
    case claude
    case codex
    case deepseek
    case openrouter

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .deepseek: "DeepSeek"
        case .openrouter: "OpenRouter"
        }
    }

    /// Starting glyph for the menu bar, overridable per provider in Settings. Kept as short as
    /// it can be while staying distinct, so the bar fits every provider plus its numbers.
    public var defaultBarGlyph: String {
        switch self {
        case .claude: "C"
        case .codex: "X"
        case .deepseek: "D"
        case .openrouter: "OR"
        }
    }

    /// Whether this provider is added by pasting a platform API key rather than by signing in.
    /// Decides the wording of the add flow and what the empty state suggests.
    public var usesAPIKey: Bool {
        switch self {
        case .claude, .codex: false
        case .deepseek, .openrouter: true
        }
    }
}

/// A gauge is either a consumed-percentage window (Claude, Codex) or a money balance
/// (DeepSeek, OpenRouter).
/// Keeping both shapes in one type is what lets a single renderer handle every provider.
public enum QuotaGaugeKind: Sendable, Equatable {
    case percentUsed(Double)
    case currency(amount: Decimal, code: String)
}

/// One measurable quota window belonging to an account.
public struct QuotaGauge: Sendable, Equatable, Identifiable {
    /// Human label for the window: "5h", "weekly", "opus weekly", "balance".
    public let label: String
    public let kind: QuotaGaugeKind
    public let resetsAt: Date?
    /// The gauge that represents this account by default. Exactly one per snapshot.
    public let isPrimary: Bool

    public var id: String { label }

    public init(
        label: String,
        kind: QuotaGaugeKind,
        resetsAt: Date? = nil,
        isPrimary: Bool = false
    ) {
        self.label = label
        self.kind = kind
        self.resetsAt = resetsAt
        self.isPrimary = isPrimary
    }

    var isPercentage: Bool {
        if case .percentUsed = kind { return true }
        return false
    }

    /// Percentage still available, for percentage gauges only.
    public var remainingPercent: Double? {
        guard case let .percentUsed(used) = kind else { return nil }
        return max(0, 100 - used)
    }
}

/// The result of one successful poll of one account.
public struct UsageSnapshot: Sendable, Equatable {
    public let gauges: [QuotaGauge]
    public let fetchedAt: Date
    /// Provider-reported plan, e.g. "max 5x" or "prolite". Nil when the provider does not say.
    public let planLabel: String?
    /// Who this account belongs to, when the provider tells us — the reliable way to tell
    /// several accounts of the same provider apart.
    public let accountLabel: String?

    public init(
        gauges: [QuotaGauge],
        fetchedAt: Date,
        planLabel: String? = nil,
        accountLabel: String? = nil
    ) {
        self.gauges = gauges
        self.fetchedAt = fetchedAt
        self.planLabel = planLabel
        self.accountLabel = accountLabel
    }

    public var primaryGauge: QuotaGauge? {
        gauges.first(where: \.isPrimary) ?? gauges.first
    }

    /// The gauge closest to running out — the one that answers "what stops me first?".
    ///
    /// Comparison is restricted to gauges of the same kind as the primary, because a
    /// percentage and a dollar balance have no common scale.
    public var bindingGauge: QuotaGauge? {
        guard let primary = primaryGauge else { return nil }
        return gauges
            .filter { $0.isPercentage == primary.isPercentage }
            .min { $0.remainingScore < $1.remainingScore }
    }
}

/// How a provider authenticates a request.
public enum ProviderCredential: Sendable, Equatable {
    /// OAuth bearer token, plus the account identifier some providers require as a header.
    case oauth(accessToken: String, accountID: String?)
    /// A long-lived platform API key.
    case apiKey(String)
}

public protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    func fetch(credential: ProviderCredential) async throws -> UsageSnapshot
}

public enum ProviderError: Error, Sendable, Equatable {
    /// The provider asked us to slow down. `retryAfter` comes from the Retry-After header when present.
    case rateLimited(retryAfter: TimeInterval?)
    /// Token rejected — the account needs re-authentication.
    case unauthorized
    case http(status: Int, body: String)
    case decoding(String)
    case missingCredentials(String)
    /// A refreshed grant could not be written back. Distinct from `unauthorized` because the
    /// sign-in itself worked — it is the storage that failed, and the fix is different.
    case credentialsNotSaved(String)
}

extension ProviderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .rateLimited(retryAfter):
            if let retryAfter {
                return "Rate limited, retry in \(Int(retryAfter))s"
            }
            return "Rate limited"
        case .unauthorized:
            return "Sign-in expired"
        case let .http(status, _):
            return "Server error (\(status))"
        case let .decoding(detail):
            return "Unexpected response: \(detail)"
        case let .missingCredentials(detail):
            return detail
        case let .credentialsNotSaved(detail):
            return detail
        }
    }
}
