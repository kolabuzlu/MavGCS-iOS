import Foundation
import MavlinkCore
import Observation
import TerrainCore

/// The terrain radar's working half: the ground ahead, sampled as the
/// desktop's TerrainRadarWorker and the Android build sample it, and what it
/// is coloured against. The Live AGL panel's too: the ground along the track,
/// read in the same pass as the fan and from mostly the same tiles, which
/// makes it nearly free, and the track actually flown.
///
/// It looks at the telemetry often, but takes a new fan only when the
/// aircraft has moved a meaningful part of a cell, turned, changed range, or
/// the picture has gone stale. A fan can mean downloading terrain, so taking
/// one per telemetry update would be far too often.
@Observable
final class TerrainRadar {
    /// How often the telemetry is looked at, as on the desktop.
    static let pollInterval = Duration.milliseconds(200)
    /// A fan older than this is taken again even if nothing moved.
    static let staleSeconds = 5.0
    /// Climb samples averaged into the predictive slope.
    static let varioSamples = 5

    /// The ground ahead, heights above the sea. Kept through a failed sample:
    /// the last picture is better than none while a tile is fetched again.
    private(set) var fan: TerrainFan?
    /// What the aircraft's height is taken to be: the last one it reported.
    ///
    /// Clearance is measured from it, so a dropped link must not quietly
    /// become an altitude of zero -- every cell would read as ground above
    /// the aircraft and the fan would go red, warning of a collision that is
    /// not happening. Until there has been a reading there is nothing to
    /// colour against at all.
    private(set) var altMslM: Float?
    /// Climb over ground speed, which projects the height forward along the
    /// fan in predictive mode.
    private(set) var slope: Double = 0
    /// What the reader is busy with, for the words shown while there is no
    /// fan to draw.
    private(set) var activity = TerrainActivity.idle

    /// The ground along the track for the Live AGL panel, as last sampled.
    /// Gone with the link, as the panel is: there is no height above anything
    /// without an aircraft.
    private(set) var profile: AglProfile?
    /// The gradient the Live AGL panel draws the path ahead at: climb over
    /// ground speed as it is now, clamped, rather than the radar's average.
    private(set) var aglSlope: Double = 0
    /// Bumped whenever the track flown gains a point, so the panel can tell.
    private(set) var flownVersion = 0

    /// The radar and the Live AGL panel, each switched on and off from its
    /// own button over the map. Both start on. Switched back on, the ground
    /// is read again at once rather than on the next stale tick, so the
    /// picture that comes back is not an old one.
    var showsRadar = true {
        didSet { if showsRadar, !oldValue { sampled = nil } }
    }
    var showsAgl = true {
        didSet { if showsAgl, !oldValue { sampled = nil } }
    }

    /// Whether the Live AGL panel is up: switched on, with some ground to
    /// draw and a height to measure it from.
    var aglShown: Bool { showsAgl && profile?.hasData == true && altMslM != nil }

    /// How much clearance the red to green ramp spans.
    var scaleM = TerrainClearance.defaultScaleM
    /// Clearance from where the present gradient will put the aircraft,
    /// rather than from its height now.
    var predictive = false

    @ObservationIgnored private var vehicle = VehicleState()
    @ObservationIgnored private var climbSamples: [Float] = []
    @ObservationIgnored private var vario: (climb: Float?, speed: Float?) = (nil, nil)
    @ObservationIgnored private var rangeM = TerrainSampler.rangeSteps[0]
    @ObservationIgnored private var sampled: SampledAt?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var flown = FlownTrack()
    @ObservationIgnored private var linkWasOpen = false

    private struct SampledAt {
        let lat: Double
        let lon: Double
        let headingDeg: Double
        let rangeM: Double
        let at: Date
    }

    init() {
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sampleIfDue()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    /// The track flown, as the Live AGL panel draws it: no further astern
    /// than it looks, oldest first.
    func flownTrack(within behindM: Double) -> [AglTrackPoint] {
        flown.astern(within: behindM)
    }

    /// The newest telemetry. Cheap: sampling happens on the radar's own time.
    func update(_ state: VehicleState) {
        vehicle = state
        if state.linkOpen != linkWasOpen {
            linkWasOpen = state.linkOpen
            if !state.linkOpen { linkGone() }
        }
        if let alt = state.altMslM, alt != altMslM {
            altMslM = alt
        }
        if let lat = state.lat, let lon = state.lon, lat != 0 || lon != 0, let alt = state.altMslM,
           flown.record(lat: lat, lon: lon, amslM: Double(alt)) {
            flownVersion += 1
        }
        let gradient = LiveAgl.slope(climbMs: state.climbMs, groundSpeedMs: state.groundSpeedMs)
        if gradient != aglSlope {
            aglSlope = gradient
        }
        // A new climb sample each time the climb or the speed moves on, as
        // the Android build takes them: a single vario reading is far too
        // twitchy to aim a terrain warning with.
        if state.climbMs != vario.climb || state.groundSpeedMs != vario.speed {
            vario = (state.climbMs, state.groundSpeedMs)
            climbSamples.append(state.climbMs ?? 0)
            if climbSamples.count > Self.varioSamples {
                climbSamples.removeFirst(climbSamples.count - Self.varioSamples)
            }
            let next = TerrainClearance.slope(climbSamples: climbSamples, groundSpeedMs: state.groundSpeedMs ?? 0)
            if next != slope {
                slope = next
            }
        }
    }

    /// The desktop's _on_link_gone, as far as the ground goes: the radar stops
    /// resampling a position nothing is flying over any more, though the last
    /// fan stays up, and the track flown belongs to that flight, not to
    /// whatever connects next.
    private func linkGone() {
        sampled = nil
        flown.clear()
        flownVersion += 1
        profile = nil
    }

    private func sampleIfDue() async {
        let state = vehicle
        // Nothing to read the ground for with both of its panels switched
        // off. Track-up: the ground track is what the aircraft will actually
        // cross, and it parts from the nose in any crosswind.
        guard showsRadar || showsAgl, state.linkOpen,
              let lat = state.lat, let lon = state.lon, lat != 0 || lon != 0,
              let heading = (state.groundCourseDeg ?? state.headingDeg).map(Double.init)
        else { return }

        rangeM = TerrainSampler.nextRange(current: rangeM, speedMs: Double(state.groundSpeedMs ?? 0))
        let cellM = rangeM / Double(TerrainSampler.radCells)
        if let last = sampled,
           Date().timeIntervalSince(last.at) <= Self.staleSeconds,
           TerrainSampler.distanceM(lat1: last.lat, lon1: last.lon, lat2: lat, lon2: lon) <= cellM * 0.5,
           TerrainSampler.angleDiff(heading, last.headingDeg) <= 2,
           last.rangeM == rangeM {
            return
        }

        if showsRadar {
            // While there is nothing drawn, say what the reader is doing: the
            // first fan over new ground can take a download or two.
            let watch: Task<Void, Never>? = fan == nil ? Task { [weak self] in
                while !Task.isCancelled {
                    let now = await CopernicusDEM.shared.activity
                    self?.show(now)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            } : nil
            let next = await CopernicusDEM.shared.fan(lat: lat, lon: lon, headingDeg: heading, rangeM: rangeM)
            watch?.cancel()
            let now = await CopernicusDEM.shared.activity
            show(now)

            if next.hasData, next != fan {
                fan = next
            }
        }

        // Same pass, same reader, and mostly the same tiles the fan has just
        // read -- the track runs up the middle of it.
        let behind = rangeM * TerrainSampler.profileBehindFraction
        var ground: [Float] = []
        if showsAgl {
            ground = await CopernicusDEM.shared.trackProfile(
                lat: lat, lon: lon, headingDeg: heading, behindM: behind, aheadM: rangeM
            )
        }
        // Not if the link went while it was being read.
        if vehicle.linkOpen, !ground.isEmpty {
            let slice = AglProfile(elevations: ground, behindM: behind, aheadM: rangeM)
            if slice != profile {
                profile = slice
            }
        }
        // Recorded even when the sample failed, so a dead link is retried on
        // the stale timer rather than every tick.
        sampled = SampledAt(lat: lat, lon: lon, headingDeg: heading, rangeM: rangeM, at: Date())
    }

    private func show(_ now: TerrainActivity) {
        if activity != now {
            activity = now
        }
    }
}
