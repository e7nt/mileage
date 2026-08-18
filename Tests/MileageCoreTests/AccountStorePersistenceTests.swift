import Foundation
import Testing

@testable import MileageCore

@MainActor
private func makeDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "mileage-persist-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// These tests are about the JSON file, not about secrets, so the secret store is a hermetic
/// double — a locked or absent Keychain in CI must not make file-handling tests flaky.
@MainActor
private func makeKeychain() -> InMemorySecretStore {
    InMemorySecretStore()
}

@Suite("Account persistence failures are reported, never swallowed")
@MainActor
struct AccountStorePersistenceTests {
    @Test("A missing file is a normal first run, not a failure")
    func noFileYet() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AccountStore(secrets: makeKeychain(), directory: directory)

        #expect(store.loadState == .noFileYet)
        #expect(store.accounts.isEmpty)
    }

    @Test("An unreadable file is reported rather than treated as an empty account list")
    func unreadableFileIsReported() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("this is not json".utf8).write(to: directory.appending(path: "accounts.json"))

        let store = AccountStore(secrets: makeKeychain(), directory: directory)

        guard case .unreadable = store.loadState else {
            Issue.record("Expected .unreadable, got \(store.loadState)")
            return
        }
        #expect(store.accounts.isEmpty)
    }

    @Test("Writes are refused while the existing file cannot be read, and it stays untouched")
    func refusesToOverwriteUnreadableFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "accounts.json")
        // Stand-in for a corrupted or half-written file that still holds real accounts.
        let original = "{ definitely not an account array }"
        try Data(original.utf8).write(to: fileURL)

        let store = AccountStore(secrets: makeKeychain(), directory: directory)

        // The old behaviour silently started from empty and then overwrote this file, losing
        // every OAuth account and every name the user had chosen.
        #expect(throws: AccountStoreError.self) {
            try store.add(Account(provider: .claude, source: .oauth, label: "work"))
        }
        #expect(throws: AccountStoreError.self) {
            _ = try store.adoptCLIAccounts()
        }

        let afterwards = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(afterwards == original)
    }

    @Test("The refusal explains itself well enough to act on")
    func refusalIsActionable() {
        let error = AccountStoreError.refusingToOverwriteUnreadableFile(reason: "bad json")
        let message = try! #require(error.errorDescription)

        #expect(message.contains("bad json"))
        #expect(message.contains("accounts.json"))
    }

    @Test("Unknown fields from a newer version do not discard the file")
    func toleratesUnknownFields() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        // A file written by a future version that added a field we know nothing about.
        let future = """
        [{"id":"\(id.uuidString)","provider":"claude","source":"oauth","label":"work",
          "sortIndex":0,"someFutureField":"ignore me"}]
        """
        try Data(future.utf8).write(to: directory.appending(path: "accounts.json"))

        let store = AccountStore(secrets: makeKeychain(), directory: directory)

        #expect(store.loadState == .loaded)
        #expect(store.accounts.map(\.id) == [id])
        #expect(store.accounts.first?.label == "work")
    }

    @Test("A write to an impossible location surfaces instead of silently doing nothing")
    func writeFailureSurfaces() throws {
        // A path under a regular file can never be created, so save() must fail loudly.
        let blocker = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "mileage-blocker-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }

        let store = AccountStore(
            secrets: makeKeychain(),
            directory: blocker.appending(path: "nested")
        )

        #expect(throws: (any Error).self) {
            try store.add(Account(provider: .claude, source: .oauth))
        }
    }
}
