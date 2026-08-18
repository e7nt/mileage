import Foundation

/// Where mileage keeps the secrets it owns.
///
/// This exists so the failure paths around credential storage can actually be tested. The
/// Keychain cannot be made to fail on demand, and those paths matter more than the happy one:
/// a swallowed write during token rotation strands an account permanently.
///
/// Reads distinguish "no such secret" (nil) from "the store refused us" (throws). Collapsing
/// those two into nil is what previously let a denied Keychain read masquerade as a missing
/// login.
public protocol SecretStoring: Sendable {
    func string(for account: String) throws -> String?
    func set(_ value: String, for account: String) throws
    func delete(_ account: String) throws
}
