import Foundation

/// Every provider key, as one payload.
///
/// Typester used to keep one Keychain item per provider and read them straight
/// from the Keychain on every property access. Opening Settings alone fired
/// five `SecItemCopyMatching` calls (one per provider), and each of those raises
/// the login-password prompt whenever macOS cannot match the item's ACL to the
/// running build — which is what turned into a wall of prompts.
///
/// One payload keeps the storage to a single item, and the accounts it holds
/// double as the answer to "is a key configured?" — so nothing has to read a
/// secret to say whether one exists.
public struct APIKeyPayload: Equatable {
    public private(set) var keys: [String: String]

    public init(keys: [String: String] = [:]) {
        // Empty values would make `accounts` claim a key that is not there.
        self.keys = keys.filter { !$0.value.isEmpty }
    }

    /// Decodes a stored payload. `nil` when the data is not a payload at all,
    /// which is the signal to fall back to the legacy per-provider items.
    public init?(json: String) {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        self.init(keys: decoded)
    }

    public var json: String? {
        guard let data = try? JSONEncoder().encode(keys) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Accounts that currently hold a key.
    public var accounts: Set<String> { Set(keys.keys) }

    public func key(for account: String) -> String? { keys[account] }

    /// Setting `nil` or an empty string removes the account.
    public mutating func setKey(_ value: String?, for account: String) {
        if let value, !value.isEmpty {
            keys[account] = value
        } else {
            keys.removeValue(forKey: account)
        }
    }
}
