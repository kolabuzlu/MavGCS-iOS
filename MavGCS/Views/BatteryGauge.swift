import SwiftUI

/// The battery left, as a plain bar standing in the strip down the screen's
/// left-hand edge: a green fill that runs down with the pack, gliding from
/// one reading to the next rather than jumping, with faint marks at the
/// quarters.
///
/// Empty until the vehicle reports a percentage.
struct BatteryGauge: View {
    /// 0...100, or nil before the vehicle has said.
    let percent: Int?

    /// How long the fill takes to settle on a new reading: slow enough to
    /// read as the pack running down, not the number changing.
    static let glide = 1.5

    private var fraction: CGFloat {
        CGFloat(min(max(percent ?? 0, 0), 100)) / 100
    }

    var body: some View {
        GeometryReader { geometry in
            let inner = CGSize(width: geometry.size.width - 4, height: geometry.size.height - 4)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.white.opacity(0.06))
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(.white.opacity(0.3), lineWidth: 1)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Palette.green)
                    .frame(width: inner.width, height: inner.height * fraction)
                    .padding(.bottom, 2)
                    .animation(.easeInOut(duration: Self.glide), value: fraction)
                // Quarter marks, seen only where the fill runs past them.
                ForEach([0.25, 0.5, 0.75], id: \.self) { mark in
                    Rectangle()
                        .fill(Palette.background.opacity(0.55))
                        .frame(width: inner.width, height: 1)
                        .padding(.bottom, 2 + inner.height * mark)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery")
        .accessibilityValue(percent.map { "\($0) percent" } ?? "Not known")
    }
}
