import Testing
import Foundation

@Suite("AccountIdentityResolver.backfill")
struct AccountIdentityResolverTests {

    @Test("Backfills uuid and email onto the target account")
    func backfills() {
        let a = Account(label: "Account 1")   // migrated, no identity
        let result = AccountIdentityResolver.backfill([a], id: a.id, provider: .anthropic, uuid: "uuid-x", email: "x@e.com")
        #expect(result.accounts.count == 1)
        #expect(result.accounts[0].accountUUID == "uuid-x")
        #expect(result.accounts[0].email == "x@e.com")
        #expect(result.duplicateOfLabel == nil)
    }

    @Test("Detects a duplicate when another account already has that identity")
    func detectsDuplicate() {
        let migrated = Account(label: "Account 1")                       // nil uuid
        let existing = Account(label: "Sam", accountUUID: "uuid-x", email: "x@e.com")
        let result = AccountIdentityResolver.backfill([migrated, existing], id: migrated.id,
                                                      provider: .anthropic, uuid: "uuid-x", email: "x@e.com")
        // The migrated account is still identified…
        #expect(result.accounts.first { $0.id == migrated.id }?.accountUUID == "uuid-x")
        // …and flagged as a duplicate of the existing one.
        #expect(result.duplicateOfLabel == "Sam")
    }

    @Test("No false duplicate for a distinct identity")
    func distinctIdentity() {
        let migrated = Account(label: "Account 1")
        let other = Account(label: "Work", accountUUID: "uuid-other")
        let result = AccountIdentityResolver.backfill([migrated, other], id: migrated.id,
                                                      provider: .anthropic, uuid: "uuid-x", email: nil)
        #expect(result.duplicateOfLabel == nil)
        #expect(result.accounts.first { $0.id == migrated.id }?.accountUUID == "uuid-x")
    }

    @Test("Unknown id leaves the list unchanged")
    func unknownID() {
        let a = Account(label: "Account 1")
        let result = AccountIdentityResolver.backfill([a], id: UUID(), provider: .anthropic, uuid: "uuid-x", email: nil)
        #expect(result.accounts == [a])
        #expect(result.duplicateOfLabel == nil)
    }

    @Test("The same account id under a different provider is not a duplicate")
    func duplicateIsPerProvider() {
        let claude = Account(label: "Work", accountUUID: "shared-id", provider: .anthropic)
        let codex = Account(label: "Codex", provider: .openai)
        let result = AccountIdentityResolver.backfill([claude, codex], id: codex.id, provider: .openai,
                                                      uuid: "shared-id", email: "sam@example.com")
        #expect(result.duplicateOfLabel == nil)
        #expect(result.accounts.first { $0.id == codex.id }?.accountUUID == "shared-id")

        let sameProvider = Account(label: "Codex 2", provider: .openai)
        let dup = AccountIdentityResolver.backfill([claude, codex, sameProvider].map { $0.id == codex.id ? result.accounts[1] : $0 },
                                                   id: sameProvider.id, provider: .openai, uuid: "shared-id", email: nil)
        #expect(dup.duplicateOfLabel == "Codex")
    }
}
