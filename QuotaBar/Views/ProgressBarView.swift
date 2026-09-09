import SwiftUI

struct ProgressBarView: View {
    let percent: Int
    let color: Color
    /// The per-model lines inside the matrix's 7-Day cell use a thinner bar; everything else
    /// keeps the original 10 pt.
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(color.opacity(0.12))

                RoundedRectangle(cornerRadius: 5)
                    .fill(color.gradient)
                    .frame(width: geo.size.width * clampedFraction)
                    .shadow(color: color.opacity(0.3), radius: 4, x: 0, y: 0)
                    .animation(.easeInOut(duration: 0.5), value: percent)
            }
        }
        .frame(height: height)
    }

    private var clampedFraction: CGFloat {
        CGFloat(min(max(percent, 0), 100)) / 100.0
    }
}
