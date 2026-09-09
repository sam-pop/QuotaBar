import Testing
import Foundation

/// Account order is user-visible twice over — the matrix's columns and the menu bar's
/// segments both read the `accounts` array — and it is whatever order `AccountsStore`
/// persisted. So each move is checked three ways: the array, the views built from it, and
/// the saved copy that survives a relaunch.
@Suite("Account reordering", .timeLimit(.minutes(1)))
@MainActor
struct AccountReorderTests {

    private func ephemeralDefaults() -> UserDefaults {
        let suite = "AccountReorderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// Reordering touches no network, keychain or notification, so every adapter here is the
    /// unavailable one: if a move ever starts doing I/O, these tests are where it surfaces.
    private var deps: AccountsViewModel.Dependencies {
        AccountsViewModel.Dependencies(
            adapters: ProviderAdapters(anthropic: .unavailable(.anthropic), openai: .unavailable(.openai)),
            openURL: { _ in },
            now: { Date(timeIntervalSince1970: 0) },
            resolveLegacyCredentials: { nil },
            deleteLegacyArtifacts: {},
            requestNotificationAuthorization: { nil },
            addNotification: { _ in })
    }

    private func makeVM(_ accounts: [Account]) -> (AccountsViewModel, UserDefaults) {
        let defaults = ephemeralDefaults()
        AccountsStore(defaults: defaults).save(accounts)
        let viewModel = AccountsViewModel(
            accountsStore: AccountsStore(defaults: defaults),
            credentialStore: InMemoryAccountCredentialStore(),
            defaults: defaults,
            startTimer: false,
            deps: deps
        )
        return (viewModel, defaults)
    }

    /// Reads the saved list the way a relaunch would: a brand-new store over the same
    /// defaults, never the view model's own copy.
    private func persisted(_ defaults: UserDefaults) -> [String] {
        AccountsStore(defaults: defaults).load().map(\.label)
    }

    private func trio() -> [Account] {
        [Account(label: "Alpha"), Account(label: "Bravo"), Account(label: "Charlie")]
    }

    @Test("Moving the middle account swaps it with its neighbor, in the list, the views, and on disk")
    func movesTheMiddleAccount() {
        let accounts = trio()
        let (vm, defaults) = makeVM(accounts)

        vm.moveAccount(accounts[1].id, by: -1)
        #expect(vm.accounts.map(\.label) == ["Bravo", "Alpha", "Charlie"])
        #expect(vm.accountViews.map(\.account.label) == ["Bravo", "Alpha", "Charlie"])
        #expect(persisted(defaults) == ["Bravo", "Alpha", "Charlie"])

        vm.moveAccount(accounts[1].id, by: 1)
        #expect(vm.accounts.map(\.label) == ["Alpha", "Bravo", "Charlie"])
        #expect(vm.accountViews.map(\.account.label) == ["Alpha", "Bravo", "Charlie"])
        #expect(persisted(defaults) == ["Alpha", "Bravo", "Charlie"])
    }

    @Test("The ends don't wrap: the first can't move left and the last can't move right")
    func theEndsHold() {
        let accounts = trio()
        let (vm, defaults) = makeVM(accounts)

        vm.moveAccount(accounts[0].id, by: -1)
        vm.moveAccount(accounts[2].id, by: 1)

        #expect(vm.accounts.map(\.label) == ["Alpha", "Bravo", "Charlie"])
        #expect(persisted(defaults) == ["Alpha", "Bravo", "Charlie"])
    }

    @Test("An id that isn't tracked moves nothing")
    func unknownIDMovesNothing() {
        let (vm, defaults) = makeVM(trio())

        vm.moveAccount(UUID(), by: -1)

        #expect(vm.accounts.map(\.label) == ["Alpha", "Bravo", "Charlie"])
        #expect(persisted(defaults) == ["Alpha", "Bravo", "Charlie"])
    }

    @Test("A move is one slot: a bigger offset is refused rather than jumping the list")
    func onlyOneSlotAtATime() {
        let accounts = trio()
        let (vm, defaults) = makeVM(accounts)

        vm.moveAccount(accounts[0].id, by: 2)

        #expect(vm.accounts.map(\.label) == ["Alpha", "Bravo", "Charlie"])
        #expect(persisted(defaults) == ["Alpha", "Bravo", "Charlie"])
    }

    @Test("The menu bar's segments follow the new order")
    func menuBarFollowsTheOrder() {
        let personal = Account(label: "Personal")
        let work = Account(label: "Work")
        let (vm, _) = makeVM([personal, work])
        let snapshots = [
            personal.id: UsageSnapshot(fiveHourPercent: 45, sevenDayPercent: 10,
                                       fiveHourResetsAt: nil, sevenDayResetsAt: nil, fetchedAt: Date()),
            work.id: UsageSnapshot(fiveHourPercent: 82, sevenDayPercent: 20,
                                   fiveHourResetsAt: nil, sevenDayResetsAt: nil, fetchedAt: Date()),
        ]
        func menuBarText() -> String {
            MenuBarPresentation.compute(accounts: vm.accounts, snapshots: snapshots, mode: .fiveHour).text
        }

        #expect(menuBarText() == "P 45% · W 82%")
        vm.moveAccount(work.id, by: -1)
        #expect(menuBarText() == "W 82% · P 45%")
    }
}
