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
