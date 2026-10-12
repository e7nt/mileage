import Foundation
import Testing
@testable import MileageCore

@Suite("Secrets share one Keychain item, read once per launch")
struct BundledSecretStoreTests {
    @Test("Every account's secret lands in the one bundle item")
    func oneItemForAllAccounts() throws {
        let keychain = InMemorySecretStore()
        let store = BundledSecretStore(keychain: keychain)

        try store.set("key-a", for: "A")
        try store.set("key-b", for: "B")

        #expect(keychain.storedAccounts == [BundledSecretStore.bundleAccount])
        #expect(try store.string(for: "A") == "key-a")
        #expect(try store.string(for: "B") == "key-b")
    }

    @Test("The Keychain is read once, however often secrets are asked for")
    func readsOnce() throws {
        let keychain = InMemorySecretStore()
        try BundledSecretStore(keychain: keychain).set("key-a", for: "A")

        // A fresh store is a fresh launch.
        let store = BundledSecretStore(keychain: keychain)
        let readsBefore = keychain.readCount
        for _ in 0 ..< 10 {
            _ = try store.string(for: "A")
        }
        #expect(keychain.readCount - readsBefore == 1)
    }

    @Test("An account with no secret is looked up once, not on every poll")
    func missesAreRemembered() throws {
        let keychain = InMemorySecretStore()
        let store = BundledSecretStore(keychain: keychain)

        for _ in 0 ..< 10 {
            #expect(try store.string(for: "nobody") == nil)
        }
        // One read for the bundle, one for the old per-account item.
        #expect(keychain.readCount == 2)
    }

    @Test("A secret from the old one-item-per-account layout moves into the bundle")
    func migratesLegacyItem() throws {
        let keychain = InMemorySecretStore()
        keychain.seed("old-key", for: "A")
        let store = BundledSecretStore(keychain: keychain)

        #expect(try store.string(for: "A") == "old-key")
        #expect(keychain.storedAccounts == [BundledSecretStore.bundleAccount])
        #expect(try BundledSecretStore(keychain: keychain).string(for: "A") == "old-key")
    }

    @Test("If the bundle can't be written, the old item is kept rather than lost")
    func failedMigrationKeepsLegacyItem() throws {
        let keychain = InMemorySecretStore()
        keychain.seed("old-key", for: "A")
        keychain.failOnSet = .init(message: "locked")
        let store = BundledSecretStore(keychain: keychain)

        #expect(throws: InMemorySecretStore.InjectedFailure.self) {
            _ = try store.string(for: "A")
        }
        #expect(keychain.storedAccounts == ["A"])
    }

    @Test("A failed write leaves memory matching the Keychain")
    func failedWriteDoesNotUpdateCache() throws {
        let keychain = InMemorySecretStore()
        let store = BundledSecretStore(keychain: keychain)
        try store.set("first", for: "A")

        keychain.failOnSet = .init(message: "locked")
        #expect(throws: InMemorySecretStore.InjectedFailure.self) {
            try store.set("second", for: "A")
        }
        #expect(try store.string(for: "A") == "first")
    }

    @Test("A bundle that won't decode is an error, never an empty store to overwrite")
    func corruptBundleIsNotEmpty() throws {
        let keychain = InMemorySecretStore()
        keychain.seed("{ not json", for: BundledSecretStore.bundleAccount)
        let store = BundledSecretStore(keychain: keychain)

        #expect(throws: AccountStoreError.self) { _ = try store.string(for: "A") }
        #expect(throws: AccountStoreError.self) { try store.set("key", for: "A") }
        #expect(try keychain.string(for: BundledSecretStore.bundleAccount) == "{ not json")
    }

    @Test("Deleting removes the secret from the bundle and any old item")
    func deleteRemovesEverywhere() throws {
        let keychain = InMemorySecretStore()
        keychain.seed("old-key", for: "B")
        let store = BundledSecretStore(keychain: keychain)
        try store.set("key-a", for: "A")

        try store.delete("A")
        try store.delete("B")

        #expect(try store.string(for: "A") == nil)
        #expect(keychain.storedAccounts == [BundledSecretStore.bundleAccount])
    }
}
