import AppKit
import MileageCore
import SwiftUI

struct PopoverView: View {
    let store: UsageStore
    let openAccounts: () -> Void

    var body: some View {
        // Countdowns and "updated N ago" are derived from the clock, not from state, so they
        // would sit frozen between polls without a ticking source. TimelineView only runs while
        // the popover is actually on screen, so a closed popover costs nothing.
        //
        // The schedule is only a redraw trigger; the time is read at render. `context.date` is
        // the scheduled tick, which can be up to a minute in the past by the time it draws —
        // and it also fires on open, which is exactly when accuracy matters most.
        TimelineView(.everyMinute) { _ in
            content(now: Date())
        }
        .frame(width: 380)
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let problem = store.storeProblem {
                Label(problem, systemImage: "exclamationmark.octagon.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                Divider()
            }

            ForEach(ProviderID.allCases) { provider in
                ProviderSection(
                    store: store,
                    provider: provider,
                    now: now,
                    openAccounts: openAccounts
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Divider()
            }
            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Refresh") { store.refreshAllNow() }
                .buttonStyle(.link)
            Button("Accounts…", action: openAccounts)
                .buttonStyle(.link)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.link)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct ProviderSection: View {
    let store: UsageStore
    let provider: ProviderID
    let now: Date
    let openAccounts: () -> Void

    private var states: [UsageStore.AccountState] { store.states(for: provider) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(provider.displayName)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if states.isEmpty {
                    Button("Add", action: openAccounts)
                        .buttonStyle(.link)
                        .font(.system(size: 10))
                }
            }

            if states.isEmpty {
                Text(provider == .deepseek
                    ? "Add a platform API key to track credit."
                    : "No account yet.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            ForEach(states) { state in
                AccountRow(state: state, now: now, showsName: states.count > 1)
            }
        }
    }
}

private struct AccountRow: View {
    let state: UsageStore.AccountState
    let now: Date
    /// With one account the provider heading already says everything; the name only earns its
    /// line once there are several.
    let showsName: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsName {
                HStack(spacing: 6) {
                    Text(state.account.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    if let plan = state.snapshot?.planLabel {
                        Text(plan)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                    Spacer()
                    freshness
                }
            }

            if let snapshot = state.snapshot {
                ForEach(snapshot.gauges) { gauge in
                    GaugeRow(gauge: gauge, now: now)
                }
            }

            if let errorText = state.errorText {
                Label(errorText, systemImage: state.needsAttention
                    ? "exclamationmark.triangle.fill"
                    : "clock.arrow.circlepath")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if !showsName, state.snapshot != nil {
                HStack {
                    Spacer()
                    freshness
                }
            }
        }
    }

    @ViewBuilder
    private var freshness: some View {
        if state.isRefreshing {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
        } else if let fetchedAt = state.snapshot?.fetchedAt {
            Text(Formatting.updatedPhrase(fetchedAt, from: now))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }
}

private struct GaugeRow: View {
    let gauge: QuotaGauge
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            Text(gauge.label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
                .lineLimit(1)
                .help(windowExplanation)

            if case let .percentUsed(used) = gauge.kind {
                meter(remainingFraction: max(0, 100 - used) / 100)
            } else {
                Spacer()
            }

            Text(valueText)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(tint)

            Text(gauge.resetsAt.map { Formatting.resetPhrase(to: $0, from: now) } ?? "")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 104, alignment: .trailing)
                .lineLimit(1)
        }
    }

    /// Fill represents what is *left*, so the bar empties as you use the quota.
    private func meter(remainingFraction: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(tint)
                    .frame(width: max(2, proxy.size.width * remainingFraction))
            }
        }
        .frame(height: 5)
    }

    private var valueText: String {
        switch gauge.kind {
        case .percentUsed:
            "\(gauge.compactDisplay) left"
        case let .currency(amount, code):
            Formatting.currency(amount, code: code)
        }
    }

    private var windowExplanation: String {
        switch gauge.kind {
        case .percentUsed:
            "Quota for the \(gauge.label) window"
        case .currency:
            "Remaining balance"
        }
    }

    private var tint: Color {
        switch gauge.severity() {
        case .healthy: .green
        case .warning: .orange
        case .critical: .red
        }
    }
}
