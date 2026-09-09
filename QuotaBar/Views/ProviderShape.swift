import AppKit

/// The mark drawn before each account's segment in the menu bar. A dot — filled with the
/// severity color — unless providers are mixed; then each provider's own logo, drawn
/// monochrome from the asset catalog.
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

    /// Draws the mark into `rect`. The dot is filled with `severity` (today's behavior). The
    /// provider marks are trademarks and are never recolored: they are drawn as template
    /// images in `NSColor.labelColor`, and `severity` is ignored for them.
    func draw(in rect: NSRect, severity: NSColor) {
        guard let image else {
            severity.setFill()
            path(in: rect).fill()
            return
        }
        // The standard AppKit template tint: stamp the mark, then paint its alpha.
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.labelColor.setFill()
        rect.fill(using: .sourceAtop)
    }
}
