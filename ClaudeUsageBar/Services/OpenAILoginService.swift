import Foundation

/// Pure body composition and response decoding for OpenAI's token endpoint, kept apart
/// from the networking so every branch is unit-testable. Two decoders, because the two
/// call sites need different error types: the exchange path speaks `OAuthLoginError`
/// (what `AccountsViewModel.finishLogin` classifies), the refresh path speaks
/// `KeychainServiceError.refreshFailed` — the only error this decoder can throw that
/// `OAuthRefreshOutcome.classify` reads a status from, and so the only one that can count
/// toward the circuit breaker. Any other error type classifies as transient, and the
/// breaker would never trip on a dead refresh token.
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
    /// CDN interstitial must not count as a token rejection. The body is carried only as a
    /// truncated snippet for classification, never rendered (spec §11 SEC-8).
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
    /// usage endpoint supplies anyway, and nothing here should persist it (spec §11 SEC-6).
    /// `refreshTokenExpiresAt` stays nil — OpenAI's token response has no such field.
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
