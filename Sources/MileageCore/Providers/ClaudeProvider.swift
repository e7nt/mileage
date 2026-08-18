import Foundation

/// Reads Claude Code quota from Anthropic's OAuth usage endpoint — the same data behind `/usage`.
///
/// This endpoint rate-limits hard. The `User-Agent: claude-code/<version>` header is not optional:
/// without it requests land in a much stricter bucket and 429 persistently.
public struct ClaudeProvider: UsageProvider {
    public let id = ProviderID.claude

    private let http: HTTPFetching
    private let baseURL: URL
    private let clientVersion: String

    public init(
        http: HTTPFetching = URLSessionHTTPClient(),
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        clientVersion: String = ClaudeCLI.detectedVersion()
    ) {
        self.http = http
        self.baseURL = baseURL
        self.clientVersion = clientVersion
    }

    public func fetch(credential: ProviderCredential) async throws -> UsageSnapshot {
        guard case let .oauth(accessToken, _) = credential else {
            throw ProviderError.missingCredentials("Claude requires an OAuth token")
        }

        var request = URLRequest(url: baseURL.appending(path: "/api/oauth/usage"))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/\(clientVersion)", forHTTPHeaderField: "User-Agent")
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

        // The 5-hour session window is what actually stops you working, so it drives the menu bar.
        var gauges: [QuotaGauge] = []
        if let window = payload.five_hour {
            gauges.append(window.gauge(label: "5h", isPrimary: true))
        }
        if let window = payload.seven_day {
            gauges.append(window.gauge(label: "weekly"))
        }
        // Per-model weekly caps are null unless the plan actually has them.
        if let window = payload.seven_day_opus {
            gauges.append(window.gauge(label: "opus weekly"))
        }
        if let window = payload.seven_day_sonnet {
            gauges.append(window.gauge(label: "sonnet weekly"))
        }
        if let extra = payload.extra_usage, extra.is_enabled == true, let utilization = extra.utilization {
            gauges.append(QuotaGauge(label: "extra usage", kind: .percentUsed(utilization)))
        }

        guard !gauges.isEmpty else {
            throw ProviderError.decoding("No usage windows in response")
        }
        return UsageSnapshot(gauges: gauges, fetchedAt: now)
    }

    private struct Payload: Decodable {
        let five_hour: Window?
        let seven_day: Window?
        let seven_day_opus: Window?
        let seven_day_sonnet: Window?
        let extra_usage: ExtraUsage?
    }

    private struct Window: Decodable {
        let utilization: Double
        let resets_at: String?

        func gauge(label: String, isPrimary: Bool = false) -> QuotaGauge {
            QuotaGauge(
                label: label,
                kind: .percentUsed(utilization),
                resetsAt: resets_at.flatMap(FlexibleISO8601.date(from:)),
                isPrimary: isPrimary
            )
        }
    }

    private struct ExtraUsage: Decodable {
        let is_enabled: Bool?
        let utilization: Double?
    }
}

/// Locates the installed Claude Code so we can send a truthful client version.
public enum ClaudeCLI {
    /// Used when the CLI cannot be found. Kept recent enough to stay out of the punitive bucket.
    public static let fallbackVersion = "2.0.0"

    public static func detectedVersion(
        fileManager: FileManager = .default,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        // Local installs keep a package.json next to the launcher.
        let candidates = [
            home.appending(path: ".claude/local/node_modules/@anthropic-ai/claude-code/package.json"),
            URL(fileURLWithPath: "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/package.json"),
            URL(fileURLWithPath: "/usr/local/lib/node_modules/@anthropic-ai/claude-code/package.json"),
        ]
        for url in candidates {
            guard fileManager.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = json["version"] as? String
            else { continue }
            return version
        }
        return fallbackVersion
    }
}
