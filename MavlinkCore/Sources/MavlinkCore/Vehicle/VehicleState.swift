import Foundation

/// Everything the vehicle has said, as the screens read it.
///
/// A reading is nil until the message carrying it has arrived. Zero is a
/// perfectly good roll, altitude or airspeed, so a default of zero would
/// have the panel state the aircraft is level at sea level when it is
/// really saying nothing at all.
public struct VehicleState: Sendable, Equatable {
    /// A link has been opened and has not been closed or failed. Says
    /// nothing about whether anything is at the other end; see [heard].
    public var linkOpen = false
    /// A heartbeat has arrived in the last few seconds.
    public var linkUp = false
    /// When the last heartbeat arrived, on the client's monotonic clock.
    public var lastHeartbeat: Double = 0
    public var packetsIn = 0
    public var systemId: UInt8 = 0
    public var componentId: UInt8 = 1
    public var autopilot = "—"
    public var vehicleType = "—"
    public var firmware = Firmware.unknown
    public var mode = "UNKNOWN"
    public var customMode: UInt32 = 0
    public var armed = false
    public var systemStatus = "—"
    /// A mode asked for and not yet seen in a heartbeat, or nil.
    ///
    /// On a link that drops a third of what it carries, a press that
    /// vanishes looks exactly like a press that was never made. Holding the
    /// request visible until the aircraft reports the mode means the pilot
    /// presses once and waits, rather than pressing four more times.
    public var modePending: String?
    public var link = LinkQuality()
    /// Receiver signal strength as a percentage, or nil when there is no RC
    /// link to report. ArduPilot and PX4 expose only this over MAVLink -- no
    /// link quality or signal-to-noise figure in any standard field.
    public var rssiPercent: Float?

    public var rollDeg: Float?
    public var pitchDeg: Float?
    /// Yaw as a compass bearing, 0..<360.
    public var yawDeg: Float?
    /// Yaw rate, positive to the right; the arc of the predicted track.
    public var yawRateDegSec: Float = 0

    public var lat: Double?
    public var lon: Double?
    public var altMslM: Float?
    /// Height above home, which is what the pilot flies by.
    public var altRelM: Float?
    public var groundSpeedMs: Float?
    public var airSpeedMs: Float?
    public var headingDeg: Float?
    /// Course over ground, which parts from heading in any crosswind.
    public var groundCourseDeg: Float?
    public var throttlePct: Int?
    public var climbMs: Float?

    public var gpsFix = "NO GPS"
    public var gpsFixType: UInt8?
    public var satellites: Int?
    public var hdop: Float?

    public var batteryV: Float?
    public var batteryA: Float?
    public var batteryRemainingPct: Int?

    public var rangefinderM: Float?
    public var distToHomeM: Float?
    public var distToWpM: Float?
    /// The bearing the navigation controller is steering, degrees true.
    ///
    /// With the distance beside it this says where the vehicle is being
    /// taken without downloading the mission: the current waypoint under
    /// AUTO, home or the loiter point under RTL, whatever a guided command
    /// named.
    public var navBearingDeg: Float?
    public var windDirectionDeg: Float?
    public var windSpeedMs: Float?
    public var qnhHpa: Float?
    public var terrainAltM: Float?

    public var homeLat: Double?
    public var homeLon: Double?
    /// Home's height above the sea. Every relative altitude the aircraft
    /// reports is measured from it.
    public var homeAltM: Double?
    /// The mission item being flown to. Item 0 is home, so the pilot's
    /// first point is 1.
    public var currentWaypointSeq: Int?

    /// SYS_STATUS's sensor bitmasks, carried whole.
    public var sensorsPresent: UInt32?
    public var sensorsHealth: UInt32?

    /// The HUD's EKF and VIBE words, or nil before a report has arrived --
    /// drawn white, the quiet state, like everywhere else MavGCS runs.
    public var ekfTint: HealthTint?
    public var vibeTint: HealthTint?

    /// The Messages panel: the vehicle's own words and the app's notes.
    public var messages: [VehicleMessage] = []

    public init() {}

    /// Whether a vehicle has ever identified itself on this link.
    ///
    /// Latches on the first heartbeat and stays on for the connection,
    /// because it answers "is there an aircraft at the other end" and not
    /// "did one speak in the last three seconds". The controls must not go
    /// dead every time a radio stutters, and must not be live before there
    /// is anything to send to.
    public var heard: Bool { systemId != 0 }

    /// A vehicle has been heard and the link to it is still open, so a
    /// command has somewhere to go. Heard alone stays true after the link
    /// ends, since the last frame is kept on screen.
    public var canCommand: Bool { heard && linkOpen }

    public var kind: VehicleKind { VehicleKind(vehicleType: vehicleType) }

    /// The autopilot's own pre-arm checks pass, so an arm would be accepted.
    /// False until SYS_STATUS has said so, rather than assumed.
    public var readyToArm: Bool {
        guard let present = sensorsPresent, let health = sensorsHealth else { return false }
        let check = MavSysStatusSensor.prearmCheck
        return present & check != 0 && health & check != 0
    }
}

/// One line in the Messages panel.
public struct VehicleMessage: Sendable, Equatable, Identifiable {
    public let id: Int
    public var text: String
    /// MAV_SEVERITY from a STATUSTEXT, or nil for a note from the app itself.
    public let severity: UInt8?
    public let time: Date

    public init(id: Int, text: String, severity: UInt8?, time: Date) {
        self.id = id
        self.text = text
        self.severity = severity
        self.time = time
    }

    /// Emergency, alert, critical or error.
    public var isError: Bool { (severity ?? 7) <= MavSeverity.error }

    public var isWarning: Bool { severity == MavSeverity.warning }
}

/// How a UDP link is set up.
public enum UdpMode: Sendable, Equatable, Codable {
    /// Bind a port and wait for the vehicle to stream to it, which is what
    /// SITL and most telemetry do.
    case listen
    /// Dial out to a named peer, which is what a WiFi bridge needs.
    ///
    /// On iOS it is also the only mode that reaches a bridge which
    /// broadcasts until spoken to, as the mLRS bridge does: an app may not
    /// receive broadcasts without an entitlement Apple hands out by request,
    /// but the bridge switches to plain unicast the moment the first
    /// heartbeat arrives from here.
    case connect
}

public enum LinkType: Sendable, Equatable, Codable {
    case udp
    case tcp
}

public struct LinkConfig: Sendable, Equatable, Codable {
    public var type: LinkType
    public var host: String
    public var port: UInt16
    public var udpMode: UdpMode

    public init(type: LinkType = .udp, host: String = "0.0.0.0", port: UInt16 = 14550, udpMode: UdpMode = .listen) {
        self.type = type
        self.host = host
        self.port = port
        self.udpMode = udpMode
    }

    /// A bound port has nothing to aim at, so the address is not the
    /// pilot's to set.
    public var hostEditable: Bool { type == .tcp || udpMode == .connect }

    public var description: String {
        switch (type, udpMode) {
        case (.udp, .listen): return "UDP port \(port)"
        case (.udp, .connect): return "UDP \(host):\(port)"
        case (.tcp, _): return "TCP \(host):\(port)"
        }
    }
}

/// How much telemetry to ask the vehicle for.
///
/// A telemetry radio has a fixed budget. ArduPilot's default streams spend
/// most of it on messages this app never reads, and the radio drops
/// whatever overflows without regard for which mattered. Asking for less
/// means what is asked for actually arrives.
public struct StreamRates: Sendable, Equatable {
    public var attitudeHz: Float = 5
    public var positionHz: Float = 2
    /// Everything at the vehicle's own rates, for a link with room to spare.
    public var full = false

    public init(attitudeHz: Float = 5, positionHz: Float = 2, full: Bool = false) {
        self.attitudeHz = attitudeHz
        self.positionHz = positionHz
        self.full = full
    }
}

/// The commands behind the fixed buttons.
public enum GcsCommand: Sendable, Equatable {
    case arm
    /// Arms with the pre-arm checks bypassed.
    case forceArm
    case disarm
}
