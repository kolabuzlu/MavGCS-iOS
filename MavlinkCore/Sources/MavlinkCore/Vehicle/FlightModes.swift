/// Which autopilot is at the other end, as its heartbeat says.
public enum Firmware: Sendable, Equatable {
    case unknown
    case ardupilot
    case px4
}

/// The broad kind of vehicle, which decides what its modes are called.
public enum VehicleKind: Sendable, Equatable {
    case plane
    case copter
    case rover

    /// From the MAV_TYPE name with its prefix dropped, the way the Android
    /// build has always decided it: VTOLs fly ArduPlane's mode table.
    public init(vehicleType: String) {
        let type = vehicleType.uppercased()
        if type.contains("ROVER") || type.contains("SURFACE") {
            self = .rover
        } else if type.contains("PLANE") || type.contains("FIXED") || type.contains("VTOL") {
            self = .plane
        } else {
            self = .copter
        }
    }
}

/// One button on the Flight Mode panel.
///
/// [mode] is the name the heartbeat decoding produces for this mode, which
/// is what the button is compared against to show it active or pending.
/// It has to be derived the same way the heartbeat derives it: a name
/// spelled any other way can never match, and a request for it waits out
/// its whole retry window and then reports a failure that did not happen.
public struct ModeButton: Sendable, Equatable, Identifiable {
    public var label: String
    public var mode: String
    public var request: ModeRequest

    public var id: String { mode }
}

/// What DO_SET_MODE carries for one mode.
///
/// ArduPilot takes its custom mode number in param2. PX4 takes a main mode
/// in param2 and a sub mode in param3, not the packed custom_mode its own
/// heartbeat reports -- sending the packed number, as the Android build
/// does, asks PX4 for a main mode of several hundred thousand.
public struct ModeRequest: Sendable, Equatable {
    public var param2: Float
    public var param3: Float = 0
}

public enum FlightModes {
    private static let copter: [UInt32: String] = [
        0: "STABILIZE", 1: "ACRO", 2: "ALT_HOLD", 3: "AUTO", 4: "GUIDED",
        5: "LOITER", 6: "RTL", 7: "CIRCLE", 9: "LAND", 11: "DRIFT",
        13: "SPORT", 14: "FLIP", 15: "AUTOTUNE", 16: "POSHOLD", 17: "BRAKE",
        18: "THROW", 21: "SMART_RTL", 25: "AUTO_RTL",
    ]

    private static let plane: [UInt32: String] = [
        0: "MANUAL", 1: "CIRCLE", 2: "STABILIZE", 3: "TRAINING", 4: "ACRO",
        5: "FBWA", 6: "FBWB", 7: "CRUISE", 8: "AUTOTUNE", 10: "AUTO",
        11: "RTL", 12: "LOITER", 13: "TAKEOFF", 14: "AVOID_ADSB", 15: "GUIDED",
        16: "INITIALISING", 17: "QSTABILIZE", 18: "QHOVER", 19: "QLOITER",
        20: "QLAND", 21: "QRTL", 22: "QAUTOTUNE", 23: "QACRO", 24: "THERMAL",
        25: "LOITER_ALT_QLAND", 26: "AUTOLAND",
    ]

    private static let rover: [UInt32: String] = [
        0: "MANUAL", 3: "STEERING", 4: "HOLD", 5: "LOITER", 10: "AUTO",
        11: "RTL", 12: "SMART_RTL", 15: "GUIDED",
    ]

    /// The name of an ArduPilot custom mode, for this kind of vehicle.
    public static func ardupilotMode(vehicleType: String, customMode: UInt32) -> String {
        let table: [UInt32: String]
        switch VehicleKind(vehicleType: vehicleType) {
        case .plane: table = plane
        case .copter: table = copter
        case .rover: table = rover
        }
        return table[customMode] ?? "MODE \(customMode)"
    }

    /// The name of a PX4 custom mode: main mode in bits 16-23, sub in 24-31.
    public static func px4Mode(customMode: UInt32) -> String {
        let main = (customMode >> 16) & 0xFF
        let sub = (customMode >> 24) & 0xFF
        switch main {
        case 1: return "MANUAL"
        case 2: return "ALTITUDE"
        case 3: return "POSITION"
        case 4:
            switch sub {
            case 1: return "AUTO READY"
            case 2: return "AUTO TAKEOFF"
            case 3: return "AUTO LOITER"
            case 4: return "AUTO MISSION"
            case 5: return "AUTO RTL"
            case 6: return "AUTO LAND"
            default: return "AUTO"
            }
        case 5: return "ACRO"
        case 6: return "OFFBOARD"
        case 7: return "STABILIZED"
        default: return "PX4 \(customMode)"
        }
    }

    /// The mode name a heartbeat reports, for any firmware.
    public static func modeName(firmware: Firmware, vehicleType: String, customMode: UInt32) -> String {
        switch firmware {
        case .ardupilot: return ardupilotMode(vehicleType: vehicleType, customMode: customMode)
        case .px4: return px4Mode(customMode: customMode)
        case .unknown: return "MODE \(customMode)"
        }
    }

    private static func ardupilot(_ label: String, _ number: UInt32) -> ModeButton {
        ModeButton(label: label, mode: label, request: ModeRequest(param2: Float(number)))
    }

    private static func px4(_ label: String, _ main: UInt32, _ sub: UInt32 = 0) -> ModeButton {
        let packed = main << 16 | sub << 24
        return ModeButton(
            label: label,
            mode: px4Mode(customMode: packed),
            request: ModeRequest(param2: Float(main), param3: Float(sub))
        )
    }

    /// The Flight Mode panel's buttons for this vehicle, three to a row.
    ///
    /// The plane rows are the Android panel's own. The others follow the same
    /// shape -- the everyday modes first, the way home in the middle -- so a
    /// pilot who flies both finds RTL where they left it.
    public static func panel(firmware: Firmware, vehicleType: String) -> [[ModeButton]] {
        if firmware == .px4 {
            return [
                [px4("MANUAL", 1), px4("STABILIZED", 7), px4("ALTITUDE", 2)],
                [px4("HOLD", 4, 3), px4("MISSION", 4, 4), px4("RTL", 4, 5)],
                [px4("POSITION", 3), px4("TAKEOFF", 4, 2), px4("LAND", 4, 6)],
            ]
        }
        switch VehicleKind(vehicleType: vehicleType) {
        case .plane:
            return [
                [ardupilot("MANUAL", 0), ardupilot("FBWA", 5), ardupilot("CRUISE", 7)],
                [ardupilot("LOITER", 12), ardupilot("AUTO", 10), ardupilot("RTL", 11)],
                [ardupilot("TAKEOFF", 13), ardupilot("AUTOLAND", 26), ardupilot("AUTOTUNE", 8)],
            ]
        case .copter:
            return [
                [ardupilot("STABILIZE", 0), ardupilot("ALT_HOLD", 2), ardupilot("POSHOLD", 16)],
                [ardupilot("LOITER", 5), ardupilot("AUTO", 3), ardupilot("RTL", 6)],
                [ardupilot("BRAKE", 17), ardupilot("LAND", 9), ardupilot("SMART_RTL", 21)],
            ]
        case .rover:
            return [
                [ardupilot("MANUAL", 0), ardupilot("STEERING", 3), ardupilot("HOLD", 4)],
                [ardupilot("LOITER", 5), ardupilot("AUTO", 10), ardupilot("RTL", 11)],
            ]
        }
    }

    /// GUIDED, which sits apart from the grid beside the fly-to controls.
    /// Nil for PX4, which has no mode by that name: a reposition puts it in
    /// its own hold at the new point.
    public static func guided(firmware: Firmware, vehicleType: String) -> ModeButton? {
        guard firmware != .px4 else { return nil }
        switch VehicleKind(vehicleType: vehicleType) {
        case .plane, .rover: return ardupilot("GUIDED", 15)
        case .copter: return ardupilot("GUIDED", 4)
        }
    }
}
