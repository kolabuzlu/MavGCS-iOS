import Foundation

/// Time to the waypoint, from distance and ground speed, as the desktop and
/// the Android build work it out.
public enum Eta {
    /// The modes that actually fly to a waypoint, and so have an arrival
    /// worth timing. Everything else shows a dash.
    ///
    /// A list of what navigates, not of what does not. The desktop once had
    /// it the other way round, and every mode nobody had thought of fell
    /// through: hand-flying in MANUAL or FBWA, ArduPlane goes on reporting
    /// the distance to the waypoint it last steered to, and the box counted
    /// down to somewhere the aircraft was not going. TAKEOFF is left out on
    /// purpose -- it climbs along the runway heading to a height, not to a
    /// place, so its distance recedes as it flies at it.
    public static let navModes: Set<String> = ["AUTO", "GUIDED", "RTL", "AUTOLAND", "QRTL"]

    /// Below this the aircraft is not really going anywhere, and distance
    /// over speed turns into hours that change every second.
    static let minGroundSpeedMs: Float = 1
    /// ArduPilot reports zero when there is no waypoint to steer to, which
    /// is not the same as having arrived.
    static let minDistanceM: Float = 1
    /// Past this the number is not telling anyone anything useful.
    static let maxSeconds: Float = 100 * 3600

    /// Seconds to the waypoint, or nil where the arithmetic has no honest
    /// answer. Deliberately not gated on the link being up: it works from
    /// the last figures that arrived, like every other reading on screen.
    public static func seconds(_ vehicle: VehicleState) -> Float? {
        guard navModes.contains(vehicle.mode),
              let distance = vehicle.distToWpM, distance >= minDistanceM,
              let speed = vehicle.groundSpeedMs, speed >= minGroundSpeedMs
        else { return nil }
        let seconds = distance / speed
        return seconds > maxSeconds ? nil : seconds
    }

    /// m:ss under an hour, h:mm:ss over it.
    public static func clock(_ seconds: Float) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// The readout: the time, or a dash where there is none to give.
    public static func text(_ vehicle: VehicleState) -> String {
        seconds(vehicle).map(clock) ?? "--"
    }
}
