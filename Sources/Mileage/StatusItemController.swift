import AppKit
import MileageCore
import SwiftUI

/// Owns the menu bar item and the popover hanging off it.
///
/// This is AppKit rather than SwiftUI's `MenuBarExtra` on purpose: `MenuBarExtra` renders its
/// label as a template image, which discards the per-provider colour that carries the warning.
/// An `NSAttributedString` title keeps full colour control and exact width behaviour.
@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let store: UsageStore
    private let preferences: Preferences
    private let accountsWindow: AccountsWindowController

    init(store: UsageStore, preferences: Preferences) {
        self.store = store
        self.preferences = preferences
        accountsWindow = AccountsWindowController(store: store, preferences: preferences)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(
                store: store,
                openAccounts: { [weak accountsWindow] in accountsWindow?.show() }
            )
        )

        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        store.onChange = { [weak self] in self?.render() }
        // Editing a glyph in Settings should show up in the bar immediately, not at the next poll.
        preferences.onChange = { [weak self] in self?.render() }
        render()
    }

    // MARK: - Rendering

    private func render() {
        guard let button = statusItem.button else { return }
        button.attributedTitle = barTitle()
        button.toolTip = tooltip()
    }

    /// Renders however much detail the user asked for: accounts separated by a space, windows
    /// within an account by "|", providers by a double space. Each number is coloured by its
    /// own severity, so one bad window is visible even beside healthy ones.
    private func barTitle() -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let result = NSMutableAttributedString()

        func append(_ string: String, _ color: NSColor) {
            result.append(NSAttributedString(
                string: string,
                attributes: [.font: font, .foregroundColor: color]
            ))
        }

        for segment in store.barSegments(detail: preferences.barDetail) {
            if result.length > 0 { append("  ", .labelColor) }
            append("\(preferences.barGlyph(for: segment.provider)) ", .secondaryLabelColor)

            for (groupIndex, group) in segment.groups.enumerated() {
                if groupIndex > 0 { append(" ", .labelColor) }

                for (gaugeIndex, gauge) in group.enumerated() {
                    if gaugeIndex > 0 { append("|", .tertiaryLabelColor) }
                    guard let gauge else {
                        append("–", .disabledControlTextColor)
                        continue
                    }
                    append(gauge.compactDisplay, color(for: gauge.severity()))
                }
            }

            // A dot marks "there are more accounts behind this number".
            if segment.showsMoreIndicator {
                append("·", .tertiaryLabelColor)
            }
        }

        if result.length == 0 {
            return NSAttributedString(string: "mileage", attributes: [.font: font])
        }
        return result
    }

    /// Healthy uses `labelColor` rather than green so the bar stays quiet until something is
    /// actually wrong — the same way the battery icon only turns red when it matters.
    private func color(for severity: Formatting.Severity) -> NSColor {
        switch severity {
        case .healthy: .labelColor
        case .warning: .systemOrange
        case .critical: .systemRed
        }
    }

    /// Deliberately carries no countdown: a tooltip is only rebuilt when a poll lands, so any
    /// "resets in" it showed would be minutes stale by the time you hovered. Reset times live
    /// in the popover, which ticks.
    private func tooltip() -> String {
        store.states.map { state in
            let header = "\(state.account.provider.displayName) · \(state.account.displayName)"
            guard let snapshot = state.snapshot else {
                return "\(header): \(state.errorText ?? "no data yet")"
            }
            let parts = snapshot.gauges.map { gauge in
                switch gauge.kind {
                case .percentUsed: "\(gauge.label) \(gauge.compactDisplay) left"
                case .currency: "\(gauge.label) \(gauge.compactDisplay)"
                }
            }
            return "\(header): \(parts.joined(separator: " · "))"
        }
        .joined(separator: "\n")
    }

    // MARK: - Interaction

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Without this the popover opens behind other apps' windows.
        popover.contentViewController?.view.window?.makeKey()
    }
}
