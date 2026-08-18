import Foundation
import Testing

@testable import MileageCore

/// Each test gets its own directory and its own in-memory secret store, so runs are hermetic:
/// no shared state, no dependence on a Keychain that may be locked or absent in CI. The real
/// KeychainStore adapter is covered separately in KeychainStoreTests.
@MainActor
private func makeStore() throws -> (AccountStore, InMemorySecretStore, URL) {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "mileage-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let secrets = InMemorySecretStore()
    return (AccountStore(secrets: secrets, directory: directory), secrets, directory)
}

@Suite("Account store")
@MainActor
struct AccountStoreTests {
    @Test("Accounts survive a reload, and secrets never enter the JSON file")
    func persistsMetadataNotSecrets() throws {
        let (store, secrets, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let account = Account(provider: .claude, source: .oauth, label: "work")
        try store.add(account, tokens: OAuthTokens(
            accessToken: "super-secret-access",
            refreshToken: "super-secret-refresh",
            expiresAt: Date(timeIntervalSince1970: 9_000_000)
        ))

        let onDisk = try String(
            contentsOf: directory.appending(path: "accounts.json"),
            encoding: .utf8
        )
        #expect(onDisk.contains("work"))
        #expect(!onDisk.contains("super-secret-access"))
        #expect(!onDisk.contains("super-secret-refresh"))

        // A fresh store over the same directory sees the account and can still read its tokens.
        let reloaded = AccountStore(secrets: secrets, directory: directory)
        #expect(reloaded.accounts.map(\.id) == [account.id])
        #expect(try reloaded.tokens(for: account.id)?.accessToken == "super-secret-access")

        try store.remove(account.id)
    }

    @Test("Removing an account deletes its secret too")
    func removalClearsKeychain() throws {
        let (store, _, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let account = Account(provider: .codex, source: .oauth)
        try store.add(account, tokens: OAuthTokens(
            accessToken: "a",
            refreshToken: "r",
            expiresAt: .distantFuture
        ))
        #expect(try store.tokens(for: account.id) != nil)

        try store.remove(account.id)

        #expect(store.accounts.isEmpty)
        // An orphaned Keychain item would outlive the account that justified it.
        #expect(try store.tokens(for: account.id) == nil)
    }

    @Test("Several accounts can share one provider")
    func supportsMultipleAccountsPerProvider() throws {
        let (store, _, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = Account(provider: .claude, source: .oauth, label: "work", sortIndex: 0)
        let second = Account(provider: .claude, source: .oauth, label: "personal", sortIndex: 1)
        try store.add(first)
        try store.add(second)

        let claude = store.accounts.filter { $0.provider == .claude }
        #expect(claude.count == 2)
        #expect(claude.map(\.displayName) == ["work", "personal"])

        try store.remove(first.id)
        try store.remove(second.id)
    }

    @Test("A user-chosen name outranks whatever the provider reports")
    func labelPrecedence() {
        var account = Account(provider: .codex, source: .oauth, detectedLabel: "someone@example.com")
        #expect(account.displayName == "someone@example.com")

        account.label = "work"
        #expect(account.displayName == "work")

        // Clearing the name falls back rather than showing an empty row.
        account.label = nil
        #expect(account.displayName == "someone@example.com")
    }

    @Test("A CLI account identifies itself even with nothing else to go on")
    func cliAccountHasAName() {
        let account = Account(provider: .claude, source: .cli)
        #expect(account.displayName == "signed in via CLI")
    }

    @Test("Renaming to blank clears the name instead of storing whitespace")
    func renameToBlankClears() throws {
        let (store, _, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let account = Account(provider: .claude, source: .oauth, label: "work")
        try store.add(account)

        try store.rename(account.id, to: "   ")
        #expect(store.account(account.id)?.label == nil)

        try store.remove(account.id)
    }

    @Test("Only mileage's own grants are refreshable")
    func onlyOwnedGrantsRefresh() {
        #expect(Account(provider: .claude, source: .oauth).isRefreshable)
        // Refreshing a CLI grant could invalidate the token the CLI still holds.
        #expect(!Account(provider: .claude, source: .cli).isRefreshable)
        #expect(!Account(provider: .deepseek, source: .apiKey).isRefreshable)
    }
}
