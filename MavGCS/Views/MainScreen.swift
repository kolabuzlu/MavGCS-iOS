import MapKit
import MavlinkCore
import SwiftUI

/// The one screen: instruments on the left, the map and its controls on
/// the right.
///
/// A phone in landscape has room for two things side by side and not much
/// more, so the controls the tablet keeps in a column of their own live
/// here on the map, and the panels that are only needed now and then --
/// the mode grid, the guided controls -- slide up over it when asked for.
struct MainScreen: View {
    @Environment(GcsModel.self) private var model

    @State private var panel: Panel?
    @State private var follow = true
    @State private var hybrid = false
    @State private var showVectors = true
    @State private var showConnection = false
    @State private var showMessages = false
    @State private var askFlyAltitude = false
    /// How much of the map's bottom edge the controls cover. The map keeps
    /// its Apple logo and Legal link above it, where they must stay visible.
    @State private var bottomStackHeight: CGFloat = 38
    @State private var edges = ScreenEdges()

    enum Panel {
        case modes
        case guided
    }

    var body: some View {
        @Bindable var model = model
        // Laid out over the whole screen, with the margins chosen here rather
        // than taken from the safe area, which is the same on both sides and
        // so keeps a strip clear for an island that is usually not there.
        // The instruments run nearly to the left edge, and give the island
        // its room only when it is on their side; the map runs out under
        // every edge and keeps just its controls clear of whatever is there.
        GeometryReader { geometry in
            let usable = geometry.size.width - edges.insets.left - edges.insets.right
            let columnWidth = min(max(usable * 0.42, 270), 380)
            HStack(spacing: 6) {
                VStack(spacing: 6) {
                    HudView(vehicle: model.vehicle, cells: $model.cells)
                    TelemetryGrid(vehicle: model.vehicle, speedInKph: $model.speedInKph)
                        .frame(height: 140)
                }
                .frame(width: columnWidth)
                .padding(.vertical, 6)

                mapArea(height: geometry.size.height)
            }
            .padding(.leading, edges.leading)
            // The battery, in the strip the display's rounded corners leave
            // down the left-hand edge. Nothing else moves or changes size
            // for it, and it keeps clear of the corners at either end.
            .overlay(alignment: .leading) {
                if edges.leading >= 10 {
                    BatteryGauge(percent: model.vehicle.batteryRemainingPct)
                        .frame(
                            width: edges.leading - 6,
                            height: max(geometry.size.height - 2 * Self.gaugeCornerClearance, 60)
                        )
                        .padding(.leading, 3)
                }
            }
        }
        .ignoresSafeArea()
        .background(Palette.background)
        .background(ScreenEdgesReader(edges: $edges))
        .sheet(isPresented: $showConnection) {
            ConnectionSheet()
        }
        .sheet(isPresented: $showMessages) {
            MessagesSheet(messages: model.vehicle.messages)
        }
        .flyHereAltitudePrompt(isPresented: $askFlyAltitude)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    /// Where the map's bottom controls stop: just clear of the strip iOS keeps
    /// for its home bar. Down inside it they sat under the bar itself, and a
    /// press there could be taken over by the swipe home -- which is how the
    /// ARM button came to be left reading FORCE….
    private var bottomPadding: CGFloat {
        edges.insets.bottom > 0 ? edges.insets.bottom + 3 : 6
    }

    /// Whether there is a home-bar strip under the buttons for the credits.
    private var creditInStrip: Bool {
        bottomPadding >= Self.creditHeight + 2
    }

    /// How much the credits take from above the readouts: nothing when they
    /// have the home-bar strip to themselves.
    private var creditRowLift: CGFloat {
        creditInStrip ? 0 : Self.creditHeight + 4
    }

    /// A line of small print over the map, in the style ESRI's credit set.
    private func credit(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 3))
    }

    private func mapArea(height: CGFloat) -> some View {
        let sizes = instrumentSizes(height: height)
        // The compass sits under the radar, and moves up into its place
        // while the radar is switched off.
        let compassTop = model.terrain.showsRadar ? Self.radarTop + sizes.radar + 6 : Self.radarTop
        // Live AGL sits just above the LAT / LON box, at the right-hand end of
        // the readouts along the foot of the map, and rises with them when
        // something opens below. Only while it fits under the compass: with
        // a panel up there is no room left for it, and it steps aside until
        // there is.
        let aglLift = bottomPadding + bottomStackHeight + 6 + creditRowLift
        let aglTop = height - aglLift - AglProfileView.height(for: sizes.aglWidth)
        // At rest the two sides are equal by construction -- the sizes are
        // chosen to fill exactly this height -- so a hair of slack keeps the
        // rounding of the arithmetic from deciding whether it shows.
        let aglFits = aglTop >= compassTop + sizes.compass + 6 - 0.5
        let aglUp = aglFits && model.terrain.aglShown
        return ZStack(alignment: .topLeading) {
            VehicleMapView(
                vehicle: model.vehicle,
                trail: model.trail,
                trailVersion: model.trailVersion,
                flyTarget: model.flyTarget,
                follow: $follow,
                hybrid: hybrid,
                showVectors: showVectors,
                weatherTiles: model.weather.tiles,
                weatherVersion: model.weather.version,
                cover: MapCover(
                    insets: UIEdgeInsets(
                        top: 6 + MapIconButton.side + (model.vehicle.messages.isEmpty ? 0 : 6 + MessageLine.height),
                        left: 6,
                        bottom: bottomStackHeight + bottomPadding,
                        right: edges.trailing
                    ),
                    corner: cornerBlocks(sizes, compassTop: compassTop, aglTop: aglUp ? aglTop : nil),
                    attributionLift: creditInStrip ? 0 : Self.creditHeight + 4
                ),
                onTap: { point in
                    // Nothing to send it to until a vehicle has been heard,
                    // or once its link has gone, and a pin that cannot be
                    // flown to only misleads.
                    guard model.vehicle.canCommand else { return }
                    panel = nil
                    model.flyTarget = point
                    model.flyTargetSent = false
                }
            )
            .ignoresSafeArea()

            // The credits along the foot of the map: ESRI's on the left,
            // which its terms ask to be shown with the imagery, and the
            // author's on the right. In the strip under the buttons that iOS
            // keeps for its home bar -- no use for a control, since a press
            // there can be taken for the swipe home, but room for a line of
            // small print. On a phone without that strip, just above the
            // readouts instead, with MapKit's Legal link lifted over ESRI's:
            // beside it, the two would collide wherever the word for "Legal"
            // runs long, and MapKit does not say how long.
            HStack(spacing: 6) {
                credit(EsriTileOverlay.credit)
                Spacer(minLength: 0)
                credit("Created by Derin Hakan Karakurt")
            }
            .frame(height: Self.creditHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.leading, 6)
            .padding(.trailing, edges.trailing)
            .padding(.bottom, creditInStrip
                ? max(1, (bottomPadding - Self.creditHeight) / 2)
                : bottomPadding + bottomStackHeight + 4)
            .allowsHitTesting(false)

            // Under the map buttons, at the right-hand end of their row. Outside
            // the controls' own stack, and beneath it, so a panel slid up from
            // the bottom covers it rather than being squeezed by it.
            if model.terrain.showsRadar {
                TerrainRadarView(radar: model.terrain, size: sizes.radar)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, Self.radarTop)
                    .padding(.trailing, edges.trailing)
                    .transition(.opacity)
            }

            // Heading, course, wind and the way home, between the radar and
            // Live AGL.
            CompassRoseView(vehicle: model.vehicle, size: sizes.compass)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, compassTop)
                .padding(.trailing, edges.trailing)

            // Live AGL, the ground along the track, in the desktop's
            // proportions and flush with the LAT / LON box's right-hand edge.
            // It comes and goes with the ground to draw, as on the desktop.
            if aglFits {
                AglProfileView(radar: model.terrain, width: sizes.aglWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.bottom, aglLift)
                    .padding(.trailing, edges.trailing)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    LinkChip(vehicle: model.vehicle, config: model.form.config) { showConnection = true }
                    ModeChip(vehicle: model.vehicle)
                    Spacer(minLength: 0)
                    mapButtons
                }
                // The newest message, under the connection box. Up here it no
                // longer takes a row from the foot of the map, and the
                // instruments down the right-hand side have that height
                // instead. It stops short of them, and cuts a long message
                // off rather than running underneath.
                if let last = model.vehicle.messages.last {
                    MessageLine(message: last) { showMessages = true }
                        .padding(.trailing, (model.terrain.showsRadar ? sizes.radar : sizes.compass) + 6)
                }
                // Also under the connection box. Along the foot of the map it
                // took its place in the stack there, and everything above it
                // moved up as it came and moved back as it went.
                if let target = model.flyTarget, !model.flyTargetSent {
                    FlyHereBar(target: target, enabled: model.vehicle.canCommand) {
                        askFlyAltitude = true
                    } onClear: {
                        model.clearFlyTarget()
                    }
                }
                Spacer(minLength: 0)
                bottomStack
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        bottomStackHeight = height
                    }
            }
            .padding(.top, 6)
            .padding(.leading, 6)
            .padding(.trailing, edges.trailing)
            .padding(.bottom, bottomPadding)
        }
    }

    /// The instruments down the map's right-hand side, one under another: the
    /// radar, the compass and Live AGL. Grown to fill the height between the
    /// buttons and the readouts at rest, in the proportions Derin chose when
    /// they first had to share it -- 76, 70 and 70 points tall -- so a
    /// taller phone gets bigger instruments rather than a gap.
    private struct InstrumentSizes {
        let radar: CGFloat
        let compass: CGFloat
        let aglWidth: CGFloat
    }

    /// The bottom stack with no panel open: the readouts over the buttons.
    private static let restingStackHeight: CGFloat = MapReadouts.height + 6 + ActionBar.height

    private func instrumentSizes(height: CGFloat) -> InstrumentSizes {
        let room = height - Self.radarTop - bottomPadding - Self.restingStackHeight - 6 - 12 - creditRowLift
        let unit = max(room, 180) / 216
        return InstrumentSizes(radar: 76 * unit, compass: 70 * unit, aglWidth: 70 * unit * 300 / 140)
    }

    /// Just below the row of buttons.
    private static let radarTop = 6 + MapIconButton.side + 6
    /// How far the battery gauge stays from the top and bottom of the screen.
    /// The display's corners are rounded to about 62 points on the current
    /// Pro phones, and at the gauge's distance from the edge they curve in
    /// over the last 43 or so.
    private static let gaugeCornerClearance: CGFloat = 48
    /// ESRI's credit line: nine-point type and its backing.
    private static let creditHeight: CGFloat = 13

    /// The instruments along the map's right-hand edge, for Follow to keep
    /// the aircraft clear of: the radar and the compass, and Live AGL while
    /// it is up.
    private func cornerBlocks(_ sizes: InstrumentSizes, compassTop: CGFloat, aglTop: CGFloat?) -> [MapCover.Block] {
        var blocks: [MapCover.Block] = []
        if model.terrain.showsRadar {
            blocks.append(MapCover.Block(width: sizes.radar, height: sizes.radar, top: Self.radarTop))
        }
        blocks.append(MapCover.Block(width: sizes.compass, height: sizes.compass, top: compassTop))
        if let aglTop {
            blocks.append(MapCover.Block(width: sizes.aglWidth, height: AglProfileView.height(for: sizes.aglWidth), top: aglTop))
        }
        return blocks
    }

    private var mapButtons: some View {
        HStack(spacing: 6) {
            MapIconButton(icon: "location.north.line", active: follow, label: "Follow UAV") {
                follow.toggle()
            }
            MapIconButton(icon: "square.2.layers.3d", active: hybrid, label: "Hybrid map") {
                hybrid.toggle()
            }
            MapIconButton(icon: "arrow.up.right", active: showVectors, label: "Vectors") {
                showVectors.toggle()
            }
            MapIconButton(icon: "cloud.rain", active: model.weather.enabled, label: "Weather") {
                model.weather.enabled.toggle()
            }
            MapIconButton(icon: "scribble", active: false, label: "Clear trail") {
                model.clearTrail()
            }
            // The fan opening upwards, as the radar draws it; the ground seen
            // side-on, as Live AGL does.
            MapIconButton(glyph: .radarFan, active: model.terrain.showsRadar, label: "Terrain radar") {
                // The compass slides up into the radar's place, and back.
                withAnimation(.easeInOut(duration: 0.25)) {
                    model.terrain.showsRadar.toggle()
                }
            }
            MapIconButton(icon: "mountain.2", active: model.terrain.showsAgl, label: "Live AGL") {
                model.terrain.showsAgl.toggle()
            }
        }
        // Never squeezed: the chips beside them give way first.
        .fixedSize()
    }

    @ViewBuilder
    private var bottomStack: some View {
        VStack(spacing: 6) {
            MapReadouts(vehicle: model.vehicle)
            switch panel {
            case .modes:
                ModePanel { panel = nil }
            case .guided:
                GuidedPanel { panel = nil }
            case nil:
                EmptyView()
            }
            ActionBar(panel: $panel)
        }
    }
}

/// The connection at a glance, and the way into its settings.
private struct LinkChip: View {
    let vehicle: VehicleState
    let config: LinkConfig
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                label
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Palette.mapReadout)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(Palette.mapChip, in: RoundedRectangle(cornerRadius: controlCorner))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Connection")
    }

    private var dotColor: Color {
        if !vehicle.linkOpen { return Palette.onSurfaceVariant.opacity(0.6) }
        if vehicle.linkUp { return Palette.green }
        if vehicle.heard { return Palette.amber }
        return Palette.red
    }

    /// Once a vehicle is heard, just the kind of link and how much of it is
    /// being lost: the address has done its job and is in Settings, and the
    /// byte rate says less about a link's health than its loss does. The
    /// loss sits in a slot as wide as its widest reading, so the chip holds
    /// its size as the figure comes and goes rather than nudging the row.
    @ViewBuilder
    private var label: some View {
        if !vehicle.linkOpen {
            Text("Not connected")
        } else if !vehicle.heard {
            Text("\(config.description) · waiting")
        } else {
            HStack(spacing: 0) {
                Text(config.type == .tcp ? "TCP · " : "UDP · ")
                Text(verbatim: "100.0%")
                    .hidden()
                    .overlay(alignment: .leading) {
                        Text(verbatim: vehicle.link.lossPercent.map { String(format: "%.1f%%", $0) } ?? "--")
                    }
            }
        }
    }
}

/// The flight mode, big enough to read in passing, and the one being
/// asked for while it is on its way.
private struct ModeChip: View {
    let vehicle: VehicleState

    var body: some View {
        if vehicle.heard {
            HStack(spacing: 4) {
                Text(vehicle.mode)
                if let pending = vehicle.modePending, pending != vehicle.mode {
                    Image(systemName: "arrow.right")
                    Text(pending)
                }
            }
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(vehicle.modePending == nil ? Palette.onGreen : Palette.onAmber)
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(vehicle.modePending == nil ? Palette.green : Palette.amber, in: RoundedRectangle(cornerRadius: controlCorner))
            .lineLimit(1)
        }
    }
}

/// A control that lives on the map rather than in a panel: dark and
/// translucent like the attribution, lit in the panel's green while it is
/// doing something.
private struct MapIconButton: View {
    static let side: CGFloat = 32

    enum Glyph {
        case symbol(String)
        /// The terrain radar's own fan. No symbol says terrain radar, and
        /// the nearest, a fan of arcs, reads as Wi-Fi.
        case radarFan
    }

    let glyph: Glyph
    let active: Bool
    let label: String
    let action: () -> Void

    init(icon: String, active: Bool, label: String, action: @escaping () -> Void) {
        self.init(glyph: .symbol(icon), active: active, label: label, action: action)
    }

    init(glyph: Glyph, active: Bool, label: String, action: @escaping () -> Void) {
        self.glyph = glyph
        self.active = active
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                switch glyph {
                case .symbol(let name):
                    Image(systemName: name)
                        .font(.system(size: 14, weight: .semibold))
                case .radarFan:
                    // Stroked about as heavily as a semibold symbol at 14.
                    RadarFanGlyph()
                        .stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                        .frame(width: 18, height: 12)
                }
            }
                .foregroundStyle(active ? Palette.onGreen : .white.opacity(0.9))
                .frame(width: Self.side, height: Self.side)
                .background(active ? Palette.green : Palette.mapChip, in: RoundedRectangle(cornerRadius: controlCorner))
                .overlay(RoundedRectangle(cornerRadius: controlCorner).stroke(.white.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The terrain radar's fan, drawn as the radar draws it: a 120 degree sector
/// opening upwards from the aircraft, with a range arc inside.
private struct RadarFanGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let apex = CGPoint(x: rect.midX, y: rect.maxY)
        let half = Angle.degrees(60)
        let radius = min(rect.width / 2 / sin(half.radians), rect.height)
        let left = Angle.degrees(-90) - half
        let right = Angle.degrees(-90) + half
        var path = Path()
        path.move(to: apex)
        path.addArc(center: apex, radius: radius, startAngle: left, endAngle: right, clockwise: false)
        path.closeSubpath()
        let inner = radius / 2
        path.move(to: CGPoint(x: apex.x + inner * cos(left.radians), y: apex.y + inner * sin(left.radians)))
        path.addArc(center: apex, radius: inner, startAngle: left, endAngle: right, clockwise: false)
        return path
    }
}

/// ETA to WP and the aircraft's position, in one row along the foot of the
/// map rather than stacked, so the map keeps its height on a phone: the ETA
/// at the left, where the desktop and the Android build keep it, and the
/// position held to the right-hand end.
private struct MapReadouts: View {
    static let height: CGFloat = 24

    let vehicle: VehicleState

    var body: some View {
        HStack(spacing: 6) {
            // Always up, and dashed when there is no arrival to time. A box
            // that came and went would look like a fault, and its absence
            // could not be told from a reading of nothing.
            HStack(spacing: 0) {
                Text("ETA to WP : ")
                Text(Eta.text(vehicle))
                    .fontWeight(.bold)
                    .monospacedDigit()
            }
            .foregroundStyle(Palette.mapReadout)
            .readoutBox()

            Spacer(minLength: 0)

            // A tap asks Google Maps for directions to the aircraft, for
            // going to fetch it.
            Button(action: navigate) {
                HStack(spacing: 14) {
                    coordinate("LAT", vehicle.lat)
                    coordinate("LON", vehicle.lon)
                }
                .readoutBox()
            }
            .buttonStyle(.plain)
            .disabled(vehicle.lat == nil || vehicle.lon == nil)
            .accessibilityLabel("Directions to the aircraft in Google Maps")
        }
        .font(.system(size: 11))
    }

    /// Directions to where the aircraft is: in the Google Maps app when it
    /// is installed, otherwise on Google's website, which offers the app.
    private func navigate() {
        guard let lat = vehicle.lat, let lon = vehicle.lon else { return }
        // A point for a decimal mark whatever the phone's language, which
        // String(format:) gives without being asked.
        let place = String(format: "%.7f,%.7f", lat, lon)
        guard let app = URL(string: "comgooglemaps://?daddr=\(place)&directionsmode=driving"),
              let web = URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(place)")
        else { return }
        UIApplication.shared.open(app) { opened in
            if !opened {
                UIApplication.shared.open(web)
            }
        }
    }

    private func coordinate(_ label: String, _ value: Double?) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .foregroundStyle(Palette.onSurfaceVariant)
            Text(value.map { String(format: "%.6f", $0) } ?? "--")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Palette.onSurface)
        }
    }
}

private extension View {
    /// The ground the map's readouts share: dark enough to read over any
    /// imagery, with the Android build's small corner.
    func readoutBox() -> some View {
        lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: MapReadouts.height)
            .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// The newest line from the Messages panel, and the way into the rest.
private struct MessageLine: View {
    static let height: CGFloat = 26

    let message: VehicleMessage
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.onSurfaceVariant)
                Text(message.text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(message.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: Self.height)
            .background(Palette.mapChip, in: RoundedRectangle(cornerRadius: controlCorner))
        }
        .buttonStyle(.plain)
    }
}

/// Along the bottom of the map: arming, and the two panels.
private struct ActionBar: View {
    static let height: CGFloat = 38

    @Environment(GcsModel.self) private var model
    @Binding var panel: MainScreen.Panel?

    var body: some View {
        let vehicle = model.vehicle
        HStack(spacing: 6) {
            // Each button names the state the vehicle is in rather than the
            // action it performs, so a glance says whether the props are
            // live. A tap asks to arm, and is the autopilot's to refuse; a
            // hold force-arms.
            HoldButton(
                label: vehicle.armed ? "ARMED" : (vehicle.readyToArm ? "ARM" : "NOT READY"),
                labelPrefix: !vehicle.armed && vehicle.readyToArm ? "READY TO" : nil,
                holdLabel: "FORCE…",
                enabled: vehicle.canCommand,
                fill: vehicle.armed
                    ? Palette.green
                    : (vehicle.readyToArm ? Palette.green : Palette.amber).mixed(over: Palette.surfaceVariant, amount: Palette.armStateTint),
                ink: vehicle.armed ? Palette.onGreen : Palette.onSurface,
                bordered: !vehicle.armed,
                onHold: model.forceArm,
                onTap: model.arm
            )
            // Hold only: the hold is the confirmation, and there is no tap to
            // fire by accident. Red and DISARMED while the propellers are
            // safe, grey and DISARM while there is something to do.
            HoldButton(
                label: vehicle.armed ? "DISARM" : "DISARMED",
                holdLabel: "HOLD…",
                enabled: vehicle.canCommand,
                fill: vehicle.armed ? Palette.surfaceVariant : Palette.red,
                ink: vehicle.armed ? Palette.onSurface : .white,
                bordered: vehicle.armed,
                onHold: model.disarm
            )
            panelButton("MODES", .modes, fill: Palette.surfaceVariant, ink: Palette.onSurface)
            panelButton("GUIDED", .guided, fill: Palette.blue, ink: .white)
        }
        .frame(height: Self.height)
    }

    private func panelButton(_ title: String, _ which: MainScreen.Panel, fill: Color, ink: Color) -> some View {
        let open = panel == which
        return Button {
            Haptics.light()
            withAnimation(.easeOut(duration: 0.18)) {
                panel = open ? nil : which
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: open ? "chevron.down" : "chevron.up")
                    .font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 12, weight: .semibold))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(PanelButtonStyle(fill: open ? Palette.onSurfaceVariant.opacity(0.35) : fill, ink: ink, bordered: fill == Palette.surfaceVariant))
    }
}

extension VehicleMessage {
    /// Errors red, warnings amber, the app's own notes in the palette's
    /// blue so they read apart from the vehicle's own words.
    var color: Color {
        if severity == nil { return Palette.cyan }
        if isError { return Color(hex: 0xFF6B5E) }
        if isWarning { return Palette.amber }
        return Palette.onSurface
    }
}
