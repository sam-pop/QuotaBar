import Testing
import Foundation

@Suite("MultiAccountMenuBar")
struct MultiAccountMenuBarTests {

    @Test("Distinct first letters yield single-character prefixes")
    func distinctFirstLetters() {
        #expect(MultiAccountMenuBar.shortPrefixes(for: ["Personal", "Work"]) == ["P", "W"])
    }

    @Test("Colliding first letters are lengthened until unique")
    func collidingPrefixes() {
        // "Personal" and "Pro" both start with P → the second grows to disambiguate.
        let prefixes = MultiAccountMenuBar.shortPrefixes(for: ["Personal", "Pro"])
        #expect(prefixes.count == 2)
        #expect(prefixes[0] != prefixes[1])
        #expect(prefixes[0].first == "P")
        #expect(prefixes[1].first == "P")
    }

    @Test("Identical labels fall back to a numeric suffix")
    func identicalLabels() {
        let prefixes = MultiAccountMenuBar.shortPrefixes(for: ["Acct", "Acct"])
        #expect(prefixes.count == 2)
        #expect(prefixes[0] != prefixes[1])
    }

    @Test("A user override is used verbatim, in place of the derived prefix")
    func userOverride() {
        let prefixes = MultiAccountMenuBar.shortPrefixes(
            for: ["Personal", "Work"],
            overrides: ["🏠", nil]
        )
        #expect(prefixes == ["🏠", "W"])
    }

    @Test("Derived prefixes avoid colliding with a user override")
    func derivedAvoidsOverride() {
        // The user set "W" for the first account; the second ("Work") must not also be "W".
        let prefixes = MultiAccountMenuBar.shortPrefixes(
            for: ["Whatever", "Work"],
            overrides: ["W", nil]
        )
        #expect(prefixes[0] == "W")
        #expect(prefixes[1] != "W")
    }

    @Test("Blank overrides are ignored and fall back to derivation")
    func blankOverrideIgnored() {
        #expect(MultiAccountMenuBar.shortPrefixes(for: ["Personal", "Work"], overrides: ["", "  "])
                == ["P", "W"])
    }

    @Test("Compose joins prefix + percent with a middot")
    func compose() {
        let text = MultiAccountMenuBar.compose(prefixes: ["P", "W"], percents: [45, 82])
        #expect(text == "P 45% · W 82%")
    }

    @Test("Worst percent is the maximum, nil when empty")
    func worst() {
        #expect(MultiAccountMenuBar.worstPercent([45, 82, 12]) == 82)
        #expect(MultiAccountMenuBar.worstPercent([]) == nil)
    }

    @Test("Window tag: every account in auto, only 7-day readings in fixed 5h, never in 7d or bars")
    func windowTag() {
        // Auto mode: tag reflects each account's chosen window.
        #expect(MultiAccountMenuBar.windowTag(mode: .auto, window: .fiveHour) == "5h")
        #expect(MultiAccountMenuBar.windowTag(mode: .auto, window: .sevenDay) == "7d")
        // Fixed 5h: an account with no 5-hour window falls back to 7d, so only it is tagged.
        #expect(MultiAccountMenuBar.windowTag(mode: .fiveHour, window: .fiveHour) == nil)
        #expect(MultiAccountMenuBar.windowTag(mode: .fiveHour, window: .sevenDay) == "7d")
        // Fixed 7d: every account shows the 7-day window.
        #expect(MultiAccountMenuBar.windowTag(mode: .sevenDay, window: .sevenDay) == nil)
        // Bars draws both windows with its own row labels.
        #expect(MultiAccountMenuBar.windowTag(mode: .bars, window: .fiveHour) == nil)
        #expect(MultiAccountMenuBar.windowTag(mode: .bars, window: .sevenDay) == nil)
    }
}
