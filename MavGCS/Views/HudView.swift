import MavlinkCore
import SwiftUI

/// The desktop HUD, as the Android build draws it: an artificial horizon
/// with an airspeed tape on the left, an altitude tape on the right, a
/// heading strip along the top, throttle and vertical speed columns inboard
/// of the tapes, and the wind and battery readouts in the upper corners.
struct HudView: View {
    let vehicle: VehicleState
    @Binding var cells: Int

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 220
            // Room for the wind and the battery side by side between the
            // columns. On the narrowest phones there is not, and the battery
            // block would sit on top of the wind.
            let roomy = geometry.size.width - 2 * (Hud.tapeWidth + Hud.sideBarWidth) >= 212
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    HudDrawing(vehicle: vehicle, size: size).draw(in: &context)
                }

                // Wind, in the top left corner the desktop puts it in, below
                // the heading strip rather than beside it: this strip runs the
                // whole way across. Where that corner is needed by the battery
                // it drops to the bottom left, which the horizon leaves free.
                WindBox(
                    fromDeg: vehicle.windDirectionDeg,
                    speedMs: vehicle.windSpeedMs,
                    headingDeg: vehicle.headingDeg ?? vehicle.yawDeg,
                    compact: compact
                )
                .padding(.leading, Hud.tapeWidth + Hud.sideBarWidth + Hud.cornerInset)
                .padding(.top, roomy ? Hud.headingStripHeight + Hud.cornerInset : 0)
                .padding(.bottom, roomy ? 0 : Hud.cornerInset)
                .frame(maxHeight: .infinity, alignment: roomy ? .top : .bottom)

                // Battery, in the corner opposite the wind.
                BatteryBlock(vehicle: vehicle, cells: $cells, compact: compact)
                    .padding(.trailing, Hud.tapeWidth + Hud.sideBarWidth + Hud.cornerInset)
                    .padding(.top, Hud.headingStripHeight + Hud.cornerInset)
                    .frame(maxWidth: .infinity, alignment: .topTrailing)

                // Mission Planner's own convention, as on the desktop: bottom
                // middle, EKF left of centre and VIBE right of it, just the
                // coloured word and no value.
                HStack(spacing: 4) {
                    StatusWord(label: "EKF", tint: vehicle.ekfTint, compact: compact)
                    StatusWord(label: "VIBE", tint: vehicle.vibeTint, compact: compact)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, compact ? 3 : 5)

                // Full white: these name the tapes, so they read at a glance
                // even though the sliding numbers beside them are faint.
                VStack {
                    Spacer()
                    HStack {
                        Text("IAS m/s")
                        Spacer()
                        Text("ALT m")
                    }
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .padding(.bottom, compact ? 12 : 18)
                }
            }
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Measurements the canvas and the overlays share.
enum Hud {
    static let tapeWidth: CGFloat = 34
    /// The throttle and vertical speed columns inboard of the tapes.
    static let sideBarWidth: CGFloat = 12
    static let headingStripHeight: CGFloat = 16
    static let cornerInset: CGFloat = 5
    static let pointerHeight: CGFloat = 15
    /// Degrees of pitch from the centre of the horizon to the top of the HUD.
    static let pitchHalfRangeDeg: CGFloat = 35
    /// Degrees of heading across the width of the heading strip.
    static let headingSpanDeg: CGFloat = 90
    /// What a full vertical speed deflection means, up or down.
    static let vsiFullScaleMs: Float = 10
    static let labelFont = Font.system(size: 9, weight: .medium)
}

private struct HudDrawing {
    let vehicle: VehicleState
    let size: CGSize

    func draw(in context: inout GraphicsContext) {
        drawHorizon(&context, roll: CGFloat(vehicle.rollDeg ?? 0), pitch: CGFloat(vehicle.pitchDeg ?? 0))
        drawTape(&context, value: vehicle.airSpeedMs, tickStep: 2, labelStep: 10, perUnit: 3.2, onLeft: true)
        drawTape(&context, value: vehicle.altRelM, tickStep: 5, labelStep: 20, perUnit: 1.1, onLeft: false)
        drawHeadingStrip(&context, heading: CGFloat(vehicle.headingDeg ?? vehicle.yawDeg ?? 0))
        drawThrottle(&context, percent: vehicle.throttlePct)
        drawVerticalSpeed(&context, climb: vehicle.climbMs)
    }

    private func label(_ text: String, opacity: Double = 1) -> Text {
        Text(text).font(Hud.labelFont).foregroundColor(Palette.hudText.opacity(opacity))
    }

    private func line(_ context: inout GraphicsContext, _ from: CGPoint, _ to: CGPoint, _ color: Color, _ width: CGFloat) {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        context.stroke(path, with: .color(color), lineWidth: width)
    }

    private func drawHorizon(_ context: inout GraphicsContext, roll: CGFloat, pitch: CGFloat) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let perDeg = size.height / (2 * Hud.pitchHalfRangeDeg)
        // Large enough that sky and ground still cover the HUD at any roll.
        let span = max(size.width, size.height) * 1.6

        var world = context
        world.translateBy(x: center.x, y: center.y)
        // Rolling right drops the right wing, so the world tips the other way
        // in the aircraft's frame.
        world.rotate(by: .degrees(Double(-roll)))
        // Nose up pushes the horizon down.
        world.translateBy(x: 0, y: min(max(pitch, -90), 90) * perDeg)
        world.fill(Path(CGRect(x: -span, y: -span, width: span * 2, height: span)), with: .color(Palette.sky))
        world.fill(Path(CGRect(x: -span, y: 0, width: span * 2, height: span)), with: .color(Palette.ground))
        line(&world, CGPoint(x: -span, y: 0), CGPoint(x: span, y: 0), .white, 1.5)
        for degrees in [-30, -20, -10, 10, 20, 30] {
            // Positive pitch marks sit above the horizon.
            let y = -CGFloat(degrees) * perDeg
            let half = size.width * (degrees % 20 == 0 ? 0.11 : 0.07)
            line(&world, CGPoint(x: -half, y: y), CGPoint(x: half, y: y), .white.opacity(0.85), 1)
            world.draw(label("\(degrees)"), at: CGPoint(x: -half - 3, y: y), anchor: .trailing)
        }

        // The aircraft, fixed.
        let wing = size.width * 0.13
        line(&context, CGPoint(x: center.x - wing, y: center.y), CGPoint(x: center.x - 7, y: center.y), Palette.hudYellow, 2.5)
        line(&context, CGPoint(x: center.x + 7, y: center.y), CGPoint(x: center.x + wing, y: center.y), Palette.hudYellow, 2.5)
        context.fill(Path(ellipseIn: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)), with: .color(Palette.hudYellow))
    }

    /// A sliding tape. The scale moves past a fixed pointer, rather than the
    /// pointer moving along a fixed scale.
    private func drawTape(_ context: inout GraphicsContext, value: Float?, tickStep: CGFloat, labelStep: CGFloat, perUnit: CGFloat, onLeft: Bool) {
        let width = Hud.tapeWidth
        let left = onLeft ? 0 : size.width - width
        let centerY = size.height / 2
        context.fill(Path(CGRect(x: left, y: 0, width: width, height: size.height)), with: .color(Palette.tape))

        // A reading that is not a number is no reading. Turned into a whole
        // number for the pointer box, NaN would bring the app down.
        let value = value.flatMap { $0.isFinite ? $0 : nil }
        let current = CGFloat(value ?? 0)
        let halfSpan = centerY / perUnit
        var tick = ((current - halfSpan) / tickStep).rounded(.down) * tickStep
        while tick <= current + halfSpan {
            let y = centerY - (tick - current) * perUnit
            let ratio = tick / labelStep
            let labelled = abs(ratio - ratio.rounded()) < 0.01
            let length: CGFloat = labelled ? 8 : 4
            let start = onLeft ? left + width - length : left
            line(&context, CGPoint(x: start, y: y), CGPoint(x: start + length, y: y), Palette.hudText.opacity(0.75), 1)
            // The sliding numbers are context, not the reading, so they are
            // drawn faint. The value in the pointer box keeps full strength.
            if labelled && tick >= 0 {
                let text = label("\(Int(tick.rounded()))", opacity: 0.32)
                if onLeft {
                    context.draw(text, at: CGPoint(x: left + 2, y: y), anchor: .leading)
                } else {
                    context.draw(text, at: CGPoint(x: left + width - 2, y: y), anchor: .trailing)
                }
            }
            tick += tickStep
        }

        let box = CGRect(x: left, y: centerY - Hud.pointerHeight / 2, width: width, height: Hud.pointerHeight)
        context.fill(Path(box), with: .color(.black))
        context.stroke(Path(box), with: .color(Palette.hudYellow), lineWidth: 1.2)
        let text = value.map { "\(Int($0.rounded()))" } ?? "--"
        context.draw(label(text), at: CGPoint(x: box.midX, y: box.midY), anchor: .center)
    }

    private func drawHeadingStrip(_ context: inout GraphicsContext, heading: CGFloat) {
        let height = Hud.headingStripHeight
        // Between the tapes rather than over them, so the span it covers is
        // the width left in the middle.
        let left = Hud.tapeWidth + Hud.sideBarWidth
        let right = size.width - Hud.tapeWidth - Hud.sideBarWidth
        let spanWidth = right - left
        guard spanWidth > 0 else { return }
        context.fill(Path(CGRect(x: left, y: 0, width: spanWidth, height: height)), with: .color(Palette.tape))

        let perDeg = spanWidth / Hud.headingSpanDeg
        let centerX = left + spanWidth / 2
        let half = Hud.headingSpanDeg / 2
        var strip = context
        // Clipped so a label at the edge slides off under the tape rather
        // than being drawn across it.
        strip.clip(to: Path(CGRect(x: left, y: 0, width: spanWidth, height: height)))
        var degrees = ((heading - half) / 10).rounded(.down) * 10
        while degrees <= heading + half {
            let x = centerX + (degrees - heading) * perDeg
            line(&strip, CGPoint(x: x, y: height - 4), CGPoint(x: x, y: height), Palette.hudText.opacity(0.75), 1)
            // Labelled every 30 degrees as a compass reads; ticks every 10.
            let wrapped = (Int(degrees.rounded()) % 360 + 360) % 360
            if wrapped % 30 == 0 {
                let name: String
                switch wrapped {
                case 0: name = "N"
                case 90: name = "E"
                case 180: name = "S"
                case 270: name = "W"
                default: name = String(format: "%03d", wrapped)
                }
                strip.draw(label(name), at: CGPoint(x: x, y: 1), anchor: .top)
            }
            degrees += 10
        }
        line(&context, CGPoint(x: centerX, y: 0), CGPoint(x: centerX, y: height), Palette.hudYellow, 1.5)
    }

    /// Throttle as a column filling from the bottom. A bar rather than a
    /// number: what matters in the air is whether it is pinned or backing
    /// off, and that is a shape, read without stopping to parse a figure.
    private func drawThrottle(_ context: inout GraphicsContext, percent: Int?) {
        let width = Hud.sideBarWidth
        let left = Hud.tapeWidth
        context.fill(Path(CGRect(x: left, y: 0, width: width, height: size.height)), with: .color(Palette.tape))
        let inset: CGFloat = 2
        let track = size.height - inset * 2
        if let percent {
            let filled = track * CGFloat(min(max(percent, 0), 100)) / 100
            context.fill(
                Path(CGRect(x: left + inset, y: inset + track - filled, width: width - inset * 2, height: filled)),
                with: .color(Palette.green)
            )
        }
        // Stays up with no reading, showing a dash: an instrument that is
        // merely waiting looks like a missing one if it disappears.
        let boxWidth: CGFloat = 30
        let box = CGRect(x: left + width, y: size.height / 2 - Hud.pointerHeight / 2, width: boxWidth, height: Hud.pointerHeight)
        context.fill(Path(box), with: .color(.black))
        context.stroke(Path(box), with: .color(Palette.green), lineWidth: 1.2)
        context.draw(label(percent.map { "\(min(max($0, 0), 100))%" } ?? "--"), at: CGPoint(x: box.midX, y: box.midY), anchor: .center)
    }

    /// Vertical speed as a needle either side of a centre line. What the
    /// pilot needs mid-circuit is whether the aeroplane is going up or down
    /// and roughly how hard, and a needle answers that without being read.
    private func drawVerticalSpeed(_ context: inout GraphicsContext, climb: Float?) {
        let width = Hud.sideBarWidth
        let left = size.width - Hud.tapeWidth - width
        context.fill(Path(CGRect(x: left, y: 0, width: width, height: size.height)), with: .color(Palette.tape))
        let inset: CGFloat = 2
        let track = size.height - inset * 2
        let centerY = inset + track / 2
        // The datum, drawn whether or not there is a reading, so the column
        // is an instrument waiting for data rather than a blank strip.
        line(&context, CGPoint(x: left, y: centerY), CGPoint(x: left + width, y: centerY), .white.opacity(0.35), 1)
        if let climb {
            let clamped = min(max(climb, -Hud.vsiFullScaleMs), Hud.vsiFullScaleMs)
            let travel = CGFloat(clamped / Hud.vsiFullScaleMs) * track / 2
            let y = centerY - travel
            context.fill(
                Path(CGRect(x: left + inset, y: min(centerY, y), width: width - inset * 2, height: abs(travel))),
                with: .color(Palette.hudYellow.opacity(0.5))
            )
            line(&context, CGPoint(x: left + inset, y: y), CGPoint(x: left + width - inset, y: y), Palette.hudYellow, 2)
        }
        // Signed, because which way it is going is the whole point.
        let text = climb.map { ($0 > 0.05 ? "+" : "") + String(format: "%.1f", $0) } ?? "--"
        let boxWidth: CGFloat = 32
        let box = CGRect(x: left - boxWidth, y: centerY - Hud.pointerHeight / 2, width: boxWidth, height: Hud.pointerHeight)
        context.fill(Path(box), with: .color(.black))
        context.stroke(Path(box), with: .color(Palette.hudYellow), lineWidth: 1.2)
        context.draw(label(text), at: CGPoint(x: box.midX, y: box.midY), anchor: .center)
    }
}

/// One of the HUD's two status words, in the desktop's colours.
///
/// White is the quiet state, and also what shows before any report has
/// arrived: the word is always there, so its going missing could never be
/// mistaken for good news.
private struct StatusWord: View {
    let label: String
    let tint: HealthTint?
    let compact: Bool

    var body: some View {
        Text(label)
            .font(.system(size: compact ? 7 : 8, weight: .bold))
            .foregroundStyle(color)
            .frame(width: compact ? 40 : 44, height: compact ? 13 : 15)
            .background(Color(.sRGB, red: 15 / 255, green: 15 / 255, blue: 15 / 255, opacity: 210 / 255))
            .overlay(Rectangle().stroke(Color.white, lineWidth: 1))
    }

    private var color: Color {
        switch tint {
        case .red: return Color(hex: 0xFF3C3C)
        case .yellow: return Color(hex: 0xFFFF00)
        case .white, nil: return .white
        }
    }
}

/// Wind speed and direction, with an arrow drawn in the aircraft's frame.
///
/// The arrow points where the wind is blowing toward: flying into a
/// headwind it points down the screen, the way the air is pushing the
/// aeroplane. WIND reports where the wind comes from, so that is a half
/// turn, and subtracting the heading swings it into the nose's frame. The
/// figure stays in degrees true, because that is what gets compared with
/// the forecast; only the arrow is relative.
private struct WindBox: View {
    let fromDeg: Float?
    let speedMs: Float?
    let headingDeg: Float?
    let compact: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.up")
                .font(.system(size: compact ? 12 : 14, weight: .bold))
                .foregroundStyle(Palette.windArrow)
                // No reading yet: the arrow rests pointing up rather than
                // vanishing, so the box keeps its shape.
                .rotationEffect(.degrees(Double(turn)))
                .frame(width: compact ? 14 : 18, height: compact ? 14 : 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(fromDeg.map { String(format: "%03d°", Int($0.rounded()) % 360) } ?? "---°")
                    .font(.system(size: compact ? 9 : 10, weight: .semibold))
                    .foregroundStyle(Palette.hudText)
                Text(speedMs.map { String(format: "%.1f kph", $0 * msToKph) } ?? "-- kph")
                    .font(.system(size: compact ? 7 : 8))
                    .foregroundStyle(Palette.hudText.opacity(0.7))
            }
        }
        .monospacedDigit()
        .padding(.horizontal, 5)
        .padding(.vertical, compact ? 2 : 3)
        .background(Palette.tape, in: RoundedRectangle(cornerRadius: 5))
    }

    private var turn: Float {
        guard let fromDeg else { return 0 }
        let raw = (fromDeg - (headingDeg ?? 0) + 180).truncatingRemainder(dividingBy: 360)
        return raw < 0 ? raw + 360 : raw
    }
}

/// Pack voltage, per-cell voltage, current and charge, with the cell count.
///
/// Per cell is the number that says how much is really left: a pack reads
/// healthy long after its cells have sagged. The cell count is the only
/// thing the app cannot work out for itself, so it is asked for here, right
/// beside the figure it changes.
private struct BatteryBlock: View {
    let vehicle: VehicleState
    @Binding var cells: Int
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 1 : 2) {
            HStack(spacing: compact ? 4 : 6) {
                reading(readout(vehicle.batteryV, digits: 1), "V")
                    .frame(width: unitColumn, alignment: .trailing)
                reading(readout(vehicle.batteryV.map { $0 / Float(cells) }, digits: 2), "V/C")
                reading(readout(vehicle.batteryA, digits: 1), "A")
            }
            HStack(spacing: 0) {
                // The per cent keeps its column under the V above it, and the
                // selector goes to the far edge.
                reading(vehicle.batteryRemainingPct.map(String.init) ?? "--", "%")
                    .frame(width: unitColumn, alignment: .trailing)
                Spacer(minLength: 4)
                HStack(spacing: 2) {
                    ForEach(Preferences.cellChoices, id: \.self) { count in
                        let chosen = count == cells
                        Text("\(count)S")
                            .font(.system(size: compact ? 7 : 8, weight: chosen ? .bold : .regular))
                            .foregroundStyle(chosen ? Color.black : Palette.hudText.opacity(0.75))
                            .padding(.horizontal, compact ? 3 : 4)
                            .padding(.vertical, 1)
                            .background(chosen ? Palette.hudYellow : Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                            .onTapGesture { cells = count }
                    }
                }
            }
        }
        .fixedSize()
        .padding(.horizontal, 5)
        .padding(.vertical, compact ? 2 : 3)
        .background(Palette.tape, in: RoundedRectangle(cornerRadius: 5))
    }

    /// Wide enough for the longest pack voltage, so the per cent sign sits
    /// directly under the V above it whatever the figures.
    private var unitColumn: CGFloat { compact ? 38 : 42 }

    private func reading(_ value: String, _ unit: String) -> some View {
        HStack(spacing: 1) {
            Text(value)
                .font(.system(size: compact ? 9 : 10, weight: .semibold))
                .foregroundStyle(Palette.hudText)
            Text(unit)
                .font(.system(size: compact ? 7 : 8))
                .foregroundStyle(Palette.hudText.opacity(0.7))
        }
        .monospacedDigit()
    }
}
