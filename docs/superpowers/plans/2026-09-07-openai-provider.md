# OpenAI / Codex Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Track OpenAI/Codex accounts alongside Claude accounts: own browser OAuth login on the pinned port 1455, one-time import from Codex CLI's login file, peer column in the matrix, provider shapes in the menu bar when providers are mixed.

**Architecture:** A `Provider` enum on `Account` (and tagged onto stored credentials) selects one `ProviderAdapter` — five closures: begin login, exchange, identity, usage, refresh — from a total `ProviderAdapters` pair injected through `AccountsViewModel.Dependencies`. Everything downstream (runtime, breaker, retry, persistence, login state machine) stays provider-blind. The OpenAI adapter synthesizes the existing `UsageResponse` so the runtime seam never changes.

**Tech Stack:** Swift 6, SwiftUI + AppKit, Network.framework, Swift Testing (`@Suite`/`@Test`/`#expect`), XcodeGen, zero third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-09-07-openai-provider-design.md` — read it first; every task cites the section it implements.

## Global Constraints

- macOS 13.0 deployment target, Swift 6 language mode, zero third-party dependencies.
- `make test` is the only arbiter. Never report a result you have not seen printed. One suite: `xcodebuild -project ClaudeUsageBar.xcodeproj -scheme ClaudeUsageBar -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO -only-testing:ClaudeUsageBarTests/<SuiteTypeName>` (run `make generate` first if `ClaudeUsageBar.xcodeproj` is missing).
- Commit with `git -c commit.gpgsign=false commit` (the signing key needs a passphrase and hangs agents). End every commit message with the line `Claude-Session: https://claude.ai/code/session_01U5QvupoEwjPZpqRNXFajaz`.
- Never run `make install` or `make run` (they replace the user's live app and touch the real keychain). Never touch the real keychain, `~/.codex`, or the network from a test.
- Constructing `AccountsViewModel` or `AccountRuntime` in a test performs ZERO keychain/network/notification/filesystem I/O — every such call goes through `Dependencies`.
- No `try?` on a credential write. Fail closed.
- Every OpenAI request sends `User-Agent: AppInfo.userAgent` and targets a URL built from `OpenAIOAuthEndpoints` constants only (SEC-3).
- Never log or print an authorize URL, token, code, or PKCE verifier.
- Doc comments describe behavior you can point at in this repo or in spec §2. Do not assert what RFCs require, what frameworks do internally, or what servers do beyond the spike.
- The strings "Task N" / "task N" never appear in shipped source or tests.
- Copy: the user-facing strings in spec §7.6 are exact.

---

### Task 1: `Provider` enum, `Account.provider`, `CachedCredentials.provider`, `PendingLogin.provider`, migration rebuild

Spec §5.1, §5.8, SEC-4.

**Files:**
- Create: `ClaudeUsageBar/Models/Provider.swift`
- Modify: `ClaudeUsageBar/Models/Account.swift` (struct `Account`, lines 6–27)
- Modify: `ClaudeUsageBar/Services/KeychainService.swift` (struct `CachedCredentials`, lines 3–18)
- Modify: `ClaudeUsageBar/Services/OAuthLoginModels.swift` (struct `PendingLogin`, lines 18–24; enum `OAuthLoginMode`, lines 7–10)
- Modify: `ClaudeUsageBar/Services/AccountMigration.swift` (rebuild branch, lines 30–36)
- Test: `ClaudeUsageBarTests/ProviderPersistenceTests.swift` (new), `ClaudeUsageBarTests/AccountMigrationTests.swift` (add one test)

**Interfaces:**
- Produces: `enum Provider: String, Codable, CaseIterable, Sendable { case anthropic, openai }` with `var displayName: String` ("Claude" / "OpenAI") and `static func lenient(_ raw: String?) -> Provider`.
- Produces: `Account.init(id:label:accountUUID:email:shortCode:provider:)` with `provider: Provider = .anthropic`; `let provider: Provider`.
- Produces: `CachedCredentials.provider: Provider?` (memberwise init gains a defaulted trailing parameter; existing 3- and 4-argument calls compile unchanged).
- Produces: `PendingLogin.init(accountID:mode:pkce:redirectURI:startedAt:provider:)` with `provider: Provider = .anthropic`; `OAuthLoginMode.imported`.

- [ ] **Step 1: Write the failing tests**

Create `ClaudeUsageBarTests/ProviderPersistenceTests.swift`:

```swift
import Testing
import Foundation

@Suite("Provider persistence")
struct ProviderPersistenceTests {

    private func ephemeralDefaults() -> UserDefaults {
        let suite = "ProviderPersistenceTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test("Account JSON written before `provider` existed decodes as Anthropic")
    func legacyAccountDecodesAsAnthropic() throws {
        let json = #"[{"id":"9F4B2C4E-3B0A-4D6D-8E3E-1B2A3C4D5E6F","label":"Personal","accountUUID":"u1"}]"#
        let accounts = try JSONDecoder().decode([Account].self, from: Data(json.utf8))
        #expect(accounts.count == 1)
        #expect(accounts[0].provider == .anthropic)
        #expect(accounts[0].accountUUID == "u1")
    }

    @Test("An OpenAI account round-trips through AccountsStore")
    func openAIRoundTrips() {
        let store = AccountsStore(defaults: ephemeralDefaults())
        store.save([Account(label: "Codex", accountUUID: "cg-1", email: "a@b.c", provider: .openai)])
        let loaded = store.load()
        #expect(loaded.count == 1)
        #expect(loaded[0].provider == .openai)
    }

    @Test("An unknown provider string decodes as Anthropic and the rest of the list survives")
    func unknownProviderIsLenient() throws {
        let json = #"""
        [{"id":"9F4B2C4E-3B0A-4D6D-8E3E-1B2A3C4D5E6F","label":"A","provider":"gemini"},
         {"id":"1F4B2C4E-3B0A-4D6D-8E3E-1B2A3C4D5E6F","label":"B","provider":"openai"}]
        """#
        let accounts = try JSONDecoder().decode([Account].self, from: Data(json.utf8))
        #expect(accounts.map(\.provider) == [.anthropic, .openai])
    }

    @Test("CachedCredentials without a provider tag decodes with nil; a tag round-trips; an unknown tag is nil")
    func credentialsProviderTag() throws {
        let legacy = #"{"accessToken":"a","refreshToken":"r"}"#
        let decodedLegacy = try JSONDecoder().decode(CachedCredentials.self, from: Data(legacy.utf8))
        #expect(decodedLegacy.provider == nil)

        var tagged = CachedCredentials(accessToken: "a", refreshToken: "r", expiresAt: nil)
        tagged.provider = .openai
        let roundTrip = try JSONDecoder().decode(CachedCredentials.self, from: JSONEncoder().encode(tagged))
        #expect(roundTrip.provider == .openai)
        #expect(roundTrip == tagged)

        let unknown = #"{"accessToken":"a","provider":"gemini"}"#
        #expect(try JSONDecoder().decode(CachedCredentials.self, from: Data(unknown.utf8)).provider == nil)
    }

    @Test("Provider.lenient maps unknown and nil to Anthropic")
    func lenient() {
        #expect(Provider.lenient(nil) == .anthropic)
        #expect(Provider.lenient("gemini") == .anthropic)
        #expect(Provider.lenient("openai") == .openai)
    }
}
```

Add to `ClaudeUsageBarTests/AccountMigrationTests.swift` (inside the suite, after the existing rebuild test if there is one; otherwise anywhere):

```swift
    @Test("Rebuilding the list from a surviving credential map keeps each slot's provider")
    func rebuildKeepsProvider() throws {
        let defaults = ephemeralDefaults()
        let openAIID = UUID(), claudeID = UUID()
        var openAICreds = CachedCredentials(accessToken: "o", refreshToken: "r", expiresAt: nil)
        openAICreds.provider = .openai
        let credStore = InMemoryAccountCredentialStore([
            openAIID: openAICreds,
            claudeID: CachedCredentials(accessToken: "c", refreshToken: "r", expiresAt: nil),
        ])
        let migration = makeMigration(defaults: defaults, credentialStore: credStore, legacyCreds: nil)

        let accounts = migration.run()

        #expect(accounts.count == 2)
        #expect(accounts.first { $0.id == openAIID }?.provider == .openai)
        #expect(accounts.first { $0.id == claudeID }?.provider == .anthropic)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test 2>&1 | tail -30`
Expected: compile errors — `Provider` not found, `Account` has no `provider`.

- [ ] **Step 3: Create `Provider.swift`**

```swift
import Foundation

/// Which vendor an account belongs to. Selects the `ProviderAdapter` used for its login,
/// identity, usage, and refresh calls. Stored on `Account` (immutable) and tagged onto
/// `CachedCredentials`, so a `UserDefaults` reset can rebuild the account list with the
/// right provider from the surviving credential map.
enum Provider: String, Codable, CaseIterable, Sendable {
    case anthropic
    case openai

    var displayName: String {
        switch self {
        case .anthropic: return "Claude"
        case .openai: return "OpenAI"
        }
    }

    /// Decoding fallback: a missing or unrecognized raw value (a newer build's provider, or a
    /// list written before this field existed) reads as Anthropic rather than failing the
    /// whole decode — `AccountsStore.load` turns any decode error into an empty list.
    static func lenient(_ raw: String?) -> Provider {
        raw.flatMap(Provider.init(rawValue:)) ?? .anthropic
    }
}
```

- [ ] **Step 4: Add `provider` to `Account` with a lenient decoder**

Replace the `Account` struct in `ClaudeUsageBar/Models/Account.swift` (keep `AccountsStore` below it unchanged):

```swift
/// One tracked account. `id` is the app's own stable handle and the key into the
/// credential map; `accountUUID`/`email` come from the provider's identity call at capture
/// time (Anthropic: the OAuth profile endpoint; OpenAI: the usage endpoint) and drive
/// labeling, dedupe, and the re-auth identity guard. `provider` never changes for the life
/// of an account: the adapter attached to its runtime is chosen from it.
struct Account: Codable, Identifiable, Equatable {
    let id: UUID
    var label: String
    /// Stable provider account identity. `nil` until it has been fetched — the case for a
    /// legacy-migrated account (identity unknown at migration time, backfilled on the first
    /// successful profile fetch). Dedupe and the re-auth identity guard only apply once this
    /// is populated, and always together with `provider`.
    var accountUUID: String?
    var email: String?
    /// Optional user-chosen menu-bar prefix (e.g. "🏠" or "Me"). When set, it overrides the
    /// prefix auto-derived from `label`. `nil`/empty means "derive from the label".
    var shortCode: String?
    let provider: Provider

    init(id: UUID = UUID(), label: String, accountUUID: String? = nil,
         email: String? = nil, shortCode: String? = nil, provider: Provider = .anthropic) {
        self.id = id
        self.label = label
        self.accountUUID = accountUUID
        self.email = email
        self.shortCode = shortCode
        self.provider = provider
    }

    enum CodingKeys: String, CodingKey { case id, label, accountUUID, email, shortCode, provider }

    /// Hand-written so `provider` decodes leniently (see `Provider.lenient`); encoding stays
    /// synthesized.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        accountUUID = try c.decodeIfPresent(String.self, forKey: .accountUUID)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        shortCode = try c.decodeIfPresent(String.self, forKey: .shortCode)
        provider = Provider.lenient(try c.decodeIfPresent(String.self, forKey: .provider))
    }
}
```

- [ ] **Step 5: Tag `CachedCredentials` with an optional provider**

Replace the `CachedCredentials` struct in `ClaudeUsageBar/Services/KeychainService.swift`:

```swift
struct CachedCredentials: Codable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    /// Expiry of the refresh token itself (Anthropic's refresh tokens carry a rolling
    /// ~28-day expiry; OpenAI's token response has no such field, so it stays nil there).
    /// Optional so previously-persisted payloads without this field still decode.
    var refreshTokenExpiresAt: Date?
    /// Which provider issued these tokens. `nil` on payloads written before the field
    /// existed, which are all Anthropic. Read by `AccountMigration`'s rebuild path only.
    var provider: Provider?

    init(accessToken: String, refreshToken: String?, expiresAt: Date?,
         refreshTokenExpiresAt: Date? = nil, provider: Provider? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
        self.provider = provider
    }

    enum CodingKeys: String, CodingKey { case accessToken, refreshToken, expiresAt, refreshTokenExpiresAt, provider }

    /// Hand-written so an unrecognized `provider` string decodes as nil instead of failing
    /// the whole credential map, which `AccountCredentialStore` would then treat as unreadable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken)
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        refreshTokenExpiresAt = try c.decodeIfPresent(Date.self, forKey: .refreshTokenExpiresAt)
        provider = try c.decodeIfPresent(String.self, forKey: .provider).flatMap(Provider.init(rawValue:))
    }

    /// Whether the access token has expired or will within `leeway`. Tokens without a
    /// known expiry (`expiresAt == nil`) never report as needing a proactive refresh —
    /// the reactive 401/403 path remains the safety net for those.
    func needsRefresh(now: Date = Date(), leeway: TimeInterval = 300) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= leeway
    }
}
```

Check that `OAuthExchange.credentials(fromStatus:body:now:)` and `KeychainService.refreshCredentials(from:fallbackRefreshToken:now:)` still compile (they use the 4-argument init; they do).

- [ ] **Step 6: Add `provider` to `PendingLogin` and `.imported` to `OAuthLoginMode`**

In `ClaudeUsageBar/Services/OAuthLoginModels.swift`:

```swift
/// How a login receives its credentials. `loopback` runs a local HTTP server and captures
/// the browser redirect; `paste` sends the browser to Anthropic's own callback page, which
/// renders a `code#state` string for the user to copy back into the app; `imported` has no
/// browser at all — the credentials were read from Codex CLI's login file and only the
/// identity/store tail of a login runs.
enum OAuthLoginMode: Equatable {
    case loopback(port: UInt16)
    case paste
    case imported
}

struct PendingLogin: Equatable {
    let accountID: UUID?
    let mode: OAuthLoginMode
    let pkce: OAuthPKCE
    let redirectURI: String
    let startedAt: Date
    /// Which provider's adapter finishes this login (exchange + identity).
    let provider: Provider

    init(accountID: UUID?, mode: OAuthLoginMode, pkce: OAuthPKCE, redirectURI: String,
         startedAt: Date, provider: Provider = .anthropic) {
        self.accountID = accountID
        self.mode = mode
        self.pkce = pkce
        self.redirectURI = redirectURI
        self.startedAt = startedAt
        self.provider = provider
    }
}
```

Keep the existing doc comment on `PendingLogin` (the one about `pkce`/`redirectURI`/`accountID`) above the struct.

- [ ] **Step 7: Migration rebuild keeps the provider**

In `ClaudeUsageBar/Services/AccountMigration.swift`, replace the rebuild branch:

```swift
        // Defaults were reset but the credential map survived in the keychain — rebuild the
        // list from its slots rather than overwriting real accounts with a fresh single one.
        // Each slot's provider tag comes along; a slot written before the tag existed is
        // Anthropic.
        if let existing = try? credentialStore.loadAll(), !existing.isEmpty {
            let accounts = existing.enumerated().map { index, entry in
                Account(id: entry.key, label: "Account \(index + 1)", provider: entry.value.provider ?? .anthropic)
            }
            accountsStore.save(accounts)
            return accounts
        }
```

- [ ] **Step 8: Run the full suite**

Run: `make test 2>&1 | tail -30`
Expected: all tests pass, including the 6 new ones. Any existing test that pattern-matches `OAuthLoginMode` exhaustively must add `.imported` (compile error tells you where).

- [ ] **Step 9: Commit**

```bash
git add ClaudeUsageBar/Models/Provider.swift ClaudeUsageBar/Models/Account.swift ClaudeUsageBar/Services/KeychainService.swift ClaudeUsageBar/Services/OAuthLoginModels.swift ClaudeUsageBar/Services/AccountMigration.swift ClaudeUsageBarTests/ProviderPersistenceTests.swift ClaudeUsageBarTests/AccountMigrationTests.swift
git -c commit.gpgsign=false commit -m "feat: Provider enum on Account, credentials, and pending login; lenient decode; rebuild keeps provider

Claude-Session: https://claude.ai/code/session_01U5QvupoEwjPZpqRNXFajaz"
```

---

### Task 2: `ProviderAdapter` seam in `AccountsViewModel.Dependencies`

Spec §5.2. Pure refactor: behavior identical, all existing tests pass.

**Files:**
- Create: `ClaudeUsageBar/Services/ProviderAdapter.swift`
- Modify: `ClaudeUsageBar/ViewModels/AccountsViewModel.swift` (`Dependencies` lines 61–142; `attachRuntime` 239–261; `backfillIdentity` 284–297; `runLogin` 415–421; `exchangeRetryingTransient` 524–531; `verifyAndStore` 535–539)
- Modify: `ClaudeUsageBarTests/AccountsViewModelLoginTests.swift` (`makeDeps` at lines 38–52 and 229–270; mutations at 108, 144, 472, 584)

**Interfaces:**
- Produces:
  ```swift
  typealias StartedLogin = (pending: PendingLogin, authorizeURL: URL, server: LoopbackServer?, callback: Task<String?, Never>?)
  struct ProviderAdapter: Sendable {
      let provider: Provider
      let supportsPaste: Bool
      var beginLogin: @Sendable (_ accountID: UUID?, _ forcePaste: Bool, _ loginHintEmail: String?) async throws -> StartedLogin
      var exchange: @Sendable (_ code: String, _ pending: PendingLogin) async throws -> CachedCredentials
      var fetchIdentity: @Sendable (_ token: String) async throws -> AccountIdentity
      var fetchUsage: @Sendable (_ token: String) async throws -> UsageResponse
      var refreshToken: @Sendable (_ credentials: CachedCredentials) async throws -> CachedCredentials
      static func unavailable(_ provider: Provider) -> ProviderAdapter
  }
  struct ProviderAdapters: Sendable { var anthropic: ProviderAdapter; var openai: ProviderAdapter; func adapter(for: Provider) -> ProviderAdapter }
  enum ProviderAdapterError: Error, Equatable { case unavailable(Provider) }
  enum AnthropicProvider { static var adapter: ProviderAdapter }
  ```
- Produces on the view model: `AccountsViewModel.Dependencies.adapters: ProviderAdapters` (replaces `beginLogin`, `exchange`, `fetchIdentity`, `fetchUsage`, `refreshToken`); `func loginProvider(for accountID: UUID?) -> Provider` (internal, not private — the views use it later).
- Consumes: `Provider`, `PendingLogin.provider` (Task 1).

- [ ] **Step 1: Create `ProviderAdapter.swift`**

```swift
import Foundation

/// What `ProviderAdapter.beginLogin` returns — the same 4-tuple `OAuthLoginService.begin`
/// has always returned, named so the two providers' login services share a signature.
typealias StartedLogin = (
    pending: PendingLogin, authorizeURL: URL, server: LoopbackServer?, callback: Task<String?, Never>?
)

/// One vendor's five network operations, as closures so tests can stub them per provider.
/// The coordinator picks the adapter from `Account.provider` (existing accounts) or from
/// the add-account flow's chosen provider, and hands `fetchUsage`/`refreshToken` down into
/// that account's `AccountRuntime`. Nothing downstream of this struct knows which vendor it
/// is talking to.
struct ProviderAdapter: Sendable {
    let provider: Provider
    /// Whether a loopback timeout may restart this provider's login in paste mode. Anthropic's
    /// callback page supports it; OpenAI's redirect URI is pinned, so it cannot.
    let supportsPaste: Bool
    var beginLogin: @Sendable (_ accountID: UUID?, _ forcePaste: Bool, _ loginHintEmail: String?) async throws -> StartedLogin
    var exchange: @Sendable (_ code: String, _ pending: PendingLogin) async throws -> CachedCredentials
    var fetchIdentity: @Sendable (_ token: String) async throws -> AccountIdentity
    var fetchUsage: @Sendable (_ token: String) async throws -> UsageResponse
    var refreshToken: @Sendable (_ credentials: CachedCredentials) async throws -> CachedCredentials

    /// An adapter whose every operation throws `ProviderAdapterError.unavailable`. Tests use
    /// it for the provider a test does not exercise, so a request routed to the wrong
    /// provider fails loudly instead of silently succeeding against a permissive stub.
    static func unavailable(_ provider: Provider) -> ProviderAdapter {
        ProviderAdapter(
            provider: provider,
            supportsPaste: false,
            beginLogin: { _, _, _ in throw ProviderAdapterError.unavailable(provider) },
            exchange: { _, _ in throw ProviderAdapterError.unavailable(provider) },
            fetchIdentity: { _ in throw ProviderAdapterError.unavailable(provider) },
            fetchUsage: { _ in throw ProviderAdapterError.unavailable(provider) },
            refreshToken: { _ in throw ProviderAdapterError.unavailable(provider) })
    }
}

enum ProviderAdapterError: Error, Equatable {
    case unavailable(Provider)
}

/// Both providers' adapters. A struct with one field per provider rather than a dictionary,
/// so a lookup can never come back empty.
struct ProviderAdapters: Sendable {
    var anthropic: ProviderAdapter
    var openai: ProviderAdapter

    func adapter(for provider: Provider) -> ProviderAdapter {
        switch provider {
        case .anthropic: return anthropic
        case .openai: return openai
        }
    }
}

/// The live Anthropic adapter: exactly the calls `AccountsViewModel.Dependencies.live`
/// used to wire inline.
enum AnthropicProvider {
    static var adapter: ProviderAdapter {
        ProviderAdapter(
            provider: .anthropic,
            supportsPaste: true,
            beginLogin: { accountID, forcePaste, loginHintEmail in
                try await OAuthLoginService().begin(
                    accountID: accountID, forcePaste: forcePaste, loginHintEmail: loginHintEmail)
            },
            exchange: { code, pending in
                try await OAuthLoginService().exchange(code: code, pending: pending)
            },
            fetchIdentity: { token in
                try await ProfileService.fetchIdentity(token: token)
            },
            fetchUsage: { try await UsageAPIService.fetch(token: $0) },
            refreshToken: { creds in
                guard let refreshToken = creds.refreshToken else {
                    throw KeychainServiceError.noRefreshToken
                }
                return try await KeychainService.performOAuthRefresh(refreshToken: refreshToken)
            })
    }
}
```

- [ ] **Step 2: Replace the five closures in `Dependencies`**

In `AccountsViewModel.Dependencies`, delete the `beginLogin`, `exchange`, `fetchIdentity`, `fetchUsage`, and `refreshToken` properties and their doc comments, and add in their place (first property in the struct):

```swift
        /// One adapter per provider: browser login, code exchange, identity, usage, and
        /// token refresh. The coordinator picks by `Account.provider`.
        var adapters: ProviderAdapters
```

In `.live`, replace the five wired closures with:

```swift
                adapters: ProviderAdapters(
                    anthropic: AnthropicProvider.adapter,
                    // Replaced by the real OpenAI adapter once its login service exists.
                    openai: .unavailable(.openai)),
```

Keep `openURL`, `now`, `resolveLegacyCredentials`, `deleteLegacyArtifacts`, `requestNotificationAuthorization`, `addNotification` as they are.

- [ ] **Step 3: Route every call through the adapter**

Add near `loginHintEmail(for:)`:

```swift
    /// The provider whose adapter serves one login flow: an existing account's own provider,
    /// or, for the add-account flow, the provider most recently chosen for it.
    func loginProvider(for accountID: UUID?) -> Provider {
        guard let accountID, let account = accounts.first(where: { $0.id == accountID }) else {
            return .anthropic
        }
        return account.provider
    }
```

(`.anthropic` for the add flow is replaced by `addLoginProvider` in the OpenAI-login task.)

Then:
- `attachRuntime`: before building `runtimeDeps`, `let adapter = deps.adapters.adapter(for: account.provider)`; use `fetchUsage: adapter.fetchUsage, refreshToken: adapter.refreshToken`.
- `backfillIdentity`: replace `deps.fetchIdentity(token)` with `deps.adapters.adapter(for: account.provider).fetchIdentity(token)`, where `account` is looked up first: `guard let account = accounts.first(where: { $0.id == id }), let token = ..., let identity = try? await deps.adapters.adapter(for: account.provider).fetchIdentity(token) else { return }`.
- `runLogin`: replace `deps.beginLogin(accountID, forcePaste, loginHintEmail(for: accountID))` with `deps.adapters.adapter(for: loginProvider(for: accountID)).beginLogin(accountID, forcePaste, loginHintEmail(for: accountID))`.
- `exchangeRetryingTransient`: both `deps.exchange(code, pending)` → `deps.adapters.adapter(for: pending.provider).exchange(code, pending)`.
- `verifyAndStore`: `deps.fetchIdentity(grant.accessToken)` → `deps.adapters.adapter(for: pending.provider).fetchIdentity(grant.accessToken)`.

- [ ] **Step 4: Update the test fixtures mechanically**

In `AccountsViewModelLoginTests.swift`, the first `makeDeps(calls:legacyCredentials:)` becomes:

```swift
    private func makeDeps(calls: Calls, legacyCredentials: CachedCredentials?) -> AccountsViewModel.Dependencies {
        AccountsViewModel.Dependencies(
            adapters: ProviderAdapters(
                anthropic: ProviderAdapter(
                    provider: .anthropic,
                    supportsPaste: true,
                    beginLogin: { _, _, _ in throw OAuthLoginError.transient },
                    exchange: { _, _ in throw OAuthLoginError.transient },
                    fetchIdentity: { _ in AccountIdentity(uuid: "u", email: "e", displayName: "d") },
                    fetchUsage: { _ in throw StubError() },
                    refreshToken: { _ in throw StubError() }),
                openai: .unavailable(.openai)),
            openURL: { _ in },
            now: { Date(timeIntervalSince1970: 0) },
            resolveLegacyCredentials: {
                calls.resolve += 1
                return legacyCredentials
            },
            deleteLegacyArtifacts: { calls.delete += 1 },
            requestNotificationAuthorization: { nil },
            addNotification: { _ in })
    }
```

The second `makeDeps(_ script:)` wraps its five closures the same way (`ProviderAdapter(provider: .anthropic, supportsPaste: true, beginLogin: {…}, exchange: {…}, fetchIdentity: {…}, fetchUsage: {…}, refreshToken: {…})`, `openai: .unavailable(.openai)`), with the other six fields unchanged. The four mutation sites change from `deps.fetchUsage = …` / `deps.beginLogin = …` to `deps.adapters.anthropic.fetchUsage = …` / `deps.adapters.anthropic.beginLogin = …`.

`AccountRuntimeTests.swift` is untouched: `AccountRuntime.Dependencies` did not change.

- [ ] **Step 5: Run the full suite**

Run: `make test 2>&1 | tail -30`
Expected: PASS, same test count as before this task.

- [ ] **Step 6: Commit**

```bash
git add ClaudeUsageBar/Services/ProviderAdapter.swift ClaudeUsageBar/ViewModels/AccountsViewModel.swift ClaudeUsageBarTests/AccountsViewModelLoginTests.swift
git -c commit.gpgsign=false commit -m "refactor: per-provider adapter seam replaces the five Anthropic closures in Dependencies

Claude-Session: https://claude.ai/code/session_01U5QvupoEwjPZpqRNXFajaz"
```

---

### Task 3: OpenAI endpoints, authorize URL, strict form encoder, start error

Spec §5.4, SEC-2, SEC-6, spike O2a/O2c.

**Files:**
- Create: `ClaudeUsageBar/Services/OpenAIOAuthModels.swift`
- Modify: `ClaudeUsageBar/Services/OAuthLoginModels.swift` (`PendingLogin.authorizeURL(loginHintEmail:)`, lines 53–82)
- Test: `ClaudeUsageBarTests/OpenAIAuthorizeURLTests.swift` (new), `ClaudeUsageBarTests/FormEncoderTests.swift` (new)

**Interfaces:**
- Produces: `enum OpenAIOAuthEndpoints` with `authorize`, `token`, `tokenURL: URL`, `usage`, `usageURL: URL`, `clientID`, `scope`, `callbackPort: UInt16 = 1455`, `callbackPath = "/auth/callback"`, `redirectURI = "http://localhost:1455/auth/callback"`, `originator = "codex_cli_rs"`.
- Produces: `enum FormEncoder { static func encode(_ fields: [(name: String, value: String)]) -> Data }`.
- Produces: `enum OAuthLoginStartError: Error, Equatable { case portBusy }`.
- Produces: `PendingLogin.authorizeURL(loginHintEmail:)` now switches on `provider`.

- [ ] **Step 1: Write the failing tests**

`ClaudeUsageBarTests/OpenAIAuthorizeURLTests.swift`:

```swift
import Testing
import Foundation

@Suite("OpenAI authorize URL")
struct OpenAIAuthorizeURLTests {
    private let pkce = OAuthPKCE(verifier: "v", challenge: "CHAL", state: "STATE")

    private func pending() -> PendingLogin {
        PendingLogin(accountID: nil, mode: .loopback(port: 1455), pkce: pkce,
                     redirectURI: OpenAIOAuthEndpoints.redirectURI,
                     startedAt: Date(timeIntervalSince1970: 0), provider: .openai)
    }

    @Test("Builds exactly the query the spike proved, with the pinned redirect and %20-encoded scope")
    func exactQuery() throws {
        let url = pending().authorizeURL(loginHintEmail: nil)
        #expect(url.scheme == "https")
        #expect(url.host == "auth.openai.com")
        #expect(url.path == "/oauth/authorize")
        let expected = "response_type=code"
            + "&client_id=app_EMoamEEZ73f0CkXaXp7hrann"
            + "&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback"
            + "&scope=openid%20profile%20email%20offline_access"
            + "&code_challenge=CHAL"
            + "&code_challenge_method=S256"
            + "&state=STATE"
            + "&id_token_add_organizations=true"
            + "&codex_cli_simplified_flow=true"
            + "&originator=codex_cli_rs"
        #expect(url.query(percentEncoded: true) == expected)
    }

    @Test("Never sends login_hint for OpenAI, even when an email is supplied")
    func noLoginHint() {
        let url = pending().authorizeURL(loginHintEmail: "someone@example.com")
        #expect(url.query(percentEncoded: true)?.contains("login_hint") == false)
        #expect(url.absoluteString.contains("example.com") == false)
    }

    @Test("Anthropic logins are unchanged: claude.ai host and login_hint still sent")
    func anthropicUnchanged() {
        let anthropic = PendingLogin(accountID: nil, mode: .loopback(port: 1), pkce: pkce,
                                     redirectURI: "http://localhost:1/callback",
                                     startedAt: Date(timeIntervalSince1970: 0))
        let url = anthropic.authorizeURL(loginHintEmail: "a@b.c")
        #expect(url.host == "claude.ai")
        #expect(url.query(percentEncoded: true)?.contains("login_hint=a%40b.c") == true)
    }
}
```

`ClaudeUsageBarTests/FormEncoderTests.swift`:

```swift
import Testing
import Foundation

@Suite("FormEncoder")
struct FormEncoderTests {
    @Test("Percent-encodes everything outside RFC 3986 unreserved characters, including + & = / %")
    func strictEncoding() {
        let body = FormEncoder.encode([
            (name: "grant_type", value: "authorization_code"),
            (name: "code", value: "a+b&c=d/e%f g"),
            (name: "redirect_uri", value: "http://localhost:1455/auth/callback"),
        ])
        #expect(String(decoding: body, as: UTF8.self)
            == "grant_type=authorization_code&code=a%2Bb%26c%3Dd%2Fe%25f%20g&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback")
    }

    @Test("Preserves field order and leaves unreserved characters alone")
    func orderAndUnreserved() {
        let body = FormEncoder.encode([(name: "z", value: "A-z_0.9~"), (name: "a", value: "")])
        #expect(String(decoding: body, as: UTF8.self) == "z=A-z_0.9~&a=")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test 2>&1 | tail -20`
Expected: compile errors — `OpenAIOAuthEndpoints`, `FormEncoder` not found.

- [ ] **Step 3: Create `OpenAIOAuthModels.swift`**

```swift
import Foundation

/// OpenAI's OAuth endpoints and client parameters for the Codex/ChatGPT browser login,
/// confirmed live against the real servers in the design spike (spec §2). Unlike Anthropic's
/// flow, the redirect URI is pinned: port 1455 and path `/auth/callback` were the only
/// combination the authorize endpoint accepted; an ephemeral port or `/callback` produced an
/// error page before login.
enum OpenAIOAuthEndpoints {
    static let authorize = "https://auth.openai.com/oauth/authorize"
    static let token = "https://auth.openai.com/oauth/token"
    static let tokenURL = URL(string: token)!
    static let usage = "https://chatgpt.com/backend-api/wham/usage"
    static let usageURL = URL(string: usage)!
    /// Codex CLI's public client. The app authenticates as that client — the same posture it
    /// takes with Anthropic's Claude Code client (spec §11 RISK-1).
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let scope = "openid profile email offline_access"
    static let callbackPort: UInt16 = 1455
    static let callbackPath = "/auth/callback"
    static let redirectURI = "http://localhost:1455/auth/callback"
    /// Sent verbatim as the spike did; whether the server accepts other values is untested.
    static let originator = "codex_cli_rs"
}

/// Why `ProviderAdapter.beginLogin` could not start a login at all — before any browser
/// opened. Distinct from `OAuthLoginError`, which classifies the code exchange.
enum OAuthLoginStartError: Error, Equatable {
    /// The pinned loopback port is held by another process — most likely Codex CLI mid-login.
    case portBusy
}

/// `application/x-www-form-urlencoded` body builder for OpenAI's token endpoint.
/// `URLComponents` leaves `+` unencoded in query values, and a form decoder reads `+` as a
/// space; this encodes every byte outside RFC 3986's unreserved set (`A–Z a–z 0–9 - . _ ~`).
enum FormEncoder {
    private static let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    static func encode(_ fields: [(name: String, value: String)]) -> Data {
        let body = fields.map { "\(percentEncode($0.name))=\(percentEncode($0.value))" }
            .joined(separator: "&")
        return Data(body.utf8)
    }

    private static func percentEncode(_ s: String) -> String {
        // `addingPercentEncoding` returns nil only for input it cannot represent; every
        // `String` this app builds is valid Unicode, so the fallback is never taken.
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}
```

- [ ] **Step 4: Make `PendingLogin.authorizeURL` provider-aware**

Replace the `extension PendingLogin` in `OAuthLoginModels.swift`:

```swift
extension PendingLogin {
    /// Builds the authorize URL for this login attempt. `loginHintEmail` should be
    /// supplied only when re-authing a known Anthropic account, to preselect it; OpenAI
    /// logins ignore it (untested against that server, and it would put an email in the URL).
    ///
    /// Never log or print the returned URL: it carries `login_hint` (a real email
    /// address) and the PKCE code challenge.
    func authorizeURL(loginHintEmail: String?) -> URL {
        switch provider {
        case .anthropic: return anthropicAuthorizeURL(loginHintEmail: loginHintEmail)
        case .openai: return openAIAuthorizeURL()
        }
    }

    private func anthropicAuthorizeURL(loginHintEmail: String?) -> URL {
        var items = [
            // Included because our Phase-0 spike sent it in the request that returned
            // HTTP 200; we did not test the flow without it, so it stays. Not observed in
            // Claude Code's own binary.
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: OAuthEndpoints.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: OAuthEndpoints.scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state),
        ]
        if let loginHintEmail {
            items.append(URLQueryItem(name: "login_hint", value: loginHintEmail))
        }
        return Self.url(base: OAuthEndpoints.authorize, items: items)
    }

    /// The exact parameter set the design spike sent and the server accepted (spec §2 O2c).
    private func openAIAuthorizeURL() -> URL {
        Self.url(base: OpenAIOAuthEndpoints.authorize, items: [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: OpenAIOAuthEndpoints.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: OpenAIOAuthEndpoints.scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: OpenAIOAuthEndpoints.originator),
        ])
    }

    /// `URLQueryItem`/`URLComponents.queryItems` leaves characters that are legal in a
    /// query component (like `:`, `/`, and `+`) un-escaped. The server form-decodes `+` as a
    /// space, so a plus-addressed email in `login_hint` would arrive corrupted. Encode every
    /// value to unreserved characters only, matching the fully percent-encoded form our
    /// spike proved the Anthropic server accepts.
    private static func url(base: String, items: [URLQueryItem]) -> URL {
        var comps = URLComponents(string: base)!
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        comps.percentEncodedQueryItems = items.map {
            URLQueryItem(name: $0.name, value: $0.value?.addingPercentEncoding(withAllowedCharacters: unreserved))
        }
        return comps.url!
    }
}
```

- [ ] **Step 5: Run the suite**

Run: `make test 2>&1 | tail -20`
Expected: PASS, including the existing `OAuthAuthorizeURLTests` (Anthropic output byte-identical).

- [ ] **Step 6: Commit**

```bash
git add ClaudeUsageBar/Services/OpenAIOAuthModels.swift ClaudeUsageBar/Services/OAuthLoginModels.swift ClaudeUsageBarTests/OpenAIAuthorizeURLTests.swift ClaudeUsageBarTests/FormEncoderTests.swift
git -c commit.gpgsign=false commit -m "feat: OpenAI OAuth endpoints, provider-aware authorize URL, strict form encoder

Claude-Session: https://claude.ai/code/session_01U5QvupoEwjPZpqRNXFajaz"
```

---

### Task 4: OpenAI usage decode → `UsageResponse` + identity, and the usage service

Spec §5.3, §5.6 (identity, usage), spike O1.

**Files:**
- Create: `ClaudeUsageBar/Services/OpenAIUsageService.swift`
- Modify: `ClaudeUsageBar/Services/ProfileService.swift` (`AccountIdentity` — no change needed; confirm it has `uuid`, `email`, `displayName`)
- Test: `ClaudeUsageBarTests/OpenAIUsageDecodeTests.swift` (new)

**Interfaces:**
- Produces:
  ```swift
  struct OpenAIUsageResponse: Decodable { let accountID: String; let email: String?; let rateLimit: RateLimit?
      struct Window: Decodable { let usedPercent: Double; let resetAt: Double? }
      struct RateLimit: Decodable { let primaryWindow: Window?; let secondaryWindow: Window? } }
  enum OpenAIUsage {
      static func decode(_ data: Data) throws -> OpenAIUsageResponse          // DecodingError on bad JSON
      static func usageResponse(from: OpenAIUsageResponse) throws -> UsageResponse   // throws UsageAPIError.decodingFailed when primary_window is missing
      static func identity(from: OpenAIUsageResponse) -> AccountIdentity
  }
  enum OpenAIUsageService {
      static func fetch(token: String) async throws -> UsageResponse       // UsageAPIError taxonomy
      static func fetchIdentity(token: String) async throws -> AccountIdentity
  }
  ```

- [ ] **Step 1: Write the failing tests**

`ClaudeUsageBarTests/OpenAIUsageDecodeTests.swift`:

```swift
import Testing
import Foundation

@Suite("OpenAI usage decode")
struct OpenAIUsageDecodeTests {
    /// Trimmed from the design spike's live response (spec §2 O1).
    private let fixture = #"""
    {"user_id":"user-x","account_id":"0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d","email":"sam@example.com","plan_type":"team",
     "rate_limit":{"allowed":true,"limit_reached":false,
       "primary_window":{"used_percent":52,"limit_window_seconds":18000,"reset_after_seconds":15891,"reset_at":1788845315},
       "secondary_window":{"used_percent":52.6,"limit_window_seconds":604800,"reset_after_seconds":499180,"reset_at":1789328604}},
     "model_usage":{"gpt-6-astra":{"available":true}},"credits":{"has_credits":false},"rate_limit_reset_credits":{"available_count":2}}
    """#

    @Test("Maps primary → five_hour and secondary → seven_day with epoch resets as ISO-8601")
    func mapsWindows() throws {
        let decoded = try OpenAIUsage.decode(Data(fixture.utf8))
        let response = try OpenAIUsage.usageResponse(from: decoded)
        #expect(response.fiveHour.utilization == 52)
        #expect(response.sevenDay.utilization == 52.6)
        #expect(response.limits == nil)
        // The synthesized ISO strings must round-trip through UsageSnapshot's parser to the
        // exact epoch instants.
        let snapshot = UsageSnapshot(from: response)
        #expect(snapshot.fiveHourPercent == 52)
        #expect(snapshot.sevenDayPercent == 53)
        #expect(snapshot.fiveHourResetsAt == Date(timeIntervalSince1970: 1_788_845_315))
        #expect(snapshot.sevenDayResetsAt == Date(timeIntervalSince1970: 1_789_328_604))
        #expect(snapshot.modelLimits == nil)
    }

    @Test("Identity comes from account_id and email; displayName is nil")
    func identity() throws {
        let identity = OpenAIUsage.identity(from: try OpenAIUsage.decode(Data(fixture.utf8)))
        #expect(identity == AccountIdentity(uuid: "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d", email: "sam@example.com", displayName: nil))
    }

    @Test("A missing secondary window becomes 0% with no reset; a missing primary window is a decode failure")
    func missingWindows() throws {
        let noSecondary = #"{"account_id":"a","rate_limit":{"primary_window":{"used_percent":10,"reset_at":1788845315},"secondary_window":null}}"#
        let response = try OpenAIUsage.usageResponse(from: try OpenAIUsage.decode(Data(noSecondary.utf8)))
        #expect(response.sevenDay.utilization == 0)
        #expect(UsageSnapshot(from: response).sevenDayResetsAt == nil)

        let noPrimary = #"{"account_id":"a","rate_limit":{"secondary_window":{"used_percent":10,"reset_at":1}}}"#
        #expect(throws: UsageAPIError.self) {
            try OpenAIUsage.usageResponse(from: try OpenAIUsage.decode(Data(noPrimary.utf8)))
        }
    }

    @Test("A non-JSON body (challenge page) is a decoding error, not a crash")
    func nonJSON() {
        #expect(throws: DecodingError.self) {
            try OpenAIUsage.decode(Data("<html>Just a moment...</html>".utf8))
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test 2>&1 | tail -20`
Expected: compile errors — `OpenAIUsage` not found.

- [ ] **Step 3: Create `OpenAIUsageService.swift`**

```swift
import Foundation

/// The subset of `GET https://chatgpt.com/backend-api/wham/usage` the app consumes
/// (spec §2 O1). Everything else in the payload — credits, model availability, plan — is
/// ignored.
struct OpenAIUsageResponse: Decodable {
    struct Window: Decodable {
        let usedPercent: Double
        /// Unix epoch seconds.
        let resetAt: Double?
        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
        }
    }
    struct RateLimit: Decodable {
        let primaryWindow: Window?
        let secondaryWindow: Window?
        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }
    let accountID: String
    let email: String?
    let rateLimit: RateLimit?
    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case email
        case rateLimit = "rate_limit"
    }
}

/// Pure decode + mapping for the OpenAI usage endpoint, kept apart from the networking so
/// it is unit-testable against the spike fixture.
enum OpenAIUsage {
    static func decode(_ data: Data) throws -> OpenAIUsageResponse {
        try JSONDecoder().decode(OpenAIUsageResponse.self, from: data)
    }

    /// Synthesizes the Anthropic-shaped `UsageResponse` the runtime already consumes:
    /// primary window → `five_hour`, secondary → `seven_day`. Formatting the epoch as an
    /// ISO-8601 string that `UsageSnapshot` immediately re-parses is deliberate — three
    /// lines here versus changing the fetch seam and every test that stubs it. Primary is
    /// required; a missing secondary window (not observed live; defensive) reads as 0% with
    /// no reset. The window lengths are not checked: primary is assumed to be the 5-hour
    /// window and secondary the 7-day one, as the spike observed.
    static func usageResponse(from response: OpenAIUsageResponse) throws -> UsageResponse {
        guard let primary = response.rateLimit?.primaryWindow else {
            throw UsageAPIError.decodingFailed(MissingWindow())
        }
        let secondary = response.rateLimit?.secondaryWindow
        return UsageResponse(
            fiveHour: UsagePeriod(utilization: primary.usedPercent, resetsAt: iso8601(primary.resetAt)),
            sevenDay: UsagePeriod(utilization: secondary?.usedPercent ?? 0, resetsAt: iso8601(secondary?.resetAt)),
            limits: nil)
    }

    static func identity(from response: OpenAIUsageResponse) -> AccountIdentity {
        AccountIdentity(uuid: response.accountID, email: response.email, displayName: nil)
    }

    private struct MissingWindow: Error {}

    /// `""` for a missing epoch: `UsageSnapshot`'s parser turns it into a nil reset date.
    private static func iso8601(_ epoch: Double?) -> String {
        guard let epoch else { return "" }
        return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: epoch))
    }
}

/// Networking for the OpenAI usage endpoint. One GET serves both usage and identity
/// (spec §5.6): the payload carries the account id and email alongside the windows.
/// Mirrors `UsageAPIService`'s request shape and reuses `UsageAPIError`.
enum OpenAIUsageService {
    static func fetch(token: String) async throws -> UsageResponse {
        let data = try await fetchRaw(token: token)
        do {
            return try OpenAIUsage.usageResponse(from: try OpenAIUsage.decode(data))
        } catch let error as UsageAPIError {
            throw error
        } catch {
            throw UsageAPIError.decodingFailed(error)
        }
    }

    static func fetchIdentity(token: String) async throws -> AccountIdentity {
        let data = try await fetchRaw(token: token)
        do {
            return OpenAIUsage.identity(from: try OpenAIUsage.decode(data))
        } catch {
            throw UsageAPIError.decodingFailed(error)
        }
    }

    private static func fetchRaw(token: String) async throws -> Data {
        var request = URLRequest(url: OpenAIOAuthEndpoints.usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "user-agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UsageAPIError.requestFailed(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw UsageAPIError.requestFailed(URLError(.badServerResponse))
        }
        guard (200...299).contains(http.statusCode) else {
            throw UsageAPIError.invalidResponse(http.statusCode)
        }
        return data
    }
}
```

- [ ] **Step 4: Run the suite**

Run: `make test 2>&1 | tail -20`
Expected: PASS. If `snapshot.sevenDayPercent == 53` fails as 52, `UsageSnapshot` rounds `.rounded()` — 52.6 rounds to 53; check the fixture, not the code.

- [ ] **Step 5: Commit**

```bash
git add ClaudeUsageBar/Services/OpenAIUsageService.swift ClaudeUsageBarTests/OpenAIUsageDecodeTests.swift
git -c commit.gpgsign=false commit -m "feat: OpenAI usage endpoint decode, mapped onto UsageResponse; identity from the same call

Claude-Session: https://claude.ai/code/session_01U5QvupoEwjPZpqRNXFajaz"
```

---

### Task 5: OpenAI code exchange and token refresh

Spec §5.6 (exchange, refresh), SEC-2, SEC-8, spike O2b/O2d.

**Files:**
- Create: `ClaudeUsageBar/Services/OpenAILoginService.swift`
- Test: `ClaudeUsageBarTests/OpenAIOAuthExchangeDecodeTests.swift` (new)

**Interfaces:**
- Produces:
  ```swift
  enum OpenAIOAuthExchange {
      static func exchangeBody(code: String, pending: PendingLogin) -> Data
      static func refreshBody(refreshToken: String) -> Data
      /// 2xx → decode; 400/401/403 → OAuthLoginError.exchangeRejected; else .transient; undecodable 2xx → .malformedResponse
      static func credentials(fromStatus: Int, body: Data, now: Date = Date()) throws -> CachedCredentials
      /// non-2xx → KeychainServiceError.refreshFailed(status:body:); undecodable 2xx → refreshFailed(status:, body:"undecodable")
      static func refreshCredentials(fromStatus: Int, body: Data, fallbackRefreshToken: String, now: Date = Date()) throws -> CachedCredentials
  }
  struct OpenAILoginService {
      func exchange(code: String, pending: PendingLogin) async throws -> CachedCredentials
      static func performOAuthRefresh(refreshToken: String) async throws -> CachedCredentials
  }
  ```
- Consumes: `FormEncoder`, `OpenAIOAuthEndpoints` (Task 3); `CachedCredentials.provider` (Task 1); `KeychainServiceError.refreshFailed`, `OAuthLoginError`, `OAuthRefreshOutcome.classify` (existing).

- [ ] **Step 1: Write the failing tests**

`ClaudeUsageBarTests/OpenAIOAuthExchangeDecodeTests.swift`:

```swift
import Testing
import Foundation

@Suite("OpenAI OAuth exchange + refresh decode")
struct OpenAIOAuthExchangeDecodeTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let grant = #"{"access_token":"at.jwt","refresh_token":"rt-1","id_token":"id.jwt","expires_in":864000,"earliest_refresh_at":1,"scope":"openid profile email offline_access","token_type":"Bearer","oai_is":"x"}"#

    private func pending() -> PendingLogin {
        PendingLogin(accountID: nil, mode: .loopback(port: 1455),
                     pkce: OAuthPKCE(verifier: "ver+ifier", challenge: "c", state: "st"),
                     redirectURI: OpenAIOAuthEndpoints.redirectURI,
                     startedAt: now, provider: .openai)
    }

    @Test("Exchange body is form-encoded with exactly the five fields the spike sent — no state")
    func exchangeBody() {
        let body = String(decoding: OpenAIOAuthExchange.exchangeBody(code: "co de", pending: pending()), as: UTF8.self)
        #expect(body == "grant_type=authorization_code&client_id=app_EMoamEEZ73f0CkXaXp7hrann&code=co%20de&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&code_verifier=ver%2Bifier")
    }

    @Test("Refresh body carries grant_type, client_id, refresh_token")
    func refreshBody() {
        let body = String(decoding: OpenAIOAuthExchange.refreshBody(refreshToken: "r/t"), as: UTF8.self)
        #expect(body == "grant_type=refresh_token&client_id=app_EMoamEEZ73f0CkXaXp7hrann&refresh_token=r%2Ft")
    }

    @Test("A 200 grant decodes: 10-day access expiry, no refresh-token expiry, tagged openai, id_token dropped")
    func decodes200() throws {
        let creds = try OpenAIOAuthExchange.credentials(fromStatus: 200, body: Data(grant.utf8), now: now)
        #expect(creds.accessToken == "at.jwt")
        #expect(creds.refreshToken == "rt-1")
        #expect(abs(creds.expiresAt!.timeIntervalSince(now) - 864_000) < 1)
        #expect(creds.refreshTokenExpiresAt == nil)
        #expect(creds.provider == .openai)
    }

    @Test("Exchange status classification matches the Anthropic path")
    func exchangeClassification() {
        #expect(throws: OAuthLoginError.exchangeRejected) {
            try OpenAIOAuthExchange.credentials(fromStatus: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8))
        }
        #expect(throws: OAuthLoginError.exchangeRejected) {
            try OpenAIOAuthExchange.credentials(fromStatus: 403, body: Data("{}".utf8))
        }
        #expect(throws: OAuthLoginError.transient) {
            try OpenAIOAuthExchange.credentials(fromStatus: 503, body: Data("{}".utf8))
        }
        #expect(throws: OAuthLoginError.malformedResponse) {
            try OpenAIOAuthExchange.credentials(fromStatus: 200, body: Data("<html>challenge</html>".utf8))
        }
    }

    @Test("Refresh keeps the old refresh token when the response omits one, and stays tagged openai")
    func refreshFallback() throws {
        let body = #"{"access_token":"at2","expires_in":864000}"#
        let creds = try OpenAIOAuthExchange.refreshCredentials(fromStatus: 200, body: Data(body.utf8), fallbackRefreshToken: "rt-old", now: now)
        #expect(creds.refreshToken == "rt-old")
        #expect(creds.provider == .openai)
    }

    @Test("A rejected refresh throws the error type the circuit breaker counts; 5xx and undecodable 2xx do not")
    func refreshErrorsClassify() {
        func outcome(_ status: Int, _ body: String) -> OAuthRefreshOutcome? {
            do {
                _ = try OpenAIOAuthExchange.refreshCredentials(fromStatus: status, body: Data(body.utf8), fallbackRefreshToken: "r")
                return nil
            } catch {
                return OAuthRefreshOutcome.classify(error)
            }
        }
        #expect(outcome(401, "{}") == .rejected)
        #expect(outcome(400, #"{"error":"invalid_grant"}"#) == .rejected)
        #expect(outcome(503, "{}") == .transient)
        #expect(outcome(429, "{}") == .transient)
        #expect(outcome(200, "<html>Just a moment</html>") == .transient)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test 2>&1 | tail -20`
Expected: compile errors — `OpenAIOAuthExchange` not found.

- [ ] **Step 3: Create `OpenAILoginService.swift`**

```swift
import Foundation

/// Pure body composition and response decoding for OpenAI's token endpoint, kept apart
/// from the networking so every branch is unit-testable. Two decoders, because the two
/// call sites need different error types: the exchange path speaks `OAuthLoginError`
/// (what `AccountsViewModel.finishLogin` classifies), the refresh path speaks
/// `KeychainServiceError.refreshFailed` (the only error `OAuthRefreshOutcome.classify`
/// counts toward the circuit breaker — anything else classifies as transient and the
/// breaker would never trip on a dead refresh token).
enum OpenAIOAuthExchange {
    private struct Grant: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int?
    }

    static func exchangeBody(code: String, pending: PendingLogin) -> Data {
        FormEncoder.encode([
            (name: "grant_type", value: "authorization_code"),
            (name: "client_id", value: OpenAIOAuthEndpoints.clientID),
            (name: "code", value: code),
            (name: "redirect_uri", value: pending.redirectURI),
            (name: "code_verifier", value: pending.pkce.verifier),
        ])
    }

    static func refreshBody(refreshToken: String) -> Data {
        FormEncoder.encode([
            (name: "grant_type", value: "refresh_token"),
            (name: "client_id", value: OpenAIOAuthEndpoints.clientID),
            (name: "refresh_token", value: refreshToken),
        ])
    }

    /// Exchange-path classification, mirroring `OAuthExchange.credentials`: 2xx decodes,
    /// 400/401/403 is a dead code, everything else fails open to transient.
    static func credentials(fromStatus status: Int, body: Data, now: Date = Date()) throws -> CachedCredentials {
        switch status {
        case 200...299:
            guard let grant = try? JSONDecoder().decode(Grant.self, from: body) else {
                throw OAuthLoginError.malformedResponse
            }
            return credentials(from: grant, fallbackRefreshToken: nil, now: now)
        case 400, 401, 403:
            throw OAuthLoginError.exchangeRejected
        default:
            throw OAuthLoginError.transient
        }
    }

    /// Refresh-path classification. A non-2xx is `refreshFailed(status:)` so
    /// `OAuthRefreshOutcome.classify` sees the status; an undecodable 2xx (a challenge
    /// page, say) is reported with its real status, which classifies as transient — a
    /// CDN interstitial must not count as a token rejection.
    static func refreshCredentials(
        fromStatus status: Int, body: Data, fallbackRefreshToken: String, now: Date = Date()
    ) throws -> CachedCredentials {
        guard (200...299).contains(status) else {
            throw KeychainServiceError.refreshFailed(status: status, body: String(decoding: body.prefix(512), as: UTF8.self))
        }
        guard let grant = try? JSONDecoder().decode(Grant.self, from: body) else {
            throw KeychainServiceError.refreshFailed(status: status, body: "undecodable")
        }
        return credentials(from: grant, fallbackRefreshToken: fallbackRefreshToken, now: now)
    }

    /// `id_token` is deliberately not read: it carries the account email and name, which the
    /// usage endpoint supplies anyway, and nothing here should persist it.
    private static func credentials(from grant: Grant, fallbackRefreshToken: String?, now: Date) -> CachedCredentials {
        CachedCredentials(
            accessToken: grant.access_token,
            refreshToken: grant.refresh_token ?? fallbackRefreshToken,
            expiresAt: grant.expires_in.map { now.addingTimeInterval(TimeInterval($0)) },
            refreshTokenExpiresAt: nil,
            provider: .openai)
    }
}

/// Networking for OpenAI's token endpoint: form-encoded bodies, `User-Agent` on every
/// request (as on every other call this app makes), and the same transport-error policy as
/// `OAuthLoginService.exchange` — a transport failure says nothing about the code, so it is
/// transient, except cancellation, which is rethrown as is.
struct OpenAILoginService {
    func exchange(code: String, pending: PendingLogin) async throws -> CachedCredentials {
        let request = Self.tokenRequest(body: OpenAIOAuthExchange.exchangeBody(code: code, pending: pending), timeout: 15)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            if Task.isCancelled { throw error }
            throw OAuthLoginError.transient
        }
        guard let http = response as? HTTPURLResponse else { throw OAuthLoginError.transient }
        return try OpenAIOAuthExchange.credentials(fromStatus: http.statusCode, body: data)
    }

    /// The bare refresh-token exchange, without persisting — the account's runtime owns
    /// persistence, exactly as with `KeychainService.performOAuthRefresh`.
    static func performOAuthRefresh(refreshToken: String) async throws -> CachedCredentials {
        let request = tokenRequest(body: OpenAIOAuthExchange.refreshBody(refreshToken: refreshToken), timeout: 10)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return try OpenAIOAuthExchange.refreshCredentials(fromStatus: status, body: data, fallbackRefreshToken: refreshToken)
    }

    private static func tokenRequest(body: Data, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: OpenAIOAuthEndpoints.tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "user-agent")
        request.httpBody = body
        return request
    }
}
```

- [ ] **Step 4: Run the suite**

Run: `make test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ClaudeUsageBar/Services/OpenAILoginService.swift ClaudeUsageBarTests/OpenAIOAuthExchangeDecodeTests.swift
git -c commit.gpgsign=false commit -m "feat: OpenAI code exchange and refresh with form bodies; refresh errors feed the circuit breaker

Claude-Session: https://claude.ai/code/session_01U5QvupoEwjPZpqRNXFajaz"
```

---

### Task 6: Loopback server — configurable callback path, fixed-port reuse

Spec §5.5 (three touch points), SEC-1, audit B2.

**Files:**
- Modify: `ClaudeUsageBar/Services/LoopbackServer.swift` (`LoopbackServer.init` line 53; `LoopbackEngine` init/`start` lines 162–215; `handleRequest` line 377; `LoopbackRequest` lines 470–500)
- Test: `ClaudeUsageBarTests/LoopbackServerTests.swift` (add three tests; reuse its `get(port:path:)` helper and `PortHog`)

**Interfaces:**
- Produces: `LoopbackServer.init(gracePeriod: TimeInterval = 600, requestedPort: UInt16 = 0, callbackPath: String = "/callback")`.
- Behavior: with `requestedPort != 0`, the listener sets `allowLocalEndpointReuse = true`; a port in TIME_WAIT from a previous served login rebinds immediately; a port held by a live POSIX listener still fails with `StartError.bindFailed`.

- [ ] **Step 1: Write the failing tests**

Add to `LoopbackServerTests` (inside the suite):

```swift
    @Test("A custom callback path is honored and the default path is rejected under it")
    func customCallbackPath() async throws {
        let server = LoopbackServer(callbackPath: "/auth/callback")
        let port = try await server.start()
        async let captured = server.waitForCallback(expectedState: "st8", timeout: 5)
        #expect(try await get(port: port, path: "/callback?code=x&state=st8").status == 404)
        #expect(try await get(port: port, path: "/auth/callback?code=good&state=st8").status == 200)
        #expect(await captured == "good")
        await server.stop()
    }

    @Test("A fixed port rebinds immediately after serving a callback (no TIME_WAIT lockout)")
    func fixedPortRebindsAfterServing() async throws {
        // Pick a free port the OS hands out, release it, then treat it as "fixed".
        let probe = LoopbackServer()
        let port = try await probe.start()
        await probe.stop()

        let first = LoopbackServer(gracePeriod: 0, requestedPort: port)
        #expect(try await first.start() == port)
        async let captured = first.waitForCallback(expectedState: "st8", timeout: 5)
        #expect(try await get(port: port, path: "/callback?code=c&state=st8").status == 200)
        #expect(await captured == "c")
        await first.stop()

        // Without endpoint reuse this bind fails with EADDRINUSE for ~30 s after the served
        // connection closed. The user-visible symptom was "Port 1455 is in use" on Try again.
        let second = LoopbackServer(gracePeriod: 0, requestedPort: port)
        #expect(try await second.start() == port)
        await second.stop()
    }

    @Test("A fixed port held by a live listener still fails to bind, with reuse on")
    func fixedPortConflictStillDetected() async throws {
        // `PortHog()` binds and listens on an OS-assigned port with a plain POSIX socket
        // (no SO_REUSEPORT) — the same shape as Codex CLI's own listener. Same setup as the
        // existing `bindFailure` test; the difference is the fixed-port reuse flag under test.
        let hog = try PortHog()
        defer { hog.close() }
        let server = LoopbackServer(gracePeriod: 0, requestedPort: hog.port)
        await #expect(throws: LoopbackServer.StartError.self) {
            _ = try await server.start()
        }
        await server.stop()
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -project ClaudeUsageBar.xcodeproj -scheme ClaudeUsageBar -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO -only-testing:ClaudeUsageBarTests/LoopbackServerTests 2>&1 | tail -30`
Expected: `customCallbackPath` fails to compile (no `callbackPath:`); after adding the parameter alone, `fixedPortRebindsAfterServing` fails on the second `start()` with `bindFailed`.

- [ ] **Step 3: Thread `callbackPath` through**

`LoopbackServer`:

```swift
    private let callbackPath: String

    /// - Parameters:
    ///   - gracePeriod: how long the "login expired" page keeps being served after a
    ///     timeout, so a late browser redirect lands on a page instead of
    ///     connection-refused. The listener shuts itself down when it elapses. `0` stops
    ///     at once — used on the fixed OpenAI port, which another process may need.
    ///   - requestedPort: a fixed port instead of an OS-assigned one. OpenAI's redirect URI
    ///     is pinned to 1455; Anthropic logins keep the default `0` (ephemeral).
    ///   - callbackPath: the path the redirect must hit (`/callback` for Anthropic,
    ///     `/auth/callback` for OpenAI). Anything else is answered 404.
    init(gracePeriod: TimeInterval = 600, requestedPort: UInt16 = 0, callbackPath: String = "/callback") {
        self.gracePeriod = gracePeriod
        self.requestedPort = requestedPort
        self.callbackPath = callbackPath
        self.engine = LoopbackEngine(callbackPath: callbackPath)
    }
```

`LoopbackEngine`: add `private let callbackPath: String` and `init(callbackPath: String) { self.callbackPath = callbackPath }`; in `handleRequest` build `LoopbackRequest(head: head, callbackPath: callbackPath)`.

`LoopbackRequest`: `init(head: Data, callbackPath: String)` stores `let callbackPath: String` and `isCallbackGET` becomes `isGET && path == callbackPath`. Update the doc comments that say `/callback` to say "the configured callback path". Fix the compile error in any existing test that constructs `LoopbackRequest` directly (it is `private`, so there should be none).

- [ ] **Step 4: Enable endpoint reuse for fixed ports only**

In `LoopbackEngine.start`, replace the two lines and their comment:

```swift
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
        // Ephemeral ports: reuse stays off, so a taken port fails with EADDRINUSE rather
        // than binding alongside. Fixed ports: reuse is on, because after this listener
        // serves and closes one connection the port sits in TIME_WAIT and a plain rebind
        // was measured to fail for ~31 s — every "Try again" inside that window would have
        // reported the port busy. A port held by a live listener still fails to bind with
        // reuse on (covered by `fixedPortConflictStillDetected`).
        parameters.allowLocalEndpointReuse = requestedPort != 0
```

- [ ] **Step 5: Run the loopback suite, then the full suite**

Run: the `-only-testing:ClaudeUsageBarTests/LoopbackServerTests` command, then `make test 2>&1 | tail -20`.
Expected: PASS. **If `fixedPortRebindsAfterServing` still fails with reuse on, or `fixedPortConflictStillDetected` starts passing the bind:** stop, do not work around it, and report BLOCKED with the exact failure — the spec's assumption about `NWListener`'s reuse flag would be wrong and the lead decides the fallback.

- [ ] **Step 6: Commit**

```bash
git add ClaudeUsageBar/Services/LoopbackServer.swift ClaudeUsageBarTests/LoopbackServerTests.swift
git -c commit.gpgsign=false commit -m "feat: loopback server takes a callback path; fixed ports rebind immediately after serving

Claude-Session: https://claude.ai/code/session_01U5QvupoEwjPZpqRNXFajaz"
```

---

### Task 7: OpenAI browser login end-to-end — begin, port-busy, timeout without paste, add-flow provider memory, affordances

Spec §5.5 (bind failure), §5.6 (begin, timeout), §5.7 (add-flow provider memory), §7.4, §7.5, SEC-1, audit B1/M2/M9/S11.

**Files:**
- Modify: `ClaudeUsageBar/Services/OpenAILoginService.swift` (add `begin`)
- Modify: `ClaudeUsageBar/Services/ProviderAdapter.swift` (add `OpenAIProvider.adapter`)
- Modify: `ClaudeUsageBar/ViewModels/AccountsViewModel.swift` (`Dependencies.live`; `addLoginProvider`; `beginAddAccountLogin(provider:)`; `loginProvider(for:)`; `runLogin` catch + timeout branch; `switchToPaste`; `supportsPaste(for:)`)
- Modify: `ClaudeUsageBar/Logic/LoginAffordance.swift` (`actions(supportsPaste:)`)
- Modify: `ClaudeUsageBar/Views/LoginPill.swift` (line ~40 `buttonRow(affordance.actions…)`; `help(for:)` line 215)
- Test: `ClaudeUsageBarTests/AccountsViewModelOpenAILoginTests.swift` (new), `ClaudeUsageBarTests/LoginAffordanceTests.swift` (add one test)

**Interfaces:**
- Produces: `OpenAILoginService.begin(accountID: UUID?, now: @Sendable () -> Date = Date.init, makeServer: @Sendable () -> LoopbackServer = …) async throws -> StartedLogin` — throws `OAuthLoginStartError.portBusy` on bind failure.
- Produces: `enum OpenAIProvider { static var adapter: ProviderAdapter }` (`supportsPaste: false`).
- Produces on the view model: `@Published private(set) var addLoginProvider: Provider = .anthropic`; `func beginAddAccountLogin(provider: Provider) async`; `func supportsPaste(for accountID: UUID?) -> Bool`; `loginProvider(for: nil)` now returns `addLoginProvider`.
- Produces: `LoginAffordance.actions(supportsPaste: Bool) -> [LoginAction]`; the existing `actions` property stays and equals `actions(supportsPaste: true)`.
- Consumes: `LoopbackServer(gracePeriod:requestedPort:callbackPath:)` (Task 6); `OpenAIOAuthEndpoints`, `OAuthLoginStartError` (Task 3); `OpenAIUsageService` (Task 4); `OpenAILoginService.exchange`/`performOAuthRefresh` (Task 5).

- [ ] **Step 1: Write the failing coordinator tests**

`ClaudeUsageBarTests/AccountsViewModelOpenAILoginTests.swift` — a self-contained script double, modeled on the browser-login suite's `Script`, but with two adapters:

```swift
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

    private func usageResponse() -> UsageResponse {
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

    @Test("The add-flow affordance hides the paste action for OpenAI and keeps it for Claude")
    func pasteAffordanceByProvider() async {
        let script = Script()
        let vm = makeVM(script)
        #expect(vm.supportsPaste(for: nil) == true)
        await vm.beginAddAccountLogin(provider: .openai)
        #expect(vm.supportsPaste(for: nil) == false)
    }
}
```

Add to `LoginAffordanceTests`:

```swift
    @Test("actions(supportsPaste: false) drops the paste action while waiting for the browser; the property is the supportsPaste: true form")
    func pasteGating() {
        #expect(LoginAffordance.waitingForBrowser.actions(supportsPaste: false) == [.cancel, .copyLink])
        #expect(LoginAffordance.waitingForBrowser.actions(supportsPaste: true) == [.cancel, .copyLink, .usePasteCode])
        #expect(LoginAffordance.waitingForBrowser.actions == LoginAffordance.waitingForBrowser.actions(supportsPaste: true))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test 2>&1 | tail -20`
Expected: compile errors — `beginAddAccountLogin`, `supportsPaste(for:)`, `actions(supportsPaste:)` missing.

- [ ] **Step 3: `OpenAILoginService.begin` and the live OpenAI adapter**

Append to `OpenAILoginService.swift`:

```swift
extension OpenAILoginService {
    /// Starts an OpenAI browser login. Loopback only: the redirect URI is pinned to
    /// `http://localhost:1455/auth/callback` (spec §2 O2a), so there is no port to choose and
    /// no paste fallback. A bind failure is `OAuthLoginStartError.portBusy` — most likely
    /// Codex CLI mid-login. `gracePeriod: 0` because the port is shared: after a timeout the
    /// listener releases it at once instead of serving an "expired" page for ten minutes.
    ///
    /// The wait is enqueued as a `Task` before returning, for the same reason
    /// `OAuthLoginService.begin` does it: the listener must be armed before the browser can
    /// deliver its redirect. The caller opens `authorizeURL` and awaits `callback`; a
    /// delivered code stops the listener, and every other outcome relies on the caller's
    /// `server.stop()`.
    func begin(
        accountID: UUID?,
        now: @Sendable () -> Date = Date.init,
        makeServer: @Sendable () -> LoopbackServer = {
            LoopbackServer(gracePeriod: 0,
                           requestedPort: OpenAIOAuthEndpoints.callbackPort,
                           callbackPath: OpenAIOAuthEndpoints.callbackPath)
        }
    ) async throws -> StartedLogin {
        let pkce = OAuthPKCE.generate()
        let server = makeServer()
        do {
            _ = try await server.start()
        } catch LoopbackServer.StartError.bindFailed {
            throw OAuthLoginStartError.portBusy
        }
        let pending = PendingLogin(
            accountID: accountID, mode: .loopback(port: OpenAIOAuthEndpoints.callbackPort), pkce: pkce,
            redirectURI: OpenAIOAuthEndpoints.redirectURI, startedAt: now(), provider: .openai)
        let expectedState = pkce.state
        let callback = Task<String?, Never> {
            let code = await server.waitForCallback(expectedState: expectedState, timeout: OAuthLoginService.loopbackTimeout)
            if code != nil { await server.stop() }
            return code
        }
        return (pending, pending.authorizeURL(loginHintEmail: nil), server, callback)
    }
}
```

Append to `ProviderAdapter.swift`:

```swift
/// The live OpenAI adapter. `supportsPaste` is false: the pinned redirect leaves no
/// paste-mode fallback (spec §5.6).
enum OpenAIProvider {
    static var adapter: ProviderAdapter {
        ProviderAdapter(
            provider: .openai,
            supportsPaste: false,
            beginLogin: { accountID, _, _ in
                try await OpenAILoginService().begin(accountID: accountID)
            },
            exchange: { code, pending in
                try await OpenAILoginService().exchange(code: code, pending: pending)
            },
            fetchIdentity: { token in try await OpenAIUsageService.fetchIdentity(token: token) },
            fetchUsage: { token in try await OpenAIUsageService.fetch(token: token) },
            refreshToken: { creds in
                guard let refreshToken = creds.refreshToken else {
                    throw KeychainServiceError.noRefreshToken
                }
                return try await OpenAILoginService.performOAuthRefresh(refreshToken: refreshToken)
            })
    }
}
```

In `AccountsViewModel.Dependencies.live`, replace `openai: .unavailable(.openai)` (and its comment) with `openai: OpenAIProvider.adapter`.

- [ ] **Step 4: Coordinator — add-flow provider memory, port-busy message, timeout without paste, paste gating**

In `AccountsViewModel`, next to `addLoginState`:

```swift
    /// The provider the add-account flow most recently chose. Every recovery control
    /// ("Try again") calls `beginLogin(nil)` with no provider, so without this a failed
    /// OpenAI add-account login would retry as a Claude one. Set by
    /// `beginAddAccountLogin(provider:)` and by the Codex import; never reset.
    @Published private(set) var addLoginProvider: Provider = .anthropic

    /// Starts an add-account login for `provider` — the menu's two "Add" items.
    func beginAddAccountLogin(provider: Provider) async {
        addLoginProvider = provider
        await beginLogin(nil)
    }

    /// Whether the flow's provider can finish a login by paste. Drives which controls
    /// `LoginPill` offers.
    func supportsPaste(for accountID: UUID?) -> Bool {
        deps.adapters.adapter(for: loginProvider(for: accountID)).supportsPaste
    }
```

Change `loginProvider(for:)`'s fallback from `.anthropic` to `addLoginProvider`:

```swift
    func loginProvider(for accountID: UUID?) -> Provider {
        guard let accountID, let account = accounts.first(where: { $0.id == accountID }) else {
            return addLoginProvider
        }
        return account.provider
    }
```

In `runLogin`, capture the adapter once at the top — `let adapter = deps.adapters.adapter(for: loginProvider(for: accountID))` — and use `adapter.beginLogin(...)`. Replace the catch's message line:

```swift
                let message: String
                switch error {
                case OAuthLoginStartError.portBusy:
                    message = "Port 1455 is in use — is Codex signing in? Try again."
                default:
                    message = "Couldn't start the login — try again."
                }
                setLoginState(.failed(message), for: accountID)
                notifyLoginProblem(accountID: accountID, message: message)
```

Replace the timeout branch (`guard let code else { … }`) body with:

```swift
        guard let code else {
            // The wait timed out. `waitForCallback` bounds how long a callback may be
            // *accepted*, not the total call duration, so a code accepted at the boundary
            // still arrives non-nil above and is handled as the success it is; only nil gets
            // here, and the fixed redirect URI means the retry has to be a brand-new login.
            guard adapter.supportsPaste else {
                // No paste mode to fall back to (OpenAI): the login is over. `endLogin` posts
                // the "didn't finish" notification for a `.failed` state.
                await endLogin(.failed("The login timed out — try again."), for: accountID)
                return
            }
            await endLogin(.idle, for: accountID)
            // At most one restart: paste mode has no listener, so it cannot time out in turn.
            // Guarding on the flag rather than on `begin` returning no callback keeps that
            // true even if the seam ever hands a forced-paste login a listener anyway. The
            // pending-login checks are re-run because `endLogin` above suspends, and a login
            // started in that window has already claimed the one pending slot — restarting on
            // top of it would strand its listener.
            if !forcePaste, pendingLogin == nil, !isStartingLogin {
                await runLogin(accountID, forcePaste: true)
                // Only once that restart is actually parked awaiting a paste: a restart that
                // failed to start has reported its own failure, and telling the user to paste
                // a code into a login that isn't running would send them nowhere.
                if pendingLogin != nil { notifyPasteFallback(accountID: accountID) }
            }
            return
        }
```

`switchToPaste()` gains a provider guard as its first line after the existing guard:

```swift
        guard supportsPaste(for: pending.accountID) else { return }
```

`completeAddAccount` must stamp the new account with the login's provider, or the happy-path test's `account.provider == .openai` fails. Change its signature to `completeAddAccount(_ grant: CachedCredentials, identity: AccountIdentity, provider: Provider)`, pass `pending.provider` from `verifyAndStore`, and construct the account as:

```swift
        let account = Account(label: label, accountUUID: identity.uuid, email: identity.email, provider: provider)
```

(The per-provider dedupe filter on the `accounts.first(where:)` lookup above it lands in the next task.)

- [ ] **Step 5: `LoginAffordance.actions(supportsPaste:)` and `LoginPill`**

In `LoginAffordance`, rename the computed property's body into a method and keep the property:

```swift
    /// The controls this state offers, in display order. `supportsPaste` is false for a
    /// provider whose login cannot finish by paste (OpenAI), which drops "Use a code
    /// instead" while the browser is open.
    func actions(supportsPaste: Bool) -> [LoginAction] {
        switch self {
        case .none:
            return []
        case .start:
            return [.logIn]
        case .waitingForBrowser:
            return supportsPaste ? [.cancel, .copyLink, .usePasteCode] : [.cancel, .copyLink]
        case .awaitingPaste:
            return [.submitPaste, .cancel, .copyLink]
        case .identityFailed:
            return [.retryIdentity, .cancel]
        case .failed:
            return [.tryAgain, .dismiss]
        case .notice:
            return [.dismiss]
        }
    }

    /// `actions(supportsPaste: true)` — the Anthropic set, which every existing caller and
    /// test expects.
    var actions: [LoginAction] { actions(supportsPaste: true) }
```

Move the existing per-case comments into the method. In `LoginPill.body`, replace `buttonRow(affordance.actions.filter { $0 != .submitPaste })` with `buttonRow(affordance.actions(supportsPaste: viewModel.supportsPaste(for: accountID)).filter { $0 != .submitPaste })`. In `help(for:)`:

```swift
        case .logIn, .tryAgain:
            switch viewModel.loginProvider(for: accountID) {
            case .anthropic: return "Opens claude.ai in your browser to sign in"
            case .openai: return "Opens auth.openai.com in your browser to sign in"
            }
```

- [ ] **Step 6: Run the suite**

Run: `make test 2>&1 | tail -30`
Expected: PASS — the 5 new coordinator tests, the affordance test, and every existing login test (the Anthropic timeout-restart tests still see the restart because their adapter has `supportsPaste: true`).

- [ ] **Step 7: Commit**

```bash
git add ClaudeUsageBar/Services/OpenAILoginService.swift ClaudeUsageBar/Services/ProviderAdapter.swift ClaudeUsageBar/ViewModels/AccountsViewModel.swift ClaudeUsageBar/Logic/LoginAffordance.swift ClaudeUsageBar/Views/LoginPill.swift ClaudeUsageBarTests/AccountsViewModelOpenAILoginTests.swift ClaudeUsageBarTests/LoginAffordanceTests.swift
git -c commit.gpgsign=false commit -m "feat: OpenAI browser login on the pinned port — port-busy error, no paste restart, add-flow provider memory

Claude-Session: https://claude.ai/code/session_01U5QvupoEwjPZpqRNXFajaz"
```

---

### Task 8: Dedupe and the identity guard are per-provider

Spec §5.7, audit S4/S5.

**Files:**
- Modify: `ClaudeUsageBar/Logic/AccountIdentityResolver.swift` (`backfill` gains `provider:`)
- Modify: `ClaudeUsageBar/ViewModels/AccountsViewModel.swift` (`backfillIdentity`, `completeReAuth`, `completeAddAccount`)
- Test: `ClaudeUsageBarTests/AccountIdentityResolverTests.swift` (add one test), `ClaudeUsageBarTests/AccountsViewModelOpenAILoginTests.swift` (add two tests)

**Interfaces:**
- Produces: `AccountIdentityResolver.backfill(_ accounts: [Account], id: UUID, provider: Provider, uuid: String, email: String?) -> Result` — a duplicate is another account with the **same provider** and the same `accountUUID`.

- [ ] **Step 1: Write the failing tests**

Add to `AccountIdentityResolverTests`:

```swift
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
```

Add to `AccountsViewModelOpenAILoginTests`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test 2>&1 | tail -20`
Expected: the resolver test fails to compile (no `provider:` label); `crossProviderIsNotADuplicate` fails with `accounts.count == 1` and a `.notice`.

- [ ] **Step 3: Make the resolver and the coordinator provider-aware**

`AccountIdentityResolver.backfill`:

```swift
    static func backfill(_ accounts: [Account], id: UUID, provider: Provider, uuid: String, email: String?) -> Result {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else {
            return Result(accounts: accounts, duplicateOfLabel: nil)
        }
        // A different account of the same provider already carrying this identity is a
        // duplicate. Identities are only comparable within a provider: an Anthropic account
        // UUID and a ChatGPT account id live in different namespaces.
        let duplicate = accounts.first { $0.id != id && $0.provider == provider && $0.accountUUID == uuid }
        var updated = accounts
        updated[index].accountUUID = uuid
        if let email { updated[index].email = email }
        return Result(accounts: updated, duplicateOfLabel: duplicate?.label)
    }
```

Update the two existing resolver call sites to pass `provider: account.provider`. In `AccountsViewModel`:
- `backfillIdentity`: `AccountIdentityResolver.backfill(accounts, id: id, provider: account.provider, uuid: identity.uuid, email: identity.email)`.
- `completeReAuth`: the resolver call passes `provider: account.provider`; the duplicate lookup becomes `accounts.first(where: { $0.id != accountID && $0.provider == account.provider && $0.accountUUID == identity.uuid })`.
- `completeAddAccount`: the dedupe lookup becomes `accounts.first(where: { $0.provider == provider && $0.accountUUID == identity.uuid })`.

Fix the existing `AccountIdentityResolverTests` call sites to add `provider: .anthropic`.

- [ ] **Step 4: Run the suite**

Run: `make test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ClaudeUsageBar/Logic/AccountIdentityResolver.swift ClaudeUsageBar/ViewModels/AccountsViewModel.swift ClaudeUsageBarTests/AccountIdentityResolverTests.swift ClaudeUsageBarTests/AccountsViewModelOpenAILoginTests.swift
git -c commit.gpgsign=false commit -m "feat: account dedupe and the re-auth identity guard compare (provider, account id)

Claude-Session: https://claude.ai/code/session_01U5QvupoEwjPZpqRNXFajaz"
```

---

### Task 9: Import from Codex CLI

Spec §6, SEC-3, SEC-5, audit B3.

**Files:**
- Create: `ClaudeUsageBar/Services/CodexAuthFile.swift`
- Modify: `ClaudeUsageBar/ViewModels/AccountsViewModel.swift` (`Dependencies` + `.live`; `LoginState.importing`; `codexImport`; `refreshCodexImportProbe()`; `importFromCodex()`; `verifyAndStore` message; `currentLoginState`/`dismissLoginMessage` switches)
- Modify: `ClaudeUsageBar/Logic/LoginAffordance.swift` (`case importing`)
- Modify: `ClaudeUsageBar/Views/LoginPill.swift` (`statusLine`, `tint`)
- Test: `ClaudeUsageBarTests/CodexAuthFileTests.swift` (new), `ClaudeUsageBarTests/AccountsViewModelOpenAILoginTests.swift` (add four tests), `ClaudeUsageBarTests/AccountsViewModelLoginTests.swift` (the two `makeDeps` gain two fields)

**Interfaces:**
- Produces:
  ```swift
  enum CodexAuthFile {
      enum Probe: Equatable { case available, notFound, unusable(reason: String) }
      enum ReadError: Error, Equatable { case notFound, unusable(reason: String) }
      static let maxBytes = 1 << 20
      static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
      static func probe(at url: URL = defaultURL()) -> Probe
      static func read(at url: URL = defaultURL()) throws -> CachedCredentials   // ReadError
  }
  ```
- Produces on `Dependencies`: `var probeCodexAuthFile: @Sendable () -> CodexAuthFile.Probe`, `var readCodexAuthFile: @Sendable () throws -> CachedCredentials`.
- Produces on the view model: `@Published private(set) var codexImport: CodexAuthFile.Probe = .notFound`; `func refreshCodexImportProbe()`; `func importFromCodex() async`; `LoginState.importing`; `LoginAffordance.importing` with `actions == [.cancel]`.

- [ ] **Step 1: Write the failing file tests**

`ClaudeUsageBarTests/CodexAuthFileTests.swift`:

```swift
import Testing
import Foundation

@Suite("CodexAuthFile")
struct CodexAuthFileTests {
    private func tempFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-auth-\(UUID().uuidString).json")
        try Data(contents.utf8).write(to: url)
        return url
    }

    private let chatgpt = #"{"auth_mode":"chatgpt","OPENAI_API_KEY":null,"tokens":{"id_token":"i.d.t","access_token":"acc.ess","refresh_token":"ref","account_id":"55f9"},"last_refresh":"2026-09-03T15:24:30Z"}"#

    @Test("A ChatGPT-mode file is available and reads as OpenAI credentials with no expiry")
    func chatGPTMode() throws {
        let url = try tempFile(chatgpt)
        #expect(CodexAuthFile.probe(at: url) == .available)
        let creds = try CodexAuthFile.read(at: url)
        #expect(creds == CachedCredentials(accessToken: "acc.ess", refreshToken: "ref", expiresAt: nil, refreshTokenExpiresAt: nil, provider: .openai))
    }

    @Test("API-key mode, missing tokens, malformed JSON, and oversized files are unusable with a reason")
    func unusable() throws {
        let apiKey = try tempFile(#"{"auth_mode":"apikey","OPENAI_API_KEY":"sk-x","tokens":null}"#)
        #expect(CodexAuthFile.probe(at: apiKey) == .unusable(reason: "Codex is signed in with an API key, not a ChatGPT account."))

        let noRefresh = try tempFile(#"{"auth_mode":"chatgpt","tokens":{"access_token":"a"}}"#)
        #expect(CodexAuthFile.probe(at: noRefresh) == .unusable(reason: "Codex's login file has no refresh token."))

        let garbage = try tempFile("not json")
        #expect(CodexAuthFile.probe(at: garbage) == .unusable(reason: "Codex's login file couldn't be read."))

        let huge = try tempFile(String(repeating: " ", count: CodexAuthFile.maxBytes + 1))
        #expect(CodexAuthFile.probe(at: huge) == .unusable(reason: "Codex's login file couldn't be read."))
        #expect(throws: CodexAuthFile.ReadError.self) { try CodexAuthFile.read(at: huge) }
    }

    @Test("A missing file is notFound")
    func missing() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        #expect(CodexAuthFile.probe(at: url) == .notFound)
        #expect(throws: CodexAuthFile.ReadError.notFound) { try CodexAuthFile.read(at: url) }
    }

    @Test("CODEX_HOME overrides the default location; otherwise ~/.codex/auth.json")
    func location() {
        #expect(CodexAuthFile.defaultURL(environment: ["CODEX_HOME": "/tmp/cx"]).path == "/tmp/cx/auth.json")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(CodexAuthFile.defaultURL(environment: [:]).path == "\(home)/.codex/auth.json")
    }
}
```

- [ ] **Step 2: Write the failing coordinator tests**

Add to `AccountsViewModelOpenAILoginTests` — first extend `Script` with `var codexProbe: CodexAuthFile.Probe = .available` and `var codexRead: Result<CachedCredentials, Error> = .success(CachedCredentials(accessToken: "codex-access", refreshToken: "codex-refresh", expiresAt: nil, provider: .openai))`, and add to `makeDeps` the two new fields `probeCodexAuthFile: { script.codexProbe }, readCodexAuthFile: { try script.codexRead.get() }`. Then:

```swift
    @Test("Import from Codex: no browser, identity via the OpenAI adapter, account stored as openai")
    func importHappyPath() async throws {
        let script = Script()
        let store = InMemoryAccountCredentialStore()
        let vm = makeVM(script, store: store)

        await vm.importFromCodex()

        #expect(script.openedCount == 0)
        #expect(script.openAIBeginCalls == 0)
        #expect(vm.accounts.count == 1)
        let account = try #require(vm.accounts.first)
        #expect(account.provider == .openai)
        #expect(try store.loadAll()[account.id]?.accessToken == "codex-access")
        #expect(vm.pendingLogin == nil)
        #expect(vm.addLoginState == .idle)
        #expect(vm.addLoginProvider == .openai)
    }

    @Test("Import is refused while a login is pending, and leaves that login untouched")
    func importRefusedWhilePending() async {
        let script = Script()
        // Park a re-auth login in `identityFailed`: a transport failure on the identity step
        // keeps the grant in memory and the pending slot held, exactly the state a concurrent
        // import must not disturb.
        let account = Account(label: "Codex", accountUUID: "cg-1", provider: .openai)
        let vm = makeVM(script, accounts: [account])
        script.openAIIdentity = .failure(UsageAPIError.requestFailed(URLError(.notConnectedToInternet)))
        await vm.beginLogin(account.id)
        #expect(vm.canRetryIdentity(for: account.id))
        let pendingBefore = vm.pendingLogin

        await vm.importFromCodex()

        #expect(vm.addLoginState == .failed("Finish the login in progress first."))
        #expect(vm.pendingLogin == pendingBefore)
        #expect(vm.canRetryIdentity(for: account.id))
    }

    @Test("An expired Codex token fails identity with the expired message and keeps Retry")
    func importExpiredToken() async {
        let script = Script()
        script.openAIIdentity = .failure(UsageAPIError.invalidResponse(401))
        let vm = makeVM(script)

        await vm.importFromCodex()

        #expect(vm.addLoginState == .failed("Codex's login has expired — sign in with the browser instead."))
        #expect(vm.canRetryIdentity(for: nil))
        #expect(vm.loginAffordance(for: nil) == .identityFailed(message: "Codex's login has expired — sign in with the browser instead."))

        script.openAIIdentity = .success(AccountIdentity(uuid: "cg-1", email: "sam@example.com", displayName: nil))
        await vm.retryIdentity()
        #expect(vm.accounts.count == 1)
        #expect(vm.addLoginState == .idle)
    }

    @Test("Importing an OpenAI account that is already tracked refreshes it")
    func importDedupes() async throws {
        let script = Script()
        let existing = Account(label: "Codex", accountUUID: "cg-1", provider: .openai)
        let store = InMemoryAccountCredentialStore([existing.id: CachedCredentials(accessToken: "old", refreshToken: "r", expiresAt: nil, provider: .openai)])
        let vm = makeVM(script, accounts: [existing], store: store)

        await vm.importFromCodex()

        #expect(vm.accounts.count == 1)
        #expect(try store.loadAll()[existing.id]?.accessToken == "codex-access")
        #expect(vm.addLoginState == .notice("“Codex” is already tracked — its login was refreshed."))
    }
```

In `AccountsViewModelLoginTests.swift`, both `makeDeps` gain `probeCodexAuthFile: { .notFound }, readCodexAuthFile: { throw CodexAuthFile.ReadError.notFound }`.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `make test 2>&1 | tail -20`
Expected: compile errors — `CodexAuthFile`, `importFromCodex`, the two `Dependencies` fields.

- [ ] **Step 4: Create `CodexAuthFile.swift`**

```swift
import Foundation

/// Read-only access to Codex CLI's login file, for the one-time "Import from Codex CLI"
/// path (spec §6). The file is never written, moved, or deleted here. Only a ChatGPT-mode
/// login with both tokens is importable; the access token's expiry is left unknown (no JWT
/// parsing — identity and validity are established by the usage endpoint afterwards).
enum CodexAuthFile {
    enum Probe: Equatable {
        case available
        case notFound
        case unusable(reason: String)
    }

    enum ReadError: Error, Equatable {
        case notFound
        case unusable(reason: String)
    }

    /// Anything larger is not a login file. Read before decoding, so a huge file is
    /// rejected without being parsed.
    static let maxBytes = 1 << 20

    private struct File: Decodable {
        struct Tokens: Decodable {
            let access_token: String?
            let refresh_token: String?
        }
        let auth_mode: String?
        let tokens: Tokens?
    }

    /// `$CODEX_HOME/auth.json`, or `~/.codex/auth.json`.
    static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let home = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        return home.appendingPathComponent("auth.json")
    }

    static func probe(at url: URL = defaultURL()) -> Probe {
        do {
            _ = try read(at: url)
            return .available
        } catch ReadError.notFound {
            return .notFound
        } catch ReadError.unusable(let reason) {
            return .unusable(reason: reason)
        } catch {
            return .unusable(reason: unreadable)
        }
    }

    static func read(at url: URL = defaultURL()) throws -> CachedCredentials {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ReadError.notFound }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
              size <= maxBytes,
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            throw ReadError.unusable(reason: unreadable)
        }
        guard file.auth_mode == "chatgpt" else {
            throw ReadError.unusable(reason: "Codex is signed in with an API key, not a ChatGPT account.")
        }
        guard let access = file.tokens?.access_token, !access.isEmpty else {
            throw ReadError.unusable(reason: "Codex's login file has no access token.")
        }
        guard let refresh = file.tokens?.refresh_token, !refresh.isEmpty else {
            throw ReadError.unusable(reason: "Codex's login file has no refresh token.")
        }
        return CachedCredentials(accessToken: access, refreshToken: refresh, expiresAt: nil,
                                 refreshTokenExpiresAt: nil, provider: .openai)
    }

    private static let unreadable = "Codex's login file couldn't be read."
}
```

- [ ] **Step 5: Coordinator — the import is a real pending login**

`Dependencies` gains (with `.live` wiring `CodexAuthFile.probe()` / `try CodexAuthFile.read()`):

```swift
        /// Checks whether Codex CLI's login file is importable. A test double must not
        /// touch the filesystem.
        var probeCodexAuthFile: @Sendable () -> CodexAuthFile.Probe
        /// Reads Codex CLI's login file into credentials. A test double must not touch the
        /// filesystem.
        var readCodexAuthFile: @Sendable () throws -> CachedCredentials
```

`LoginState` gains `case importing` (place it after `awaitingPaste`). Update every exhaustive switch on `LoginState` in the view model (`dismissLoginMessage`: `.importing` joins the `return` group) and `LoginAffordance.resolve` (`case .importing: return .importing`).

Add to the view model:

```swift
    /// Whether Codex CLI's login file is importable right now. Refreshed when the popover
    /// appears, not on a timer.
    @Published private(set) var codexImport: CodexAuthFile.Probe = .notFound

    func refreshCodexImportProbe() {
        codexImport = deps.probeCodexAuthFile()
    }

    /// Imports Codex CLI's login as a new OpenAI account. This is a login without a browser:
    /// it claims the one pending-login slot like any other, so it is refused while a login is
    /// running and cannot end a concurrent login's state, and it runs the same identity →
    /// dedupe → store tail as a browser login, so `retryIdentity()` works if the identity
    /// check fails.
    func importFromCodex() async {
        guard pendingLogin == nil, !isStartingLogin else {
            setLoginState(.failed(Self.busyMessage), for: nil)
            return
        }
        addLoginProvider = .openai
        let grant: CachedCredentials
        do {
            grant = try deps.readCodexAuthFile()
        } catch {
            let message = "Couldn't read Codex's login file — sign in with the browser instead."
            setLoginState(.failed(message), for: nil)
            notifyLoginProblem(accountID: nil, message: message)
            return
        }
        loginEpoch += 1
        let pending = PendingLogin(
            accountID: nil, mode: .imported, pkce: OAuthPKCE.generate(), redirectURI: "",
            startedAt: deps.now(), provider: .openai)
        pendingLogin = pending
        pendingAuthorizeURL = nil
        unverifiedGrant = grant
        setLoginState(.importing, for: nil)
        await verifyAndStore(grant, pending: pending)
    }
```

In `verifyAndStore`'s catch, replace the fixed message with:

```swift
            let message: String
            if pending.mode == .imported, case .invalidResponse(let status)? = error as? UsageAPIError,
               (401...403).contains(status) {
                message = "Codex's login has expired — sign in with the browser instead."
            } else {
                message = "Logged in, but couldn't verify the account — Retry."
            }
```

`LoginAffordance`: add `case importing` ("The credentials came from Codex CLI's file and the identity check is running.") with `message: nil` and `actions(supportsPaste:) == [.cancel]`. `LoginPill.statusLine`: `case .importing: line("Checking Codex's login…", icon: "arrow.down.circle", tint: .blue)`; `tint(for:)`: `.importing` → `.blue`.

- [ ] **Step 6: Run the suite**

Run: `make test 2>&1 | tail -30`
Expected: PASS. If `importRefusedWhilePending` cannot park the re-auth in `identityFailed`, check that the Script's `openAIIdentity` failure is a `UsageAPIError.requestFailed` (not cancellation) — that is what keeps the grant in memory.

- [ ] **Step 7: Commit**

```bash
git add ClaudeUsageBar/Services/CodexAuthFile.swift ClaudeUsageBar/ViewModels/AccountsViewModel.swift ClaudeUsageBar/Logic/LoginAffordance.swift ClaudeUsageBar/Views/LoginPill.swift ClaudeUsageBarTests/CodexAuthFileTests.swift ClaudeUsageBarTests/AccountsViewModelOpenAILoginTests.swift ClaudeUsageBarTests/AccountsViewModelLoginTests.swift
git -c commit.gpgsign=false commit -m "feat: import Codex CLI's login as an OpenAI account through the same pending-login gate

Claude-Session: https://claude.ai/code/session_01U5QvupoEwjPZpqRNXFajaz"
```

---

### Task 10: Menu bar — provider shapes when providers are mixed

Spec §4.3, §7.1, audit M5/S9.

**Files:**
- Modify: `ClaudeUsageBar/Logic/MultiAccountMenuBar.swift` (add `providerShapes(for:)`)
- Create: `ClaudeUsageBar/Views/ProviderShape.swift`
- Modify: `ClaudeUsageBar/Views/MenuBarImage.swift` (`multiAccount` lines 41–123; `twoStat` lines 125–212)
- Test: `ClaudeUsageBarTests/ProviderShapeTests.swift` (new)

**Interfaces:**
- Produces: `MultiAccountMenuBar.providerShapes(for providers: [Provider]) -> Bool` — true iff more than one distinct provider.
- Produces: `enum ProviderShape { case dot, star, hexagon; static func mark(for provider: Provider, mixed: Bool) -> ProviderShape; func path(in rect: NSRect) -> NSBezierPath }`.
- `MenuBarImage.multiAccount(accounts:snapshots:mode:)` and `twoStat(accounts:snapshots:now:)` signatures are unchanged; they compute the rule from `accounts` themselves.

- [ ] **Step 1: Write the failing tests**

`ClaudeUsageBarTests/ProviderShapeTests.swift`:

```swift
import Testing
import AppKit

@Suite("Provider shapes")
struct ProviderShapeTests {
    @Test("Shapes appear only when tracked accounts span both providers")
    func rule() {
        #expect(MultiAccountMenuBar.providerShapes(for: [.anthropic, .anthropic]) == false)
        #expect(MultiAccountMenuBar.providerShapes(for: [.openai]) == false)
        #expect(MultiAccountMenuBar.providerShapes(for: []) == false)
        #expect(MultiAccountMenuBar.providerShapes(for: [.anthropic, .openai]) == true)
    }

    @Test("Single-provider installs draw the dot; mixed installs draw star / hexagon by provider")
    func markSelection() {
        #expect(ProviderShape.mark(for: .anthropic, mixed: false) == .dot)
        #expect(ProviderShape.mark(for: .openai, mixed: false) == .dot)
        #expect(ProviderShape.mark(for: .anthropic, mixed: true) == .star)
        #expect(ProviderShape.mark(for: .openai, mixed: true) == .hexagon)
    }

    @Test("Every shape's path stays inside its rect and is non-empty")
    func pathsFitTheirRect() {
        let rect = NSRect(x: 10, y: 4, width: 7, height: 7)
        for shape in [ProviderShape.dot, .star, .hexagon] {
            let path = shape.path(in: rect)
            #expect(!path.isEmpty)
            #expect(rect.insetBy(dx: -0.01, dy: -0.01).contains(path.bounds), "\(shape)")
        }
    }

    @Test("A mixed-provider bar image is wider than a single-provider one with the same accounts (the glyph is drawn) in both compact and Bars modes")
    func mixedBarDrawsGlyph() {
        let a = Account(label: "P", provider: .anthropic)
        let b = Account(label: "W", provider: .anthropic)
        let c = Account(label: "C", provider: .openai)
        let snap = UsageSnapshot(fiveHourPercent: 40, sevenDayPercent: 60, fiveHourResetsAt: nil, sevenDayResetsAt: nil, fetchedAt: Date())
        let single = MenuBarImage.twoStat(accounts: [a, b], snapshots: [a.id: snap, b.id: snap])
        let mixed = MenuBarImage.twoStat(accounts: [a, c], snapshots: [a.id: snap, c.id: snap])
        #expect(mixed.size.width > single.size.width)

        let singleCompact = MenuBarImage.multiAccount(accounts: [a, b], snapshots: [a.id: snap, b.id: snap], mode: .fiveHour)
        let mixedCompact = MenuBarImage.multiAccount(accounts: [a, c], snapshots: [a.id: snap, c.id: snap], mode: .fiveHour)
        // Compact mode replaces the dot with a same-size glyph, so the width is unchanged;
        // the rule is what changes, and it is pinned by `rule()` above.
        #expect(mixedCompact.size.width == singleCompact.size.width)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test 2>&1 | tail -20`
Expected: compile errors — `providerShapes`, `ProviderShape` missing.

- [ ] **Step 3: The rule and the shapes**

Add to `MultiAccountMenuBar`:

```swift
    /// Whether the bar marks each account with its provider's shape instead of a dot: only
    /// when the tracked accounts span more than one provider. A single-provider install —
    /// all Claude, or all OpenAI — renders exactly as before.
    static func providerShapes(for providers: [Provider]) -> Bool {
        Set(providers).count > 1
    }
```

Create `ClaudeUsageBar/Views/ProviderShape.swift`:

```swift
import AppKit

/// The 7-pt mark drawn before each account's segment in the menu bar. A dot unless
/// providers are mixed; then a four-point star for Claude and a hexagon for OpenAI, filled
/// with the same severity color the dot uses.
enum ProviderShape: Equatable {
    case dot
    case star
    case hexagon

    static func mark(for provider: Provider, mixed: Bool) -> ProviderShape {
        guard mixed else { return .dot }
        switch provider {
        case .anthropic: return .star
        case .openai: return .hexagon
        }
    }

    func path(in rect: NSRect) -> NSBezierPath {
        switch self {
        case .dot:
            return NSBezierPath(ovalIn: rect)
        case .star:
            // Four points on the rect's edges, waist at 30% — reads as a sparkle at 7 pt.
            let c = NSPoint(x: rect.midX, y: rect.midY)
            let r = rect.width / 2, w = r * 0.3
            let path = NSBezierPath()
            path.move(to: NSPoint(x: c.x, y: c.y + r))
            path.line(to: NSPoint(x: c.x + w, y: c.y + w))
            path.line(to: NSPoint(x: c.x + r, y: c.y))
            path.line(to: NSPoint(x: c.x + w, y: c.y - w))
            path.line(to: NSPoint(x: c.x, y: c.y - r))
            path.line(to: NSPoint(x: c.x - w, y: c.y - w))
            path.line(to: NSPoint(x: c.x - r, y: c.y))
            path.line(to: NSPoint(x: c.x - w, y: c.y + w))
            path.close()
            return path
        case .hexagon:
            let c = NSPoint(x: rect.midX, y: rect.midY)
            let r = rect.width / 2
            let path = NSBezierPath()
            for i in 0..<6 {
                let angle = CGFloat(i) * .pi / 3 + .pi / 6   // flat top and bottom
                let p = NSPoint(x: c.x + r * cos(angle), y: c.y + r * sin(angle))
                if i == 0 { path.move(to: p) } else { path.line(to: p) }
            }
            path.close()
            return path
        }
    }
}
```

- [ ] **Step 4: Draw the shapes in both menu-bar images**

`MenuBarImage.multiAccount`: compute `let mixed = MultiAccountMenuBar.providerShapes(for: accounts.map(\.provider))`; extend `Segment` with `let shape: ProviderShape`, set `shape: ProviderShape.mark(for: account.provider, mixed: mixed)` in both branches; replace the dot drawing with:

```swift
                if let dot = segment.dotColor {
                    dot.setFill()
                    segment.shape.path(in: NSRect(x: x, y: (height - dotDiameter) / 2,
                                                  width: dotDiameter, height: dotDiameter)).fill()
                    x += dotDiameter + dotGap
                }
```

Update the function's doc comment: "a colored dot — or, when providers are mixed, the provider's shape — per account".

`MenuBarImage.twoStat`: compute `mixed` the same way; add `let glyph: CGFloat = 7, glyphGap: CGFloat = 3`; extend `Cluster` with `let shape: ProviderShape?` (`nil` when not mixed, else `ProviderShape.mark(for: account.provider, mixed: true)`) and `let level: Int?` (`p5.map { max($0, p7 ?? 0) }`, the cluster's worse window, for the glyph's color); `clusterW` adds `(c.shape == nil ? 0 : glyph + glyphGap)`; before drawing the prefix:

```swift
                if let shape = c.shape {
                    (c.level.map(levelColor) ?? NSColor.tertiaryLabelColor).setFill()
                    shape.path(in: NSRect(x: x, y: (height - glyph) / 2, width: glyph, height: glyph)).fill()
                    x += glyph + glyphGap
                }
```

- [ ] **Step 5: Run the suite**

Run: `make test 2>&1 | tail -20`
Expected: PASS, including `MenuBarPresentationTests` and `MultiAccountMenuBarTests` unchanged.

- [ ] **Step 6: Commit**

```bash
git add ClaudeUsageBar/Logic/MultiAccountMenuBar.swift ClaudeUsageBar/Views/ProviderShape.swift ClaudeUsageBar/Views/MenuBarImage.swift ClaudeUsageBarTests/ProviderShapeTests.swift
git -c commit.gpgsign=false commit -m "feat: menu bar draws provider shapes (star/hexagon) only when providers are mixed

Claude-Session: https://claude.ai/code/session_01U5QvupoEwjPZpqRNXFajaz"
```

---

### Task 11: Popover — add-account menu, provider chip, probe refresh, copy inventory

Spec §7.2, §7.3, §7.6, audit M6.

**Files:**
- Modify: `ClaudeUsageBar/Views/UsagePopoverView.swift` (`addAccountControls` lines 94–118; add `.onAppear`)
- Modify: `ClaudeUsageBar/Views/UsageMatrixView.swift` (`headerCell` lines 68–90; add `mixedProviders`)
- Modify: `ClaudeUsageBar/ViewModels/AccountsViewModel.swift` (`sendNotification` title line 826; `label(for:)` line 760)
- Test: `ClaudeUsageBarTests/AccountsViewModelLoginTests.swift` (add one notification-copy test), `ClaudeUsageBarTests/MenuBarPresentationTests.swift` (no change)

**Interfaces:**
- Consumes: `beginAddAccountLogin(provider:)`, `importFromCodex()`, `codexImport`, `refreshCodexImportProbe()`, `MultiAccountMenuBar.providerShapes(for:)`, `Provider.displayName`.

- [ ] **Step 1: Write the failing copy test**

Add to `AccountsViewModelLoginTests` (the first suite, which has `Calls.notifications`):

```swift
    @Test("Threshold notifications are titled without a vendor name; the add-flow fallback label is 'Add account'")
    func notificationCopyIsVendorNeutral() async {
        let calls = Calls()
        let sharedDefaults = ephemeralDefaults()
        let account = Account(label: "Codex", accountUUID: "cg-1", provider: .openai)
        let accountsStore = AccountsStore(defaults: sharedDefaults)
        accountsStore.save([account])
        let credentialStore = InMemoryAccountCredentialStore([
            account.id: CachedCredentials(accessToken: "t", refreshToken: "r", expiresAt: nil, provider: .openai)
        ])
        var deps = makeDeps(calls: calls, legacyCredentials: nil)
        deps.addNotification = { calls.notifications.append($0) }
        deps.adapters.openai = ProviderAdapter(
            provider: .openai, supportsPaste: false,
            beginLogin: { _, _, _ in throw OAuthLoginStartError.portBusy },
            exchange: { _, _ in throw OAuthLoginError.transient },
            fetchIdentity: { _ in AccountIdentity(uuid: "cg-1", email: nil, displayName: nil) },
            fetchUsage: { _ in
                UsageResponse(fiveHour: UsagePeriod(utilization: 95, resetsAt: "2026-09-09T00:00:00Z"),
                              sevenDay: UsagePeriod(utilization: 10, resetsAt: "2026-09-13T00:00:00Z"))
            },
            refreshToken: { _ in throw StubError() })
        let vm = AccountsViewModel(accountsStore: accountsStore, credentialStore: credentialStore,
                                   defaults: sharedDefaults, startTimer: false, deps: deps)

        await vm.refreshAll()
        let usage = calls.notifications.first { $0.identifier.hasPrefix("usage-") }
        #expect(usage?.content.title == "Codex: Usage Warning")

        await vm.beginAddAccountLogin(provider: .openai)
        let login = calls.notifications.first { $0.identifier == "login-outcome-add" }
        #expect(login?.content.title == "Add account: login didn't finish")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -project ClaudeUsageBar.xcodeproj -scheme ClaudeUsageBar -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO -only-testing:ClaudeUsageBarTests/AccountsViewModelLoginTests 2>&1 | tail -20`
Expected: FAIL — titles still read "Codex: Claude Usage Warning" and "Claude Usage: login didn't finish".

- [ ] **Step 3: Copy changes in the view model**

- `sendNotification`: `content.title = "\(account.label): Usage Warning"`.
- `label(for:)`: fallback `"Add account"` instead of `"Claude Usage"`.

- [ ] **Step 4: Add-account menu and probe refresh in `UsagePopoverView`**

Replace the `Button { … } label: { Label("Add account…", …) }` block inside `addAccountControls` with:

```swift
                Menu {
                    Button {
                        Task { await viewModel.beginAddAccountLogin(provider: .anthropic) }
                    } label: { Label("Claude", systemImage: "sparkle") }
                        .help("Opens claude.ai in your browser to sign in")
                    Button {
                        Task { await viewModel.beginAddAccountLogin(provider: .openai) }
                    } label: { Label("OpenAI / Codex", systemImage: "hexagon") }
                        .help("Opens auth.openai.com in your browser to sign in with your ChatGPT account")
                    Divider()
                    Button {
                        Task { await viewModel.importFromCodex() }
                    } label: { Label("Import from Codex CLI", systemImage: "arrow.down.circle") }
                        .disabled(viewModel.codexImport != .available)
                        .help(importHelp)
                } label: {
                    Label("Add account…", systemImage: "plus.circle")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
```

and add the helper plus the probe refresh:

```swift
    private var importHelp: String {
        switch viewModel.codexImport {
        case .available: return "Copies the login from ~/.codex/auth.json; Codex CLI keeps its own"
        case .notFound: return "No Codex CLI login found at ~/.codex/auth.json"
        case .unusable(let reason): return reason
        }
    }
```

On the popover's outermost container add `.onAppear { viewModel.refreshCodexImportProbe() }`. Remove the old `.help("Opens claude.ai in your browser to sign in")` from the footer button (it moved onto the Claude item).

- [ ] **Step 5: Provider chip in the matrix header**

In `UsageMatrixView`, add a stored property computed in `init` or as a computed var:

```swift
    /// Same rule as the menu bar: name the provider only when there is more than one.
    private var mixedProviders: Bool {
        MultiAccountMenuBar.providerShapes(for: columns.map(\.account.provider))
    }
```

In `headerCell`, directly after the `if let email … Text(email)` line:

```swift
            if mixedProviders {
                HStack(spacing: 3) {
                    Image(systemName: account.provider == .anthropic ? "sparkle" : "hexagon").font(.system(size: 7))
                    Text(account.provider.displayName.uppercased()).font(.system(size: 8, weight: .semibold)).tracking(0.4)
                }
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
            }
```

The model-row `—` cell and the expiry-pill help strings are unchanged: an OpenAI column has no model limits and no expiry warning, so those strings never render for it.

- [ ] **Step 6: Run the suite**

Run: `make test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add ClaudeUsageBar/Views/UsagePopoverView.swift ClaudeUsageBar/Views/UsageMatrixView.swift ClaudeUsageBar/ViewModels/AccountsViewModel.swift ClaudeUsageBarTests/AccountsViewModelLoginTests.swift
git -c commit.gpgsign=false commit -m "feat: Add-account menu (Claude / OpenAI / Import from Codex), provider chip when mixed, vendor-neutral notification copy

Claude-Session: https://claude.ai/code/session_01U5QvupoEwjPZpqRNXFajaz"
```

---

### Task 12: README, spec status, and the lead's live QA checklist

Spec §7.6 (README row), §9 (live), §12.

**Files:**
- Modify: `README.md` (lines 14, 20, 54–59, 89–113 diagram, 116, 124–125, 218)
- Modify: `docs/superpowers/specs/2026-09-07-openai-provider-design.md` (status line)

- [ ] **Step 1: README**

- Line 14: "straight to Anthropic" → "straight to Anthropic or OpenAI".
- Line 20 features: add "- Track OpenAI / Codex accounts alongside Claude accounts — sign in with your ChatGPT account, or import Codex CLI's login".
- After the "Multiple accounts" section, add:

```markdown
## OpenAI / Codex accounts

**Add account… → OpenAI / Codex** opens auth.openai.com in your browser; sign in with the ChatGPT account you use for Codex. OpenAI pins the login's callback to `http://localhost:1455/auth/callback`, so the app listens on port 1455 for the few seconds the login takes. If Codex CLI is signing in at the same moment you'll see "Port 1455 is in use" — just try again. There is no paste-code fallback for OpenAI logins.

**Add account… → Import from Codex CLI** copies the login from `~/.codex/auth.json` (or `$CODEX_HOME/auth.json`) into the app as a new account, with no browser round trip. Only a ChatGPT-mode Codex login can be imported (not an API key). The file is only ever read. From then on the app refreshes that login itself; Codex CLI keeps its own.

The browser's current ChatGPT session decides which account signs in. To add a **second** OpenAI account, use **Copy link** on the waiting pill and open it in a browser profile signed into that account.

OpenAI shows a 5-hour and a weekly window, which land on the same rows as Claude's. OpenAI does not report a login expiry, so OpenAI accounts show no "login expires in" countdown; a login that stops refreshing gets the same red **Log in again** pill.

When your accounts span both providers, the menu bar marks each one with its provider's shape (✦ Claude, ⬡ OpenAI) instead of a dot, and each column in the popover gets a provider chip. With one provider, nothing changes.
```

- Line 59: "identified by its Anthropic account ID (fetched from the OAuth profile endpoint)" → "identified by its provider account ID (Anthropic: the OAuth profile endpoint; OpenAI: the usage endpoint)".
- Diagram (lines 89–113): add a second leg under the Anthropic API block:

```
                                  │ OpenAI (ChatGPT plan)
                                  ├─ POST auth.openai.com/oauth/token         (exchange / refresh)
                                  └─ GET chatgpt.com/backend-api/wham/usage   ({primary, secondary} + identity)
```

- Features table (124–125): "straight to claude.ai" → "straight to claude.ai or auth.openai.com"; "deduped by Anthropic account ID" → "deduped by provider account ID".
- Troubleshooting (218): add a row: `| "Port 1455 is in use — is Codex signing in?" | OpenAI's login callback is pinned to port 1455 and something else holds it (usually Codex CLI mid-login). Finish that login, or try again in a moment. |`

- [ ] **Step 2: Spec status**

Change the spec's `**Status:**` line to `implemented on sam-pop/add-OpenAI; probe O3 result: <fill in after running spikes/openai_spike_o3.py>`.

- [ ] **Step 3: Full suite, then commit**

Run: `make test 2>&1 | tail -20`
Expected: PASS.

```bash
git add README.md docs/superpowers/specs/2026-09-07-openai-provider-design.md
git -c commit.gpgsign=false commit -m "docs: README covers OpenAI / Codex accounts, port 1455, import, and mixed-provider marks

Claude-Session: https://claude.ai/code/session_01U5QvupoEwjPZpqRNXFajaz"
```

- [ ] **Step 4: Live QA (lead only — never a subagent)**

Run `spikes/openai_spike_o3.py` first (after 2026-09-08 21:10) and record its result in the spec status. Then `make run` and walk spec §9's live list: add Codex via browser; import from Codex CLI; shapes on in compact and Bars modes; chips on; retry an OpenAI login immediately after a completed one (no port-busy); remove the OpenAI account → shapes/chips off; second OpenAI account via Copy link; threshold notification for the OpenAI account. Report each with what was seen.

---

## Self-review notes

- **Spec coverage:** §5.1/5.8 → T1; §5.2 → T2; §5.4 + SEC-2 → T3; §5.3 + identity → T4; §5.6 exchange/refresh + M1 → T5; §5.5 + B2 → T6; §5.5 bind failure, §5.6 begin/timeout, §5.7 add-flow memory, §7.4, §7.5, B1/M2/M9 → T7; §5.7 dedupe → T8; §6 + B3 → T9; §7.1 + M5 → T10; §7.2, §7.3, §7.6 → T11; README, §9 live, O3 → T12.
- **Deviations from the spec, deliberate:** `AccountView` gains no `provider` field (the embedded `account.provider` already serves the views). The expiry-pill help strings stay Anthropic-specific because an OpenAI column never renders them.
- **Type consistency checked:** `StartedLogin`, `ProviderAdapter` field names, `ProviderAdapters.adapter(for:)`, `OAuthLoginStartError.portBusy`, `OAuthLoginMode.imported`, `CodexAuthFile.Probe`, `LoginState.importing`, `LoginAffordance.importing`, `actions(supportsPaste:)`, `beginAddAccountLogin(provider:)`, `supportsPaste(for:)`, `loginProvider(for:)`, `addLoginProvider`, `codexImport`, `refreshCodexImportProbe()`, `importFromCodex()`, `MultiAccountMenuBar.providerShapes(for:)`, `ProviderShape.mark(for:mixed:)` are spelled identically in every task that uses them.
