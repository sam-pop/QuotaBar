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
