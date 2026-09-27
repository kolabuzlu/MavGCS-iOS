import Foundation

/// The desktop's Live AGL panel, less the drawing: height above the ground
/// along the track, behind on the left and ahead on the right, and the two
/// numbers it exists for -- the height above the ground here, and the
/// smallest gap anywhere ahead along the path the aircraft is on.
public enum LiveAgl {
    /// Beyond about a thirty degree climb the aircraft is not flying a
    /// trajectory any more, it is in trouble, and the line would leave the box.
    public static let maxSlope = 0.55
    /// Sitting still, "where will I be in two kilometres" has no answer.
    public static let minGroundSpeedMs: Float = 3
    /// The number ahead turns amber below this much clearance, red at none.
    public static let warnClearanceM = 50.0

    /// Metres of height per metre along the track, clamped, or level when
    /// the aircraft is not going anywhere. The desktop's _agl_slope.
    public static func slope(climbMs: Float?, groundSpeedMs: Float?) -> Double {
        guard let speed = groundSpeedMs, speed >= minGroundSpeedMs else { return 0 }
        let slope = Double(climbMs ?? 0) / Double(speed)
        return min(max(slope, -maxSlope), maxSlope)
    }

    /// A round number of metres per gridline, whatever the span turns out to
    /// be: 1, 2 or 5 times a power of ten. Five lines read about right at the
    /// panel's size.
    public static func niceStep(_ span: Double, want: Double = 5) -> Double {
        guard span > 0 else { return 1 }
        let raw = span / want
        let magnitude = pow(10, floor(log10(raw)))
        let n = raw / magnitude
        return (n <= 1 ? 1 : n <= 2 ? 2 : n <= 5 ? 5 : 10) * magnitude
    }
}

/// The ground along the track, as last sampled: heights above the sea from
/// `behindM` astern to `aheadM` ahead, NaN where no tile has arrived.
public struct AglProfile: Sendable, Equatable {
    public let elevations: [Float]
    public let behindM: Double
    public let aheadM: Double

    public init(elevations: [Float], behindM: Double, aheadM: Double) {
        self.elevations = elevations
        self.behindM = behindM
        self.aheadM = aheadM
    }

    /// True once at least one point carries a real height.
    public var hasData: Bool { elevations.contains { !$0.isNaN } }

    // NaN is not equal to itself: the same sea sampled twice is still the
    // same picture.
    public static func == (lhs: AglProfile, rhs: AglProfile) -> Bool {
        lhs.behindM == rhs.behindM && lhs.aheadM == rhs.aheadM
            && lhs.elevations.elementsEqual(rhs.elevations) { $0 == $1 || ($0.isNaN && $1.isNaN) }
    }
}

/// A point on the track already flown: how far astern it now is, and the
/// height above the sea the aircraft had there.
public struct AglTrackPoint: Sendable, Equatable {
    public let asternM: Double
    public let amslM: Double

    public init(asternM: Double, amslM: Double) {
        self.asternM = asternM
        self.amslM = amslM
    }
}

/// Where the aircraft has actually been, as metres flown and height above the
/// sea, so the line behind it on the panel is the climb and descent it really
/// did rather than a straight line projected backwards from now. The
/// desktop's _agl_history.
public struct FlownTrack: Sendable, Equatable {
    /// Below this the aircraft has not really gone anywhere, and recording
    /// it would stack a pile of points on one spot.
    public static let stepM = 2.0
    /// More than the longest look behind the panel ever asks for, so a
    /// change of range never finds the history already thrown away.
    public static let keepM = 4000.0

    private var points: [Point] = []
    private var flownM = 0.0
    private var lastLat: Double?
    private var lastLon: Double?

    private struct Point: Sendable, Equatable {
        let flownM: Double
        let amslM: Double
    }

    public init() {}

    /// One more point, if the aircraft has moved far enough since the last.
    /// True if one was added.
    @discardableResult
    public mutating func record(lat: Double, lon: Double, amslM: Double) -> Bool {
        guard let lastLat, let lastLon else {
            self.lastLat = lat
            self.lastLon = lon
            return false
        }
        let step = TerrainSampler.distanceM(lat1: lastLat, lon1: lastLon, lat2: lat, lon2: lon)
        guard step >= Self.stepM else { return false }
        self.lastLat = lat
        self.lastLon = lon
        flownM += step
        points.append(Point(flownM: flownM, amslM: amslM))
        let cutoff = flownM - Self.keepM
        if let keep = points.firstIndex(where: { $0.flownM >= cutoff }), keep > 0 {
            points.removeFirst(keep)
        }
        return true
    }

    /// The track as the panel wants it: no further astern than it looks,
    /// oldest first.
    public func astern(within behindM: Double) -> [AglTrackPoint] {
        guard behindM > 0 else { return [] }
        return points.compactMap { point in
            let astern = flownM - point.flownM
            return astern >= 0 && astern <= behindM ? AglTrackPoint(asternM: astern, amslM: point.amslM) : nil
        }
    }

    /// The track belongs to a flight: the next aircraft to connect starts
    /// its own.
    public mutating func clear() {
        self = FlownTrack()
    }
}

/// Everything the panel shows, worked out from the ground and the aircraft
/// the way the desktop's drawAglProfile does before it draws.
public struct AglPicture: Sendable {
    /// The ground relative to the aircraft at each sample: negative below
    /// it, positive standing higher than it is flying. NaN where unknown.
    public let relative: [Double]
    /// The aircraft's height above the sea, which everything is relative to.
    public let amslM: Double
    public let behindM: Double
    public let aheadM: Double
    public let slope: Double
    public let track: [AglTrackPoint]
    /// The heights, relative to the aircraft, at the bottom and top of the
    /// plot.
    public let lo: Double
    public let hi: Double
    /// Height above the ground right here.
    public let aglM: Double?
    /// The smallest gap anywhere ahead, against the path the aircraft is on
    /// rather than its present height held level, so a descent towards
    /// rising ground reads as the problem it is.
    public let clearAheadM: Double?

    public enum Alarm: Sendable {
        case none
        /// Less than LiveAgl.warnClearanceM to spare somewhere ahead.
        case warn
        /// The path meets the ground.
        case bad
    }

    /// Nil when there is nothing to draw: no ground known yet.
    public init?(profile: AglProfile, amslM: Double, slope: Double, track: [AglTrackPoint]) {
        let n = profile.elevations.count
        let span = profile.behindM + profile.aheadM
        guard n >= 2, span > 0 else { return nil }

        var relative: [Double] = []
        relative.reserveCapacity(n)
        var lo = 0.0
        var hi = 0.0
        var any = false
        for elevation in profile.elevations {
            guard !elevation.isNaN else {
                relative.append(.nan)
                continue
            }
            let r = Double(elevation) - amslM
            relative.append(r)
            if !any {
                lo = r
                hi = r
                any = true
            }
            lo = min(lo, r)
            hi = max(hi, r)
        }
        guard any else { return nil }

        // Always show the aircraft's own level, and never squash the picture
        // into a sliver when the ground happens to be flat. The track flown
        // has to fit, because it happened. The projection ahead deliberately
        // does not: a steep climb would put its far end a kilometre above
        // everything else and press the ground -- the thing the panel is
        // for -- into a few pixels. It runs off the edge instead.
        hi = max(hi, 0)
        lo = min(lo, 0)
        for point in track {
            let r = point.amslM - amslM
            hi = max(hi, r)
            lo = min(lo, r)
        }
        if hi - lo < 60 { lo = hi - 60 }
        let pad = (hi - lo) * 0.12
        hi += pad
        lo -= pad

        self.relative = relative
        self.amslM = amslM
        self.behindM = profile.behindM
        self.aheadM = profile.aheadM
        self.slope = slope
        self.track = track
        self.lo = lo
        self.hi = hi

        // The known sample nearest the aircraft, and the tightest gap ahead.
        var here: (index: Int, distance: Double)?
        var worstGap: Double?
        for i in 0..<n where !relative[i].isNaN {
            let distance = -profile.behindM + span * Double(i) / Double(n - 1)
            if here.map({ abs(distance) < abs($0.distance) }) ?? true {
                here = (i, distance)
            }
            if distance >= 0 {
                let gap = slope * distance - relative[i]
                if worstGap.map({ gap < $0 }) ?? true {
                    worstGap = gap
                }
            }
        }
        aglM = here.map { -relative[$0.index] }
        clearAheadM = worstGap
    }

    /// How far along the track a sample is, negative astern.
    public func distance(ofSample i: Int) -> Double {
        -behindM + (behindM + aheadM) * Double(i) / Double(relative.count - 1)
    }

    /// What the number ahead should look like: amber as the gap ahead
    /// closes, red once there is none. The number is the point of the whole
    /// panel, so it should not need reading to alarm.
    public var alarm: Alarm {
        guard let gap = clearAheadM else { return .none }
        if gap <= 0 { return .bad }
        return gap < LiveAgl.warnClearanceM ? .warn : .none
    }
}
