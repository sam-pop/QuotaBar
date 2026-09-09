import AppKit

/// The mark drawn before each account's segment in the menu bar. A dot — filled with the
/// severity color — unless providers are mixed; then each provider's own logo from the asset
/// catalog, drawn in its brand color (Claude) or the label color (OpenAI, whose mark is
/// black/white), never in the severity color.
enum ProviderShape: Equatable {
    case dot
    case claudeMark
    case openAIMark

    static func mark(for provider: Provider, mixed: Bool) -> ProviderShape {
        guard mixed else { return .dot }
        switch provider {
        case .anthropic: return .claudeMark
        case .openai: return .openAIMark
        }
    }

    /// The dot's path. Provider marks are images, not geometry — see `draw(in:severity:)`.
    func path(in rect: NSRect) -> NSBezierPath {
        NSBezierPath(ovalIn: rect)
    }

    /// Claude's brand orange, as listed by simple-icons (#D97757).
    static let claudeBrand = NSColor(srgbRed: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0, alpha: 1)

    /// Brand color for marks that have one; `nil` draws in the label color. Never the
    /// severity color.
    var brandColor: NSColor? {
        self == .claudeMark ? Self.claudeBrand : nil
    }

    /// The template image for a provider mark, from the app's asset catalog; nil for `.dot`.
    /// Loaded via `Bundle(for:)` because under `make test` `Bundle.main` is the xctest runner.
    var image: NSImage? {
        let name: String
        switch self {
        case .dot: return nil
        case .claudeMark: name = "ProviderMarkClaude"
        case .openAIMark: name = "ProviderMarkOpenAI"
        }
        guard let image = Bundle(for: AccountRuntime.self).image(forResource: name) else { return nil }
        image.isTemplate = true
        return image
    }

    /// The mark as an `NSMenuItem` image. Menu items size by `NSImage.size` — SwiftUI's
    /// bridge to `NSMenuItem` drops a `.frame` on a non-SF image — so the copy carries its own
    /// size. The bridge drops `.foregroundStyle` too, so Claude's orange is baked in here;
    /// OpenAI's mark stays a template, which the menu tints itself (white on a highlighted
    /// row). nil for `.dot`, which has no image.
    func menuImage(pointSize: CGFloat) -> NSImage? {
        guard let mark = image?.copy() as? NSImage else { return nil }
        mark.size = NSSize(width: pointSize, height: pointSize)
        guard let brandColor else { return mark }
        return NSImage(size: mark.size, flipped: false) { rect in
            mark.draw(in: rect)
            brandColor.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    /// Draws the mark into `rect`. The dot is filled with `severity` (today's behavior). The
    /// provider marks are trademarks and never carry severity: they are drawn as template
    /// images in `brandColor` — Claude's orange, or the label color when the brand mark is
    /// black/white — and `severity` is ignored for them.
    func draw(in rect: NSRect, severity: NSColor) {
        guard let image else {
            severity.setFill()
            path(in: rect).fill()
            return
        }
        // The standard AppKit template tint: stamp the mark, then paint its alpha.
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        (brandColor ?? .labelColor).setFill()
        rect.fill(using: .sourceAtop)
    }
}
