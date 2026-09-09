import Testing
import Foundation

@Suite("Provider persistence")
struct ProviderPersistenceTests {

    private func ephemeralDefaults() -> UserDefaults {
        let suite = "ProviderPersistenceTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test("Account JSON written before `provider` existed decodes as Anthropic")
    func legacyAccountDecodesAsAnthropic() throws {
        let json = #"[{"id":"9F4B2C4E-3B0A-4D6D-8E3E-1B2A3C4D5E6F","label":"Personal","accountUUID":"u1"}]"#
        let accounts = try JSONDecoder().decode([Account].self, from: Data(json.utf8))
        #expect(accounts.count == 1)
        #expect(accounts[0].provider == .anthropic)
        #expect(accounts[0].accountUUID == "u1")
    }

    @Test("An OpenAI account round-trips through AccountsStore")
    func openAIRoundTrips() {
        let store = AccountsStore(defaults: ephemeralDefaults())
        store.save([Account(label: "Codex", accountUUID: "cg-1", email: "a@b.c", provider: .openai)])
        let loaded = store.load()
        #expect(loaded.count == 1)
        #expect(loaded[0].provider == .openai)
    }

    @Test("An unknown provider string decodes as Anthropic and the rest of the list survives")
    func unknownProviderIsLenient() throws {
        let json = #"""
        [{"id":"9F4B2C4E-3B0A-4D6D-8E3E-1B2A3C4D5E6F","label":"A","provider":"gemini"},
         {"id":"1F4B2C4E-3B0A-4D6D-8E3E-1B2A3C4D5E6F","label":"B","provider":"openai"}]
        """#
        let accounts = try JSONDecoder().decode([Account].self, from: Data(json.utf8))
        #expect(accounts.map(\.provider) == [.anthropic, .openai])
    }

    @Test("CachedCredentials without a provider tag decodes with nil; a tag round-trips; an unknown tag is nil")
    func credentialsProviderTag() throws {
        let legacy = #"{"accessToken":"a","refreshToken":"r"}"#
        let decodedLegacy = try JSONDecoder().decode(CachedCredentials.self, from: Data(legacy.utf8))
        #expect(decodedLegacy.provider == nil)

        var tagged = CachedCredentials(accessToken: "a", refreshToken: "r", expiresAt: nil)
        tagged.provider = .openai
        let roundTrip = try JSONDecoder().decode(CachedCredentials.self, from: JSONEncoder().encode(tagged))
        #expect(roundTrip.provider == .openai)
        #expect(roundTrip == tagged)

        let unknown = #"{"accessToken":"a","provider":"gemini"}"#
        #expect(try JSONDecoder().decode(CachedCredentials.self, from: Data(unknown.utf8)).provider == nil)
    }

    @Test("Provider.lenient maps unknown and nil to Anthropic")
    func lenient() {
        #expect(Provider.lenient(nil) == .anthropic)
        #expect(Provider.lenient("gemini") == .anthropic)
        #expect(Provider.lenient("openai") == .openai)
    }
}
