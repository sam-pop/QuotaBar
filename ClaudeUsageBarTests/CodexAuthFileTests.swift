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
