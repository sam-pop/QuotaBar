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

    /// Anything larger is not a login file. Enforced by reading at most `maxBytes + 1` bytes
    /// and rejecting the overflow — never by looking the size up first, which a symlink
    /// (whose own size is a few dozen bytes) would walk straight past.
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
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ReadError.unusable(reason: unreadable)
        }
        defer { try? handle.close() }
        // One bounded read: nothing over the cap is ever held in memory, and there is no
        // window between measuring the file and reading it.
        guard let data = try? handle.read(upToCount: maxBytes + 1), data.count <= maxBytes,
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
