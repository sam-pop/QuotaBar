import Foundation

/// Popover width rules for the account matrix. Pure so the numbers are unit-tested
/// rather than eyeballed in a MenuBarExtra window.
enum PopoverLayout {
    /// Single-account layout width (unchanged historical value).
    static let singleAccountWidth: CGFloat = 320
    /// Breathing room kept between the popover and the screen's visible edges.
    static let screenMargin: CGFloat = 40

    /// The widest matrix drawn inline on a screen `visibleWidth` wide; wider matrices scroll.
    static func maxInlineWidth(visibleWidth: CGFloat) -> CGFloat {
        max(visibleWidth - screenMargin, singleAccountWidth)
    }

    /// Popover width for `accountCount` accounts whose matrix needs `matrixOuterWidth` points.
    static func width(accountCount: Int, matrixOuterWidth: CGFloat, visibleWidth: CGFloat) -> CGFloat {
        accountCount <= 1
            ? singleAccountWidth
            : min(matrixOuterWidth, maxInlineWidth(visibleWidth: visibleWidth))
    }

    /// Whether the matrix must scroll horizontally on this screen.
    static func scrolls(matrixOuterWidth: CGFloat, visibleWidth: CGFloat) -> Bool {
        matrixOuterWidth > maxInlineWidth(visibleWidth: visibleWidth)
    }
}
