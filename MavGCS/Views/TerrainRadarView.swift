import SwiftUI
import TerrainCore

/// Forward-looking terrain awareness, EGPWS-style: a track-up fan of the
/// ground ahead, coloured by how much clearance there is beneath the
/// aircraft rather than by height, so the colour answers the only question
/// that matters. Ground more than the scale below is left unpainted, which is
/// why a safe picture is mostly empty.
///
/// The desktop's widget (map_view.py) by way of the Android build's: laid out
/// in the same 200-unit space and scaled to whatever size it is given, so the
/// geometry below reads straight across from both.
struct TerrainRadarView: View {
    let radar: TerrainRadar
    var size: CGFloat = 200

    @State private var editingScale = false
    @State private var scaleText = ""

    static let chipBlue = Color(hex: 0x37A8DB)

    /// Smaller than the Android build ever draws it (150 dp), the chips and
    /// the writing come down with the rest. At their full size the two chips
    /// alone would take up most of the width.
    private var compact: Bool { size < 150 }

    var body: some View {
        // Read here rather than inside the Canvas, so a change to any of them
        // redraws it.
        let fan = radar.fan
        let altMslM = radar.altMslM
        let painter = fan.flatMap { fan in
            altMslM.map {
                FanPainter(fan: fan, altMslM: $0, slope: radar.slope, predictive: radar.predictive, scaleM: radar.scaleM, compact: compact)
            }
        }
        ZStack {
            if let painter {
                Canvas { context, canvasSize in
                    painter.draw(&context, size: canvasSize)
                }
            } else {
                Text(placeholder)
                    .font(.system(size: compact ? 9 : 11))
                    .foregroundStyle(Color(hex: 0x888888))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, compact ? 4 : 8)
            }
        }
        .frame(width: size, height: size)
        .background(Color(hex: 0x1E1E1E, opacity: 0.75))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08), lineWidth: 1))
        // An instrument, not more map: a tap on it is not a place to fly to.
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture {}
        .overlay(alignment: .topLeading) {
            chip("\(Int(radar.scaleM.rounded()))m") {
                scaleText = "\(Int(radar.scaleM.rounded()))"
                editingScale = true
            }
        }
        .overlay(alignment: .topTrailing) {
            chip(radar.predictive ? "PRED" : "REL") {
                radar.predictive.toggle()
            }
        }
        .alert("Clearance scale", isPresented: $editingScale) {
            TextField("Metres", text: $scaleText)
                .keyboardType(.decimalPad)
            Button("Cancel", role: .cancel) {}
            Button("Apply") { applyScale() }
        } message: {
            Text(verbatim: "Metres (\(Int(TerrainClearance.scaleMinM))–\(Int(TerrainClearance.scaleMaxM)))")
        }
    }

    private var placeholder: String {
        switch radar.activity {
        case .downloading: "Downloading terrain…"
        case .retrying: "Terrain download failed - retrying"
        case .idle: "Terrain Radar - no data"
        }
    }

    /// "120", "120m" and " 120 m" alike, as the desktop takes them.
    private func applyScale() {
        guard let value = Float(scaleText.filter { $0.isNumber || $0 == "." }), value > 0 else { return }
        radar.scaleM = min(max(value, TerrainClearance.scaleMinM), TerrainClearance.scaleMaxM)
    }

    private func chip(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            let corner: CGFloat = compact ? 5 : 6
            Text(text)
                .font(.system(size: compact ? 9 : 12, weight: .bold))
                .foregroundStyle(Self.chipBlue)
                .padding(.horizontal, compact ? 5 : 8)
                .padding(.vertical, compact ? 1 : 2)
                .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: corner))
                .overlay(RoundedRectangle(cornerRadius: corner).strokeBorder(Self.chipBlue.opacity(0.4), lineWidth: 1))
                // The chip's own margin is part of what can be pressed: a
                // chip this small is a hard target for a thumb.
                .padding(compact ? 3 : 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The fan itself, in the desktop's 200-unit space.
private struct FanPainter {
    let fan: TerrainFan
    let altMslM: Float
    let slope: Double
    let predictive: Bool
    let scaleM: Float
    let compact: Bool

    static let side: CGFloat = 200
    static let ringR: CGFloat = 6
    /// The aircraft sits near the bottom edge; the fan opens upwards from it.
    static let apexY: CGFloat = side - ringR - 3
    /// Radius of the fan's outer arc.
    static let radius: CGFloat = apexY - 6
    /// How far each cell is grown past its neighbours, in points: about a
    /// pixel. Two antialiased edges meeting on the same line each cover their
    /// pixel about half way, so without an overlap the seams read as a dark
    /// grid over the fan. The Android build's 0.4 of its 200 units comes to
    /// this at full size; held in points, it stays a pixel at any size.
    static let bleedPoints: CGFloat = 0.37

    /// Red through orange and yellow to green, over the clearance scale.
    static let ramp: [(red: Double, green: Double, blue: Double)] = [
        (231, 76, 60), (230, 126, 34), (241, 196, 15), (46, 204, 113),
    ]

    func draw(_ context: inout GraphicsContext, size: CGSize) {
        let unit = size.width / Self.side
        let half = TerrainSampler.halfAngleDeg * .pi / 180
        let ang = fan.angCells
        let rad = fan.radCells

        func point(_ theta: Double, _ distance: Double) -> CGPoint {
            let r = CGFloat(distance / fan.rangeM) * Self.radius
            return CGPoint(
                x: (Self.side / 2 + r * CGFloat(sin(theta))) * unit,
                y: (Self.apexY - r * CGFloat(cos(theta))) * unit
            )
        }
        func theta(_ step: Int) -> Double {
            -half + 2 * half * Double(step) / Double(ang)
        }
        let apex = CGPoint(x: Self.side / 2 * unit, y: Self.apexY * unit)

        // Cells, from the aircraft outwards. The whole group is composited at
        // 0.85 rather than each cell on its own, as the desktop does: painted
        // one at a time, every shared edge would come out more transparent
        // than the cells it joins, and the map would show through as a grid.
        let bleed = Self.bleedPoints / unit
        let bleedM = Double(bleed / Self.radius) * fan.rangeM
        var cells = context
        cells.opacity = 0.85
        cells.drawLayer { layer in
            for a in 0..<ang {
                for b in 0..<rad {
                    guard let fraction = TerrainClearance.fraction(
                        elevation: fan.elevation(angular: a, radial: b),
                        distanceM: fan.distanceOf(radial: b),
                        altMslM: altMslM,
                        slope: slope,
                        predictive: predictive,
                        scaleM: scaleM
                    ) else { continue }

                    let inner = max(fan.rangeM * Double(b) / Double(rad) - bleedM, 0)
                    let outer = fan.rangeM * Double(b + 1) / Double(rad) + bleedM
                    // Angular bleed is taken at the outer edge, so the overlap
                    // stays the same width along the cell rather than fanning
                    // out with it.
                    let spread = Double(bleed / (CGFloat(outer / fan.rangeM) * Self.radius))
                    var path = Path()
                    path.move(to: point(theta(a) - spread, inner))
                    path.addLine(to: point(theta(a + 1) + spread, inner))
                    path.addLine(to: point(theta(a + 1) + spread, outer))
                    path.addLine(to: point(theta(a) - spread, outer))
                    path.closeSubpath()
                    layer.fill(path, with: .color(Self.colour(fraction)))
                }
            }
        }

        // Range arcs at thirds, with the distance written on each.
        for k in 1...3 {
            let distance = fan.rangeM * Double(k) / 3
            var arc = Path()
            arc.move(to: point(theta(0), distance))
            for s in 1...ang {
                arc.addLine(to: point(theta(s), distance))
            }
            context.stroke(arc, with: .color(.white.opacity(0.22)), lineWidth: unit)

            // Small, the chips take the whole strip across the top, where the
            // outer ring's figure would go. The inner two give the range as
            // well: the outer ring is always half as far again as the middle.
            if compact && k == 3 { continue }
            let r = CGFloat(distance / fan.rangeM) * Self.radius
            // Verbatim, or the locale's grouping turns 1200 into "1.200",
            // which reads as a kilometre and a bit.
            context.draw(
                Text(verbatim: "\(Int(distance.rounded()))")
                    .font(.system(size: compact ? 7 : 9))
                    .foregroundStyle(Color(hex: 0xB8B8B8)),
                at: CGPoint(x: (Self.side / 2 + 3) * unit, y: (Self.apexY - r) * unit),
                anchor: .leading
            )
        }

        // The fan's two edges, and the nose line straight up the middle. The
        // fan is already track-up, so the heading is always vertical.
        var edges = Path()
        edges.move(to: apex)
        edges.addLine(to: point(-half, fan.rangeM))
        edges.move(to: apex)
        edges.addLine(to: point(half, fan.rangeM))
        context.stroke(edges, with: .color(.white.opacity(0.28)), lineWidth: unit)

        var nose = Path()
        nose.move(to: apex)
        nose.addLine(to: point(0, fan.rangeM))
        context.stroke(
            nose,
            with: .color(.white.opacity(0.35)),
            style: StrokeStyle(lineWidth: unit, dash: [4 * unit, 3 * unit])
        )

        // The aircraft.
        let ring = Path(ellipseIn: CGRect(x: apex.x - Self.ringR * unit, y: apex.y - Self.ringR * unit, width: 2 * Self.ringR * unit, height: 2 * Self.ringR * unit))
        context.fill(ring, with: .color(Color(hex: 0x37A8DB, opacity: 0x40 / 255)))
        context.stroke(ring, with: .color(.white), lineWidth: 2 * unit)
        let dot = Path(ellipseIn: CGRect(x: apex.x - 3 * unit, y: apex.y - 3 * unit, width: 6 * unit, height: 6 * unit))
        context.fill(dot, with: .color(.white))
        context.stroke(dot, with: .color(Color(hex: 0x1A1A1A)), lineWidth: unit)
    }

    /// A point on the ramp, 0 red to 1 green, blended as the desktop blends.
    static func colour(_ fraction: Float) -> Color {
        let x = Double(min(max(fraction, 0), 1)) * Double(ramp.count - 1)
        let index = min(Int(x), ramp.count - 2)
        let f = x - Double(index)
        let a = ramp[index]
        let b = ramp[index + 1]
        return Color(
            .sRGB,
            red: (a.red + (b.red - a.red) * f) / 255,
            green: (a.green + (b.green - a.green) * f) / 255,
            blue: (a.blue + (b.blue - a.blue) * f) / 255
        )
    }
}
