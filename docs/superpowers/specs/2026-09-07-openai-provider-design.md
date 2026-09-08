# OpenAI / Codex Provider — Design (v2, post-audit)

**Date:** 2026-09-07 · **Status:** implemented on sam-pop/add-OpenAI (commits 744d394..31d819a); probe O3 pending — runs 2026-09-08 after 21:10 EDT, result recorded here by the lead
**Builds on:** `2026-08-21-browser-oauth-login-design.md` (the app owns its credentials; browser OAuth + PKCE per account). Its invariants — exactly one pending login, single-use pending login, zero I/O in view-model `init`, no `try?` on credential writes — all still hold here.
**Audit trail:** v1 hardened by one independent Opus audit (3 blockers, 9 majors, 11 minors, 12 traced scenarios) + the lead security pass. Every finding is folded in below; §13 lists them with their resolution.

## 1. Context and motivation

The app tracks Anthropic accounts' 5-hour and 7-day usage windows. Codex (OpenAI's coding agent) has the same two-window rate-limit model for ChatGPT-plan users, and the user runs both. Goal: track Codex/OpenAI accounts alongside Claude accounts in the same menu bar and popover, with the same "app owns its login" posture.

## 2. Phase-0 spike — RUN 2026-09-07, PASSED

Scripts: `spikes/openai_spike_o1.py`, `spikes/openai_spike_o2.py`, `spikes/openai_spike_o3.py` (pending). Ran live against the user's real Codex login. Findings that drive the design:

- **O1 usage endpoint.** `GET https://chatgpt.com/backend-api/wham/usage` with `Authorization: Bearer <access_token>` → 200. The `ChatGPT-Account-Id` header is optional (identical 200 without it). Response (fields we use):
  ```json
  { "account_id": "<uuid>", "email": "...", "plan_type": "team",
    "rate_limit": {
      "primary_window":   { "used_percent": 52, "limit_window_seconds": 18000,  "reset_after_seconds": 15891, "reset_at": 1788845315 },
      "secondary_window": { "used_percent": 52, "limit_window_seconds": 604800, "reset_after_seconds": 499180, "reset_at": 1789328604 } },
    "model_usage": { "gpt-6-astra": { "available": true } },
    "credits": { ... }, "rate_limit_reset_credits": { "available_count": 2 } }
  ```
  `reset_at` is a Unix epoch (seconds). Primary = 5h (18000 s), secondary = 7d (604800 s) — the same two windows the app already models.
- **O2a the whole redirect URI is pinned.** In a real browser (curl probes of the authorize URL are Cloudflare-challenged, 403), `https://auth.openai.com/oauth/authorize` with the Codex public client (`app_EMoamEEZ73f0CkXaXp7hrann`) shows an "Authentication Error" page before login for `http://localhost:<ephemeral>/auth/callback` **and** for `http://localhost:1455/callback`, and shows the login page for `http://localhost:1455/auth/callback`. Port and path are both fixed.
- **O2b exchange.** `POST https://auth.openai.com/oauth/token`, **form-encoded** `grant_type=authorization_code&client_id&code&redirect_uri&code_verifier` → 200. Keys: `access_token, refresh_token, id_token, expires_in (864000 = 10 days), earliest_refresh_at, scope, token_type, oai_is`. **No `refresh_token_expires_in`** — the refresh token's lifetime is not disclosed.
- **O2c authorize params.** Sent and accepted: `response_type=code, client_id, redirect_uri, scope=openid profile email offline_access, code_challenge (S256), code_challenge_method, state, id_token_add_organizations=true, codex_cli_simplified_flow=true, originator=codex_cli_rs`. The callback arrived with `code`, `state`, and one extra param `scope`. `User-Agent: ClaudeUsageBar/…` was sent on every HTTPS call and worked. The spike encoded the scope's spaces as `+`; the app's URL builder emits `%20` — both are valid query encodings, and live QA (§9) confirms the app's form.
- **O2d refresh.** Form-encoded `grant_type=refresh_token&client_id&refresh_token` → 200 with a **rotated** refresh token; the **old refresh token still worked** immediately afterward, and the chain continued from the new one. Codex CLI's own **access** token still worked on the usage endpoint afterwards (its refresh token was not exercised).
- **O2e access-token lifetime** is 10 days (`exp − iat = 864000`), vs ~8 h for Anthropic. Refresh pressure is low.
- **`~/.codex/auth.json` shape** (ChatGPT mode): `auth_mode: "chatgpt"`, `tokens.{id_token, access_token, refresh_token, account_id}`, `last_refresh`, `OPENAI_API_KEY: null`.

**Probe O3 (gate for §6 Import, not for the rest):** `spikes/openai_spike_o3.py`, runnable from 2026-09-08 21:10 local — re-uses the pre-rotation refresh token O2 saved (chmod-600, outside the repo) to see whether the post-rotation grace outlasts a day. It probes our own grant as a proxy for Codex's chain, which the import path takes over.

## 3. Goal / non-goals

**Goal:** An OpenAI account is a peer of a Claude account: added via the app's own browser OAuth login (or imported once from Codex CLI's login file), refreshed independently, shown as a column in the matrix and a segment in the menu bar, with the same notifications and failure affordances.

**Non-goals (this PR):** product rename; OpenAI device-code / headless login; a paste-mode fallback for OpenAI (the pinned redirect makes it impossible); credits, spend control, and rate-limit-reset-credit display; per-model availability (`model_usage`); showing `plan_type`; OpenAI API-key accounts; org selection; `login_hint` on the OpenAI authorize URL (untested); writing anything back to `~/.codex/auth.json`; a provider mark in the single-account menu-bar layout.

## 4. Decisions (locked with the user, 2026-09-07)

1. Credential source: **own browser OAuth login + one-time "Import from Codex CLI"**.
2. Popover: OpenAI account is a **peer column** in the existing matrix. Consequence, accepted: `PEAK` ranks percentages across providers — a Claude 5-hour window against an OpenAI one — because "closest to its cap" is the comparison the user wants.
3. Menu bar: **provider shape replaces the dot only when tracked accounts span both providers** (star = Claude, hexagon = OpenAI, tinted by the existing severity color). Single-provider installs are pixel-identical to today.
4. Add account: **"Add account…" becomes a menu**: Claude · OpenAI / Codex · Import from Codex CLI.
5. Login expiry for OpenAI: **no countdown, no pre-expiry notification** (lifetime unknown); a rejected refresh shows the existing red "Log in again" pill.

Two v1 details were cut at audit (YAGNI) and deviate from the mockup: the "· Team" plan suffix in the provider chip, and the email subtitle on the import menu item. Both needed persisted fields or a JWT parser for a decoration; either can return later without touching this design.

## 5. Architecture

### 5.1 Provider enum and account model

```swift
enum Provider: String, Codable, CaseIterable, Sendable { case anthropic, openai }
```

`Account` gains `let provider: Provider` (immutable, SEC-4; `init` parameter defaulted to `.anthropic` so the ~30 existing construction sites compile unchanged). `Account` gets a hand-written `init(from:)`: `provider` decodes leniently — missing **or unknown** raw value → `.anthropic` — so a persisted `accounts.v1` list from an older *or newer* build never fails to decode (`AccountsStore.load` collapses any decode error into an empty list, which would hide every account while their credentials stay in the keychain). Storage key unchanged.

`accountUUID` keeps its name and now means "the provider's stable account id" (Anthropic account UUID, or ChatGPT `account_id`).

`CachedCredentials` gains `var provider: Provider?` (optional; nil decodes as Anthropic for every existing payload). It is written on every save and read only by the migration rebuild path (§5.8): the credential map is the sole survivor of a `UserDefaults` reset, so the provider has to live there too or an OpenAI account would be resurrected as an Anthropic one and refresh its token against the wrong vendor.

### 5.2 Provider adapter (the seam)

Today `AccountsViewModel.Dependencies` carries five Anthropic-specific closures (`beginLogin`, `exchange`, `fetchIdentity`, `fetchUsage`, `refreshToken`). They move into one struct, instantiated once per provider:

```swift
/// What `beginLogin` returns today, named. Same 4-tuple as `OAuthLoginService.begin`.
typealias StartedLogin = (pending: PendingLogin, authorizeURL: URL, server: LoopbackServer?, callback: Task<String?, Never>?)

struct ProviderAdapter: Sendable {
    let provider: Provider
    /// Whether a loopback timeout may restart the login in paste mode (Anthropic: true; OpenAI: false).
    let supportsPaste: Bool
    var beginLogin: @Sendable (_ accountID: UUID?, _ forcePaste: Bool, _ loginHintEmail: String?) async throws -> StartedLogin
    var exchange: @Sendable (_ code: String, _ pending: PendingLogin) async throws -> CachedCredentials
    var fetchIdentity: @Sendable (_ token: String) async throws -> AccountIdentity
    var fetchUsage: @Sendable (_ token: String) async throws -> UsageResponse
    var refreshToken: @Sendable (_ credentials: CachedCredentials) async throws -> CachedCredentials
}

struct ProviderAdapters: Sendable {           // total by construction — no optional lookup
    let anthropic: ProviderAdapter
    let openai: ProviderAdapter
    func adapter(for provider: Provider) -> ProviderAdapter
}
```

`Dependencies.adapters: ProviderAdapters`; everything else in `Dependencies` unchanged. `.live` wires `AnthropicProvider.adapter` and `OpenAIProvider.adapter`. `AccountRuntime.Dependencies` is unchanged; the coordinator threads the account's adapter closures into it in `attachRuntime`. Tests get `ProviderAdapters.stub(anthropic:openai:)` where an omitted side is an adapter whose every closure throws a test-only `unexpectedProviderCall` error — so a test that accidentally routes an OpenAI account to the Anthropic adapter fails loudly.

**Blast radius (measured):** 12 literal `Dependencies(` constructions in tests (2 view-model, 10 runtime) + 4 closure-field mutations + 4 helpers/fixtures — all in `AccountsViewModelLoginTests.swift` and `AccountRuntimeTests.swift`. Mechanical.

**Why this shape:** one login state machine, one refresh/breaker/retry path, one persistence path — all provider-blind. The two rejected alternatives (inline `if provider == .openai` branches in the coordinator; a separate OpenAI runtime class) duplicate invariant-laden code that took two audits to get right.

### 5.3 Usage seam keeps `UsageResponse`

The seam continues to return `UsageResponse`; the runtime keeps calling `UsageSnapshot(from:)`, so `fetchedAt`, history, sparklines, thresholds, and 20 existing test sites are untouched. The OpenAI adapter decodes its own DTO (`OpenAIUsageResponse`) and **synthesizes** a `UsageResponse`:

- `fiveHour = UsagePeriod(utilization: primary_window.used_percent, resetsAt: iso8601(reset_at))`
- `sevenDay` likewise from `secondary_window`; if it is absent/null (not observed; defensive), `utilization: 0` and `resetsAt: ""` (parses to nil). This renders as a truthful-looking "7-Day 0%", accepted for a case that has not been seen.
- `limits: nil`.
- Formatting an epoch to an ISO-8601 string that `UsageSnapshot` immediately re-parses is deliberate: three lines inside the adapter versus a `UsageSnapshot`-returning seam that changes 20 test sites and moves `fetchedAt` out of the runtime's control. Documented at the call site.
- Window-length assumption: primary is treated as the 5-hour row and secondary as the 7-day row without checking `limit_window_seconds`. Documented; revisit if OpenAI changes windows.

### 5.4 Endpoints and login models

`OAuthEndpoints` (Anthropic) is left as is; a sibling `OpenAIOAuthEndpoints` holds `authorize`, `token`, `clientID`, `scope`, `redirectURI = "http://localhost:1455/auth/callback"`, `callbackPort = 1455`, `callbackPath = "/auth/callback"`, `usage = "https://chatgpt.com/backend-api/wham/usage"`, and the three extra authorize params (`id_token_add_organizations=true`, `codex_cli_simplified_flow=true`, `originator=codex_cli_rs` — see §11 RISK-1).

`PendingLogin` gains `provider: Provider`. `authorizeURL(loginHintEmail:)` switches on provider; OpenAI ignores the hint.

`OAuthLoginMode` gains `case imported` (§6). An OpenAI browser login is always `.loopback(port: 1455)`.

New: `enum OAuthLoginStartError: Error { case portBusy }`, thrown only by the OpenAI adapter's `beginLogin`.

### 5.5 Loopback server

Three touch points, all inside `LoopbackServer.swift`:
1. `LoopbackServer.init` gains `callbackPath: String = "/callback"` and passes it to `LoopbackEngine`.
2. `LoopbackEngine` stores it and hands it to `LoopbackRequest`, whose `isCallbackGET` and `callbackCode(matchingState:)` compare against it instead of the literal.
3. `LoopbackEngine.start` sets `parameters.allowLocalEndpointReuse = (requestedPort != 0)`. Rationale: after a listener on a **fixed** port serves and closes one connection, the port sits in TIME_WAIT and a plain rebind fails `EADDRINUSE` for ~30 s (measured 31.1 s on this machine at audit); with address reuse it rebinds immediately, while a bind against a *live* listener still fails `EADDRINUSE`. Ephemeral ports keep reuse off (unchanged). The audit measured this with POSIX sockets; the implementation must prove `NWListener`'s flag behaves the same with two tests (§9): immediate rebind after a served callback, and conflict against a live listener still detected.

`requestedPort` (already an init parameter, documented as a test seam) becomes a production option. Binding `127.0.0.1` only, fixed-string responses, single-waiter, constant-time state check, and the grace-page mechanism are unchanged; the OpenAI adapter passes `gracePeriod: 0` (SEC-1).

**Bind failure on 1455:** `OpenAIProvider.beginLogin` throws `OAuthLoginStartError.portBusy`; it never falls back to paste. `runLogin`'s catch — which today hardcodes one message — gains a `switch`: `portBusy` → `"Port 1455 is in use — is Codex signing in? Try again."`; every other non-cancellation error keeps `"Couldn't start the login — try again."`. Both post the existing login-problem notification. Coordinator state after the failure is clean (`pendingLogin` nil, `isStartingLogin` false, no server), so a retry is allowed immediately — and, thanks to touch point 3, succeeds unless the port is genuinely held.

### 5.6 OpenAI login, exchange, identity, refresh

- **begin:** PKCE + state as today; start `LoopbackServer(gracePeriod: 0, requestedPort: 1455, callbackPath: "/auth/callback")`; on success return `.loopback(port: 1455)` with `redirectURI` exactly `http://localhost:1455/auth/callback`; `forcePaste` is ignored (never paste).
- **loopback timeout (no paste mode):** `runLogin`'s timeout branch today ends the login and restarts it with `forcePaste: true`, then posts "Still waiting — paste the code…". Both the restart and that notification become conditional on `adapter.supportsPaste`. For OpenAI a timeout ends the login as `.failed("The login timed out — try again.")` with the usual login-problem notification; no second browser tab, no paste prompt.
- **exchange:** `POST token` with `Content-Type: application/x-www-form-urlencoded`, body `grant_type=authorization_code&client_id&code&redirect_uri&code_verifier` (no `state` — not part of OpenAI's exchange), strictly form-encoded (SEC-2), `User-Agent: AppInfo.userAgent`. Decode (`OpenAIOAuthExchange.credentials(fromStatus:body:now:)`, pure, tested): `accessToken`, `refreshToken`, `expiresAt = now + expires_in`, `refreshTokenExpiresAt = nil`, `provider = .openai`. `id_token` is **not stored**. Status classification mirrors `OAuthExchange`: 2xx decode, 400/401/403 → `.exchangeRejected`, else `.transient`.
- **identity:** `fetchIdentity(token)` = `GET usage` and map `account_id → uuid`, `email → email`, `displayName = nil`. One request validates the token and identifies the account; no JWT parsing anywhere in the app. The default label rule is the existing provider-blind one (`displayName ?? email ?? "Account \(n)"`), so an OpenAI account is labeled by its email.
- **refresh:** form-encoded `grant_type=refresh_token&client_id&refresh_token`; decode as exchange; if the response omits `refresh_token`, keep the old one (same fallback as Anthropic). `refreshTokenExpiresAt` stays nil; the runtime's carry-forward treats nil→nil as "unknown", which yields no countdown and no expiry notification. **Error type matters:** on a non-2xx the adapter throws `KeychainServiceError.refreshFailed(status:body:)` — the only shape `OAuthRefreshOutcome.classify` counts toward the circuit breaker (400/401/403 → `.rejected`; everything else falls open to `.transient`). Throwing `OAuthLoginError` here would classify every rejection as transient and the breaker would never trip. Tested (§9).
- **usage:** `GET usage` with `Authorization: Bearer`, `User-Agent`, 10 s timeout; same `UsageAPIError` taxonomy (401/403 → auth error → reactive refresh; 5xx/transport → transient/retry; a non-JSON 200 such as a challenge page → `decodingFailed`, shown as an error, not retried).
- **User-Agent** is sent on every OpenAI call, as on Anthropic's. It is still enforced by convention, not by a test (open follow-up 2(b) of the prior spec, now with double the surface — §12).

### 5.7 Which account signs in, dedupe, re-auth

All comparisons of `accountUUID` become comparisons of `(provider, accountUUID)`:
- `completeAddAccount`: existing account with same provider + id → refresh its login instead of adding.
- `AccountIdentityResolver.backfill`: duplicate detection filtered by provider.
- `completeReAuth`: the identity returned must match the account's provider id; the "signed into a different account" message (already provider-neutral) is unchanged.
A Claude account and an OpenAI account that share an email are two accounts.

**Steering the browser:** OpenAI gets no `login_hint`, and the app omits `ChatGPT-Account-Id`, so the browser's current ChatGPT session decides which account signs in. Adding a *second* OpenAI account therefore requires **Copy link** into a browser window or profile signed into that account — the same guidance the README already gives for Claude — and re-auth of an OpenAI account whose browser is on the wrong ChatGPT account fails the identity guard with the existing message and Copy link as the recovery. `.copyLink` stays for OpenAI for exactly this reason. Live QA covers it (§9).

**Add-flow provider memory:** the provider chosen in the menu is stored on the view model (`addLoginProvider`, `@Published private(set)`), and `beginLogin(nil)` — which every recovery control (`LoginPill`'s Try again) calls without a provider — reuses it. Without this, "Try again" after a failed OpenAI add-account login would silently open claude.ai. It is set by the menu items and by Import, and only ever replaced by the next choice.

### 5.8 Persistence and migration

- `AccountsStore` round-trips `.openai`; unknown provider strings decode as `.anthropic` (§5.1).
- `AccountMigration`'s "defaults reset, credential map survived" rebuild (`Account(id:label:)` per slot) now reads `provider` from each slot's `CachedCredentials` (nil → `.anthropic`). The legacy single-account migration is Anthropic by definition.
- `AccountPersistence` (snapshot/history) is unchanged.
- `Account` construction sites: 3 in the app (`completeAddAccount`, two in `AccountMigration`), ~28 in tests; all keep compiling via the defaulted parameter, and the two that matter (`completeAddAccount`, the rebuild) pass the provider explicitly.

## 6. Import from Codex CLI

- **Source:** `$CODEX_HOME/auth.json`, default `~/.codex/auth.json`. Accepted only when `auth_mode == "chatgpt"` and `tokens.access_token` and `tokens.refresh_token` are non-empty strings. Read-only; the file is never written, moved, or deleted.
- **Discovery for the menu:** `CodexAuthFile.probe()` returns `.available`, `.notFound`, or `.unusable(reason:)` (API-key mode, malformed, missing tokens, over the 1 MiB cap). The menu item is disabled with a `.help` reason when not `.available`. The probe runs when the popover appears, not on a timer. No email subtitle (no JWT parsing).
- **Import is a login.** It constructs a real `PendingLogin(provider: .openai, mode: .imported, …)` and takes the same `pendingLogin == nil, !isStartingLogin` gate as `beginLogin` — so it is refused with the existing busy message while any login is running, and it can never reach `endLogin` on top of a concurrent browser login (which would null that login's state, bump its epoch, and stop its listener). It sets `pendingLogin`, skips the browser, builds `CachedCredentials(accessToken, refreshToken, expiresAt: nil, refreshTokenExpiresAt: nil, provider: .openai)`, stores it in `unverifiedGrant`, and calls the existing `verifyAndStore`: identity via `fetchIdentity` (usage endpoint), per-provider dedupe (an already-tracked OpenAI account gets its login refreshed with the usual notice), store, attach runtime, `credentialsReplaced()`. Because `pendingLogin` is real, `retryIdentity()` / `canRetryIdentity` work exactly as for a browser login, and `LoginAffordance` offers Retry, not a browser "Try again".
- **No access-token expiry:** `expiresAt` is nil, so there is no proactive refresh for an imported token; the reactive 401 → refresh path (already the documented safety net for tokens without an expiry) handles it on the first fetch after the 10-day mark. An imported token that is *already* expired fails identity with a 401 → `identityFailed` → message "Codex's login has expired — sign in with the browser instead." (Retry is still offered; it will fail the same way until the user picks the browser item.)
- **Refresh-chain divergence (gated on O3):** after import, the app refreshes with Codex's refresh token and stores the rotated one; Codex CLI keeps the pre-rotation token. The spike showed the pre-rotation token still works immediately after rotation. If O3 shows it also works a day later, both chains coexist and nothing further is needed. If O3 fails, the menu item's `.help` and the README say "Codex CLI may need to sign in again afterwards", and the import stays.

## 7. UI

### 7.1 Menu bar (`MenuBarImage`, `MenuBarLabel`)
- `MultiAccountMenuBar.providerShapes(for accounts: [Account]) -> Bool` — `true` iff `Set(accounts.map(\.provider)).count > 1`. Pure; trivially tested.
- `MenuBarImage.multiAccount` already receives `accounts`; it computes the rule itself and draws, per segment, either the 7 pt dot (today) or a 7 pt star (Anthropic) / hexagon (OpenAI) via `NSBezierPath`, filled with the same severity color the dot uses today. No call-site plumbing.
- `MenuBarImage.twoStat` (Bars mode) draws no dot today. When shapes are on, each cluster gets the same 7 pt glyph before its prefix (plus the existing 3 pt gap), and `clusterW` grows accordingly; when shapes are off it is unchanged.
- Single-account rendering (`badge`, the 5h/7d circle) and the empty-state `sparkle` are untouched.

### 7.2 Popover
- `AccountView` gains `provider`.
- Column header: under the email, a small chip `<glyph> Claude` / `<glyph> OpenAI` shown **only when providers are mixed** (same rule as the bar). Glyphs are SF Symbols (`sparkle` / `hexagon`), no new assets.
- Model rows: a column with no `modelLimits` entry for that model already renders the `—` cell; OpenAI columns always take that branch. No new UI.
- `AccountRowView` (single-account layout): unchanged for OpenAI except the per-model section and the expiry line are naturally absent.
- Header stays "Claude Usage" (rename is out of scope).

### 7.3 Add-account menu
`addAccountControls` replaces the button with a `Menu`:
- **Claude** — sets `addLoginProvider = .anthropic`, `beginLogin(nil)`
- **OpenAI / Codex** — sets `addLoginProvider = .openai`, `beginLogin(nil)`
- divider
- **Import from Codex CLI** — `importFromCodex()`; disabled when the probe is not `.available`, with the reason in `.help`.
The existing `LoginPill` replaces the menu while a login is running, as today.

### 7.4 Login affordances for OpenAI
`LoginAffordance.resolve` and `.actions` are pure and provider-blind today; they gain a `supportsPaste: Bool` input, resolved inside `AccountsViewModel.loginAffordance(for:)` from the pending login's (or the add flow's) provider, so the seven view call sites don't change. For OpenAI: `waitingForBrowser` offers `[.cancel, .copyLink]` (no `.usePasteCode`), and `awaitingPaste` is unreachable. `switchToPaste()` is additionally guarded to be a no-op for a non-paste provider (unreachable from the UI once the button is gone; belt-and-braces, one test).

### 7.5 Re-auth
"Log in again" and the stale-refresh pill call `beginLogin(accountID)`; the coordinator reads the account's provider and uses its adapter. No `login_hint` for OpenAI.

### 7.6 Copy and docs inventory
User-facing strings that currently assume Anthropic, and what they become:
| Where | Today | Change |
|---|---|---|
| `AccountsViewModel.sendNotification` title | `"\(label): Claude Usage Warning"` | `"\(label): Usage Warning"` |
| `AccountsViewModel.label(for:)` fallback (add-flow notifications) | `"Claude Usage"` | `"Add account"` |
| `LoginPill` help for `.logIn`/`.tryAgain` | "Opens claude.ai in your browser to sign in" | provider-aware: "Opens claude.ai…" / "Opens auth.openai.com…" (add flow: by `addLoginProvider`) |
| `UsagePopoverView` add-account help | "Opens claude.ai in your browser to sign in" | moves to the Claude menu item; OpenAI item gets its own |
| `AccountRowView`, `UsageMatrixView` expiry-pill help | "Opens claude.ai…" | provider-aware via the account |
| Loopback success/expired pages | mention "ClaudeUsageBar" | unchanged (app name) |
| README | "straight to Anthropic", "identified by its Anthropic account ID", ASCII diagram, features table, troubleshooting row | new "OpenAI / Codex accounts" section (login, port 1455, import, second-account Copy-link guidance, no expiry countdown); diagram gains the OpenAI leg; "Anthropic account ID" → "provider account ID" |

## 8. Error handling summary

| Situation | Classification | User sees |
|---|---|---|
| Port 1455 busy (live listener) | `OAuthLoginStartError.portBusy` | "Port 1455 is in use — is Codex signing in? Try again." + notification; retry allowed at once |
| Port 1455 in TIME_WAIT after our own login | cannot happen (endpoint reuse on fixed ports) | — |
| Ephemeral / other-path redirect | cannot happen (pinned, constants) | — |
| Loopback timeout | `.failed`, no restart, no paste | "The login timed out — try again." + notification |
| Exchange 400/401/403 | `exchangeRejected` | existing "Login expired or was already used — try again." |
| Exchange transport/other | `transient` (one retry) | existing "Couldn't reach the login server — try again." |
| Identity (usage) fetch fails | `identityFailed`, Retry keeps grant in memory | existing message; for an imported token: "Codex's login has expired — sign in with the browser instead." |
| Refresh 400/401/403 | `refreshFailed` → `.rejected` → breaker | red "Log in again" pill (existing) |
| Refresh 429/5xx/offline | `.transient` | nothing; retried |
| Usage 401/403 | reactive refresh, then `tokenExpired` | existing |
| Usage 200 non-JSON (challenge page) | `decodingFailed` | column error text; no retry loop |
| Codex auth.json missing / API-key mode / malformed / >1 MiB | probe `.notFound` / `.unusable` | menu item disabled with reason |
| Import while a login is pending | existing busy gate | existing busy message |
| Browser on the wrong ChatGPT account (re-auth) | identity guard | existing "That browser is signed into X — expected Y." + Copy link |

## 9. Testing

Every test below fails against the pre-change code unless marked *(rule)*.

Pure/unit (new):
- `OpenAIUsageDecodeTests` — O1 fixture → `UsageResponse` (utilization, ISO reset), null `secondary_window` → 0 / nil reset, rounding, non-JSON body → decode error.
- `OpenAIOAuthExchangeDecodeTests` — form body composition (exact key set, no `state`), strict form encoding with `+ & = / %` in values, response decode, `refreshTokenExpiresAt == nil`, `provider == .openai`, status classification.
- `OpenAIRefreshOutcomeTests` — a 401 from the OpenAI refresh path is thrown as `KeychainServiceError.refreshFailed` and classifies `.rejected`; a 503 classifies `.transient`. Runtime-level: **breaker trips → `needsReAuth` → pill** after repeated OpenAI 401s.
- `CodexAuthFileTests` — chatgpt mode, api-key mode, missing tokens, missing file, malformed JSON, >1 MiB, `CODEX_HOME` override.
- `OpenAIAuthorizeURLTests` — exact query string (pinned redirect, `%20`-encoded scope, the three extra params, no `login_hint` even when an email is supplied).
- `ProviderShapeRuleTests` *(rule)* — mixed → true, single → false.
- `AccountDecodeTests` — legacy JSON → `.anthropic`; `.openai` round-trips; unknown raw value → `.anthropic` and the **rest of the list survives**.
- `CachedCredentialsProviderTests` — legacy payload → nil provider; round-trip.
- `AccountMigrationTests` — rebuild from a credential map with an `.openai` slot yields an `.openai` account.
- `AccountIdentityResolver` per-provider dedupe; `LoginAffordance` with `supportsPaste: false` (no `.usePasteCode`).
- `LoopbackServerTests` — custom `callbackPath` accepted and `/callback` rejected under it; **fixed port rebinds immediately after serving a callback**; **bind against a live listener on a fixed port still fails**.

Coordinator (`AccountsViewModelLoginTests`, stub adapters):
- Add-OpenAI happy path: asserts the persisted `Account.provider == .openai`, the runtime received the OpenAI adapter's closures, and the Anthropic stub was **never** invoked.
- Port-busy: `.failed` with the 1455 message, state clean, immediate retry allowed.
- Loopback timeout on an OpenAI login: `.failed("The login timed out…")`, no second `beginLogin` call, no paste notification.
- "Try again" after a failed OpenAI add-account login calls the OpenAI adapter.
- Cross-provider same email → two accounts; same provider + id → refresh-not-add (both directions: browser after import, import after browser).
- Import while a browser login is pending → refused, pending login untouched (epoch, `pendingLogin`, server all intact).
- Import identity failure → Retry re-runs identity (not a browser login).
- Re-auth on an OpenAI account uses the OpenAI adapter; wrong-account identity → guard message.

Live (lead QA in `make run`, real Codex account): add Codex account via browser (confirms the `%20` authorize URL); import from Codex CLI; both providers in bar (shapes on, both compact and Bars modes) and popover (chips on); retry an OpenAI login immediately after a completed one (no port-busy); remove the OpenAI account → shapes/chips off; add a second OpenAI account via Copy link into another browser profile; threshold notification for the OpenAI account (temporarily lower the threshold).

## 10. Resolved questions

- Q1 `originator`: keep `codex_cli_rs`, recorded as RISK-1. A probe with our own value costs one browser round trip and is worth doing in live QA; if the server rejects it, nothing changes.
- Q2 Identity: usage endpoint (uniform, validates the token, no parser). JWT decode cut entirely.
- Q3 Chip rule "only when mixed": kept; `plan_type` cut, so nothing is hidden by it any more.

## 11. Lead security pass (2026-09-07) — requirements folded into §5–§6

- **SEC-1 Fixed port 1455 is shared with Codex CLI.** A local process squatting 1455 can receive the browser's redirect (the authorization code), but PKCE makes that code useless without the `code_verifier`, which never leaves the app's memory; the `state` check (constant-time, existing) rejects injected codes. Conversely, while *our* listener holds 1455, a Codex CLI login's redirect lands on us: it is answered with the fixed 404 page, never logged or stored, and Codex's login fails visibly on its side. The OpenAI listener therefore uses **`gracePeriod: 0`** (no "expired" page on 1455) — making explicit on the fixed port what the prior spec's AS-SHIPPED note already records for ephemeral ones (`endLogin` stops the listener, so the grace is "effectively milliseconds"). `cancelLogin`/`endLogin` release the port before returning, as today; the 600 s loopback timeout stays.
- **SEC-2 Form encoding must be strict.** `URLComponents` leaves `+` unencoded in query values, and `+` means space in `application/x-www-form-urlencoded`. The OpenAI adapter uses a dedicated form encoder that percent-encodes everything outside RFC 3986 unreserved characters; tested with `+ & = / %`.
- **SEC-3 Tokens go only to hard-coded hosts.** Every OpenAI request targets a URL built from `OpenAIOAuthEndpoints` constants (`auth.openai.com`, `chatgpt.com`). Nothing read from `~/.codex/auth.json` or from a server response is ever used to form a URL.
- **SEC-4 `Account.provider` is `let`.** The adapter chosen for a runtime is derived from the provider at attach time; an immutable provider (and the provider tag stored with the credentials) makes cross-provider token misuse impossible by construction.
- **SEC-5 Codex auth file parsing is hostile-input safe.** Cap the file at 1 MiB before decoding; any decode failure → `.unusable`; no JWT parsing at all — identity is authoritative only from the usage endpoint. The file is opened read-only and never written, renamed, or deleted.
- **SEC-6 No PII in URLs or logs.** No `login_hint` for OpenAI; the authorize URL is never logged; `id_token` (email, name) is never persisted.
- **SEC-7 Scope.** `openid profile email offline_access` is what Codex requests. `offline_access` is required (refresh). Dropping `profile email` is an optional probe (O4); not a blocker.
- **SEC-8 Error bodies.** Refresh/exchange error bodies are classified, never rendered; a Cloudflare challenge page must never reach the UI.
- **RISK-1 (accepted, product):** the app authenticates with OpenAI's Codex public `client_id` and `originator=codex_cli_rs`, i.e. as another vendor's first-party CLI — exactly as it already does with Anthropic's Claude Code `client_id`. This is a ToS / rate-limit exposure outside the app's control; the fallback if OpenAI ever closes it is "Import from Codex CLI" only.
- **Note:** the token response's `earliest_refresh_at` suggests refreshing too early may be rejected. Proactive refresh happens at ~10 days, far past it; a reactive refresh after a spurious 401 could be rejected with a 400 and count toward the breaker. Accepted; revisit if it shows up.

## 12. Follow-ups (not this PR)

- Product rename (candidate: **QuotaBar**); bundle identifier and Keychain service name stay `com.sam.ClaudeUsageBar` to avoid a credential migration.
- OpenAI device-code login as a fallback when 1455 is unavailable.
- Credits / reset-credit display; `model_usage` availability; `plan_type` in the chip; email subtitle on the import item.
- A test that fails when `User-Agent` is missing from any token/usage request (prior spec's open follow-up 2(b), now twice the surface).
- Optional probes: O4 minimal scope; our own `originator` value.

## 13. Audit findings → resolutions (2026-09-07, Opus, fresh context)

| # | Finding | Resolution |
|---|---|---|
| B1 | Loopback timeout restarted an OpenAI login in paste mode and pointed the user at a paste field that no longer exists | `ProviderAdapter.supportsPaste`; OpenAI timeout → `.failed`, no restart, no paste notification (§5.6) |
| B2 | Fixed port + `allowLocalEndpointReuse = false` → ~31 s of self-inflicted "port busy" after every OpenAI login | reuse on for fixed ports, two listener tests (§5.5, §9) |
| B3 | Import was "PendingLogin-free", so Retry couldn't work and its tail could kill a concurrent login | Import is a real pending login (`.imported`), same gate (§6) |
| M1 | OpenAI refresh throwing `OAuthLoginError` would never trip the breaker | throw `KeychainServiceError.refreshFailed`; breaker test (§5.6, §9) |
| M2 | "Try again" after a failed OpenAI add-account started a Claude login | `addLoginProvider` remembered on the view model (§5.7) |
| M3 | `UserDefaults` reset resurrected an OpenAI account as Anthropic | `CachedCredentials.provider`; rebuild reads it (§5.1, §5.8) |
| M4 | Unknown provider raw value wiped the whole account list | lenient `init(from:)` (§5.1) |
| M5 | Bars mode has no dot to reshape | glyph before the prefix when mixed (§7.1) |
| M6 | No copy/docs inventory; "Claude Usage Warning" for OpenAI | §7.6 |
| M7 | Nothing steers which ChatGPT account signs in | Copy-link guidance, QA item, `.copyLink` kept (§5.7, §9) |
| M8 | `StartedLogin` undefined; `adapter(for:)` partial | typealias; `ProviderAdapters` total struct; loud stub (§5.2) |
| M9 | "only the message changes" was false | `runLogin` catch gains a switch (§5.5) |
| N1–N3 | grace-period contradiction; single-account `sparkle` claim; `callbackPath` touch points | fixed (§5.5, §7.1, §11) |
| N4 | overstated "Codex's token unaffected" | reworded; O3 gates import specifically (§2, §6) |
| N5 | path pinning unverified | verified live: `/callback` on 1455 rejected (§2 O2a) |
| N6 | `%20` vs `+` in the authorize URL | exact-string test + live QA (§2, §9) |
| N7–N9 | 0% for missing window; cross-provider PEAK; label rule | stated and accepted (§4, §5.3, §5.6) |
| N10 | `AccountIdentity.planType` | cut (§4) |
| N11 | vendor `client_id` / `originator` risk | RISK-1 (§11) |
| YAGNI | `planType`, `JWTPayload.decode` | cut; `.copyLink` kept as load-bearing (§4, §6, §7.4) |
| S6 | `UsageSnapshot`-returning seam | reverted to `UsageResponse`; adapter synthesizes it (§5.3) |
| S11 | `LoginAffordance` provider input | `supportsPaste` resolved in the view model (§7.4) |
