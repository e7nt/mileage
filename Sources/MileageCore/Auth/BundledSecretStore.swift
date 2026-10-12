import Foundation

/// Keeps every secret mileage owns in a single Keychain item, read once per launch.
///
/// macOS asks before an app reads a Keychain item, per item, and asks again after every
/// upgrade because an ad-hoc signed build is a new identity each time. One item per account
/// meant one prompt per account per upgrade, and a read on every poll meant that clicking
/// "Allow" rather than "Always Allow" brought the prompt straight back. One item, cached in
/// memory, makes that a single prompt per launch at most.
///
/// Secrets saved by older versions (one item per account) move into the bundle the first time
/// each is read, and the old item is deleted.
public final class BundledSecretStore: SecretStoring, @unchecked Sendable {
    /// The Keychain account name of the single item. Old per-account items use UUIDs, so the
    /// two can never collide.
    static let bundleAccount = "secrets"

    private let keychain: any SecretStoring
    private let lock = NSLock()
    /// nil until the bundle has been read successfully.
    private var cached: [String: String]?
    /// Accounts already looked up in the old per-item layout, so a miss isn't repeated per poll.
    private var checkedLegacy: Set<String> = []

    public init(keychain: any SecretStoring = KeychainStore()) {
        self.keychain = keychain
    }

    public func string(for account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }

        var secrets = try loadBundle()
        if let value = secrets[account] { return value }
        guard !checkedLegacy.contains(account) else { return nil }

        guard let legacy = try keychain.string(for: account) else {
            checkedLegacy.insert(account)
            return nil
        }
        secrets[account] = legacy
        try saveBundle(secrets)
        checkedLegacy.insert(account)
        // Only after the bundle holds it, so a failed save can never lose the secret.
        try? keychain.delete(account)
        return legacy
    }

    public func set(_ value: String, for account: String) throws {
        lock.lock()
        defer { lock.unlock() }

        var secrets = try loadBundle()
        secrets[account] = value
        try saveBundle(secrets)
    }

    public func delete(_ account: String) throws {
        lock.lock()
        defer { lock.unlock() }

        var secrets = try loadBundle()
        if secrets.removeValue(forKey: account) != nil {
            try saveBundle(secrets)
        }
        // The account may predate the bundle and never have been read since.
        try keychain.delete(account)
    }

    // MARK: - Bundle

    private func loadBundle() throws -> [String: String] {
        if let cached { return cached }
        guard let raw = try keychain.string(for: Self.bundleAccount) else {
            cached = [:]
            return [:]
        }
        do {
            let secrets = try JSONDecoder().decode([String: String].self, from: Data(raw.utf8))
            cached = secrets
            return secrets
        } catch {
            // Never treat this as empty: the next save would overwrite every stored sign-in.
            throw AccountStoreError.storedCredentialsUnreadable(reason: error.localizedDescription)
        }
    }

    /// Writes first and updates the cache only on success, so memory never claims a secret
    /// the Keychain doesn't hold.
    private func saveBundle(_ secrets: [String: String]) throws {
        let data = try JSONEncoder().encode(secrets)
        try keychain.set(String(decoding: data, as: UTF8.self), for: Self.bundleAccount)
        cached = secrets
    }
}
