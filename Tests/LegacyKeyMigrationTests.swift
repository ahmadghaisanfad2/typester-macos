import XCTest
@testable import TypesterCore

final class LegacyKeyMigrationTests: XCTestCase {
    private let accounts = ["soniox-api-key", "deepgram-api-key", "openai-api-key"]

    /// The regression that lost every stored key: a read macOS refuses must
    /// never be recorded as "no key", and must not end the migration.
    func testRefusedReadIsNotTreatedAsAnAbsentKey() {
        let plan = LegacyKeyMigration.plan(
            existing: APIKeyPayload(),
            accounts: accounts
        ) { _ in .unavailable }

        XCTAssertTrue(plan.payload.accounts.isEmpty)
        XCTAssertTrue(plan.migratedAccounts.isEmpty)
        XCTAssertFalse(plan.complete, "a refused read has to be retried, not recorded as done")
    }

    func testRefusedAccountIsNotDeleted() {
        let plan = LegacyKeyMigration.plan(
            existing: APIKeyPayload(),
            accounts: accounts
        ) { account in
            account == "soniox-api-key" ? .value("soniox-secret") : .unavailable
        }

        XCTAssertEqual(plan.migratedAccounts, ["soniox-api-key"])
        XCTAssertFalse(plan.complete)
        // Only the account we actually read is safe to remove.
        XCTAssertFalse(plan.migratedAccounts.contains("deepgram-api-key"))
        XCTAssertFalse(plan.migratedAccounts.contains("openai-api-key"))
    }

    func testAbsentItemsCompleteWithoutDeletingAnything() {
        let plan = LegacyKeyMigration.plan(
            existing: APIKeyPayload(),
            accounts: accounts
        ) { _ in .missing }

        XCTAssertTrue(plan.migratedAccounts.isEmpty)
        XCTAssertTrue(plan.complete, "nothing exists, so there is nothing left to try")
    }

    func testReadsEveryAccountAndMergesThem() {
        let plan = LegacyKeyMigration.plan(
            existing: APIKeyPayload(),
            accounts: accounts
        ) { account in .value("\(account)-secret") }

        XCTAssertEqual(plan.payload.accounts, Set(accounts))
        XCTAssertEqual(plan.migratedAccounts, accounts)
        XCTAssertTrue(plan.complete)
    }

    func testExistingKeyIsKeptInsteadOfOverwrittenOrRead() {
        var existing = APIKeyPayload()
        existing.setKey("newer", for: "soniox-api-key")

        var readAccounts: [String] = []
        let plan = LegacyKeyMigration.plan(existing: existing, accounts: accounts) { account in
            readAccounts.append(account)
            return .value("older")
        }

        XCTAssertEqual(plan.payload.key(for: "soniox-api-key"), "newer")
        XCTAssertFalse(readAccounts.contains("soniox-api-key"), "no need to read what we already have")
        XCTAssertEqual(plan.migratedAccounts, ["deepgram-api-key", "openai-api-key"])
    }

    func testEmptyLegacyValueIsIgnored() {
        let plan = LegacyKeyMigration.plan(
            existing: APIKeyPayload(),
            accounts: ["soniox-api-key"]
        ) { _ in .value("") }

        XCTAssertTrue(plan.payload.accounts.isEmpty)
        XCTAssertTrue(plan.migratedAccounts.isEmpty)
        XCTAssertTrue(plan.complete)
    }
}
