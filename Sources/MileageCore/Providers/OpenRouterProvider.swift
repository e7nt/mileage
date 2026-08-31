import Foundation

/// Reads remaining OpenRouter credit. Like DeepSeek this is a money balance, but OpenRouter
/// reports it as two running totals rather than one figure, so the remainder is computed here.
public struct OpenRouterProvider: UsageProvider {
    public let id = ProviderID.openrouter

    /// OpenRouter bills in US dollars regardless of how the credits were bought, and the
    /// endpoint does not name a currency.
    private static let currencyCode = "USD"

    private let http: HTTPFetching
    private let baseURL: URL

    public init(
        http: HTTPFetching = URLSessionHTTPClient(),
        baseURL: URL = URL(string: "https://openrouter.ai/api/v1")!
    ) {
        self.http = http
        self.baseURL = baseURL
    }

    public func fetch(credential: ProviderCredential) async throws -> UsageSnapshot {
        guard case let .apiKey(key) = credential else {
            throw ProviderError.missingCredentials("OpenRouter requires a platform API key")
        }

        var request = URLRequest(url: baseURL.appending(path: "/credits"))
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await http.send(request)
        // 403 here does not mean the key is stale — it means this key is not allowed to read the
        // account's credits. Left to the generic mapping it would read as "sign-in expired" and
        // send the user to re-add a key that was never going to work.
        if response.statusCode == 403 {
            throw ProviderError.missingCredentials(
                "This key cannot read your OpenRouter credits. Create one at "
                    + "openrouter.ai/settings/keys that is allowed to."
            )
        }
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

        // OpenRouter reports lifetime purchased and lifetime spent; what you can still spend is
        // the difference. It can go negative on an overdrawn account, and that is shown as-is —
        // rounding it up to zero would hide the one state that needs acting on.
        let remaining = payload.data.total_credits - payload.data.total_usage

        return UsageSnapshot(
            gauges: [
                QuotaGauge(
                    label: "credits",
                    kind: .currency(amount: remaining, code: Self.currencyCode),
                    isPrimary: true
                ),
            ],
            fetchedAt: now
        )
    }

    private struct Payload: Decodable {
        let data: Credits
    }

    private struct Credits: Decodable {
        let total_credits: Decimal
        let total_usage: Decimal
    }
}
