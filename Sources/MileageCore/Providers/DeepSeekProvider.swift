import Foundation

/// Reads remaining DeepSeek platform credit. Unlike the other two providers this is a money
/// balance, not a percentage — there is no denominator to turn it into one.
public struct DeepSeekProvider: UsageProvider {
    public let id = ProviderID.deepseek

    private let http: HTTPFetching
    private let baseURL: URL

    public init(
        http: HTTPFetching = URLSessionHTTPClient(),
        baseURL: URL = URL(string: "https://api.deepseek.com")!
    ) {
        self.http = http
        self.baseURL = baseURL
    }

    public func fetch(credential: ProviderCredential) async throws -> UsageSnapshot {
        guard case let .apiKey(key) = credential else {
            throw ProviderError.missingCredentials("DeepSeek requires a platform API key")
        }

        var request = URLRequest(url: baseURL.appending(path: "/user/balance"))
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

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

        guard let balance = payload.balance_infos.first else {
            throw ProviderError.decoding("No balance information in response")
        }

        // Only the spendable total. The granted/topped-up split is an accounting detail that
        // answers a question nobody asks of a menu bar: what stops you is the total running out.
        let gauges = [
            QuotaGauge(
                label: "balance",
                kind: .currency(amount: balance.total, code: balance.currency),
                isPrimary: true
            ),
        ]

        return UsageSnapshot(
            gauges: gauges,
            fetchedAt: now,
            planLabel: payload.is_available ? nil : "insufficient balance"
        )
    }

    private struct Payload: Decodable {
        let is_available: Bool
        let balance_infos: [BalanceInfo]
    }

    private struct BalanceInfo: Decodable {
        let currency: String
        let total: Decimal

        // granted_balance and topped_up_balance are deliberately not decoded: mileage shows the
        // spendable total only, and decoding fields nothing reads invites someone to surface them.
        private enum CodingKeys: String, CodingKey {
            case currency
            case total_balance
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            currency = try container.decode(String.self, forKey: .currency)
            total = try Self.decimal(container, .total_balance)
        }

        /// DeepSeek sends these as JSON strings ("110.00"). Accept a bare number too, in case
        /// that ever changes, rather than failing the whole poll over a type.
        private static func decimal(
            _ container: KeyedDecodingContainer<CodingKeys>,
            _ key: CodingKeys
        ) throws -> Decimal {
            if let text = try? container.decode(String.self, forKey: key) {
                guard let value = Decimal(string: text) else {
                    throw ProviderError.decoding("Unparsable balance \"\(text)\" for \(key.stringValue)")
                }
                return value
            }
            return try container.decode(Decimal.self, forKey: key)
        }
    }
}
