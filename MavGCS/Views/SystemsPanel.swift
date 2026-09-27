import MavlinkCore
import SwiftUI
import UIKit

/// Every subsystem the autopilot reports on, side by side: the Systems strip
/// of the desktop and Android builds, cell for cell and colour for colour.
///
/// It sits between the HUD and the data fields and takes only the height its
/// labels need, since every point it takes comes out of the HUD.
struct SystemsPanel: View {
    let systems: [SystemStatus]

    static let height: CGFloat = 26

    private static let gap: CGFloat = 3
    private static let inset: CGFloat = 4
    private static let cellBorder = Color(hex: 0x3A3D42)

    /// The desktop's and Android's cell text is 10 pt bold. A phone's column
    /// is narrower than their panels, so this is the condensed cut of the
    /// same face, which fits RNGFND at full size on most phones; on the
    /// narrowest the whole strip steps down together, never one cell alone.
    private static let fullSize: CGFloat = 10
    private static let widestLabel: CGFloat = {
        let font = UIFont.systemFont(ofSize: fullSize, weight: .bold, width: .condensed)
        let widths = SystemHealth.noTelemetry.map { ($0.label as NSString).size(withAttributes: [.font: font]).width }
        return widths.max() ?? 35
    }()

    var body: some View {
        GeometryReader { geometry in
            let count = CGFloat(max(systems.count, 1))
            let cellWidth = (geometry.size.width - 2 * Self.inset - (count - 1) * Self.gap) / count
            // A point of air either side of the widest label.
            let size = min(Self.fullSize, Self.fullSize * (cellWidth - 2) / Self.widestLabel)
            HStack(spacing: Self.gap) {
                ForEach(systems, id: \.label) { system in
                    let colours = Self.colours(system.state)
                    Text(verbatim: system.label)
                        .font(.system(size: size, weight: .bold))
                        .fontWidth(.condensed)
                        .foregroundStyle(colours.text)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(colours.background, in: RoundedRectangle(cornerRadius: 3))
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Self.cellBorder, lineWidth: 1))
                        .accessibilityLabel(Text(verbatim: "\(system.label), \(system.detail)"))
                }
            }
            .padding(Self.inset)
        }
        .frame(height: Self.height)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    /// The colours the EKF and VIBE words use elsewhere, so a red here means
    /// what a red there means.
    private static func colours(_ state: HealthState) -> (text: Color, background: Color) {
        switch state {
        // Not reported present at all: nothing fitted, or this autopilot does
        // not say. Dim, because it is not a fault.
        case .absent: (Color(hex: 0x5C6066), Color(hex: 0x1C1E21))
        // Fitted but switched off. Cool rather than warm on purpose: amber is
        // kept for something actually going wrong, and a disabled airspeed
        // sensor is a decision, not a warning.
        case .off: (Color(hex: 0x7D8EA0), Color(hex: 0x1A1F24))
        case .ok: (Palette.green, Color(hex: 0x172117))
        case .warn: (Color(hex: 0xD8A23A), Color(hex: 0x241F16))
        case .failed: (Color(hex: 0xFF5555), Color(hex: 0x2A1616))
        }
    }
}
