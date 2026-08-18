import Foundation

public enum AccountStoreError: Error, LocalizedError, Equatable {
    /// The account file exists but could not be parsed. Writing over it would destroy accounts
    /// we simply failed to read, so every write is refused until a human resolves it.
    case refusingToOverwriteUnreadableFile(reason: String)
    /// A secret was retrieved but could not be understood — a corrupted or foreign Keychain item.
    case storedCredentialsUnreadable(reason: String)

    public var errorDescription: String? {
        switch self {
        case let .refusingToOverwriteUnreadableFile(reason):
            "Not saving: mileage could not read your existing account list (\(reason)). "
                + "Your accounts are still on disk — fix or move accounts.json, then reopen mileage."
        case let .storedCredentialsUnreadable(reason):
            "This account's stored sign-in could not be read (\(reason)). Remove and add it again."
        }
    }
}

/// The list of tracked accounts, plus their secrets.
///
/// Metadata (which accounts exist, what they are called) is plain JSON on disk. Secrets never
/// touch that file — they live in the Keychain under the account's UUID.
@MainActor
public final class AccountStore {
    /// Whether the on-disk account list was understood. Anything other than `.loaded` after a
    /// file exists means writes are unsafe.
    public enum LoadState: Equatable {
        /// No file yet — a normal first run.
        case noFileYet
        case loaded
        case unreadable(reason: String)
    }

    public private(set) var accounts: [Account] = []
    public private(set) var loadState: LoadState = .noFileYet

    private let directory: URL
    private let fileURL: URL
    private let secrets: any SecretStoring

    public init(
        secrets: any SecretStoring = KeychainStore(),
        directory: URL? = nil
    ) {
        self.secrets = secrets
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Mileage")
        fileURL = self.directory.appending(path: "accounts.json")
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            loadState = .noFileYet
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            accounts = try JSONDecoder().decode([Account].self, from: data)
                .sorted { $0.sortIndex < $1.sortIndex }
            loadState = .loaded
        } catch {
            // Deliberately do not fall back to an empty list: the very next save would then
            // overwrite a file full of accounts we merely failed to parse.
            loadState = .unreadable(reason: error.localizedDescription)
        }
    }

    private func save() throws {
        if case let .unreadable(reason) = loadState {
            throw AccountStoreError.refusingToOverwriteUnreadableFile(reason: reason)
        }
        // Idempotent, and doing it here means a missing or unwritable directory surfaces as a
        // real error at the point of writing rather than being swallowed at construction.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(accounts)
        try data.write(to: fileURL, options: .atomic)
        loadState = .loaded
    }

    // MARK: - Discovery

    /// Adopts whatever the CLIs are already signed into, once. Called on every launch so a
    /// later `claude login` on a fresh machine is picked up without any user action.
    @discardableResult
    public func adoptCLIAccounts() throws -> [Account] {
        var adopted: [Account] = []

        for provider in [ProviderID.claude, .codex] {
            guard !accounts.contains(where: { $0.provider == provider && $0.source == .cli })
            else { continue }

            // A provider that is simply not signed in is an expected outcome, not an error.
            let discovered: LocalCLICredentials.Discovered?
            switch provider {
            case .claude: discovered = try? LocalCLICredentials.claude()
            case .codex: discovered = try? LocalCLICredentials.codex()
            case .deepseek: discovered = nil
            }
            guard let discovered else { continue }

            adopted.append(Account(
                provider: provider,
                source: .cli,
                detectedLabel: discovered.label,
                sortIndex: nextSortIndex(for: provider)
            ))
        }

        guard !adopted.isEmpty else { return [] }
        accounts.append(contentsOf: adopted)
        try save()
        return adopted
    }

    // MARK: - Mutation

    public func add(_ account: Account, tokens: OAuthTokens? = nil) throws {
        if let tokens {
            try setTokens(tokens, for: account.id)
        }
        accounts.append(account)
        try save()
    }

    public func addAPIKeyAccount(provider: ProviderID, key: String, label: String? = nil) throws -> Account {
        let account = Account(
            provider: provider,
            source: .apiKey,
            label: label,
            sortIndex: nextSortIndex(for: provider)
        )
        try secrets.set(key, for: account.id.uuidString)
        accounts.append(account)
        try save()
        return account
    }

    public func remove(_ id: UUID) throws {
        // Drop the secret first: an orphaned Keychain item is worse than an orphaned row.
        try secrets.delete(id.uuidString)
        accounts.removeAll { $0.id == id }
        try save()
    }

    public func rename(_ id: UUID, to label: String?) throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        accounts[index].label = (trimmed?.isEmpty ?? true) ? nil : trimmed
        try save()
    }

    /// Records what the provider called this account, so rows are identifiable before the user
    /// names them.
    public func updateDetectedLabel(_ label: String?, for id: UUID) throws {
        guard let label, !label.isEmpty,
              let index = accounts.firstIndex(where: { $0.id == id }),
              accounts[index].detectedLabel != label
        else { return }
        accounts[index].detectedLabel = label
        try save()
    }

    public func account(_ id: UUID) -> Account? {
        accounts.first { $0.id == id }
    }

    private func nextSortIndex(for provider: ProviderID) -> Int {
        (accounts.filter { $0.provider == provider }.map(\.sortIndex).max() ?? -1) + 1
    }

    // MARK: - Secrets

    /// Returns nil only when this account has no stored grant. A store that refuses the read,
    /// or a grant that will not decode, throws — those need re-authentication, not a retry.
    public func tokens(for id: UUID) throws -> OAuthTokens? {
        guard let raw = try secrets.string(for: id.uuidString) else { return nil }
        do {
            return try JSONDecoder().decode(OAuthTokens.self, from: Data(raw.utf8))
        } catch {
            throw AccountStoreError.storedCredentialsUnreadable(reason: error.localizedDescription)
        }
    }

    public func setTokens(_ tokens: OAuthTokens, for id: UUID) throws {
        let data = try JSONEncoder().encode(tokens)
        guard let json = String(data: data, encoding: .utf8) else {
            throw AccountStoreError.storedCredentialsUnreadable(reason: "could not encode grant")
        }
        try secrets.set(json, for: id.uuidString)
    }

    public func apiKey(for id: UUID) throws -> String? {
        try secrets.string(for: id.uuidString)
    }
}
