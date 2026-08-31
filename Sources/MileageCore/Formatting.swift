import Foundation

/// Shared presentation rules, kept in Core so the menu bar string and the popover can never
/// disagree about what a number means.
public enum Formatting {
    /// How close an account is to running out. Drives colour in both the bar and the popover.
    public enum Severity: Sendable, Equatable, CaseIterable {
        case healthy
        case warning
        case critical
    }

    /// Thresholds are on *remaining*, matching the battery metaphor: plenty left, getting low, nearly out.
    public static func severity(remainingPercent: Double) -> Severity {
        switch remainingPercent {
        case ..<15: .critical
        case ..<40: .warning
        default: .healthy
        }
    }

    public static func severity(remainingBalance: Decimal, lowThreshold: Decimal) -> Severity {
        if remainingBalance <= 0 { return .critical }
        if remainingBalance < lowThreshold { return .warning }
        return .healthy
    }

    /// Compact enough for the menu bar: "22%".
    public static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// Compact money for the menu bar: "$14", "$3.40", "$1.2k". Precision drops as the number
    /// grows so the bar width stays roughly constant.
    public static func compactCurrency(_ amount: Decimal, code: String) -> String {
        let value = NSDecimalNumber(decimal: amount).doubleValue
        let magnitude = abs(value)
        let digits: String = if magnitude >= 1000 {
            "\(String(format: "%.1f", magnitude / 1000))k"
        } else if magnitude >= 10 {
            "\(Int(magnitude.rounded()))"
        } else {
            String(format: "%.2f", magnitude)
        }
        return signed(digits, code: code, isNegative: value < 0)
    }

    /// Full precision for the popover: "$14.20".
    public static func currency(_ amount: Decimal, code: String) -> String {
        let value = NSDecimalNumber(decimal: amount).doubleValue
        return signed(String(format: "%.2f", abs(value)), code: code, isNegative: value < 0)
    }

    /// An overdrawn balance reads as "-$3.50", never "$-3.50" — the sign belongs to the amount,
    /// not to the symbol.
    private static func signed(_ digits: String, code: String, isNegative: Bool) -> String {
        "\(isNegative ? "-" : "")\(currencySymbol(for: code))\(digits)"
    }

    public static func currencySymbol(for code: String) -> String {
        switch code.uppercased() {
        case "USD": "$"
        case "CNY": "¥"
        case "EUR": "€"
        default: "\(code) "
        }
    }

    /// "4h 12m", "38m", "<1m" — a countdown, because a wall-clock reset time makes you do
    /// arithmetic to answer the question you actually have.
    public static func countdown(to date: Date, from now: Date = Date()) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return "now" }
        // Under a minute would otherwise round down to a misleading "0m".
        guard seconds >= 60 else { return "<1m" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }

    /// The full phrase, so the grammar is built in one place rather than assembled at the call
    /// site — "3h 27m" on its own never says *what* happens in 3h 27m.
    public static func resetPhrase(to date: Date, from now: Date = Date()) -> String {
        date <= now ? "resets now" : "resets in \(countdown(to: date, from: now))"
    }

    /// "updated 3m ago" — pairs with `relativeAge` so a bare timestamp never floats unlabelled.
    public static func updatedPhrase(_ date: Date, from now: Date = Date()) -> String {
        "updated \(relativeAge(of: date, from: now))"
    }

    /// "just now", "3m ago" — staleness of the last successful poll.
    public static func relativeAge(of date: Date, from now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }
}

public extension QuotaGauge {
    /// The single number this gauge contributes to the menu bar, already formatted.
    var compactDisplay: String {
        switch kind {
        case let .percentUsed(used):
            Formatting.percent(max(0, 100 - used))
        case let .currency(amount, code):
            Formatting.compactCurrency(amount, code: code)
        }
    }

    /// How much headroom this gauge has, for picking the worst account of a provider.
    /// Lower is worse. Only meaningful between gauges of the same kind, which is always the
    /// case within one provider.
    var remainingScore: Double {
        switch kind {
        case let .percentUsed(used):
            max(0, 100 - used)
        case let .currency(amount, _):
            NSDecimalNumber(decimal: amount).doubleValue
        }
    }

    func severity(lowBalanceThreshold: Decimal = 5) -> Formatting.Severity {
        switch kind {
        case let .percentUsed(used):
            Formatting.severity(remainingPercent: max(0, 100 - used))
        case let .currency(amount, _):
            Formatting.severity(remainingBalance: amount, lowThreshold: lowBalanceThreshold)
        }
    }
}
