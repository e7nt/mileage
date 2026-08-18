import Foundation
import MileageCore
import Observation

/// Owns every account's current state and the polling loops that keep it current.
///
/// One polling loop per account, not per provider: two Claude accounts have independent quotas
/// and independent rate-limit budgets, so they must be polled independently.
@MainActor
@Observable
final class UsageStore {
    struct AccountState: Identifiable {
        var account: Account
        var snapshot: UsageSnapshot?
        var errorText: String?
        /// The user must do something — re-authenticate, add a key — before this can recover.
        var needsAttention: Bool = false
        var isRefreshing: Bool = false

        var id: UUID { account.id }
        var primaryGauge: QuotaGauge? { snapshot?.primaryGauge }
    }

    /// What one provider contributes to the menu bar: its worst account, so the bar stays three
    /// items wide no matter how many accounts exist.
    struct ProviderSummary: Identifiable {
        let provider: ProviderID
        let gauge: QuotaGauge?
        let accountCount: Int
        let hasProblem: Bool

        var id: ProviderID { provider }
    }

    private(set) var states: [AccountState] = []
    let accountStore: AccountStore

    /// Called after any state change so the AppKit status item can redraw. @Observable does not
    /// reach into NSStatusItem, so the notification is explicit.
    var onChange: (() -> Void)?

    private let providers: [ProviderID: any UsageProvider]
    private let resolver: CredentialResolver
    private var pollingTasks: [UUID: Task<Void, Never>] = [:]
    private var lastManualRefresh: [UUID: Date] = [:]
    private var adoptionError: String?

    init(
        accountStore: AccountStore = AccountStore(),
        providers: [ProviderID: any UsageProvider] = [
            .claude: ClaudeProvider(),
            .codex: CodexProvider(),
            .deepseek: DeepSeekProvider(),
        ]
    ) {
        self.accountStore = accountStore
        self.providers = providers
        resolver = CredentialResolver(store: accountStore)
        do {
            try accountStore.adoptCLIAccounts()
        } catch {
            adoptionError = error.localizedDescription
        }
        syncStates()
    }

    /// A problem with the account list itself rather than with any one account — surfaced at the
    /// top of the popover, because none of the per-account rows can explain it.
    var storeProblem: String? {
        if case let .unreadable(reason) = accountStore.loadState {
            return "mileage could not read its account list (\(reason)). Nothing has been "
                + "overwritten. Fix or move ~/Library/Application Support/Mileage/accounts.json."
        }
        return adoptionError
    }

    // MARK: - Account list

    /// Re-reads the account list and starts or stops polling loops to match it.
    func syncStates() {
        let accounts = accountStore.accounts
        var updated: [AccountState] = []

        for account in accounts {
            if var existing = states.first(where: { $0.id == account.id }) {
                existing.account = account
                updated.append(existing)
            } else {
                updated.append(AccountState(account: account))
            }
        }
        states = updated

        let liveIDs = Set(accounts.map(\.id))
        for (id, task) in pollingTasks where !liveIDs.contains(id) {
            task.cancel()
            pollingTasks[id] = nil
        }
        for account in accounts where pollingTasks[account.id] == nil {
            pollingTasks[account.id] = Task { [weak self] in
                await self?.pollLoop(account.id)
            }
        }

        onChange?()
    }

    func stop() {
        pollingTasks.values.forEach { $0.cancel() }
        pollingTasks.removeAll()
    }

    // MARK: - Menu bar aggregation

    var providerSummaries: [ProviderSummary] {
        ProviderID.allCases.map { provider in
            let accounts = states.filter { $0.account.provider == provider }
            // The worst account is the one that answers "am I about to run out?".
            let worst = accounts
                .compactMap(\.primaryGauge)
                .min { $0.remainingScore < $1.remainingScore }
            return ProviderSummary(
                provider: provider,
                gauge: worst,
                accountCount: accounts.count,
                hasProblem: accounts.contains { $0.needsAttention }
            )
        }
    }

    /// What the menu bar actually draws. A provider with no accounts is omitted entirely rather
    /// than shown as a dead placeholder — the bar should report what you have, not advertise
    /// what you don't. Discovering the other providers is the popover's job, which always lists
    /// all three with an Add button.
    var barSummaries: [ProviderSummary] {
        providerSummaries.filter { $0.accountCount > 0 }
    }

    /// One provider's contribution to the bar, already reduced to the gauges that will be drawn.
    /// Each inner array is one account; nil entries are accounts with no data yet.
    struct BarSegment: Identifiable {
        let provider: ProviderID
        let groups: [[QuotaGauge?]]
        /// Whether to mark that accounts exist beyond the number shown.
        let showsMoreIndicator: Bool

        var id: ProviderID { provider }
    }

    func barSegments(detail: Preferences.BarDetail) -> [BarSegment] {
        ProviderID.allCases.compactMap { provider in
            let accounts = states(for: provider)
            guard !accounts.isEmpty else { return nil }

            switch detail {
            case .tightest:
                // The single worst gauge anywhere in this provider — across accounts *and*
                // windows, so a nearly-exhausted weekly limit cannot hide behind a healthy
                // session window.
                let worst = accounts
                    .compactMap { $0.snapshot?.bindingGauge }
                    .min { $0.remainingScore < $1.remainingScore }
                return BarSegment(
                    provider: provider,
                    groups: [[worst]],
                    showsMoreIndicator: accounts.count > 1
                )

            case .perAccount:
                return BarSegment(
                    provider: provider,
                    groups: accounts.map { [$0.snapshot?.bindingGauge] },
                    showsMoreIndicator: false
                )

            case .everything:
                return BarSegment(
                    provider: provider,
                    groups: accounts.map { state in
                        let gauges = state.snapshot?.gauges ?? []
                        return gauges.isEmpty ? [nil] : gauges.map { $0 }
                    },
                    showsMoreIndicator: false
                )
            }
        }
    }

    func states(for provider: ProviderID) -> [AccountState] {
        states.filter { $0.account.provider == provider }
    }

    // MARK: - Polling

    /// Base cadence per provider. Anthropic's endpoint is the strictest, so it gets the longest
    /// interval; DeepSeek balances barely move.
    private func baseInterval(_ provider: ProviderID) -> TimeInterval {
        switch provider {
        case .claude: 300
        case .codex: 180
        case .deepseek: 900
        }
    }

    private func pollLoop(_ id: UUID) async {
        var backoff: TimeInterval = 0
        while !Task.isCancelled {
            guard let provider = accountStore.account(id)?.provider else { return }
            let outcome = await refresh(id)

            switch outcome {
            case let .transientFailure(retryAfter):
                // Double each time, floored at the base interval, capped at an hour, and never
                // sooner than the provider's own Retry-After hint.
                backoff = min(max(backoff * 2, baseInterval(provider)), 3600)
                if let retryAfter { backoff = max(backoff, retryAfter) }
            case .success, .permanentFailure:
                backoff = 0
            }

            let delay = backoff > 0 ? backoff : jittered(baseInterval(provider))
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    /// ±20% so several accounts never stampede the same endpoint in lockstep.
    private func jittered(_ interval: TimeInterval) -> TimeInterval {
        interval * Double.random(in: 0.8 ... 1.2)
    }

    private enum Outcome {
        case success
        /// Worth retrying sooner or later: 429, 5xx, network blips.
        case transientFailure(retryAfter: TimeInterval?)
        /// Retrying will not help until the user does something.
        case permanentFailure
    }

    // MARK: - Refresh

    /// Manual refresh, throttled so clicking repeatedly cannot trigger a 429 storm.
    func refreshNow(_ id: UUID) {
        let now = Date()
        if let last = lastManualRefresh[id], now.timeIntervalSince(last) < 30 { return }
        lastManualRefresh[id] = now
        Task { _ = await refresh(id) }
    }

    func refreshAllNow() {
        states.map(\.id).forEach(refreshNow)
    }

    /// Refresh everything and wait for it. Used by `--once`; the UI never needs to block.
    func refreshAllAwaiting() async {
        for state in states {
            _ = await refresh(state.id)
        }
    }

    @discardableResult
    private func refresh(_ id: UUID) async -> Outcome {
        guard let account = accountStore.account(id),
              let provider = providers[account.provider]
        else { return .permanentFailure }

        mutate(id) { $0.isRefreshing = true }
        defer { mutate(id) { $0.isRefreshing = false } }

        do {
            let resolved = try await resolver.resolve(account)
            let snapshot: UsageSnapshot
            do {
                snapshot = try await provider.fetch(credential: resolved.credential)
            } catch ProviderError.unauthorized where account.isRefreshable {
                // One stale access token should cost a retry, not an error the user must act on.
                let retried = try await resolver.refreshAfterUnauthorized(account)
                snapshot = try await provider.fetch(credential: retried.credential)
            }

            // Failing to persist a display label must not fail the poll — the usage data is
            // good. But it is still reported rather than dropped, since a Keychain or disk
            // problem here predicts a worse one when a token needs saving.
            var labelProblem: String?
            do {
                try accountStore.updateDetectedLabel(
                    snapshot.accountLabel ?? resolved.detectedLabel,
                    for: id
                )
            } catch {
                labelProblem = "Usage is current, but mileage could not save this account's "
                    + "name (\(error.localizedDescription))."
            }

            mutate(id) {
                $0.snapshot = snapshot
                $0.errorText = labelProblem
                $0.needsAttention = false
                if let refreshed = accountStore.account(id) { $0.account = refreshed }
            }
            return .success
        } catch let error as ProviderError {
            return apply(error, to: id, provider: account.provider)
        } catch {
            mutate(id) { $0.errorText = error.localizedDescription }
            return .transientFailure(retryAfter: nil)
        }
    }

    private func apply(_ error: ProviderError, to id: UUID, provider: ProviderID) -> Outcome {
        switch error {
        case let .rateLimited(retryAfter):
            // Keep showing the last good numbers; the popover marks them stale.
            mutate(id) { $0.errorText = error.errorDescription }
            return .transientFailure(retryAfter: retryAfter)

        case .http, .decoding:
            mutate(id) { $0.errorText = error.errorDescription }
            return .transientFailure(retryAfter: nil)

        case .unauthorized:
            let source = accountStore.account(id)?.source
            mutate(id) {
                $0.errorText = source == .cli
                    ? "\(provider.displayName) sign-in expired — run the CLI once to refresh it"
                    : "Sign-in expired — remove and add this account again"
                $0.needsAttention = true
            }
            return .permanentFailure

        case let .missingCredentials(detail):
            mutate(id) {
                $0.errorText = detail
                $0.needsAttention = true
                $0.snapshot = nil
            }
            return .permanentFailure

        case let .credentialsNotSaved(detail):
            // The grant was rotated but not stored, so this account cannot recover on its own.
            // Keep the last good numbers visible, but flag it loudly.
            mutate(id) {
                $0.errorText = detail
                $0.needsAttention = true
            }
            return .permanentFailure
        }
    }

    // MARK: - Mutation

    private func mutate(_ id: UUID, _ body: (inout AccountState) -> Void) {
        guard let index = states.firstIndex(where: { $0.id == id }) else { return }
        body(&states[index])
        onChange?()
    }
}
