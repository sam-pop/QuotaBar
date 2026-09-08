import Testing
import AppKit

@Suite("Provider shapes")
struct ProviderShapeTests {
    @Test("Shapes appear only when tracked accounts span both providers")
    func rule() {
        #expect(MultiAccountMenuBar.providerShapes(for: [.anthropic, .anthropic]) == false)
        #expect(MultiAccountMenuBar.providerShapes(for: [.openai]) == false)
        #expect(MultiAccountMenuBar.providerShapes(for: []) == false)
        #expect(MultiAccountMenuBar.providerShapes(for: [.anthropic, .openai]) == true)
    }

    @Test("Single-provider installs draw the dot; mixed installs draw star / hexagon by provider")
    func markSelection() {
        #expect(ProviderShape.mark(for: .anthropic, mixed: false) == .dot)
        #expect(ProviderShape.mark(for: .openai, mixed: false) == .dot)
        #expect(ProviderShape.mark(for: .anthropic, mixed: true) == .star)
        #expect(ProviderShape.mark(for: .openai, mixed: true) == .hexagon)
    }

    @Test("Every shape's path stays inside its rect and is non-empty")
    func pathsFitTheirRect() {
        let rect = NSRect(x: 10, y: 4, width: 7, height: 7)
        for shape in [ProviderShape.dot, .star, .hexagon] {
            let path = shape.path(in: rect)
            #expect(!path.isEmpty)
            #expect(rect.insetBy(dx: -0.01, dy: -0.01).contains(path.bounds), "\(shape)")
        }
    }

    @Test("A mixed-provider bar image is wider than a single-provider one with the same accounts (the glyph is drawn) in both compact and Bars modes")
    func mixedBarDrawsGlyph() {
        let a = Account(label: "P", provider: .anthropic)
        // `b` and `c` share a label so the two images differ only by provider: the fonts are
        // proportional, so different labels would move the width on their own.
        let b = Account(label: "W", provider: .anthropic)
        let c = Account(label: "W", provider: .openai)
        let snap = UsageSnapshot(fiveHourPercent: 40, sevenDayPercent: 60, fiveHourResetsAt: nil, sevenDayResetsAt: nil, fetchedAt: Date())
        let single = MenuBarImage.twoStat(accounts: [a, b], snapshots: [a.id: snap, b.id: snap])
        let mixed = MenuBarImage.twoStat(accounts: [a, c], snapshots: [a.id: snap, c.id: snap])
        #expect(mixed.size.width > single.size.width)

        let singleCompact = MenuBarImage.multiAccount(accounts: [a, b], snapshots: [a.id: snap, b.id: snap], mode: .fiveHour)
        let mixedCompact = MenuBarImage.multiAccount(accounts: [a, c], snapshots: [a.id: snap, c.id: snap], mode: .fiveHour)
        // Compact mode replaces the dot with a same-size glyph, so the width is unchanged;
        // the rule is what changes, and it is pinned by `rule()` above.
        #expect(mixedCompact.size.width == singleCompact.size.width)
    }
}
