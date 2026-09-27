import Foundation

/// How a subsystem is doing, for one cell of the Systems strip.
///
/// Four states rather than two. SYS_STATUS carries three bitmasks --
/// present, enabled, healthy -- and they answer different questions: a
/// sensor can be fitted and switched off, or fitted and broken, and those
/// are not the same trouble. Folding them into one green light would throw
/// away the distinction that says which.
public enum HealthState: Sendable, Equatable {
    case absent
    case off
    case ok
    case warn
    case failed
}

/// One cell of the Systems strip.
public struct SystemStatus: Sendable, Equatable {
    public let label: String
    public let state: HealthState
    /// Why, in the words of the desktop's tooltip.
    public let detail: String
}

/// The autopilot's own view of every subsystem it reports on.
///
/// Ported from the desktop MavGCS's SensorHealthPanel, by way of the Android
/// build's SystemHealth, and held to the desktop's answers by the same table
/// of cases the Android build is tested against.
///
/// Green is meant to mean nothing is wrong, not merely that the autopilot
/// has not declared the part broken. SYS_STATUS answers the narrower
/// question -- is the hardware working -- and it goes on answering yes
/// through a GPS with no fix, a compass arguing with its neighbours, and an
/// airframe shaking itself apart. So where the aircraft sends something
/// sharper, that decides too; it can only ever make a cell worse.
public enum SystemHealth {
    /// Bit and label, roughly in the order they matter on a preflight: the
    /// IMU, then what corrects it, then what it needs to navigate.
    static let sensors: [(bit: UInt32, label: String)] = [
        (MavSysStatusSensor.sensor3dGyro, "GYRO"),
        (MavSysStatusSensor.sensor3dAccel, "ACC"),
        (MavSysStatusSensor.sensor3dMag, "MAG"),
        (MavSysStatusSensor.sensorAbsolutePressure, "BARO"),
        (MavSysStatusSensor.sensorGps, "GPS"),
        (MavSysStatusSensor.sensorLaserPosition, "RNGFND"),
        (MavSysStatusSensor.sensorDifferentialPressure, "PITOT"),
        (MavSysStatusSensor.ahrs, "EKF"),
    ]

    /// Mission Planner's own bands for an EKF variance: over 0.5 is worth a
    /// look, over 0.8 means the filter is rejecting the measurement.
    static let varianceWarn: Float = 0.5
    static let varianceBad: Float = 0.8

    /// What ArduPilot itself calls a good enough GPS to arm on: GPS_HDOP_GOOD
    /// defaults to 1.4, and the arming check wants six satellites. A fix that
    /// would not pass those is a fix, but it is not a healthy GPS.
    static let hdopGood: Float = 1.4
    static let satsGood = 6

    static let tipAbsent = "not fitted, or not reported by this autopilot"
    static let tipOff = "fitted but not enabled"
    static let tipOk = "present, enabled and healthy"
    static let tipFailed = "present and enabled, but reporting unhealthy"
    static let tipNoTelemetry = "no telemetry"

    /// Every cell dim: nothing to ask, so nothing guessed.
    public static let noTelemetry: [SystemStatus] = sensors.map {
        SystemStatus(label: $0.label, state: .absent, detail: tipNoTelemetry)
    }

    /// Every cell, in strip order.
    public static func cells(_ vehicle: VehicleState) -> [SystemStatus] {
        guard let present = vehicle.sensorsPresent,
              let enabled = vehicle.sensorsEnabled,
              let health = vehicle.sensorsHealth
        else { return noTelemetry }
        return sensors.map { bit, label in
            let base: HealthState
            if present & bit == 0 {
                base = .absent
            } else if enabled & bit == 0 {
                base = .off
            } else {
                base = health & bit != 0 ? .ok : .failed
            }
            guard base == .ok else {
                return SystemStatus(label: label, state: base, detail: tip(for: base))
            }
            // A good sensor can still be argued down by a sharper source.
            if let (state, why) = secondOpinion(label, vehicle) {
                return SystemStatus(label: label, state: state, detail: why)
            }
            return SystemStatus(label: label, state: .ok, detail: tipOk)
        }
    }

    private static func tip(for state: HealthState) -> String {
        switch state {
        case .absent: tipAbsent
        case .off: tipOff
        case .ok: tipOk
        case .warn, .failed: tipFailed
        }
    }

    /// A second opinion, for the cells that have one. GYRO and PITOT reach
    /// here with nothing: neither the EKF nor any other message carries a
    /// figure for them, so those two are only ever as good as the
    /// autopilot's own health bit.
    private static func secondOpinion(_ label: String, _ vehicle: VehicleState) -> (HealthState, String)? {
        var worst: (HealthState, String)?
        func worse(_ candidate: (HealthState, String)?) {
            guard let candidate else { return }
            let rank = { (state: HealthState) in state == .failed ? 2 : 1 }
            if worst.map({ rank(candidate.0) > rank($0.0) }) ?? true {
                worst = candidate
            }
        }

        switch label {
        case "GPS":
            if let fix = vehicle.gpsFixType {
                if fix <= 1 {
                    worse((.failed, "no fix"))
                } else if fix == 2 {
                    worse((.warn, "2D fix only"))
                }
            }
            if let sats = vehicle.satellites, sats < satsGood {
                worse((.warn, "only \(sats) satellites"))
            }
            if let hdop = vehicle.hdop, hdop > hdopGood {
                worse((.warn, String(format: "HDOP %.1f", hdop)))
            }
            worse(variance("GPS", vehicle.ekfPosHorizVariance))
        case "MAG":
            worse(variance("MAG", vehicle.ekfCompassVariance))
        case "BARO":
            worse(variance("BARO", vehicle.ekfPosVertVariance))
        case "RNGFND":
            worse(variance("RNGFND", vehicle.ekfTerrainVariance))
        case "EKF":
            switch vehicle.ekfTint {
            case .red: worse((.failed, "EKF variances high"))
            case .yellow: worse((.warn, "EKF variances raised"))
            default: break
            }
        case "ACC":
            // Vibration is measured off the accelerometers, so it belongs to
            // this cell: the sensor is healthy but what it is being asked to
            // measure through is not.
            switch vehicle.vibeTint {
            case .red: worse((.failed, "vibration above 60"))
            case .yellow: worse((.warn, "vibration above 30"))
            default: break
            }
        default:
            break
        }
        return worst
    }

    /// A cell's own EKF variance, if it has one, as a state.
    private static func variance(_ label: String, _ value: Float?) -> (HealthState, String)? {
        guard let value, value >= 0 else { return nil }
        if value > varianceBad { return (.failed, "\(label) variance high") }
        if value > varianceWarn { return (.warn, "\(label) variance raised") }
        return nil
    }
}
