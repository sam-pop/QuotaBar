import AppKit

/// The 7-pt mark drawn before each account's segment in the menu bar. A dot unless
/// providers are mixed; then a four-point star for Claude and a hexagon for OpenAI, filled
/// with the same severity color the dot uses.
enum ProviderShape: Equatable {
    case dot
    case star
    case hexagon

    static func mark(for provider: Provider, mixed: Bool) -> ProviderShape {
        guard mixed else { return .dot }
        switch provider {
        case .anthropic: return .star
        case .openai: return .hexagon
        }
    }

    func path(in rect: NSRect) -> NSBezierPath {
        switch self {
        case .dot:
            return NSBezierPath(ovalIn: rect)
        case .star:
            // Four points on the rect's edges, waist at 30% — reads as a sparkle at 7 pt.
            let c = NSPoint(x: rect.midX, y: rect.midY)
            let r = rect.width / 2, w = r * 0.3
            let path = NSBezierPath()
            path.move(to: NSPoint(x: c.x, y: c.y + r))
            path.line(to: NSPoint(x: c.x + w, y: c.y + w))
            path.line(to: NSPoint(x: c.x + r, y: c.y))
            path.line(to: NSPoint(x: c.x + w, y: c.y - w))
            path.line(to: NSPoint(x: c.x, y: c.y - r))
            path.line(to: NSPoint(x: c.x - w, y: c.y - w))
            path.line(to: NSPoint(x: c.x - r, y: c.y))
            path.line(to: NSPoint(x: c.x - w, y: c.y + w))
            path.close()
            return path
        case .hexagon:
            let c = NSPoint(x: rect.midX, y: rect.midY)
            let r = rect.width / 2
            let path = NSBezierPath()
            for i in 0..<6 {
                let angle = CGFloat(i) * .pi / 3 + .pi / 6   // pointy top, flat left and right sides
                let p = NSPoint(x: c.x + r * cos(angle), y: c.y + r * sin(angle))
                if i == 0 { path.move(to: p) } else { path.line(to: p) }
            }
            path.close()
            return path
        }
    }
}
