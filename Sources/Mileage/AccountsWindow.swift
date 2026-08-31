import AppKit
import MileageCore
import SwiftUI

/// Adding an account needs a browser round-trip, and a `.transient` popover closes the moment
/// focus leaves it — so account management lives in a real window.
@MainActor
final class AccountsWindowController {
    private var window: NSWindow?
    private let store: UsageStore
    private let preferences: Preferences

    init(store: UsageStore, preferences: Preferences) {
        self.store = store
        self.preferences = preferences
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 460),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Accounts"
            window.isReleasedWhenClosed = false
            window.center()
            window.contentView = NSHostingView(
                rootView: AccountsView(store: store, preferences: preferences)
            )
            self.window = window
        }

        // An .accessory app has no Dock icon, so it must ask for activation explicitly or the
        // window opens behind whatever the user was doing.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct AccountsView: View {
    let store: UsageStore
    let preferences: Preferences

    @State private var flow: AddAccountFlow?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                MenuBarSection(preferences: preferences)
                Divider()
                ForEach(ProviderID.allCases) { provider in
                    providerSection(provider)
                }
            }
            .padding(18)
        }
        .frame(minWidth: 460, minHeight: 460)
        .sheet(item: $flow) { flow in
            AddAccountSheet(flow: flow, store: store) { self.flow = nil }
        }
    }

    private func providerSection(_ provider: ProviderID) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                GlyphField(provider: provider, preferences: preferences)
                Text(provider.displayName)
                    .font(.headline)
                Spacer()
                Button(provider.usesAPIKey ? "Add key…" : "Add account…") {
                    flow = AddAccountFlow(provider: provider)
                }
                .controlSize(.small)
            }

            let accounts = store.states(for: provider)
            if accounts.isEmpty {
                Text("None yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(accounts) { state in
                    AccountEditorRow(store: store, state: state)
                }
            }
        }
    }
}

/// How much of the data earns menu bar width. Local @State drives the control because
/// Preferences is backed by UserDefaults, which SwiftUI cannot observe directly.
private struct MenuBarSection: View {
    let preferences: Preferences

    @State private var detail: Preferences.BarDetail = .tightest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Menu bar")
                .font(.headline)

            Picker("", selection: $detail) {
                ForEach(Preferences.BarDetail.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Text(detail.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Everything is always in the popover — this only decides how much is worth the menu bar's width.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { detail = preferences.barDetail }
        .onChange(of: detail) { _, new in preferences.barDetail = new }
    }
}

/// The label this provider gets in the menu bar. Any letters, symbols or emoji you like —
/// clearing it falls back to the built-in default, so there is no way to get stuck with a blank.
private struct GlyphField: View {
    let provider: ProviderID
    let preferences: Preferences

    @State private var text = ""

    var body: some View {
        TextField(provider.defaultBarGlyph, text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, weight: .medium))
            .multilineTextAlignment(.center)
            .frame(width: 46)
            .help("Shown in the menu bar. Leave blank for \"\(provider.defaultBarGlyph)\".")
            .onAppear { text = preferences.customBarGlyph(for: provider) }
            .onChange(of: text) { _, new in
                preferences.setBarGlyph(new, for: provider)
                // Reflect the length cap back into the field rather than silently truncating.
                let stored = preferences.customBarGlyph(for: provider)
                if stored != new.trimmingCharacters(in: .whitespacesAndNewlines) {
                    text = stored
                }
            }
    }
}

private struct AccountEditorRow: View {
    let store: UsageStore
    let state: UsageStore.AccountState

    @State private var draftLabel = ""
    @State private var isEditing = false
    @State private var saveFailure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row
            if let saveFailure {
                Text(saveFailure)
                    .font(.caption2)
                    .foregroundStyle(Formatting.Severity.critical.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)

            if isEditing {
                TextField("Name", text: $draftLabel)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commit)
                Button("Save", action: commit)
                    .controlSize(.small)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.account.displayName)
                        .font(.system(size: 12))
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Rename") {
                    draftLabel = state.account.label ?? ""
                    isEditing = true
                }
                .controlSize(.small)

                Button("Remove", role: .destructive, action: remove)
                    .controlSize(.small)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func commit() {
        do {
            try store.accountStore.rename(state.id, to: draftLabel)
            store.syncStates()
            isEditing = false
            saveFailure = nil
        } catch {
            // Stay in edit mode: the name the user typed is still in the field, so they can
            // retry once the underlying problem is fixed.
            saveFailure = error.localizedDescription
        }
    }

    private func remove() {
        do {
            try store.accountStore.remove(state.id)
            store.syncStates()
            saveFailure = nil
        } catch {
            saveFailure = error.localizedDescription
        }
    }

    private var subtitle: String {
        switch state.account.source {
        case .cli:
            "read from the CLI · mileage never modifies it"
        case .oauth:
            state.errorText ?? "signed in to mileage"
        case .apiKey:
            state.errorText ?? "API key in Keychain"
        }
    }

    private var statusColor: Color {
        if state.needsAttention { return Formatting.Severity.critical.color }
        return state.snapshot == nil ? .secondary : Formatting.Severity.healthy.color
    }
}

// MARK: - Add flows

@MainActor
@Observable
final class AddAccountFlow: Identifiable {
    enum Phase: Equatable {
        case start
        /// Claude redirects to a page we do not control, so the user pastes the code back.
        case awaitingPaste
        /// Codex redirects to loopback, so mileage just waits.
        case awaitingBrowser
        case working
        case failed(String)
    }

    let id = UUID()
    let provider: ProviderID
    var phase: Phase = .start
    var name = ""
    var pastedCode = ""
    var apiKey = ""

    private var pkce = PKCE()
    private var callbackServer: LoopbackCallbackServer?

    init(provider: ProviderID) {
        self.provider = provider
    }

    var title: String {
        "Add \(provider.displayName) \(provider.usesAPIKey ? "key" : "account")"
    }

    // MARK: Claude

    func startClaude() {
        pkce = PKCE()
        phase = .awaitingPaste
        NSWorkspace.shared.open(ClaudeOAuth.authorizationURL(pkce: pkce))
    }

    func finishClaude(store: UsageStore) async -> Bool {
        phase = .working
        do {
            let tokens = try await ClaudeOAuth.exchange(pastedCode: pastedCode, pkce: pkce)
            try store.accountStore.add(
                Account(provider: .claude, source: .oauth, label: trimmedName),
                tokens: tokens
            )
            store.syncStates()
            return true
        } catch {
            phase = .failed(message(for: error))
            return false
        }
    }

    // MARK: Codex

    func startCodex(store: UsageStore) async -> Bool {
        pkce = PKCE()
        let state = PKCE().verifier

        let server: LoopbackCallbackServer
        do {
            server = try LoopbackCallbackServer(
                port: CodexOAuth.callbackPort,
                path: "/auth/callback"
            )
        } catch {
            phase = .failed(message(for: error))
            return false
        }
        callbackServer = server
        phase = .awaitingBrowser

        NSWorkspace.shared.open(CodexOAuth.authorizationURL(pkce: pkce, state: state))

        do {
            let code = try await CodexOAuth.awaitCallback(state: state, server: server)
            phase = .working
            let tokens = try await CodexOAuth.exchange(code: code, pkce: pkce)
            try store.accountStore.add(
                Account(provider: .codex, source: .oauth, label: trimmedName),
                tokens: tokens
            )
            store.syncStates()
            return true
        } catch {
            phase = .failed(message(for: error))
            return false
        }
    }

    func cancelCodex() {
        callbackServer?.cancel()
        callbackServer = nil
        phase = .start
    }

    // MARK: API key providers

    func saveAPIKey(store: UsageStore) async -> Bool {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            phase = .failed("Enter an API key")
            return false
        }
        guard let client = store.provider(for: provider) else {
            phase = .failed("\(provider.displayName) does not take an API key")
            return false
        }
        phase = .working
        do {
            // Validate before storing so a bad key fails here, not silently at the next poll.
            _ = try await client.fetch(credential: .apiKey(key))
            _ = try store.accountStore.addAPIKeyAccount(
                provider: provider,
                key: key,
                label: trimmedName
            )
            store.syncStates()
            return true
        } catch {
            phase = .failed(message(for: error))
            return false
        }
    }

    private var trimmedName: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

private struct AddAccountSheet: View {
    let flow: AddAccountFlow
    let store: UsageStore
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(flow.title)
                .font(.headline)

            TextField("Name (optional)", text: Bindable(flow).name)
                .textFieldStyle(.roundedBorder)
            Text("Claude does not report which account is which, so a name is the only way to tell several apart.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .opacity(flow.provider == .claude ? 1 : 0)

            content

            if case let .failed(message) = flow.phase {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Formatting.Severity.critical.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    flow.cancelCodex()
                    dismiss()
                }
            }
        }
        .padding(18)
        .frame(width: 420)
    }

    @ViewBuilder
    private var content: some View {
        switch flow.provider {
        case .claude: claude
        case .codex: codex
        case .deepseek, .openrouter: apiKeyForm
        }
    }

    private var claude: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("Open Anthropic sign-in…") { flow.startClaude() }

            if flow.phase == .awaitingPaste || isPasteReady {
                Text("Sign in, then paste the code the page gives you:")
                    .font(.caption)
                TextField("code#state", text: Bindable(flow).pastedCode)
                    .textFieldStyle(.roundedBorder)
                Button("Connect") {
                    Task { if await flow.finishClaude(store: store) { dismiss() } }
                }
                .disabled(flow.pastedCode.isEmpty || flow.phase == .working)
            }
        }
    }

    private var isPasteReady: Bool {
        if case .failed = flow.phase { return true }
        return false
    }

    private var codex: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch flow.phase {
            case .awaitingBrowser:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the browser to finish sign-in…")
                        .font(.caption)
                }
            case .working:
                ProgressView().controlSize(.small)
            default:
                Button("Sign in with ChatGPT…") {
                    Task { if await flow.startCodex(store: store) { dismiss() } }
                }
                Text("Opens your browser and returns automatically. Close any running `codex login` first — both use port \(CodexOAuth.callbackPort).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var apiKeyForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            SecureField(keyPlaceholder, text: Bindable(flow).apiKey)
                .textFieldStyle(.roundedBorder)
            Text("\(keyOrigin) Stored in your Keychain and validated before saving.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Button("Save") {
                Task { if await flow.saveAPIKey(store: store) { dismiss() } }
            }
            .disabled(flow.apiKey.isEmpty || flow.phase == .working)
        }
    }

    private var keyPlaceholder: String {
        switch flow.provider {
        case .openrouter: "sk-or-…"
        default: "sk-…"
        }
    }

    private var keyOrigin: String {
        switch flow.provider {
        case .openrouter:
            "Create one at openrouter.ai/settings/keys, allowed to read your credits."
        default:
            "Create one at platform.deepseek.com."
        }
    }
}
