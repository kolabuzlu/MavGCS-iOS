import MavlinkCore
import SwiftUI

/// Heading-up compass rose, the desktop's (map_view.py) by way of the
/// Android build's CompassRose. The card turns under a fixed white index,
/// so whatever sits at the top of the dial is straight ahead.
///
/// Four bearings at once: the nose (the white index), the course over
/// ground (amber, riding the card), home (green) and the wind (blue). The
/// gap between the white index and the amber marker is the drift angle,
/// seen as a separation rather than worked out from two numbers.
///
/// Laid out in the desktop's 200-unit space and scaled to whatever size it
/// is given, so the geometry reads straight across from map_view.py. Only
/// the writing has a floor: a phone draws the dial at a third of the
/// desktop's size, where its figures would otherwise be too small to read.
struct CompassRoseView: View {
    let vehicle: VehicleState
    var size: CGFloat = 200

    var body: some View {
        let dial = CompassDial(
            heading: vehicle.headingDeg ?? vehicle.yawDeg,
            course: vehicle.groundCourseDeg,
            home: homeBearing,
            windFrom: vehicle.windDirectionDeg,
            windSpeedMs: vehicle.windSpeedMs
        )
        Canvas { context, canvasSize in
            dial.draw(&context, size: canvasSize)
        }
        .frame(width: size, height: size)
        // Lighter than the radar's: that is a data display needing its own
        // ground, this is a dial read against the map showing through it.
        .background(Color(hex: 0x1E1E1E, opacity: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08), lineWidth: 1))
        // An instrument, not more map: a tap on it is not a place to fly to.
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture {}
        .accessibilityElement()
        .accessibilityLabel("Compass")
    }

    /// Which way home lies, or nil until both the aircraft and its home are
    /// known -- which hides the arrow rather than leaving it pointing north.
    private var homeBearing: Double? {
        guard let lat = vehicle.lat, let lon = vehicle.lon, lat != 0 || lon != 0,
              let homeLat = vehicle.homeLat, let homeLon = vehicle.homeLon
        else { return nil }
        return Geo.bearing(fromLat: lat, lon: lon, toLat: homeLat, lon: homeLon)
    }
}

private struct CompassDial {
    let heading: Float?
    let course: Float?
    let home: Double?
    let windFrom: Float?
    let windSpeedMs: Float?

    static let side: CGFloat = 200
    static let radius: CGFloat = 94

    static let north = Color(hex: 0xFF4D4D)
    static let track = Color(hex: 0xFFC83D)
    static let courseText = Color(hex: 0xFFA726)
    static let windText = Color(hex: 0x4FC3F7)
    static let home = Color(hex: 0x6EE787)
    static let wind = Color(hex: 0x1E9FD6)
    /// The wind arrow sits under the cardinals, which paint over it.
    static let windAlpha = 0.78

    func draw(_ context: inout GraphicsContext, size: CGSize) {
        let unit = size.width / Self.side
        let centre = CGPoint(x: 100 * unit, y: 100 * unit)

        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: x * unit, y: y * unit)
        }
        func polygon(_ points: (CGFloat, CGFloat)...) -> Path {
            var path = Path()
            path.move(to: at(points[0].0, points[0].1))
            for point in points.dropFirst() {
                path.addLine(to: at(point.0, point.1))
            }
            path.closeSubpath()
            return path
        }
        /// The desktop's size scaled to the dial, but never below `floor`.
        func font(_ desktop: CGFloat, floor: CGFloat, weight: Font.Weight) -> Font {
            .system(size: max(desktop * unit, floor), weight: weight)
        }
        /// A copy of the context turned about the dial's centre.
        func turned(_ base: GraphicsContext, _ degrees: Double) -> GraphicsContext {
            var turned = base
            turned.translateBy(x: centre.x, y: centre.y)
            turned.rotate(by: .degrees(degrees))
            turned.translateBy(x: -centre.x, y: -centre.y)
            return turned
        }

        let face = Path(ellipseIn: CGRect(
            x: centre.x - Self.radius * unit, y: centre.y - Self.radius * unit,
            width: 2 * Self.radius * unit, height: 2 * Self.radius * unit
        ))
        context.fill(face, with: .color(.black.opacity(0.22)))
        context.stroke(face, with: .color(.white.opacity(0.18)), lineWidth: 2 * unit)

        // The card turns under the index, so the rose is turned against the
        // heading.
        let card = turned(context, -Double(heading ?? 0))

        for degrees in stride(from: 0, to: 360, by: 10) {
            let major = degrees % 30 == 0
            let inner: CGFloat = major ? 80 : 87
            let radians = CGFloat(degrees - 90) * .pi / 180
            var tick = Path()
            tick.move(to: at(100 + Self.radius * cos(radians), 100 + Self.radius * sin(radians)))
            tick.addLine(to: at(100 + inner * cos(radians), 100 + inner * sin(radians)))
            card.stroke(tick, with: .color(major ? .white : .white.opacity(0.55)), lineWidth: (major ? 2.5 : 1.5) * unit)
        }

        // WIND reports where the wind comes from; the arrow shows where it
        // is pushing the aircraft, which is the opposite way.
        if let windFrom {
            var arrow = turned(card, Double(windFrom) + 180)
            arrow.opacity = Self.windAlpha
            var shaft = Path()
            shaft.move(to: at(100, 72))
            shaft.addLine(to: at(100, 42))
            arrow.stroke(shaft, with: .color(Self.wind), style: StrokeStyle(lineWidth: 4 * unit, lineCap: .round))
            arrow.fill(polygon((100, 28), (91, 46), (100, 41), (109, 46)), with: .color(Self.wind))
        }

        // Home. Ends short of the wind arrow's head, so when the two point
        // the same way there are two arrowheads at different radii rather
        // than one muddled shape.
        if let home {
            let arrow = turned(card, home)
            var shaft = Path()
            shaft.move(to: at(100, 66))
            shaft.addLine(to: at(100, 46))
            arrow.stroke(shaft, with: .color(Self.home), style: StrokeStyle(lineWidth: 4 * unit, lineCap: .round))
            arrow.fill(polygon((100, 34), (92, 50), (100, 45), (108, 50)), with: .color(Self.home))
        }

        let cardinal = font(20, floor: 8, weight: .bold)
        let cardinals: [(String, CGFloat, CGFloat, Color)] = [
            ("N", 100, 34, Self.north), ("E", 166, 100, .white), ("S", 100, 166, .white), ("W", 34, 100, .white),
        ]
        for (letter, x, y, colour) in cardinals {
            card.draw(Text(verbatim: letter).font(cardinal).foregroundStyle(colour), at: at(x, y), anchor: .center)
        }

        // Rides the card at its own bearing, so on screen it lands course
        // minus heading from the top: the drift angle.
        if let course {
            turned(card, Double(course)).fill(polygon((100, 28), (91, 6), (109, 6)), with: .color(Self.track))
        }

        // Fixed: the card turns beneath it, so it always marks the nose.
        context.fill(polygon((100, 4), (94, 22), (106, 22)), with: .color(.white))

        // Verbatim throughout, or a locale's grouping and decimal comma
        // would dress the figures differently from everywhere else.
        context.draw(
            Text(verbatim: course.map { "\(Int($0.rounded()) % 360)°" } ?? "---")
                .font(font(13, floor: 7, weight: .semibold))
                .foregroundStyle(Self.courseText),
            at: at(100, 79), anchor: .center
        )
        context.draw(
            Text(verbatim: heading.map { "\(Int($0.rounded()) % 360)°" } ?? "---")
                .font(font(25, floor: 11, weight: .bold))
                .foregroundStyle(.white),
            at: at(100, 103), anchor: .center
        )
        // km/h, matching the wind readout in the telemetry grid.
        context.draw(
            Text(verbatim: windSpeedMs.map { String(format: "%.1f km/h", $0 * 3.6) } ?? "--")
                .font(font(13, floor: 7, weight: .semibold))
                .foregroundStyle(Self.windText),
            at: at(100, 134), anchor: .center
        )
    }
}
