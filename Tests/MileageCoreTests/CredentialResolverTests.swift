import Foundation
import Testing

@testable import MileageCore

@MainActor
private func makeStore(secrets: InMemorySecretStore) throws -> (AccountStore, URL) {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "mileage-resolver-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (AccountStore(secrets: secrets, directory: directory), directory)
}

private let refreshedGrant = """
{"access_token":"new-access","refresh_token":"rotated-refresh","expires_in":3600}
"""

@Suite("Credential resolution")
@MainActor
struct CredentialResolverTests {
    @Test("A valid grant is used as-is, with no refresh and no write")
    func usesValidGrant() async throws {
        let secrets = InMemorySecretStore()
        let (store, directory) = try makeStore(secrets: secrets)
        defer { try? FileManager.default.removeItem(at: directory) }

        let account = Account(provider: .claude, source: .oauth)
        try store.add(account, tokens: OAuthTokens(
            accessToken: "still-good",
            refreshToken: "r",
            expiresAt: Date().addingTimeInterval(3600)
        ))
        let writesAfterSetup = secrets.writeCount

        let resolver = CredentialResolver(store: store, http: StubHTTP(json: refreshedGrant))
        let resolved = try await resolver.resolve(account)

        #expect(resolved.credential == .oauth(accessToken: "still-good", accountID: nil))
        #expect(secrets.writeCount == writesAfterSetup)
    }

    @Test("An expiring grant is refreshed and the rotated token is persisted")
    func refreshesAndPersists() async throws {
        let secrets = InMemorySecretStore()
        let (store, directory) = try makeStore(secrets: secrets)
        defer { try? FileManager.default.removeItem(at: directory) }

        let account = Account(provider: .claude, source: .oauth)
        try store.add(account, tokens: OAuthTokens(
            accessToken: "stale",
            refreshToken: "original-refresh",
            expiresAt: .distantPast
        ))

        let resolver = CredentialResolver(store: store, http: StubHTTP(json: refreshedGrant))
        let resolved = try await resolver.resolve(account)

        #expect(resolved.credential == .oauth(accessToken: "new-access", accountID: nil))
        // The rotated refresh token must be what is stored — keeping the old one would strand
        // the account the moment the provider retires it.
        #expect(try store.tokens(for: account.id)?.refreshToken == "rotated-refresh")
    }

    @Test("A failed write after rotation is reported, never swallowed")
    func reportsFailureToPersistRotatedGrant() async throws {
        let secrets = InMemorySecretStore()
        let (store, directory) = try makeStore(secrets: secrets)
        defer { try? FileManager.default.removeItem(at: directory) }

        let account = Account(provider: .claude, source: .oauth)
        try store.add(account, tokens: OAuthTokens(
            accessToken: "stale",
            refreshToken: "original-refresh",
            expiresAt: .distantPast
        ))

        // The provider will rotate the grant, and the Keychain will refuse to store it. This is
        // the branch that previously used `try?`: the old refresh token may already be dead, so
        // silence here left the account permanently broken with no explanation.
        secrets.failOnSet = .init(message: "keychain is locked")

        let resolver = CredentialResolver(store: store, http: StubHTTP(json: refreshedGrant))

        do {
            _ = try await resolver.resolve(account)
            Issue.record("Expected the failed write to surface")
        } catch let error as ProviderError {
            guard case let .credentialsNotSaved(detail) = error else {
                Issue.record("Expected .credentialsNotSaved, got \(error)")
                return
            }
            #expect(detail.contains("keychain is locked"))
            // The message has to tell the user the one thing that fixes it.
            #expect(detail.contains("add the account again"))
        }
    }

    @Test("A refused secret read is not mistaken for a missing account")
    func distinguishesDeniedReadFromMissingGrant() async throws {
        let secrets = InMemorySecretStore()
        let (store, directory) = try makeStore(secrets: secrets)
        defer { try? FileManager.default.removeItem(at: directory) }

        let account = Account(provider: .claude, source: .oauth)
        try store.add(account, tokens: OAuthTokens(
            accessToken: "a",
            refreshToken: "r",
            expiresAt: .distantFuture
        ))
        secrets.failOnRead = .init(message: "user denied access")

        let resolver = CredentialResolver(store: store, http: StubHTTP(json: refreshedGrant))

        // "Sign in again to restore this account" would be wrong and actively misleading advice.
        do {
            _ = try await resolver.resolve(account)
            Issue.record("Expected the denied read to surface")
        } catch let error as ProviderError {
            Issue.record("Expected the store's own error, got \(error)")
        } catch let error as InMemorySecretStore.InjectedFailure {
            #expect(error.message == "user denied access")
        }
    }

    @Test("A genuinely absent grant still reads as needing sign-in")
    func missingGrantAsksForSignIn() async throws {
        let secrets = InMemorySecretStore()
        let (store, directory) = try makeStore(secrets: secrets)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Registered but with nothing in the secret store, e.g. after a Keychain reset.
        let account = Account(provider: .claude, source: .oauth)
        try store.add(account)

        let resolver = CredentialResolver(store: store, http: StubHTTP(json: refreshedGrant))

        await #expect(throws: ProviderError.missingCredentials("Sign in again to restore this account")) {
            _ = try await resolver.resolve(account)
        }
    }

    @Test("A corrupted stored grant asks to be re-added rather than decoding to nothing")
    func corruptedGrantIsReported() throws {
        let secrets = InMemorySecretStore()
        let (store, directory) = try makeStore(secrets: secrets)
        defer { try? FileManager.default.removeItem(at: directory) }

        let account = Account(provider: .codex, source: .oauth)
        try store.add(account)
        secrets.seed("this is not a grant", for: account.id.uuidString)

        #expect(throws: AccountStoreError.self) {
            _ = try store.tokens(for: account.id)
        }
    }

    @Test("CLI accounts are never refreshed, whatever their state")
    func cliAccountsAreNeverRefreshed() async throws {
        let secrets = InMemorySecretStore()
        let (store, directory) = try makeStore(secrets: secrets)
        defer { try? FileManager.default.removeItem(at: directory) }

        let account = Account(provider: .claude, source: .cli)
        let resolver = CredentialResolver(store: store, http: StubHTTP(json: refreshedGrant))

        // Refreshing a CLI grant could invalidate the copy Claude Code itself holds.
        await #expect(throws: ProviderError.unauthorized) {
            _ = try await resolver.refreshAfterUnauthorized(account)
        }
        #expect(secrets.writeCount == 0)
    }
}
