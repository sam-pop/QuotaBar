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
