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

/// Install, upgrade and uninstall all live in the hosted installer, so there is one copy of
/// that logic and it can be fixed without shipping a new build. MILEAGE_SITE_URL points it at a
/// local server for testing.
func runInstaller(_ command: String) -> Never {
    let installer = Process()
    installer.executableURL = URL(fileURLWithPath: "/bin/sh")
    installer.arguments = [
        "-c",
        "curl -fsSL \"${MILEAGE_SITE_URL:-https://mileage.e7nt.com}/install.sh\" | sh -s -- \(command)",
    ]
    do {
        try installer.run()
    } catch {
        print("mileage: could not start the installer: \(error.localizedDescription)")
        exit(1)
    }
    installer.waitUntilExit()
    exit(installer.terminationStatus)
}

let arguments = CommandLine.arguments

if arguments.contains("--version") {
    // The installer runs this through a `mileage` symlink, which Bundle.main doesn't follow,
    // so locate the bundle from the real executable (Mileage.app/Contents/MacOS/Mileage).
    let appURL = Bundle.main.executableURL?.resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let version = appURL.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] }
    // Builds outside an app bundle (`swift run`) have no Info.plist.
    print(version as? String ?? "dev")
    exit(0)
}

if arguments.contains("--upgrade") {
    runInstaller("upgrade")
}

if arguments.contains("--uninstall") {
    runInstaller("uninstall")
}

if arguments.contains("--once") {
    await runOnce()
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// .accessory keeps mileage out of the Dock and the app switcher.
application.setActivationPolicy(.accessory)
application.run()
