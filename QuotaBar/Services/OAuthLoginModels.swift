import Foundation

/// How a login receives its credentials. `loopback` runs a local HTTP server and captures
/// the browser redirect; `paste` sends the browser to Anthropic's own callback page, which
/// renders a `code#state` string for the user to copy back into the app.
enum OAuthLoginMode: Equatable {
    case loopback(port: UInt16)
    case paste
}

/// A browser OAuth login that has been started but not yet completed. `pkce` is the
/// verifier/challenge/state generated for this attempt; `redirectURI` is the exact
/// redirect_uri string sent with the authorize request, replayed verbatim at the
/// token exchange. `accountID` is set when this login is re-authenticating an
/// existing account, so its identity can be checked against the account returned
/// by the token exchange.
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

/// Anthropic's OAuth endpoints and client parameters for the browser login flow,
/// confirmed live against the real servers during the design spike for this feature.
enum OAuthEndpoints {
    static let authorize = "https://claude.ai/oauth/authorize"
    static let token = "https://console.anthropic.com/v1/oauth/token"
    /// The single parsed-`URL` form of `token`. Both `OAuthLoginService` (fresh login) and
    /// `KeychainService` (refresh) POST here; this is the one place the token URL's
    /// force-unwrap happens.
    static let tokenURL = URL(string: token)!
    /// Anthropic's own callback page for paste mode: it renders a `code#state` string
    /// for the user to copy back into the app, instead of redirecting to a local port.
    static let pasteRedirect = "https://console.anthropic.com/oauth/code/callback"
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    /// Deliberately excludes `org:create_api_key`. Spike S4 requested it and the
    /// server granted back only `user:inference user:profile` for this client;
    /// requesting the minimum keeps api-key-minting privilege off every stored
    /// token regardless of what the server would grant.
    static let scope = "user:profile user:inference"
}

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

enum OAuthPaste {
    /// Parses a `code#state` string pasted back from Anthropic's OAuth callback page
    /// in paste-mode login. Splits on the first `#`, trims surrounding whitespace,
    /// and rejects input containing internal whitespace or exceeding 8192 characters.
    ///
    /// The returned `state` is security-critical: the caller must compare it against
    /// the pending login's stored state before using the returned `code`.
    static func parse(_ raw: String) -> (code: String, state: String)? {
        guard raw.count <= 8192 else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let hash = trimmed.firstIndex(of: "#") else { return nil }
        let code = String(trimmed[..<hash])
        let state = String(trimmed[trimmed.index(after: hash)...])
        guard !code.isEmpty, !state.isEmpty else { return nil }
        guard !code.contains(where: { $0.isWhitespace }), !state.contains(where: { $0.isWhitespace }) else { return nil }
        return (code, state)
    }
}
