import Foundation
import Testing

@testable import MileageCore

/// The only tests that touch the real Keychain. Everything else uses InMemorySecretStore, so a
/// locked or unavailable Keychain costs us this one suite rather than the whole run.
///
/// Skipped when the Keychain will not accept a write at all — a headless CI runner with a locked
/// login keychain would otherwise fail here for reasons that have nothing to do with the code.
private func keychainIsUsable() -> Bool {
    let probe = KeychainStore(service: "com.e7nt.mileage.probe.\(UUID().uuidString)")
    do {
        try probe.set("probe", for: "probe")
        try probe.delete("probe")
        return true
    } catch {
        return false
    }
}

@Suite("KeychainStore adapter", .enabled(if: keychainIsUsable()))
struct KeychainStoreTests {
    private func makeStore() -> KeychainStore {
        KeychainStore(service: "com.e7nt.mileage.tests.\(UUID().uuidString)")
    }

    @Test("Stores and reads a secret back unchanged")
    func roundTrip() throws {
        let store = makeStore()
        let account = UUID().uuidString
        defer { try? store.delete(account) }

        try store.set("a-secret-value", for: account)

        #expect(try store.string(for: account) == "a-secret-value")
    }

    @Test("Writing twice updates in place instead of failing as a duplicate")
    func overwrites() throws {
        let store = makeStore()
        let account = UUID().uuidString
        defer { try? store.delete(account) }

        try store.set("first", for: account)
        try store.set("second", for: account)

        #expect(try store.string(for: account) == "second")
    }

    @Test("A missing secret reads as nil, not as an error")
    func missingIsNil() throws {
        // This distinction is what lets AccountStore tell "no grant yet" apart from
        // "the Keychain refused us", which need opposite advice.
        #expect(try makeStore().string(for: UUID().uuidString) == nil)
    }

    @Test("Deleting is idempotent")
    func deleteIsIdempotent() throws {
        let store = makeStore()
        let account = UUID().uuidString

        try store.set("value", for: account)
        try store.delete(account)
        // Deleting again must not throw: removing an account should not fail because its
        // secret was already gone.
        try store.delete(account)

        #expect(try store.string(for: account) == nil)
    }

    @Test("Services are isolated from each other")
    func servicesAreIsolated() throws {
        let first = makeStore()
        let second = makeStore()
        let account = UUID().uuidString
        defer { try? first.delete(account) }

        try first.set("mine", for: account)

        #expect(try second.string(for: account) == nil)
    }
}
