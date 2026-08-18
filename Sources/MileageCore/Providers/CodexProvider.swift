import Foundation

/// Reads Codex quota from the endpoint the Codex CLI's own rate-limit poller uses.
///
/// Note the wire format differs from the `rate_limits` struct the CLI writes into its session
/// rollout logs — that is an internal normalisation. This decodes what the endpoint actually
/// returns, verified against a live response.
///
/// Window names in the payload (`primary_window`/`secondary_window`) are positional labels, not
/// identities: on some plans the primary window is weekly and there is no secondary at all. The
/// real identity of a window is `limit_window_seconds`, so labels are derived from that.
public struct CodexProvider: UsageProvider {
    public let id = ProviderID.codex

    private let http: HTTPFetching
    private let baseURL: URL

    public init(
        http: HTTPFetching = URLSessionHTTPClient(),
        baseURL: URL = URL(string: "https://chatgpt.com")!
    ) {
        self.http = http
        self.baseURL = baseURL
    }

    public func fetch(credential: ProviderCredential) async throws -> UsageSnapshot {
        guard case let .oauth(accessToken, accountID) = credential else {
            throw ProviderError.missingCredentials("Codex requires an OAuth token")
        }

        var request = URLRequest(url: baseURL.appending(path: "/backend-api/wham/usage"))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await http.send(request)
        if let error = HTTPStatus.error(for: response, body: data) { throw error }
        return try parse(data)
    }

    func parse(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw ProviderError.decoding(String(describing: error))
        }

        // Shortest window first: it is the one that stops you working soonest.
        let windows = payload.rate_limit?.windows.sorted {
            ($0.limit_window_seconds ?? .max) < ($1.limit_window_seconds ?? .max)
        } ?? []

        var gauges: [QuotaGauge] = windows.enumerated().map { index, window in
            window.gauge(label: window.label, isPrimary: index == 0)
        }

        // Per-model caps (e.g. a Spark allowance) come through as their own limits.
        for extra in payload.additional_rate_limits ?? [] {
            guard let window = extra.rate_limit?.windows.first else { continue }
            gauges.append(window.gauge(label: extra.limit_name ?? "model limit"))
        }

        if let credits = payload.credits, credits.unlimited != true,
           let balance = credits.balance.flatMap { Decimal(string: $0) }, balance > 0
        {
            gauges.append(QuotaGauge(label: "credits", kind: .currency(amount: balance, code: "USD")))
        }

        guard !gauges.isEmpty else {
            throw ProviderError.decoding("No rate limit windows in response")
        }

        return UsageSnapshot(
            gauges: gauges,
            fetchedAt: now,
            planLabel: payload.plan_type,
            accountLabel: payload.email
        )
    }

    // MARK: - Wire format

    private struct Payload: Decodable {
        let email: String?
        let plan_type: String?
        let rate_limit: RateLimit?
        let additional_rate_limits: [AdditionalLimit]?
        let credits: Credits?
    }

    private struct AdditionalLimit: Decodable {
        let limit_name: String?
        let rate_limit: RateLimit?
    }

    private struct RateLimit: Decodable {
        let primary_window: Window?
        let secondary_window: Window?

        var windows: [Window] {
            [primary_window, secondary_window].compactMap { $0 }
        }
    }

    private struct Window: Decodable {
        let used_percent: Double
        let limit_window_seconds: Int?
        let reset_at: Int?

        var label: String {
            limit_window_seconds.map { windowLabel(minutes: $0 / 60) } ?? "usage"
        }

        func gauge(label: String, isPrimary: Bool = false) -> QuotaGauge {
            QuotaGauge(
                label: label,
                kind: .percentUsed(used_percent),
                // Unlike Anthropic, Codex sends a unix epoch here, not an ISO string.
                resetsAt: reset_at.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                isPrimary: isPrimary
            )
        }
    }

    private struct Credits: Decodable {
        let unlimited: Bool?
        /// Sent as a string, like DeepSeek's balances.
        let balance: String?
    }
}
