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

    @Test("Single-provider installs draw the dot; mixed installs draw each provider's mark")
    func markSelection() {
        #expect(ProviderShape.mark(for: .anthropic, mixed: false) == .dot)
        #expect(ProviderShape.mark(for: .openai, mixed: false) == .dot)
        #expect(ProviderShape.mark(for: .anthropic, mixed: true) == .claudeMark)
        #expect(ProviderShape.mark(for: .openai, mixed: true) == .openAIMark)
    }

    @Test("The dot's path stays inside its rect and is non-empty")
    func dotPathFitsItsRect() {
        let rect = NSRect(x: 10, y: 4, width: 7, height: 7)
        let path = ProviderShape.dot.path(in: rect)
        #expect(!path.isEmpty)
        #expect(rect.insetBy(dx: -0.01, dy: -0.01).contains(path.bounds))
    }

    @Test("Both provider marks load from the asset catalog as template images")
    func marksLoadAsTemplateImages() throws {
        #expect(ProviderShape.dot.image == nil)
        for shape in [ProviderShape.claudeMark, .openAIMark] {
            let image = try #require(shape.image, "\(shape)")
            #expect(image.isTemplate, "\(shape)")
            #expect(image.size.width > 0 && image.size.height > 0, "\(shape)")
        }
    }

    @Test("Claude's mark carries its brand color; OpenAI's has none")
    func brandColors() throws {
        let claude = try #require(ProviderShape.claudeMark.brandColor?.usingColorSpace(.sRGB))
        #expect((claude.redComponent * 1000).rounded() / 1000 == 0.851)     // 0xD9
        #expect((claude.greenComponent * 1000).rounded() / 1000 == 0.467)   // 0x77
        #expect((claude.blueComponent * 1000).rounded() / 1000 == 0.341)    // 0x57
        #expect(ProviderShape.openAIMark.brandColor == nil)
        #expect(ProviderShape.dot.brandColor == nil)
    }

    /// Simplest of the two options in the brief: render each mark on its own and inspect its
    /// solid pixels, rather than hunting the mark's region inside a whole menu-bar image.
    @Test("A drawn Claude mark is orange, a drawn OpenAI mark is gray, and neither is severity-colored")
    func drawnMarkColors() throws {
        func solidPixels(_ shape: ProviderShape) throws -> [NSColor] {
            let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
                shape.draw(in: rect, severity: .systemGreen)
                return true
            }
            let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            return (0..<rep.pixelsWide).flatMap { x in
                (0..<rep.pixelsHigh).compactMap { y -> NSColor? in
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                          c.alphaComponent > 0.9 else { return nil }
                    return c
                }
            }
        }

        let claude = try solidPixels(.claudeMark)
        #expect(!claude.isEmpty)
        #expect(claude.allSatisfy { $0.redComponent > $0.greenComponent && $0.greenComponent > $0.blueComponent })

        let openAI = try solidPixels(.openAIMark)
        #expect(!openAI.isEmpty)
        #expect(openAI.allSatisfy {
            abs($0.redComponent - $0.greenComponent) < 0.02 && abs($0.greenComponent - $0.blueComponent) < 0.02
        })
    }

    @Test("A mixed-provider bar is wider than the same accounts under one provider")
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
        // The 9 pt provider mark is wider than the 7 pt dot it replaces.
        #expect(mixedCompact.size.width > singleCompact.size.width)
        #expect(mixedCompact.tiffRepresentation != singleCompact.tiffRepresentation)
    }

    @Test("A single-provider compact bar still lays out the 7 pt dot")
    func singleProviderKeepsTheDotLayout() {
        let a = Account(label: "P", provider: .anthropic)
        let b = Account(label: "W", provider: .anthropic)
        let snap = UsageSnapshot(fiveHourPercent: 40, sevenDayPercent: 60, fiveHourResetsAt: nil, sevenDayResetsAt: nil, fetchedAt: Date())
        let image = MenuBarImage.multiAccount(accounts: [a, b], snapshots: [a.id: snap, b.id: snap], mode: .fiveHour)

        // The pre-change formula, spelled out: 7 pt dot + 3 pt gap per segment, and a middot
        // with 5 pt on each side between them, all rounded up plus a 1 pt margin per side.
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        func width(_ s: String) -> CGFloat {
            NSAttributedString(string: s, attributes: [.font: font]).size().width
        }
        let expected = ceil((7 + 3 + width("P 40%")) + (5 + width("·") + 5) + (7 + 3 + width("W 40%"))) + 2
        #expect(image.size.width == expected)
    }
}
