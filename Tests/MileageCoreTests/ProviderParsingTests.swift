import Foundation
import Testing

@testable import MileageCore

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json"))
    return try Data(contentsOf: url)
}

// MARK: - Claude

@Suite("Claude usage parsing")
struct ClaudeParsingTests {
    @Test("Parses every non-null window and makes the 5h window primary")
    func parsesWindows() throws {
        let snapshot = try ClaudeProvider().parse(fixture("claude_usage"))

        // seven_day_opus is null, so it must not appear at all.
        #expect(snapshot.gauges.map(\.label) == ["5h", "weekly", "sonnet weekly"])
        #expect(snapshot.primaryGauge?.label == "5h")
    }

    @Test("Converts utilization into remaining percentage")
    func convertsToRemaining() throws {
        let snapshot = try ClaudeProvider().parse(fixture("claude_usage"))
        let fiveHour = try #require(snapshot.gauges.first)

        #expect(fiveHour.kind == .percentUsed(33.0))
        #expect(fiveHour.remainingPercent == 67.0)
        #expect(fiveHour.compactDisplay == "67%")
    }

    @Test("Parses six-digit fractional-second timestamps")
    func parsesTimestamps() throws {
        let snapshot = try ClaudeProvider().parse(fixture("claude_usage"))
        let resetsAt = try #require(snapshot.gauges.first?.resetsAt)

        var components = DateComponents()
        components.year = 2026
        components.month = 4
        components.day = 11
        components.hour = 7
        components.timeZone = TimeZone(identifier: "UTC")
        let expected = try #require(Calendar(identifier: .gregorian).date(from: components))

        #expect(abs(resetsAt.timeIntervalSince(expected)) < 1)
    }

    @Test("Disabled extra usage is omitted")
    func skipsDisabledExtraUsage() throws {
        let snapshot = try ClaudeProvider().parse(fixture("claude_usage"))
        #expect(!snapshot.gauges.contains { $0.label == "extra usage" })
    }

    @Test("A response with no windows is an error, not an empty snapshot")
    func rejectsEmptyResponse() throws {
        let empty = Data("{}".utf8)
        #expect(throws: ProviderError.self) {
            try ClaudeProvider().parse(empty)
        }
    }
}

// MARK: - Codex

@Suite("Codex usage parsing")
struct CodexParsingTests {
    @Test("Labels windows by duration, not by their positional name")
    func labelsByDuration() throws {
        // This plan's *primary* window is the weekly one and there is no secondary at all,
        // so trusting the "primary"/"secondary" names would mislabel it as a session window.
        let snapshot = try CodexProvider().parse(fixture("codex_usage"))

        #expect(snapshot.primaryGauge?.label == "weekly")
        #expect(snapshot.primaryGauge?.kind == .percentUsed(75))
        #expect(snapshot.planLabel == "prolite")
        #expect(snapshot.accountLabel == "someone@example.com")
    }

    @Test("Orders windows shortest-first regardless of which slot they arrived in")
    func ordersByWindowLength() throws {
        // Here the 5h window arrives in secondary_window and must still lead.
        let snapshot = try CodexProvider().parse(fixture("codex_usage_two_windows"))

        #expect(snapshot.gauges.prefix(2).map(\.label) == ["5h", "weekly"])
        #expect(snapshot.primaryGauge?.kind == .percentUsed(40))
    }

    @Test("Reads reset_at as a unix epoch rather than an ISO string")
    func parsesEpochResets() throws {
        let snapshot = try CodexProvider().parse(fixture("codex_usage"))
        let resetsAt = try #require(snapshot.primaryGauge?.resetsAt)

        #expect(resetsAt == Date(timeIntervalSince1970: 1_787_199_266))
    }

    @Test("Per-model allowances appear as their own gauges")
    func surfacesAdditionalLimits() throws {
        let snapshot = try CodexProvider().parse(fixture("codex_usage"))
        let spark = try #require(snapshot.gauges.first { $0.label == "GPT-5.3-Codex-Spark" })

        #expect(spark.kind == .percentUsed(0))
        #expect(!spark.isPrimary)
    }

    @Test("A zero credit balance is not shown as a gauge")
    func hidesZeroCredits() throws {
        let snapshot = try CodexProvider().parse(fixture("codex_usage"))
        #expect(!snapshot.gauges.contains { $0.label == "credits" })
    }

    @Test("A real credit balance is shown, decoded from its string form")
    func showsCredits() throws {
        let snapshot = try CodexProvider().parse(fixture("codex_usage_two_windows"))
        let credits = try #require(snapshot.gauges.first { $0.label == "credits" })

        #expect(credits.kind == .currency(amount: Decimal(string: "25.50")!, code: "USD"))
    }

    @Test("A response with no windows is an error, not an empty snapshot")
    func rejectsEmptyResponse() {
        #expect(throws: ProviderError.self) {
            try CodexProvider().parse(Data("{}".utf8))
        }
    }

    @Test("Unusual window sizes still get a sensible label")
    func labelsUnusualWindows() {
        #expect(windowLabel(minutes: 30) == "30m")
        #expect(windowLabel(minutes: 300) == "5h")
        #expect(windowLabel(minutes: 10080) == "weekly")
        #expect(windowLabel(minutes: 43200) == "30d")
    }
}

// MARK: - DeepSeek

@Suite("DeepSeek balance parsing")
struct DeepSeekParsingTests {
    @Test("Decodes balances that arrive as JSON strings")
    func decodesStringBalances() throws {
        let snapshot = try DeepSeekProvider().parse(fixture("deepseek_balance"))

        #expect(snapshot.primaryGauge?.kind == .currency(amount: Decimal(string: "14.20")!, code: "USD"))
    }

    @Test("Only the spendable total is shown, never the accounting breakdown")
    func showsOnlyTheTotal() throws {
        // The fixture carries granted and topped-up figures; neither belongs in the menu bar.
        let snapshot = try DeepSeekProvider().parse(fixture("deepseek_balance"))

        #expect(snapshot.gauges.map(\.label) == ["balance"])
    }

    @Test("Also accepts numeric balances, in case the API changes")
    func decodesNumericBalances() throws {
        let json = """
        {"is_available":true,"balance_infos":[{"currency":"USD","total_balance":9.5,
        "granted_balance":0,"topped_up_balance":9.5}]}
        """
        let snapshot = try DeepSeekProvider().parse(Data(json.utf8))

        #expect(snapshot.primaryGauge?.kind == .currency(amount: Decimal(string: "9.5")!, code: "USD"))
    }

    @Test("An exhausted account is flagged")
    func flagsUnavailable() throws {
        let json = """
        {"is_available":false,"balance_infos":[{"currency":"CNY","total_balance":"0.00",
        "granted_balance":"0.00","topped_up_balance":"0.00"}]}
        """
        let snapshot = try DeepSeekProvider().parse(Data(json.utf8))

        #expect(snapshot.planLabel == "insufficient balance")
        #expect(snapshot.primaryGauge?.severity() == .critical)
    }
}

// MARK: - HTTP

@Suite("HTTP error mapping")
struct HTTPStatusTests {
    private func response(_ status: Int, headers: [String: String] = [:]) throws -> HTTPURLResponse {
        try #require(HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        ))
    }

    @Test("429 carries the provider's Retry-After hint through to the poller")
    func mapsRateLimit() throws {
        let error = HTTPStatus.error(for: try response(429, headers: ["Retry-After": "120"]), body: Data())
        #expect(error == .rateLimited(retryAfter: 120))
    }

    @Test("429 without a hint still maps to rate limited")
    func mapsRateLimitWithoutHint() throws {
        let error = HTTPStatus.error(for: try response(429), body: Data())
        #expect(error == .rateLimited(retryAfter: nil))
    }

    @Test("401 and 403 mean re-authentication, not retry")
    func mapsUnauthorized() throws {
        #expect(HTTPStatus.error(for: try response(401), body: Data()) == .unauthorized)
        #expect(HTTPStatus.error(for: try response(403), body: Data()) == .unauthorized)
    }

    @Test("Success produces no error")
    func mapsSuccess() throws {
        #expect(HTTPStatus.error(for: try response(200), body: Data()) == nil)
    }
}

// MARK: - Date parsing

@Suite("Flexible ISO8601 parsing")
struct FlexibleISO8601Tests {
    @Test(
        "Handles the fractional-second precisions Anthropic actually sends",
        arguments: [
            "2026-04-11T07:00:00.528743+00:00",
            "2026-04-11T07:00:00.528+00:00",
            "2026-04-11T07:00:00+00:00",
            "2026-04-11T07:00:00Z",
        ]
    )
    func parsesVariants(_ input: String) throws {
        let parsed = try #require(FlexibleISO8601.date(from: input))
        let expected = Date(timeIntervalSince1970: 1_775_890_800)
        #expect(abs(parsed.timeIntervalSince(expected)) < 1)
    }

    @Test("Garbage returns nil rather than a wrong date")
    func rejectsGarbage() {
        #expect(FlexibleISO8601.date(from: "not a date") == nil)
    }
}

// MARK: - Formatting

@Suite("Formatting")
struct FormattingTests {
    @Test("Severity follows remaining, not consumed")
    func severityThresholds() {
        #expect(Formatting.severity(remainingPercent: 80) == .healthy)
        #expect(Formatting.severity(remainingPercent: 30) == .warning)
        #expect(Formatting.severity(remainingPercent: 5) == .critical)
    }

    @Test("Currency stays narrow as the number grows")
    func compactCurrency() {
        #expect(Formatting.compactCurrency(Decimal(string: "3.4")!, code: "USD") == "$3.40")
        #expect(Formatting.compactCurrency(Decimal(string: "14.2")!, code: "USD") == "$14")
        #expect(Formatting.compactCurrency(Decimal(string: "1240")!, code: "USD") == "$1.2k")
        #expect(Formatting.compactCurrency(Decimal(string: "8")!, code: "CNY") == "¥8.00")
    }

    @Test("Countdown reads as time remaining")
    func countdown() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(Formatting.countdown(to: now.addingTimeInterval(2280), from: now) == "38m")
        #expect(Formatting.countdown(to: now.addingTimeInterval(15120), from: now) == "4h 12m")
        #expect(Formatting.countdown(to: now.addingTimeInterval(320_000), from: now) == "3d 16h")
    }

    @Test("Under a minute does not round down to a misleading 0m")
    func countdownUnderAMinute() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(Formatting.countdown(to: now.addingTimeInterval(30), from: now) == "<1m")
        #expect(Formatting.countdown(to: now.addingTimeInterval(59), from: now) == "<1m")
        #expect(Formatting.countdown(to: now.addingTimeInterval(60), from: now) == "1m")
    }

    @Test("Reset phrases say what the number means, in any tense")
    func resetPhrase() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(Formatting.resetPhrase(to: now.addingTimeInterval(12420), from: now) == "resets in 3h 27m")
        // A reset time in the past means our snapshot is stale, not that time is negative.
        #expect(Formatting.resetPhrase(to: now.addingTimeInterval(-60), from: now) == "resets now")
        #expect(Formatting.resetPhrase(to: now, from: now) == "resets now")
    }

    @Test("Freshness reads as a labelled age, not a bare duration")
    func updatedPhrase() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(Formatting.updatedPhrase(now.addingTimeInterval(-20), from: now) == "updated just now")
        #expect(Formatting.updatedPhrase(now.addingTimeInterval(-180), from: now) == "updated 3m ago")
        #expect(Formatting.updatedPhrase(now.addingTimeInterval(-7200), from: now) == "updated 2h ago")
    }
}
