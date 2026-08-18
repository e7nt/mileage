import AppKit
import MileageCore

/// Menu bar utilities have no Dock icon and no main window, so the app is driven directly
/// rather than through a SwiftUI `App` scene.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var store: UsageStore?

    func applicationDidFinishLaunching(_: Notification) {
        EditMenu.install()
        let store = UsageStore()
        self.store = store
        statusItemController = StatusItemController(store: store, preferences: Preferences())
        store.refreshAllNow()
    }

    func applicationWillTerminate(_: Notification) {
        store?.stop()
    }
}

/// `--once` polls every account, prints what the menu bar would show, and exits. Useful for
/// diagnosing a provider without a UI, and as a smoke test in CI.
@MainActor
func runOnce() async {
    let store = UsageStore()
    await store.refreshAllAwaiting()

    for summary in store.providerSummaries {
        let states = store.states(for: summary.provider)
        let worst = summary.gauge.map { " → bar shows \($0.compactDisplay)" } ?? ""
        print("\(summary.provider.displayName) (\(states.count) account(s))\(worst)")

        for state in states {
            print("  \(state.account.displayName) [\(state.account.source.rawValue)]")
            for gauge in state.snapshot?.gauges ?? [] {
                let reset = gauge.resetsAt.map { " · \(Formatting.resetPhrase(to: $0))" } ?? ""
                let marker = gauge.isPrimary ? "*" : " "
                switch gauge.kind {
                case .percentUsed:
                    print("    \(marker) \(gauge.label): \(gauge.compactDisplay) left\(reset)")
                case .currency:
                    print("    \(marker) \(gauge.label): \(gauge.compactDisplay)\(reset)")
                }
            }
            if let errorText = state.errorText {
                print("    ! \(errorText)")
            }
        }
    }
}

if CommandLine.arguments.contains("--once") {
    await runOnce()
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// .accessory keeps mileage out of the Dock and the app switcher.
application.setActivationPolicy(.accessory)
application.run()
