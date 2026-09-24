import Foundation

/// Folding the pre-1.25.6 one-item-per-provider storage into the single payload.
///
/// Kept pure and separate because getting it wrong is silent and destructive:
/// a read macOS *refused* must not be recorded as "no key here", must not have
/// its item deleted, and must leave the migration incomplete so it is tried
/// again. Collapsing those outcomes into `String?` is exactly what made every
/// stored key look like it had vanished.
public enum LegacyKeyMigration {
    public enum ReadOutcome: Equatable {
        case value(String)
        case missing
        case unavailable
    }

    public struct Plan: Equatable {
        /// The merged payload to store.
        public var payload: APIKeyPayload
        /// Accounts that were read successfully and may now be deleted.
        public var migratedAccounts: [String]
        /// False when something exists that could not be read, meaning the
        /// caller must not record the migration as done.
        public var complete: Bool

        public init(payload: APIKeyPayload, migratedAccounts: [String], complete: Bool) {
            self.payload = payload
            self.migratedAccounts = migratedAccounts
            self.complete = complete
        }
    }

    /// Accounts already present in `existing` are left alone, so a key the user
    /// entered since the last attempt is never overwritten by an older one.
    public static func plan(
        existing: APIKeyPayload,
        accounts: [String],
        read: (String) -> ReadOutcome
    ) -> Plan {
        var payload = existing
        var migrated: [String] = []
        var complete = true

        for account in accounts where payload.key(for: account) == nil {
            switch read(account) {
            case .value(let value) where !value.isEmpty:
                payload.setKey(value, for: account)
                migrated.append(account)
            case .value, .missing:
                break
            case .unavailable:
                complete = false
            }
        }

        return Plan(payload: payload, migratedAccounts: migrated, complete: complete)
    }
}
