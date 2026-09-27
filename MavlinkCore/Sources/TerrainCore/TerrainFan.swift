import Foundation

/// Ground heights over a forward polar fan, row-major as `[a * radCells + b]`,
/// NaN where the height is not known. Cell `a` runs left to right across the
/// fan and `b` outwards from the aircraft.
public struct TerrainFan: Sendable, Equatable {
    public let elevations: [Float]
    public let rangeM: Double
    public var angCells: Int { TerrainSampler.angCells }
    public var radCells: Int { TerrainSampler.radCells }

    public init(elevations: [Float], rangeM: Double) {
        self.elevations = elevations
        self.rangeM = rangeM
    }

    /// The height in a cell, or NaN.
    public func elevation(angular: Int, radial: Int) -> Float {
        elevations[angular * radCells + radial]
    }

    /// How far out the centre of a radial ring sits, in metres.
    public func distanceOf(radial: Int) -> Double {
        rangeM * (Double(radial) + 0.5) / Double(radCells)
    }

    /// True once at least one cell carries a real height.
    public var hasData: Bool { elevations.contains { !$0.isNaN } }

    // NaN is not equal to itself, so two fans over the same sea would
    // otherwise never compare equal and every resample would redraw.
    public static func == (lhs: TerrainFan, rhs: TerrainFan) -> Bool {
        lhs.rangeM == rhs.rangeM
            && lhs.elevations.elementsEqual(rhs.elevations) { $0 == $1 || ($0.isNaN && $1.isNaN) }
    }
}

/// The shape of the fan and the rules for when to take a new one, as the
/// desktop's TerrainRadarWorker and the Android build have them. The rules
/// matter because a new fan can mean a block download, which is slow.
public enum TerrainSampler {
    /// Half the fan's width; the whole sweep is twice this.
    public static let halfAngleDeg = 60.0
    public static let angCells = 32
    public static let radCells = 16

    /// Range steps in metres, picked from ground speed.
    public static let rangeSteps: [Double] = [300, 900, 1800, 3600]

    /// The smallest step covering this many seconds of flight is chosen.
    static let lookaheadS = 120.0
    /// Speed has to fall this far below a step before dropping back to it.
    static let stepDownHysteresis = 0.7

    /// How far the Live AGL profile looks back, as a fraction of the range
    /// it looks ahead.
    public static let profileBehindFraction = 0.35
    /// Points along the profile. Eighty reads smooth at panel width.
    public static let profileSamples = 80

    private static let earthRadiusM = 6_371_000.0

    /// The range to draw at for a ground speed, given the range already in
    /// use. Stepping up is immediate; stepping down waits for the speed to
    /// fall clear of the boundary, so the picture does not flip back and
    /// forth while the speed hovers there.
    public static func nextRange(current: Double, speedMs: Double) -> Double {
        let need = speedMs * lookaheadS
        let index = rangeSteps.firstIndex(of: current) ?? 0
        let target = rangeSteps.first { $0 >= need } ?? rangeSteps[rangeSteps.count - 1]
        if target > current {
            return target
        }
        if target < current, index > 0, need < rangeSteps[index - 1] * stepDownHysteresis {
            return target
        }
        return current
    }

    /// Great-circle destination from a start point, bearing and distance.
    public static func destination(lat: Double, lon: Double, bearingDeg: Double, distanceM: Double) -> (lat: Double, lon: Double) {
        let angular = distanceM / earthRadiusM
        let bearing = bearingDeg * .pi / 180
        let lat1 = lat * .pi / 180
        let lon1 = lon * .pi / 180
        let lat2 = asin(sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(bearing))
        let lon2 = lon1 + atan2(
            sin(bearing) * sin(angular) * cos(lat1),
            cos(angular) - sin(lat1) * sin(lat2)
        )
        return (lat2 * 180 / .pi, lon2 * 180 / .pi)
    }

    /// Great-circle distance in metres.
    public static func distanceM(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let p1 = lat1 * .pi / 180
        let p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180
        let dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * earthRadiusM * asin(min(1, sqrt(a)))
    }

    /// The smallest turn between two headings, in degrees.
    public static func angleDiff(_ a: Double, _ b: Double) -> Double {
        abs((a - b + 540).truncatingRemainder(dividingBy: 360) - 180)
    }
}

/// How a cell is coloured: by the clearance beneath the aircraft rather than
/// by the height of the ground, so the colour answers the only question that
/// matters. Red where the ground is at or above the aircraft, through orange
/// and yellow, to green at the edge of the scale; beyond it, nothing.
public enum TerrainClearance {
    public static let scaleMinM: Float = 5
    public static let scaleMaxM: Float = 2000
    public static let defaultScaleM: Float = 120

    /// Where a cell sits on the ramp, 0 red to 1 green, or nil to leave it
    /// unpainted: no height known, or the ground more than the scale below.
    /// Clearance is taken from the aircraft's height now or, predictive, from
    /// where its present gradient puts it by the time it gets there.
    public static func fraction(
        elevation: Float,
        distanceM: Double,
        altMslM: Float,
        slope: Double,
        predictive: Bool,
        scaleM: Float
    ) -> Float? {
        guard !elevation.isNaN else { return nil }
        let reference = predictive ? altMslM + Float(slope * distanceM) : altMslM
        let clearance = reference - elevation
        guard clearance < scaleM else { return nil }
        return min(max(clearance / scaleM, 0), 1)
    }

    /// Climb over ground speed: the gradient being flown, averaged over the
    /// climb samples given because one vario reading is far too twitchy to
    /// aim a terrain warning with. Level below 2 m/s, where it means nothing.
    public static func slope(climbSamples: [Float], groundSpeedMs: Float) -> Double {
        guard groundSpeedMs > 2, !climbSamples.isEmpty else { return 0 }
        let average = Double(climbSamples.reduce(0, +)) / Double(climbSamples.count)
        return average / Double(groundSpeedMs)
    }
}
