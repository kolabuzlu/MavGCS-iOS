import SwiftUI

/// MavGCS's colours, the Android build's own.
///
/// Neutral dark greys, matching the desktop, with one green for everything
/// that means live, engaged or healthy. The Android palette went through a
/// round of near-miss greens that read as a rendering fault rather than a
/// palette, so there is exactly one here and everything mixes from it.
nonisolated enum Palette {
    static let background = Color(hex: 0x1E1E1E)
    static let surface = Color(hex: 0x252526)
    static let surfaceVariant = Color(hex: 0x2E2E30)
    static let onSurface = Color(hex: 0xE6E6E6)
    static let onSurfaceVariant = Color(hex: 0xB0B0B4)
    static let outline = Color(hex: 0x454549)

    static let green = Color(hex: 0x5CCF5C)
    static let onGreen = Color(hex: 0x04210F)
    static let red = Color(hex: 0xC0392B)
    /// Fly-to and the other "go there" actions.
    static let blue = Color(hex: 0x1E6FD9)
    static let cyan = Color(hex: 0x4FC3F7)
    /// A request sent and not yet confirmed.
    static let amber = Color(hex: 0xD8B400)
    static let onAmber = Color(hex: 0x2A2200)

    static let hudYellow = Color(hex: 0xFFD54F)
    static let sky = Color(hex: 0x3A6EA5)
    static let ground = Color(hex: 0x8B5A2B)
    static let tape = Color(hex: 0x141414, opacity: 0.8)
    static let hudText = Color(hex: 0xE6E6E6)
    static let windArrow = Color(hex: 0x78DCFF)

    /// Map furniture: dark and translucent like the attribution, so it reads
    /// as part of the map rather than a piece of the panel that has drifted
    /// onto the imagery.
    static let mapChip = Color.black.opacity(0.55)
    static let mapReadout = Color(hex: 0xCFD8E0)

    /// How strongly the ARM button hints at readiness: far dimmer than
    /// armed, since "it would work" and "the propellers are live" must never
    /// be mistaken for each other at a glance.
    static let armStateTint = 0.22
}

/// The corner every command button shares.
let controlCorner: CGFloat = 6

extension Color {
    nonisolated init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// This colour at [amount] strength laid over [base], as one opaque colour.
    func mixed(over base: Color, amount: Double) -> Color {
        let top = UIColor(self)
        let bottom = UIColor(base)
        var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        top.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        bottom.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return Color(
            .sRGB,
            red: r2 + (r1 - r2) * amount,
            green: g2 + (g1 - g2) * amount,
            blue: b2 + (b1 - b2) * amount
        )
    }
}

/// A figure, or two dashes for a reading that has not arrived.
func readout(_ value: Float?, digits: Int) -> String {
    guard let value, value.isFinite else { return "--" }
    return String(format: "%.\(digits)f", value)
}

func readout(_ value: Double?, digits: Int) -> String {
    guard let value, value.isFinite else { return "--" }
    return String(format: "%.\(digits)f", value)
}

let msToKph: Float = 3.6
