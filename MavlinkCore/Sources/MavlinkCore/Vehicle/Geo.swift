import Foundation

/// Small spherical-earth helpers. The distances involved are a few
/// kilometres, where the sphere is wrong by far less than GPS is.
public enum Geo {
    public static let earthRadiusM = 6_371_000.0

    /// Wraps a bearing into 0..<360, the convention all state uses.
    public static func normaliseBearing(_ degrees: Float) -> Float {
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }

    /// Great-circle distance in metres, or nil unless both points are known.
    public static func distance(_ lat1: Double?, _ lon1: Double?, _ lat2: Double?, _ lon2: Double?) -> Float? {
        guard let lat1, let lon1, let lat2, let lon2 else { return nil }
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = pow(sin(dLat / 2), 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * pow(sin(dLon / 2), 2)
        // min() guards asin against floating point drift above 1.
        return Float(2 * earthRadiusM * asin(min(1, sqrt(a))))
    }

    /// Initial bearing from one point to another, 0..<360 degrees true.
    public static func bearing(fromLat lat1: Double, lon lon1: Double, toLat lat2: Double, lon lon2: Double) -> Double {
        let phi1 = lat1 * .pi / 180
        let phi2 = lat2 * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let y = sin(dLon) * cos(phi2)
        let x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(dLon)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    /// The point [distanceM] along [bearingDeg] from a start.
    public static func destination(lat: Double, lon: Double, bearingDeg: Double, distanceM: Double) -> (lat: Double, lon: Double) {
        let delta = distanceM / earthRadiusM
        let theta = bearingDeg * .pi / 180
        let phi1 = lat * .pi / 180
        let lambda1 = lon * .pi / 180
        let phi2 = asin(sin(phi1) * cos(delta) + cos(phi1) * sin(delta) * cos(theta))
        let lambda2 = lambda1 + atan2(sin(theta) * sin(delta) * cos(phi1), cos(delta) - sin(phi1) * sin(phi2))
        return (phi2 * 180 / .pi, (lambda2 * 180 / .pi + 540).truncatingRemainder(dividingBy: 360) - 180)
    }

    /// Sea level pressure from the absolute reading, via the standard
    /// atmosphere. With no altitude to correct for, the absolute reading is
    /// already the answer.
    public static func qnh(pressAbsHpa: Float, altMslM: Float?) -> Float {
        guard let altitude = altMslM else { return pressAbsHpa }
        return Float(Double(pressAbsHpa) * pow(1 - 0.0065 * Double(altitude) / 288.15, -5.257))
    }
}
