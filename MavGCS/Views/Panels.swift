import CoreLocation
import MavlinkCore
import SwiftUI

/// The Flight Mode panel, three to a row, over the bottom of the map.
///
/// Stays open after a press, because what matters next is the button
/// turning from amber to green: the mode is only taken once a heartbeat
/// says so, and until then it is resent every second.
struct ModePanel: View {
    @Environment(GcsModel.self) private var model
    let close: () -> Void

    var body: some View {
        let vehicle = model.vehicle
        VStack(spacing: 6) {
            ForEach(Array(model.modePanel.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    ForEach(row) { button in
                        ModeButtonView(
                            label: button.label,
                            active: vehicle.mode == button.mode,
                            pending: vehicle.modePending == button.mode,
                            enabled: vehicle.heard,
                            alert: button.label == "RTL"
                        ) {
                            model.setMode(button)
                        }
                    }
                }
                .frame(height: 34)
            }
        }
        .panelBackground()
    }
}

/// Guided control: the mode, flying to a place, and the three values the
/// autopilot can be asked to change while it flies there.
struct GuidedPanel: View {
    @Environment(GcsModel.self) private var model
    let close: () -> Void

    @State private var prompt: GuidedValue?
    @State private var text = ""
    @State private var askLatLon = false
    @State private var latText = ""
    @State private var lonText = ""
    @State private var altText = ""

    enum GuidedValue: String, Identifiable {
        case speed = "Change Speed"
        case altitude = "Change Altitude"
        case loiterRadius = "Change Loiter Radius"

        var id: String { rawValue }

        var unit: String {
            switch self {
            case .speed: return "m/s"
            case .altitude, .loiterRadius: return "m"
            }
        }

        var explanation: String {
            switch self {
            case .speed: return "Target speed, in metres per second. The autopilot keeps the throttle."
            case .altitude: return "Target altitude above home, in metres."
            case .loiterRadius: return "Sets WP_LOITER_RAD. The aircraft says what it actually took, which may be clamped to its own limits."
            }
        }
    }

    var body: some View {
        let vehicle = model.vehicle
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                if let guided = model.guidedMode {
                    ModeButtonView(
                        label: guided.label,
                        active: vehicle.mode == guided.mode,
                        pending: vehicle.modePending == guided.mode,
                        enabled: vehicle.heard
                    ) {
                        model.setMode(guided)
                    }
                }
                Button {
                    latText = vehicle.lat.map { String(format: "%.6f", $0) } ?? ""
                    lonText = vehicle.lon.map { String(format: "%.6f", $0) } ?? ""
                    altText = defaultAltitudeText
                    askLatLon = true
                } label: {
                    Label("FLY TO LAT / LON", systemImage: "globe")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(PanelButtonStyle(fill: Palette.blue, ink: .white, bordered: false))
                .disabled(!vehicle.heard)
                // Two units wide, filling the space the row would otherwise leave.
                .layoutPriority(1)
            }
            .frame(height: 34)
            HStack(spacing: 6) {
                valueButton(.speed)
                valueButton(.altitude)
                // A plane's parameter: nothing else has WP_LOITER_RAD to set.
                if vehicle.kind == .plane || !vehicle.heard {
                    valueButton(.loiterRadius)
                }
            }
            .frame(height: 34)
        }
        .panelBackground()
        .alert(prompt?.rawValue ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }), presenting: prompt) { value in
            TextField(value.unit, text: $text)
                .keyboardType(.decimalPad)
            Button("Send") { send(value) }
            Button("Cancel", role: .cancel) {}
        } message: { value in
            Text(value.explanation)
        }
        .alert("Fly to Lat / Lon", isPresented: $askLatLon) {
            TextField("Latitude", text: $latText)
                .keyboardType(.numbersAndPunctuation)
            TextField("Longitude", text: $lonText)
                .keyboardType(.numbersAndPunctuation)
            TextField("Altitude above home (m)", text: $altText)
                .keyboardType(.decimalPad)
            Button("Fly") { flyToTyped() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Switches the vehicle to GUIDED and flies to this point.")
        }
    }

    private var defaultAltitudeText: String {
        guard let altitude = model.vehicle.altRelM, altitude > 1 else { return "100" }
        return String(format: "%.0f", altitude)
    }

    private func valueButton(_ value: GuidedValue) -> some View {
        Button {
            text = ""
            prompt = value
        } label: {
            Text(value.rawValue)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(PanelButtonStyle())
        .disabled(!model.vehicle.heard)
    }

    private func send(_ value: GuidedValue) {
        guard let number = Float(text.replacingOccurrences(of: ",", with: ".")), number.isFinite else { return }
        switch value {
        case .speed: model.changeSpeed(number)
        case .altitude: model.changeAltitude(number)
        case .loiterRadius: model.setLoiterRadius(number)
        }
    }

    private func flyToTyped() {
        let clean = { (s: String) in s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".") }
        guard let lat = Double(clean(latText)), let lon = Double(clean(lonText)), let alt = Float(clean(altText)),
              (-90...90).contains(lat), (-180...180).contains(lon), alt > 0
        else { return }
        model.flyTo(CLLocationCoordinate2D(latitude: lat, longitude: lon), altitudeM: alt)
    }
}

/// The point tapped on the map, waiting to be flown to or cleared.
struct FlyHereBar: View {
    let target: CLLocationCoordinate2D
    let enabled: Bool
    let onFly: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(String(format: "%.6f, %.6f", target.latitude, target.longitude))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Palette.onSurface)
            Button(action: onFly) {
                Text("FLY HERE")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 30)
            }
            .buttonStyle(PanelButtonStyle(fill: Palette.cyan, ink: Color(hex: 0x04121C), bordered: false))
            .disabled(!enabled)
            Button("Clear", action: onClear)
                .font(.system(size: 12))
                .foregroundStyle(Palette.cyan)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Palette.surface.opacity(0.94), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The altitude question for a fly-here, answered before anything is sent.
private struct FlyHereAltitudePrompt: ViewModifier {
    @Environment(GcsModel.self) private var model
    @Binding var isPresented: Bool
    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { _, shown in
                if shown {
                    // The height it is already flying at, which is usually
                    // what a pilot sending it somewhere else wants to keep.
                    let current = model.vehicle.altRelM
                    text = current.flatMap { $0 > 1 ? String(format: "%.0f", $0) : nil } ?? "100"
                }
            }
            .alert("Fly to here", isPresented: $isPresented) {
                TextField("Altitude above home (m)", text: $text)
                    .keyboardType(.decimalPad)
                Button("Fly") {
                    guard let target = model.flyTarget,
                          let altitude = Float(text.replacingOccurrences(of: ",", with: ".")),
                          altitude > 0
                    else { return }
                    model.flyTo(target, altitudeM: altitude)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let target = model.flyTarget {
                    Text(String(format: "%.6f, %.6f\nSwitches the vehicle to GUIDED and flies to this point.", target.latitude, target.longitude))
                }
            }
    }
}

extension View {
    func flyHereAltitudePrompt(isPresented: Binding<Bool>) -> some View {
        modifier(FlyHereAltitudePrompt(isPresented: isPresented))
    }

    /// The panels' shared ground over the map.
    func panelBackground() -> some View {
        padding(6)
            .background(Palette.surface.opacity(0.94), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.outline, lineWidth: 1))
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
