import Foundation
import Testing

@testable import MileageCore

private func snapshot(_ gauges: [QuotaGauge]) -> UsageSnapshot {
    UsageSnapshot(gauges: gauges, fetchedAt: Date(timeIntervalSince1970: 0))
}

private func percent(_ label: String, used: Double, primary: Bool = false) -> QuotaGauge {
    QuotaGauge(label: label, kind: .percentUsed(used), isPrimary: primary)
}

@Suite("Binding gauge — what actually stops you")
struct BindingGaugeTests {
    @Test("A nearly-exhausted weekly limit beats a healthy session window")
    func weeklyCanBind() throws {
        // The regression this exists to prevent: picking the primary window alone reported a
        // comfortable 90% while the weekly limit sat at 4%.
        let usage = snapshot([
            percent("5h", used: 10, primary: true),
            percent("weekly", used: 96),
        ])

        #expect(usage.primaryGauge?.label == "5h")
        #expect(usage.bindingGauge?.label == "weekly")
        #expect(usage.bindingGauge?.compactDisplay == "4%")
    }

    @Test("The session window still wins when it is genuinely the tightest")
    func sessionCanBind() {
        let usage = snapshot([
            percent("5h", used: 60, primary: true),
            percent("weekly", used: 20),
        ])
        #expect(usage.bindingGauge?.label == "5h")
    }

    @Test("Per-model caps are real limits and can bind")
    func perModelCapCanBind() {
        let usage = snapshot([
            percent("5h", used: 10, primary: true),
            percent("weekly", used: 20),
            percent("opus weekly", used: 99),
        ])
        #expect(usage.bindingGauge?.label == "opus weekly")
    }

    @Test("Percentages and money are never compared against each other")
    func doesNotMixKinds() {
        // Codex can report both a percentage window and a credit balance. "$3 < 40" is
        // meaningless, so the binding gauge must stay in the primary's units.
        let usage = snapshot([
            percent("weekly", used: 60, primary: true),
            QuotaGauge(label: "credits", kind: .currency(amount: 3, code: "USD")),
        ])

        #expect(usage.bindingGauge?.label == "weekly")
    }

    @Test("An empty snapshot has no binding gauge rather than a wrong one")
    func emptySnapshot() {
        #expect(snapshot([]).bindingGauge == nil)
    }

    @Test("Real Claude data picks the tighter of the two windows")
    func againstRealFixture() throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/claude_usage", withExtension: "json"))
        let usage = try ClaudeProvider().parse(try Data(contentsOf: url))

        // 5h is 33% used (67% left), weekly 13% used (87% left) — the session window binds.
        #expect(usage.bindingGauge?.label == "5h")
        #expect(usage.bindingGauge?.compactDisplay == "67%")
    }
}
