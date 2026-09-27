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

    /// Whether there is a home-bar strip under the buttons for ESRI's credit.
    private var creditInStrip: Bool {
        bottomPadding >= Self.creditHeight + 2
    }

    private func mapArea(height: CGFloat) -> some View {
        // Live AGL sits just above the LAT / LON box, at the right-hand end of
        // the readouts along the foot of the map, and rises with them when
        // something opens below. Only while it fits under the radar: with a
        // panel up there is no room left for it, and it steps aside until
        // there is.
        let aglLift = bottomPadding + bottomStackHeight + 6
        let aglTop = height - aglLift - AglProfileView.height(for: Self.aglWidth)
        let aglFits = aglTop >= Self.radarTop + Self.radarSide + 6
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
                        top: 6 + MapIconButton.side,
                        left: 6,
                        bottom: bottomStackHeight + bottomPadding,
                        right: edges.trailing
                    ),
                    corner: cornerBlocks(aglTop: aglUp ? aglTop : nil),
                    attributionLift: creditInStrip ? 0 : Self.creditHeight + 4
                ),
                onTap: { point in
                    // Nothing to send it to until a vehicle has been heard,
                    // and a pin that cannot be flown to only misleads.
                    guard model.vehicle.heard else { return }
                    panel = nil
                    model.flyTarget = point
                    model.flyTargetSent = false
                }
            )
            .ignoresSafeArea()

            // ESRI's attribution, which its terms ask to be shown with the
            // imagery: bottom left, in the strip under the buttons that iOS
            // keeps for its home bar -- no use for a control, since a press
            // there can be taken for the swipe home, but room for a line of
            // small print. On a phone without that strip, just above the
            // readouts instead, with MapKit's Legal link lifted over it:
            // beside it, the two would collide wherever the word for "Legal"
            // runs long, and MapKit does not say how long.
            Text(EsriTileOverlay.credit)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 3))
                .frame(height: Self.creditHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, 6)
                .padding(.trailing, creditInStrip ? edges.trailing : edges.trailing + (aglUp ? Self.aglWidth + 6 : 0))
                .padding(.bottom, creditInStrip
                    ? max(1, (bottomPadding - Self.creditHeight) / 2)
                    : bottomPadding + bottomStackHeight + 4)
                .allowsHitTesting(false)

            // Under the map buttons, at the right-hand end of their row and
            // half as wide: at the row's full width it hid too much of the
            // map. Outside the controls' own stack, and beneath it, so a panel
            // slid up from the bottom covers it rather than being squeezed by it.
            TerrainRadarView(radar: model.terrain, size: Self.radarSide)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, Self.radarTop)
                .padding(.trailing, edges.trailing)

            // Live AGL, the ground along the track: as wide as the row of
            // buttons, in the desktop's proportions, and flush with the
            // LAT / LON box's right-hand edge. It comes and goes with the
            // ground to draw, as on the desktop.
            if aglFits {
                AglProfileView(radar: model.terrain, width: Self.aglWidth)
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
                // Under the connection box. Along the foot of the map it took
                // its place in the stack there, and everything above it moved
                // up as it came and moved back as it went.
                if let target = model.flyTarget, !model.flyTargetSent {
                    FlyHereBar(target: target, enabled: model.vehicle.heard) {
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

    /// Five buttons and the gaps between them.
    private static let mapButtonsWidth = 5 * MapIconButton.side + 4 * 6
    private static let radarSide = mapButtonsWidth / 2
    /// Just below the row of buttons.
    private static let radarTop = 6 + MapIconButton.side + 6
    private static let aglWidth = mapButtonsWidth
    /// ESRI's credit line: nine-point type and its backing.
    private static let creditHeight: CGFloat = 13

    /// The instruments along the map's right-hand edge, for Follow to keep
    /// the aircraft clear of: the radar, and Live AGL while it is up.
    private func cornerBlocks(aglTop: CGFloat?) -> [MapCover.Block] {
        var blocks = [MapCover.Block(width: Self.radarSide, height: Self.radarSide, top: Self.radarTop)]
        if let aglTop {
            blocks.append(MapCover.Block(width: Self.aglWidth, height: AglProfileView.height(for: Self.aglWidth), top: aglTop))
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
        }
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
                if let last = model.vehicle.messages.last {
                    MessageLine(message: last) { showMessages = true }
                }
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
                Text(text)
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

    private var text: String {
        guard vehicle.linkOpen else { return "Not connected" }
        guard vehicle.heard else { return "\(config.description) · waiting" }
        let link = vehicle.link
        // Just the kind of link once a vehicle is heard: the address has
        // done its job, it is in the connection panel, and the row across
        // the top of the map has room for the figures or the address, not both.
        var parts = [config.type == .tcp ? "TCP" : "UDP", "\(link.rxBytesPerSec) B/s"]
        if let loss = link.lossPercent {
            parts.append(String(format: "%.1f%%", loss))
        }
        return parts.joined(separator: " · ")
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

    let icon: String
    let active: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(active ? Palette.onGreen : .white.opacity(0.9))
                .frame(width: Self.side, height: Self.side)
                .background(active ? Palette.green : Palette.mapChip, in: RoundedRectangle(cornerRadius: controlCorner))
                .overlay(RoundedRectangle(cornerRadius: controlCorner).stroke(.white.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// ETA to WP and the aircraft's position, in one row along the foot of the
/// map rather than stacked, so the map keeps its height on a phone: the ETA
/// at the left, where the desktop and the Android build keep it, and the
/// position held to the right-hand end.
private struct MapReadouts: View {
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

            HStack(spacing: 14) {
                coordinate("LAT", vehicle.lat)
                coordinate("LON", vehicle.lon)
            }
            .readoutBox()
        }
        .font(.system(size: 11))
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
            .frame(height: 24)
            .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// The newest line from the Messages panel, and the way into the rest.
private struct MessageLine: View {
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
            .frame(height: 26)
            .background(Palette.mapChip, in: RoundedRectangle(cornerRadius: controlCorner))
        }
        .buttonStyle(.plain)
    }
}

/// Along the bottom of the map: arming, and the two panels.
private struct ActionBar: View {
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
                enabled: vehicle.heard,
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
                enabled: vehicle.heard,
                fill: vehicle.armed ? Palette.surfaceVariant : Palette.red,
                ink: vehicle.armed ? Palette.onSurface : .white,
                bordered: vehicle.armed,
                onHold: model.disarm
            )
            panelButton("MODES", .modes, fill: Palette.surfaceVariant, ink: Palette.onSurface)
            panelButton("GUIDED", .guided, fill: Palette.blue, ink: .white)
        }
        .frame(height: 38)
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
