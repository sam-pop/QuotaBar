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
