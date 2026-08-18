import Foundation

@testable import MileageCore

/// Canned HTTP so network-dependent code can be exercised without a provider.
final class StubHTTP: HTTPFetching, @unchecked Sendable {
    private let status: Int
    private let body: Data
    private(set) var lastRequest: URLRequest?

    init(status: Int = 200, json: String) {
        self.status = status
        body = Data(json.utf8)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (body, response)
    }
}

/// A secret store that can be told to fail on demand.
///
/// The Keychain cannot be made to fail deliberately, which left the most consequential branch
/// in the whole app — a write that fails *after* a provider has already rotated the grant —
/// impossible to test. That is the branch this exists for.
final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    struct InjectedFailure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let lock = NSLock()
    private var storage: [String: String] = [:]

    /// When set, every `set` throws this instead of storing.
    var failOnSet: InjectedFailure?
    /// When set, every `string(for:)` throws this instead of returning.
    var failOnRead: InjectedFailure?

    private(set) var writeCount = 0

    func string(for account: String) throws -> String? {
        if let failOnRead { throw failOnRead }
        lock.lock()
        defer { lock.unlock() }
        return storage[account]
    }

    func set(_ value: String, for account: String) throws {
        if let failOnSet { throw failOnSet }
        lock.lock()
        defer { lock.unlock() }
        storage[account] = value
        writeCount += 1
    }

    func delete(_ account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[account] = nil
    }

    /// Bypasses the injected failures, so a test can seed state and then arm the failure.
    func seed(_ value: String, for account: String) {
        lock.lock()
        defer { lock.unlock() }
        storage[account] = value
    }
}
