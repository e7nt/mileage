import Foundation
import Security

/// Reads the credentials the Claude Code and Codex CLIs already store on this machine, so the
/// first run needs no configuration.
///
/// Deliberate constraint: mileage **never writes to these files and never refreshes these tokens**.
/// Both providers rotate refresh tokens, so refreshing here could invalidate the copy the CLI
/// holds and silently sign the user out of their actual coding tool. A status icon is not worth
/// that risk. Credentials are re-read on every poll instead — the CLI keeps them fresh in normal
/// use — and an expired token surfaces as a re-authentication prompt.
public enum LocalCLICredentials {
    public struct Discovered: Sendable, Equatable {
        public let provider: ProviderID
        public let credential: ProviderCredential
        /// Best-effort label for the account, e.g. the plan or email when the file reveals one.
        public let label: String?
        public let expiresAt: Date?

        public var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt <= Date()
        }
    }

    // MARK: - Claude

    /// Claude Code stores its OAuth grant in the login Keychain on some installs and in
    /// `~/.claude/.credentials.json` on others — and a machine can easily have both, with the
    /// file left behind stale from an older install. Preferring either one unconditionally
    /// picks the dead credential roughly half the time, so read both and keep whichever expires
    /// later.
    public static func claude(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> Discovered {
        let fileData = try? Data(contentsOf: home.appending(path: ".claude/.credentials.json"))
        let keychain = keychainSecret(service: "Claude Code-credentials")

        var sources: [Data] = []
        if let fileData { sources.append(fileData) }
        if case let .found(data) = keychain { sources.append(data) }

        let candidates = sources.compactMap(parseClaude(_:))
        let best = candidates.max {
            ($0.expiresAt ?? .distantPast) < ($1.expiresAt ?? .distantPast)
        }

        // A denied Keychain read looks exactly like an expired login from the outside: the only
        // credential left is whatever stale copy is on disk. Reporting "sign-in expired" would
        // send the user off to re-run a CLI that is working fine, so say what actually happened.
        if case let .denied(status) = keychain, best?.isExpired ?? true {
            throw ProviderError.missingCredentials(
                "mileage cannot read Claude Code's Keychain item (\(keychainMessage(status))). "
                    + "Click Allow if macOS asks, or run any claude command to refresh the file copy."
            )
        }

        guard let best else {
            throw ProviderError.missingCredentials("Claude Code is not signed in on this Mac")
        }
        return best
    }

    private static func keychainMessage(_ status: OSStatus) -> String {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "\(text), OSStatus \(status)"
    }

    private static func parseClaude(_ data: Data) -> Discovered? {
        struct File: Decodable {
            struct OAuth: Decodable {
                let accessToken: String
                let expiresAt: Double?
                let subscriptionType: String?
            }

            let claudeAiOauth: OAuth?
        }

        guard let oauth = (try? JSONDecoder().decode(File.self, from: data))?.claudeAiOauth else {
            return nil
        }

        return Discovered(
            provider: .claude,
            credential: .oauth(accessToken: oauth.accessToken, accountID: nil),
            label: oauth.subscriptionType,
            // expiresAt is milliseconds since epoch, not seconds.
            expiresAt: oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }

    // MARK: - Codex

    public static func codex(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> Discovered {
        let path = home.appending(path: ".codex/auth.json")
        guard let data = try? Data(contentsOf: path) else {
            throw ProviderError.missingCredentials("Codex is not signed in on this Mac")
        }

        struct File: Decodable {
            struct Tokens: Decodable {
                let access_token: String
                let account_id: String?
                let id_token: String?
            }

            let tokens: Tokens?
        }

        guard let tokens = (try? JSONDecoder().decode(File.self, from: data))?.tokens else {
            throw ProviderError.missingCredentials("Could not read Codex credentials")
        }

        return Discovered(
            provider: .codex,
            credential: .oauth(accessToken: tokens.access_token, accountID: tokens.account_id),
            label: tokens.id_token.flatMap(JWT.email(from:)),
            // auth.json records no expiry; a stale token surfaces as a 401 on the next poll.
            expiresAt: nil
        )
    }

    // MARK: - Keychain

    /// Distinguishes "there is no such item" from "macOS refused us", because the two need
    /// completely different advice.
    enum KeychainRead {
        case found(Data)
        case notFound
        case denied(OSStatus)
    }

    static func keychainSecret(service: String) -> KeychainRead {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return .denied(status) }
            return .found(data)
        case errSecItemNotFound:
            return .notFound
        default:
            return .denied(status)
        }
    }
}

/// Minimal unverified JWT claim reader. Used only to put a friendly name on an account —
/// never for authorization decisions, so no signature check is needed.
enum JWT {
    static func email(from token: String) -> String? {
        claims(from: token)?["email"] as? String
    }

    static func claims(from token: String) -> [String: Any]? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // base64url drops padding; restore it before decoding.
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
