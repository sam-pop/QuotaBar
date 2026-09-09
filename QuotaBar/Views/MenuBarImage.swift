import AppKit

/// AppKit drawing for the menu-bar status item. Color must be baked into an `NSImage`
/// because `Text`/SF Symbols render monochrome in a `MenuBarExtra` label.
enum MenuBarImage {

    /// Level color for a percent, matching `UsageViewModel.color(for:)`.
    static func levelColor(_ percent: Int) -> NSColor {
        switch percent {
        case ..<50: return .systemGreen
        case ..<75: return .systemYellow
        default:    return .systemRed
        }
    }

    /// Level color for a percent drawn as *text*, not as a filled dot: text needs far more
    /// contrast to stay legible, and `systemYellow` at 11 pt on a light menu bar does not have
    /// it. These are the popover mockups' severity tokens (`design-mockups/popover-redesign.html`,
    /// `--lvl-low/mid/crit`), light / dark. The dynamic provider resolves them at draw time, so a
    /// dark menu bar under a light desktop still gets the dark variant. Thresholds match
    /// `levelColor`.
    static func textLevelColor(_ percent: Int) -> NSColor {
        let light: UInt32, dark: UInt32
        switch percent {
        case ..<50: (light, dark) = (0x1A_7F_37, 0x3F_B9_50)
        case ..<75: (light, dark) = (0x9A_67_00, 0xE3_B3_41)
        default:    (light, dark) = (0xCF_22_2E, 0xF8_51_49)
        }
        return NSColor(name: nil) { appearance in
            srgb(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        }
    }

    private static func srgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }

    /// The single-account 5h/7d badge (blue in auto mode, else the level color).
    static func badge(window: MenuBarDisplayMode, isAuto: Bool, percent: Int) -> NSImage {
        let badgeText = window == .fiveHour ? "5h" : "7d"
        let bgColor = isAuto ? NSColor.systemBlue : levelColor(percent)
        let size = NSSize(width: 18, height: 18)

        let image = NSImage(size: size, flipped: false) { rect in
            bgColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()

            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let str = NSAttributedString(string: badgeText, attributes: attrs)
            let strSize = str.size()
            str.draw(in: NSRect(x: (rect.width - strSize.width) / 2,
                                y: (rect.height - strSize.height) / 2,
                                width: strSize.width, height: strSize.height))
            return true
        }
        image.isTemplate = false
        return image
    }

    /// The multi-account compact image: a colored dot + `X 45%` segment per account,
    /// separated by a middot. Text uses the dynamic label color so it adapts to light/dark.
    /// When providers are mixed the 7 pt dot becomes the provider's own 11 pt mark, drawn in
    /// its brand color (a trademark never carries severity), and the *percent alone* carries the
    /// severity color the dot used to carry — in its text variant (`textLevelColor`), since the
    /// prefix beside it stays `labelColor`. Single-provider output is unchanged.
    static func multiAccount(
        accounts: [Account],
        snapshots: [UUID: UsageSnapshot],
        mode: MenuBarDisplayMode
    ) -> NSImage {
        let prefixes = MultiAccountMenuBar.shortPrefixes(
            for: accounts.map(\.label),
            overrides: accounts.map(\.shortCode)
        )
        let mixed = MultiAccountMenuBar.providerShapes(for: accounts.map(\.provider))
        // `valueColor` is nil unless the percent carries severity on its own — that is, only
        // when providers are mixed and there is a reading; "--%" is never severity-colored.
        struct Segment {
            let dotColor: NSColor?; let valueColor: NSColor?
            let prefix: String; let value: String; let tag: String?; let shape: ProviderShape
        }
        let segments: [Segment] = zip(prefixes, accounts).map { prefix, account in
            let shape = ProviderShape.mark(for: account.provider, mixed: mixed)
            if let snapshot = snapshots[account.id],
               let active = MenuBarSelection.active(mode: mode, snapshot: snapshot) {
                let tag = MultiAccountMenuBar.windowTag(mode: mode, window: active.window)
                return Segment(dotColor: levelColor(active.percent),
                               valueColor: mixed ? textLevelColor(active.percent) : nil,
                               prefix: prefix, value: "\(active.percent)%", tag: tag, shape: shape)
            }
            return Segment(dotColor: nil, valueColor: nil, prefix: prefix, value: "--%", tag: nil, shape: shape)
        }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let tagFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
        let textAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let tagAttrs: [NSAttributedString.Key: Any] = [.font: tagFont, .foregroundColor: NSColor.secondaryLabelColor]
        let sepAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        let tagGap: CGFloat = 2

        // The prefix is always label-colored. When the percent carries severity it is drawn as
        // its own string beside it; otherwise the segment stays the single string it always was,
        // so single-provider output is byte-identical.
        func pieces(_ segment: Segment) -> [NSAttributedString] {
            guard let valueColor = segment.valueColor else {
                return [NSAttributedString(string: "\(segment.prefix) \(segment.value)", attributes: textAttrs)]
            }
            var valueAttrs = textAttrs
            valueAttrs[.foregroundColor] = valueColor
            return [NSAttributedString(string: "\(segment.prefix) ", attributes: textAttrs),
                    NSAttributedString(string: segment.value, attributes: valueAttrs)]
        }

        // The provider marks need more room than the dot to read at menu-bar size: 11 pt,
        // the most that stays comfortably inside the 18 pt image. The dot keeps its 7 pt so
        // single-provider output stays pixel-identical.
        let markSize: CGFloat = mixed ? 11 : 7
        let dotGap: CGFloat = 3
        let segGap: CGFloat = 5
        let height: CGFloat = 18

        // Measure total width.
        var width: CGFloat = 0
        let sep = NSAttributedString(string: "·", attributes: sepAttrs)
        for (index, segment) in segments.enumerated() {
            if index > 0 { width += sep.size().width + segGap * 2 }
            if segment.dotColor != nil || mixed { width += markSize + dotGap }
            width += pieces(segment).reduce(0) { $0 + $1.size().width }
            if let tag = segment.tag {
                width += tagGap + NSAttributedString(string: tag, attributes: tagAttrs).size().width
            }
        }
        width = ceil(width) + 2

        let image = NSImage(size: NSSize(width: max(width, 1), height: height), flipped: false) { _ in
            var x: CGFloat = 1
            for (index, segment) in segments.enumerated() {
                if index > 0 {
                    x += segGap
                    let sepSize = sep.size()
                    sep.draw(at: NSPoint(x: x, y: (height - sepSize.height) / 2))
                    x += sepSize.width + segGap
                }
                // Mixed: every account shows its provider mark, reading or not — the mark never
                // carried severity anyway, so a signed-out column is not the odd one out. Not
                // mixed: no reading still means no dot, exactly as before.
                if segment.dotColor != nil || mixed {
                    segment.shape.draw(in: NSRect(x: x, y: (height - markSize) / 2,
                                                  width: markSize, height: markSize),
                                       severity: segment.dotColor ?? .labelColor)
                    x += markSize + dotGap
                }
                // A provider mark keeps its own color, so the number carries severity — the
                // prefix in front of it does not.
                for piece in pieces(segment) {
                    let pieceSize = piece.size()
                    piece.draw(at: NSPoint(x: x, y: (height - pieceSize.height) / 2))
                    x += pieceSize.width
                }
                // Auto-mode window tag ("5h"/"7d"), drawn slightly raised and smaller.
                if let tag = segment.tag {
                    x += tagGap
                    let tagStr = NSAttributedString(string: tag, attributes: tagAttrs)
                    let tagSize = tagStr.size()
                    tagStr.draw(at: NSPoint(x: x, y: (height - tagSize.height) / 2 + 3))
                    x += tagSize.width
                }
            }
            return true
        }
        // Not a template: the colored dots (and, when mixed, the numbers) keep their color.
        image.isTemplate = false
        return image
    }

    /// The "Bars" mode image: one cluster per account, each a stacked pair of mini progress
    /// bars — 5h on top, 7d below — with its short prefix and the percent beside each bar.
    /// Bars use the *effective* percent, so a window past its reset shows empty, not stale.
    static func twoStat(accounts: [Account], snapshots: [UUID: UsageSnapshot], now: Date = Date()) -> NSImage {
        let prefixes = MultiAccountMenuBar.shortPrefixes(
            for: accounts.map(\.label), overrides: accounts.map(\.shortCode)
        )

        let prefixAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: NSColor.labelColor,
        ]
        let rowLabelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 7, weight: .medium), .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let numAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        let mixed = MultiAccountMenuBar.providerShapes(for: accounts.map(\.provider))
        // `shape` is nil unless providers are mixed; the mark keeps its own color — the
        // bars already carry severity.
        struct Cluster {
            let prefix: String; let p5: Int?; let p7: Int?; let num5: String; let num7: String
            let shape: ProviderShape?
        }
        let clusters: [Cluster] = zip(prefixes, accounts).map { prefix, account in
            let shape = mixed ? ProviderShape.mark(for: account.provider, mixed: true) : nil
            guard let s = snapshots[account.id] else {
                return Cluster(prefix: prefix, p5: nil, p7: nil, num5: "--", num7: "--", shape: shape)
            }
            let p5 = UsageSnapshot.effectivePercent(s.fiveHourPercent, resetsAt: s.fiveHourResetsAt, now: now)
            let p7 = UsageSnapshot.effectivePercent(s.sevenDayPercent, resetsAt: s.sevenDayResetsAt, now: now)
            return Cluster(prefix: prefix, p5: p5, p7: p7, num5: "\(p5)%", num7: "\(p7)%", shape: shape)
        }

        let barW: CGFloat = 26, barH: CGFloat = 4.5
        let gap: CGFloat = 3, prefixGap: CGFloat = 4, clusterGap: CGFloat = 7
        // 11 pt mark, matching the compact bar and still inside the 20 pt image.
        let glyph: CGFloat = 11, glyphGap: CGFloat = 3
        let height: CGFloat = 20
        let rowCenterTop = height - 6, rowCenterBot: CGFloat = 6

        func width(_ s: String, _ a: [NSAttributedString.Key: Any]) -> CGFloat {
            NSAttributedString(string: s, attributes: a).size().width
        }
        let labelW = max(width("5h", rowLabelAttrs), width("7d", rowLabelAttrs))
        func numW(_ c: Cluster) -> CGFloat { max(width(c.num5, numAttrs), width(c.num7, numAttrs)) }
        func prefixW(_ c: Cluster) -> CGFloat { width(c.prefix, prefixAttrs) }
        func clusterW(_ c: Cluster) -> CGFloat {
            (c.shape == nil ? 0 : glyph + glyphGap)
                + prefixW(c) + prefixGap + labelW + gap + barW + gap + numW(c)
        }

        var total: CGFloat = 0
        for (i, c) in clusters.enumerated() {
            if i > 0 { total += clusterGap + 0.5 + clusterGap }
            total += clusterW(c)
        }
        total = ceil(total) + 2

        let image = NSImage(size: NSSize(width: max(total, 1), height: height), flipped: false) { _ in
            var x: CGFloat = 1
            for (i, c) in clusters.enumerated() {
                if i > 0 {
                    x += clusterGap
                    NSColor.tertiaryLabelColor.withAlphaComponent(0.4).setFill()
                    NSBezierPath(rect: NSRect(x: x, y: 3, width: 0.5, height: height - 6)).fill()
                    x += 0.5 + clusterGap
                }
                if let shape = c.shape {
                    // Always a provider mark here, so `severity` is ignored: the mark keeps
                    // its brand/label color and the bars below carry the level color.
                    shape.draw(in: NSRect(x: x, y: (height - glyph) / 2, width: glyph, height: glyph),
                               severity: .labelColor)
                    x += glyph + glyphGap
                }
                let pfx = NSAttributedString(string: c.prefix, attributes: prefixAttrs)
                pfx.draw(at: NSPoint(x: x, y: (height - pfx.size().height) / 2))
                x += pfx.size().width + prefixGap

                let clusterX = x
                func drawRow(_ label: String, pct: Int?, num: String, cy: CGFloat) {
                    var rx = clusterX
                    let lbl = NSAttributedString(string: label, attributes: rowLabelAttrs)
                    lbl.draw(at: NSPoint(x: rx, y: cy - lbl.size().height / 2))
                    rx += labelW + gap

                    let track = NSRect(x: rx, y: cy - barH / 2, width: barW, height: barH)
                    NSColor.tertiaryLabelColor.withAlphaComponent(0.28).setFill()
                    NSBezierPath(roundedRect: track, xRadius: barH / 2, yRadius: barH / 2).fill()
                    if let pct, pct > 0 {
                        let w = max(barW * CGFloat(min(pct, 100)) / 100, barH)
                        levelColor(pct).setFill()
                        NSBezierPath(roundedRect: NSRect(x: rx, y: cy - barH / 2, width: w, height: barH),
                                     xRadius: barH / 2, yRadius: barH / 2).fill()
                    }
                    rx += barW + gap
                    let numStr = NSAttributedString(string: num, attributes: numAttrs)
                    numStr.draw(at: NSPoint(x: rx, y: cy - numStr.size().height / 2))
                }
                drawRow("5h", pct: c.p5, num: c.num5, cy: rowCenterTop)
                drawRow("7d", pct: c.p7, num: c.num7, cy: rowCenterBot)
                x = clusterX + labelW + gap + barW + gap + numW(c)
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
