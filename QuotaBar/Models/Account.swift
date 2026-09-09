import Foundation

/// One tracked account. `id` is the app's own stable handle and the key into the
/// credential map; `accountUUID`/`email` come from the provider's identity call at capture
/// time (Anthropic: the OAuth profile endpoint; OpenAI: the usage endpoint) and drive
/// labeling, dedupe, and the re-auth identity guard. `provider` never changes for the life
/// of an account: the adapter attached to its runtime is chosen from it.
struct Account: Codable, Identifiable, Equatable {
    let id: UUID
    var label: String
    /// Stable provider account identity. `nil` until it has been fetched — the case for a
    /// legacy-migrated account (identity unknown at migration time, backfilled on the first
    /// successful profile fetch). Dedupe and the re-auth identity guard only apply once this
    /// is populated, and always together with `provider`.
    var accountUUID: String?
    var email: String?
    /// Optional user-chosen menu-bar prefix (e.g. "🏠" or "Me"). When set, it overrides the
    /// prefix auto-derived from `label`. `nil`/empty means "derive from the label".
    var shortCode: String?
    let provider: Provider

    init(id: UUID = UUID(), label: String, accountUUID: String? = nil,
         email: String? = nil, shortCode: String? = nil, provider: Provider = .anthropic) {
        self.id = id
        self.label = label
        self.accountUUID = accountUUID
        self.email = email
        self.shortCode = shortCode
        self.provider = provider
    }

    enum CodingKeys: String, CodingKey { case id, label, accountUUID, email, shortCode, provider }

    /// Hand-written so `provider` decodes leniently (see `Provider.lenient`); encoding stays
    /// synthesized.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        accountUUID = try c.decodeIfPresent(String.self, forKey: .accountUUID)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        shortCode = try c.decodeIfPresent(String.self, forKey: .shortCode)
        provider = Provider.lenient(try c.decodeIfPresent(String.self, forKey: .provider))
    }
}

/// Persists the ordered account list under a single, versioned `UserDefaults` key.
/// `UserDefaults` is injected so tests use an ephemeral suite.
struct AccountsStore {
    static let key = "accounts.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether a list has ever been written — the migration's idempotency guard.
    var hasAccounts: Bool {
        defaults.object(forKey: Self.key) != nil
    }

    func load() -> [Account] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([Account].self, from: data)) ?? []
    }

    func save(_ accounts: [Account]) {
        if let data = try? JSONEncoder().encode(accounts) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
