import Foundation

/// User-facing display settings. Deliberately not @Observable: these are read by the AppKit
/// status item, which needs an explicit redraw signal rather than SwiftUI observation.
@MainActor
public final class Preferences {
    /// Fired whenever a setting changes, so the menu bar can redraw immediately.
    public var onChange: (() -> Void)?

    /// Longer than this and one provider starts crowding the others out of the bar.
    public static let maxGlyphLength = 3

    /// How much the menu bar shows. Every level shows the same underlying data — the popover
    /// always has all of it — this only decides how much is worth the width.
    public enum BarDetail: String, CaseIterable, Sendable {
        /// One number per provider: whatever is closest to running out, across every account
        /// and every window.
        case tightest
        /// One number per account: that account's tightest window.
        case perAccount
        /// Every window of every account.
        case everything

        public var displayName: String {
            switch self {
            case .tightest: "Tightest limit"
            case .perAccount: "One per account"
            case .everything: "Every window"
            }
        }

        public var explanation: String {
            switch self {
            case .tightest: "Narrowest. Shows only what will stop you first."
            case .perAccount: "One number per account, each its own tightest window."
            case .everything: "Widest. Every window of every account, split by |."
            }
        }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var barDetail: BarDetail {
        get { BarDetail(rawValue: defaults.string(forKey: "barDetail") ?? "") ?? .tightest }
        set {
            defaults.set(newValue.rawValue, forKey: "barDetail")
            onChange?()
        }
    }

    private func key(_ provider: ProviderID) -> String {
        "barGlyph.\(provider.rawValue)"
    }

    /// What the menu bar should draw for this provider — the user's choice when they have made
    /// one, otherwise the built-in default.
    public func barGlyph(for provider: ProviderID) -> String {
        let stored = customBarGlyph(for: provider).trimmingCharacters(in: .whitespacesAndNewlines)
        return stored.isEmpty ? provider.defaultBarGlyph : stored
    }

    /// What the settings field shows: empty when the user has not overridden the default, so
    /// clearing the field is an obvious way back to it.
    public func customBarGlyph(for provider: ProviderID) -> String {
        defaults.string(forKey: key(provider)) ?? ""
    }

    public func setBarGlyph(_ glyph: String, for provider: ProviderID) {
        // Count in Characters, not scalars, so a multi-scalar emoji counts as one.
        let trimmed = String(
            glyph.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxGlyphLength)
        )
        if trimmed.isEmpty {
            defaults.removeObject(forKey: key(provider))
        } else {
            defaults.set(trimmed, forKey: key(provider))
        }
        onChange?()
    }
}
