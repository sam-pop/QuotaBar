import Testing
import Foundation
import UserNotifications

@Suite("AccountsViewModel OpenAI login", .timeLimit(.minutes(1)))
@MainActor
struct AccountsViewModelOpenAILoginTests {
    private struct StubError: Error {}

    /// Records every adapter call per provider so a test can prove the OpenAI login never
    /// touched the Anthropic adapter (and vice versa).
    private final class Script: @unchecked Sendable {
        let pkce = OAuthPKCE.generate()
        var openAIBeginError: Error?
        var openAICallbackCode: String? = "code-1"
        var openAIBeginCalls = 0
        var anthropicBeginCalls = 0
        var openAIExchangeCalls = 0
        var openAIIdentity: Result<AccountIdentity, Error> = .success(
            AccountIdentity(uuid: "cg-1", email: "sam@example.com", displayName: nil))
        var openAIUsageCalls = 0
        var notifications: [UNNotificationRequest] = []
        var openedCount = 0
    }

    private func ephemeralDefaults() -> UserDefaults {
        let suite = "AccountsViewModelOpenAILoginTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    /// `nonisolated`: the adapter's `fetchUsage` closure is `@Sendable` and runs off the
    /// main actor, and building a `UsageResponse` touches no actor state.
    private nonisolated func usageResponse() -> UsageResponse {
        UsageResponse(
            fiveHour: UsagePeriod(utilization: 70, resetsAt: "2026-09-08T00:00:00Z"),
            sevenDay: UsagePeriod(utilization: 52, resetsAt: "2026-09-13T00:00:00Z"))
    }

    private func makeDeps(_ script: Script) -> AccountsViewModel.Dependencies {
        let openai = ProviderAdapter(
            provider: .openai,
            supportsPaste: false,
            beginLogin: { accountID, _, _ in
                script.openAIBeginCalls += 1
                if let error = script.openAIBeginError { throw error }
                let pending = PendingLogin(
                    accountID: accountID, mode: .loopback(port: 1455), pkce: script.pkce,
                    redirectURI: OpenAIOAuthEndpoints.redirectURI,
                    startedAt: Date(timeIntervalSince1970: 0), provider: .openai)
                let code = script.openAICallbackCode
                let callback = Task<String?, Never> { code }
                return (pending, URL(string: "https://auth.openai.com/oauth/authorize")!, nil, callback)
            },
            exchange: { _, _ in
                script.openAIExchangeCalls += 1
                return CachedCredentials(accessToken: "oa-token", refreshToken: "oa-refresh", expiresAt: nil, provider: .openai)
            },
            fetchIdentity: { _ in try script.openAIIdentity.get() },
            fetchUsage: { _ in
                script.openAIUsageCalls += 1
                return self.usageResponse()
            },
            refreshToken: { _ in throw StubError() })
        var anthropic = ProviderAdapter.unavailable(.anthropic)
        anthropic = ProviderAdapter(
            provider: .anthropic, supportsPaste: true,
            beginLogin: { _, _, _ in
                script.anthropicBeginCalls += 1
                throw OAuthLoginError.transient
            },
            exchange: anthropic.exchange, fetchIdentity: anthropic.fetchIdentity,
            fetchUsage: anthropic.fetchUsage, refreshToken: anthropic.refreshToken)
        return AccountsViewModel.Dependencies(
            adapters: ProviderAdapters(anthropic: anthropic, openai: openai),
            openURL: { _ in script.openedCount += 1 },
            now: { Date(timeIntervalSince1970: 0) },
            resolveLegacyCredentials: { nil },
            deleteLegacyArtifacts: {},
            requestNotificationAuthorization: { nil },
            addNotification: { script.notifications.append($0) })
    }

    private func makeVM(_ script: Script, accounts: [Account] = [], store: AccountCredentialStoring = InMemoryAccountCredentialStore()) -> AccountsViewModel {
        let defaults = ephemeralDefaults()
        let accountsStore = AccountsStore(defaults: defaults)
        accountsStore.save(accounts)
        return AccountsViewModel(accountsStore: accountsStore, credentialStore: store,
                                 defaults: defaults, startTimer: false, deps: makeDeps(script))
    }

    @Test("Adding an OpenAI account persists provider = .openai, fetches through the OpenAI adapter, and never calls the Anthropic adapter")
    func addOpenAIHappyPath() async throws {
        let script = Script()
        let store = InMemoryAccountCredentialStore()
        let vm = makeVM(script, store: store)

        await vm.beginAddAccountLogin(provider: .openai)

        #expect(vm.accounts.count == 1)
        let account = try #require(vm.accounts.first)
        #expect(account.provider == .openai)
        #expect(account.accountUUID == "cg-1")
        #expect(account.label == "sam@example.com")
        #expect(try store.loadAll()[account.id]?.provider == .openai)
        #expect(script.openAIBeginCalls == 1)
        #expect(script.openAIExchangeCalls == 1)
        #expect(script.openAIUsageCalls >= 1)
        #expect(script.anthropicBeginCalls == 0)
        #expect(vm.pendingLogin == nil)
        #expect(vm.addLoginState == .idle)
    }

    @Test("Port 1455 busy: the add flow fails with the port message, state is clean, and an immediate retry is allowed")
    func portBusy() async {
        let script = Script()
        script.openAIBeginError = OAuthLoginStartError.portBusy
        let vm = makeVM(script)

        await vm.beginAddAccountLogin(provider: .openai)

        #expect(vm.addLoginState == .failed("Port 1455 is in use — is Codex signing in? Try again."))
        #expect(vm.pendingLogin == nil)
        #expect(script.notifications.last?.content.body == "Port 1455 is in use — is Codex signing in? Try again.")

        script.openAIBeginError = nil
        await vm.beginLogin(nil)          // "Try again" — no provider argument
        #expect(script.openAIBeginCalls == 2)
        #expect(script.anthropicBeginCalls == 0)
        #expect(vm.accounts.count == 1)
    }

    @Test("A loopback timeout on an OpenAI login fails without a paste restart or a paste notification")
    func timeoutDoesNotRestartInPasteMode() async {
        let script = Script()
        script.openAICallbackCode = nil   // the wait yields nil = timeout
        let vm = makeVM(script)

        await vm.beginAddAccountLogin(provider: .openai)

        #expect(vm.addLoginState == .failed("The login timed out — try again."))
        #expect(script.openAIBeginCalls == 1)
        #expect(vm.pendingLogin == nil)
        #expect(script.notifications.contains { $0.content.body.contains("paste") } == false)
        #expect(script.notifications.count == 1)   // the failure only; no paste prompt alongside it
        #expect(script.notifications.last?.content.body == "The login timed out — try again.")
    }

    @Test("Re-auth of an OpenAI account uses the OpenAI adapter and refuses a different ChatGPT account")
    func reAuthUsesOpenAIAdapter() async {
        let script = Script()
        let account = Account(label: "Codex", accountUUID: "cg-1", email: "sam@example.com", provider: .openai)
        let vm = makeVM(script, accounts: [account])

        script.openAIIdentity = .success(AccountIdentity(uuid: "cg-OTHER", email: "other@example.com", displayName: nil))
        await vm.beginLogin(account.id)

        #expect(script.openAIBeginCalls == 1)
        #expect(script.anthropicBeginCalls == 0)
        #expect(vm.loginState[account.id] == .failed("That browser is signed into other@example.com — expected “Codex”."))
    }

    @Test("A second Add click while an OpenAI login is pending can't turn it into a paste login")
    func pendingProviderWinsOverALaterAddChoice() async {
        let script = Script()
        // The identity step fails with the grant still in hand, which parks the login in
        // `identityFailed` — still holding the one pending slot.
        script.openAIIdentity = .failure(StubError())
        let vm = makeVM(script)

        await vm.beginAddAccountLogin(provider: .openai)
        let pending = vm.pendingLogin
        #expect(pending?.provider == .openai)

        // The one-login-at-a-time rule refuses this silently — but it has already moved
        // `addLoginProvider`, so the controls must still follow the login that is running.
        await vm.beginAddAccountLogin(provider: .anthropic)

        #expect(vm.supportsPaste(for: nil) == false)
        await vm.switchToPaste()
        #expect(vm.pendingLogin == pending)      // the OpenAI login is untouched…
        #expect(script.openAIBeginCalls == 1)    // …and nothing was restarted
        #expect(script.anthropicBeginCalls == 0)
    }

    @Test("The add-flow affordance hides the paste action for OpenAI and keeps it for Claude")
    func pasteAffordanceByProvider() async {
        let script = Script()
        let vm = makeVM(script)
        #expect(vm.supportsPaste(for: nil) == true)
        await vm.beginAddAccountLogin(provider: .openai)
        #expect(vm.supportsPaste(for: nil) == false)
    }
    @Test("A Claude account and an OpenAI account with the same email and id are two accounts")
    func crossProviderIsNotADuplicate() async {
        let script = Script()
        let claude = Account(label: "Work", accountUUID: "cg-1", email: "sam@example.com", provider: .anthropic)
        let vm = makeVM(script, accounts: [claude])

        await vm.beginAddAccountLogin(provider: .openai)

        #expect(vm.accounts.count == 2)
        #expect(vm.accounts.map(\.provider) == [.anthropic, .openai])
        #expect(vm.addLoginState == .idle)
    }

    @Test("Adding an OpenAI account that is already tracked refreshes it instead of duplicating")
    func sameProviderDedupes() async throws {
        let script = Script()
        let existing = Account(label: "Codex", accountUUID: "cg-1", email: "sam@example.com", provider: .openai)
        let store = InMemoryAccountCredentialStore([existing.id: CachedCredentials(accessToken: "old", refreshToken: "r", expiresAt: nil, provider: .openai)])
        let vm = makeVM(script, accounts: [existing], store: store)

        await vm.beginAddAccountLogin(provider: .openai)

        #expect(vm.accounts.count == 1)
        #expect(try store.loadAll()[existing.id]?.accessToken == "oa-token")
        #expect(vm.addLoginState == .notice("“Codex” is already tracked — its login was refreshed."))
    }
}
