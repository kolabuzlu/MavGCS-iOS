/// The colour of a HUD status word: EKF or VIBE.
///
/// White is the quiet state, not the absence of one. Mission Planner shows
/// the word whatever it has to say, so its going missing would be a fault
/// the pilot could not see.
public enum HealthTint: Sendable, Equatable {
    case white
    case yellow
    case red
}

/// The EKF and vibration verdicts, as the desktop MavGCS reaches them.
///
/// Ported from Mission Planner's own CurrentState.cs and HUD.cs, not from
/// ArduPilot's general guidance on variances, so the words turn colour at
/// exactly the moments they do in Mission Planner -- and in the desktop and
/// Android builds, which carry the same port.
public enum HealthVerdict {
    /// Mission Planner's three-way banding, shared by both words: over the
    /// warning mark is yellow, over the bad mark red.
    public static func tint(_ value: Float, warn: Float, bad: Float) -> HealthTint {
        if value > bad { return .red }
        if value > warn { return .yellow }
        return .white
    }

    /// The EKF word: the worst of the five variances, banded at 0.5 and 0.8.
    ///
    /// Three flag states force the top of the scale whatever the variances
    /// say: no attitude estimate, no horizontal velocity while there is a
    /// GPS fix to have one from, and a filter not yet initialised. Mission
    /// Planner deliberately does not look at EKF_GPS_GLITCHING or
    /// EKF_CONST_POS_MODE here, despite what their names suggest, so
    /// neither does this.
    ///
    /// [gpsFixType] is GPS_RAW_INT's fix_type, and "a fix" is anything
    /// above zero, as in Mission Planner -- which counts 1, NO_FIX, as one.
    public static func ekf(_ report: EkfStatusReport, gpsFixType: UInt8?) -> HealthTint {
        let flags = report.flags
        let haveGpsFix = (gpsFixType ?? 0) > 0
        let score: Float
        if flags & EkfStatusFlags.attitude == 0 {
            score = 1
        } else if flags & EkfStatusFlags.velocityHoriz == 0 && haveGpsFix {
            score = 1
        } else if flags & EkfStatusFlags.uninitialized != 0 {
            score = 1
        } else {
            score = max(
                report.velocityVariance,
                report.compassVariance,
                report.posHorizVariance,
                report.posVertVariance,
                report.terrainAltVariance
            )
        }
        return tint(score, warn: 0.5, bad: 0.8)
    }

    /// The VIBE word: the worst of the three raw axes, banded at 30 and 60.
    ///
    /// The clipping counters are deliberately left out. They start climbing
    /// well below 30 on plenty of boards, and folding them in -- which the
    /// desktop once did -- forced red and skipped yellow entirely.
    public static func vibration(_ report: Vibration) -> HealthTint {
        tint(max(report.vibrationX, report.vibrationY, report.vibrationZ), warn: 30, bad: 60)
    }
}
