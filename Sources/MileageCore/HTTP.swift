import Foundation

/// Indirection over URLSession so tests can drive providers with canned responses
/// (including 429s) without touching the network.
public protocol HTTPFetching: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPClient: HTTPFetching {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.decoding("Non-HTTP response")
        }
        return (data, http)
    }
}

enum HTTPStatus {
    /// Maps a non-2xx response onto a ProviderError, pulling Retry-After out of 429s so the
    /// poller can honour the provider's own backoff hint instead of guessing.
    static func error(for response: HTTPURLResponse, body: Data) -> ProviderError? {
        switch response.statusCode {
        case 200 ..< 300:
            return nil
        case 401, 403:
            return .unauthorized
        case 429:
            let header = response.value(forHTTPHeaderField: "Retry-After")
            return .rateLimited(retryAfter: header.flatMap(TimeInterval.init))
        default:
            let text = String(data: body.prefix(512), encoding: .utf8) ?? ""
            return .http(status: response.statusCode, body: text)
        }
    }
}

/// Anthropic returns timestamps like "2026-04-11T07:00:00.528743+00:00" — six fractional digits,
/// which ISO8601DateFormatter does not reliably accept. Normalise to milliseconds, then fall back
/// to the no-fractional-seconds form.
public enum FlexibleISO8601 {
    /// Built per call rather than cached: ISO8601DateFormatter is not Sendable, and we parse
    /// only a handful of dates per poll, so there is nothing to gain from sharing one.
    private static func formatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }

    public static func date(from string: String) -> Date? {
        let withFraction = formatter(fractionalSeconds: true)
        if let date = withFraction.date(from: string) { return date }
        if let date = withFraction.date(from: truncatingFractionalSeconds(string)) { return date }
        return formatter(fractionalSeconds: false).date(from: strippingFractionalSeconds(string))
    }

    /// "…:00.528743+00:00" -> "…:00.528+00:00"
    private static func truncatingFractionalSeconds(_ string: String) -> String {
        guard let dot = string.firstIndex(of: ".") else { return string }
        let afterDot = string.index(after: dot)
        let digits = string[afterDot...].prefix(while: \.isNumber)
        guard digits.count > 3 else { return string }
        let tail = string[string.index(afterDot, offsetBy: digits.count)...]
        return String(string[..<afterDot]) + String(digits.prefix(3)) + String(tail)
    }

    /// "…:00.528743+00:00" -> "…:00+00:00"
    private static func strippingFractionalSeconds(_ string: String) -> String {
        guard let dot = string.firstIndex(of: ".") else { return string }
        let afterDot = string.index(after: dot)
        let digits = string[afterDot...].prefix(while: \.isNumber)
        let tail = string[string.index(afterDot, offsetBy: digits.count)...]
        return String(string[..<dot]) + String(tail)
    }
}

/// Codex reports window sizes in minutes; turn those into the labels a human recognises.
func windowLabel(minutes: Int) -> String {
    switch minutes {
    case 10080: "weekly"
    case ..<60: "\(minutes)m"
    case ..<1440: "\(minutes / 60)h"
    default: "\(minutes / 1440)d"
    }
}
