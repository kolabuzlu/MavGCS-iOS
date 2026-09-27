import CoreLocation
import MavlinkCore
import Observation
import UIKit

/// What the screens read and what their buttons call.
///
/// The client does the talking on its own queue; this holds the latest state
/// it published, on the main actor, along with what belongs to the screen
/// rather than the vehicle: the connection form, the trail, the point the
/// pilot tapped.
@Observable
final class GcsModel {
    private let client = MavlinkClient()

    private(set) var vehicle = VehicleState()
    /// RainViewer's radar around the aircraft, when the Weather button is on.
    let weather = WeatherRadar()
    /// The ground ahead of the aircraft, for the terrain radar.
    let terrain = TerrainRadar()
    var form: ConnectionForm {
        didSet { Preferences.saveForm(form) }
    }

    /// Where the aircraft has been, oldest first.
    private(set) var trail: [CLLocationCoordinate2D] = []
    /// Bumped whenever the trail changes, so the map can tell cheaply.
    private(set) var trailVersion = 0

    /// A point tapped on the map and not yet flown to or cleared.
    var flyTarget: CLLocationCoordinate2D?
    /// Set once the fly command has gone. The marker outlives the prompt:
    /// the bar has done its job, but the point the aircraft is heading for
    /// is worth keeping on the map.
    var flyTargetSent = false

    var speedInKph: Bool {
        didSet { Preferences.speedInKph = speedInKph }
    }

    var cells: Int {
        didSet { Preferences.cells = cells }
    }

    /// How often attitude and position are asked for. A change goes to the
    /// vehicle at once when connected, which is what is wanted when the
    /// picture starts to stutter mid-flight.
    var rates: StreamRates {
        didSet {
            guard rates != oldValue else { return }
            Preferences.rates = rates
            client.setStreamRates(rates)
        }
    }

    init() {
        form = Preferences.loadForm()
        speedInKph = Preferences.speedInKph
        cells = Preferences.cells
        rates = Preferences.rates
        // The main queue rather than a Task: it runs what it is given in the
        // order given, so an older state can never land on top of a newer one.
        client.observe { [weak self] state in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(state) }
            }
        }
        // For development: launched with `-autoconnect YES`, the saved link
        // opens at start, so a rebuilt app is back on the air without a
        // trip through the connection panel. Never set in normal use.
        if UserDefaults.standard.bool(forKey: "autoconnect") {
            client.connect(form.config, rates: rates)
        }
    }

    private func apply(_ state: VehicleState) {
        vehicle = state
        if let lat = state.lat, let lon = state.lon, lat != 0 || lon != 0 {
            extendTrail(CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
        weather.follow(lat: state.lat, lon: state.lon)
        terrain.update(state)
        // The screen stays on while a link is open. A GCS that goes dark in
        // the middle of a flight is a GCS that has to be unlocked, found and
        // read again at the worst possible moment.
        UIApplication.shared.isIdleTimerDisabled = state.linkOpen
    }

    // MARK: - Link

    func toggleConnection() {
        if vehicle.linkOpen {
            client.disconnect()
        } else {
            client.connect(form.config, rates: rates)
        }
    }

    // MARK: - Commands

    func arm() { client.send(.arm) }
    func forceArm() { client.send(.forceArm) }
    func disarm() { client.send(.disarm) }

    func setMode(_ button: ModeButton) {
        client.setFlightMode(button)
    }

    func changeSpeed(_ metersPerSecond: Float) { client.changeSpeed(metersPerSecond) }
    func changeAltitude(_ meters: Float) { client.changeAltitude(meters) }
    func setLoiterRadius(_ meters: Float) { client.setLoiterRadius(meters) }

    func flyTo(_ target: CLLocationCoordinate2D, altitudeM: Float) {
        // With the link gone nothing would go, so the point is not marked
        // as flown to.
        guard vehicle.canCommand else { return }
        client.flyTo(lat: target.latitude, lon: target.longitude, altitudeM: altitudeM)
        flyTarget = target
        flyTargetSent = true
    }

    func clearFlyTarget() {
        flyTarget = nil
        flyTargetSent = false
    }

    // MARK: - Trail

    /// Points closer than this to the last one are not worth a vertex: at the
    /// rates asked for, a loitering aircraft would otherwise lay hundreds of
    /// points on top of each other a minute.
    private static let trailSpacingM = 2.0
    /// About three hours of flying at 20 m/s, well within what the map draws
    /// without effort.
    private static let trailLimit = 20_000

    private func extendTrail(_ point: CLLocationCoordinate2D) {
        if let last = trail.last {
            let moved = CLLocation(latitude: last.latitude, longitude: last.longitude)
                .distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude))
            guard moved >= Self.trailSpacingM else { return }
        }
        trail.append(point)
        if trail.count > Self.trailLimit {
            trail.removeFirst(trail.count - Self.trailLimit)
        }
        trailVersion += 1
    }

    func clearTrail() {
        trail.removeAll()
        trailVersion += 1
    }

    /// The Flight Mode panel's buttons for whatever is connected.
    ///
    /// Before anything is heard the plane's modes stand in, disabled:
    /// MavGCS is flown with planes first, an empty panel reads as broken,
    /// and a type of "—" would otherwise fall through to the copter table.
    var modePanel: [[ModeButton]] {
        guard vehicle.heard else { return FlightModes.panel(firmware: .ardupilot, vehicleType: "FIXED_WING") }
        return FlightModes.panel(firmware: vehicle.firmware, vehicleType: vehicle.vehicleType)
    }

    var guidedMode: ModeButton? {
        guard vehicle.heard else { return FlightModes.guided(firmware: .ardupilot, vehicleType: "FIXED_WING") }
        return FlightModes.guided(firmware: vehicle.firmware, vehicleType: vehicle.vehicleType)
    }
}

/// The connection panel's fields, as typed.
struct ConnectionForm: Codable, Equatable {
    var type: LinkType = .udp
    var udpMode: UdpMode = .listen
    /// Kept whatever the mode, so switching to listen and back does not lose
    /// what was typed.
    ///
    /// The default is the address the mLRS WiFi bridge gives itself, which
    /// is the radio this app is most likely to be dialling out to.
    var host = "192.168.4.55"
    var port = "14550"

    /// A bound port has nothing to aim at, so the address is not the
    /// pilot's to set.
    var hostEditable: Bool { type == .tcp || (type == .udp && udpMode == .connect) }

    var config: LinkConfig {
        LinkConfig(
            type: type,
            host: hostEditable ? host.trimmingCharacters(in: .whitespaces) : "0.0.0.0",
            port: UInt16(port) ?? 14550,
            udpMode: udpMode
        )
    }
}

/// What the app remembers between launches.
///
/// A pilot who thinks in kph thinks in kph tomorrow as well, and the pack
/// on the aircraft does not change between one launch and the next; having
/// to say so again every time is the kind of small friction that gets
/// noticed daily.
enum Preferences {
    private static let defaults = UserDefaults.standard

    static var speedInKph: Bool {
        get { defaults.bool(forKey: "speed_in_kph") }
        set { defaults.set(newValue, forKey: "speed_in_kph") }
    }

    static let cellChoices = [3, 4, 6]

    static var cells: Int {
        get {
            let stored = defaults.integer(forKey: "battery_cells")
            return cellChoices.contains(stored) ? stored : 4
        }
        set { defaults.set(newValue, forKey: "battery_cells") }
    }

    /// The rates offered, in Hz, as on the desktop and Android.
    static let rateChoices: [Float] = [1, 2, 3, 5]

    /// Read on every connection, so a stored value outside the offered set
    /// is treated as absent: a stray setting must not be why a link
    /// misbehaves.
    static var rates: StreamRates {
        get {
            let attitude = defaults.float(forKey: "telemetry_attitude_hz")
            let position = defaults.float(forKey: "telemetry_position_hz")
            return StreamRates(
                attitudeHz: rateChoices.contains(attitude) ? attitude : 5,
                positionHz: rateChoices.contains(position) ? position : 2,
                // Off unless chosen: the reduced set is what fits a slow link.
                full: defaults.bool(forKey: "telemetry_full")
            )
        }
        set {
            defaults.set(newValue.attitudeHz, forKey: "telemetry_attitude_hz")
            defaults.set(newValue.positionHz, forKey: "telemetry_position_hz")
            defaults.set(newValue.full, forKey: "telemetry_full")
        }
    }

    static func loadForm() -> ConnectionForm {
        guard let data = defaults.data(forKey: "connection_form"),
              let form = try? JSONDecoder().decode(ConnectionForm.self, from: data)
        else { return ConnectionForm() }
        return form
    }

    static func saveForm(_ form: ConnectionForm) {
        if let data = try? JSONEncoder().encode(form) {
            defaults.set(data, forKey: "connection_form")
        }
    }
}
