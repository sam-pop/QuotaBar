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
