import Foundation
import Testing
@testable import TerrainCore

/// The Live AGL panel's figures, against the desktop's drawAglProfile.
struct LiveAglTests {
    private func profile(_ elevations: [Float], behind: Double = 100, ahead: Double = 300) -> AglProfile {
        AglProfile(elevations: elevations, behindM: behind, aheadM: ahead)
    }

    @Test func slopeIsClimbOverGroundSpeedWithinReason() {
        #expect(LiveAgl.slope(climbMs: 2, groundSpeedMs: 20) == 0.1)
        #expect(LiveAgl.slope(climbMs: -2, groundSpeedMs: 20) == -0.1)
        #expect(LiveAgl.slope(climbMs: 20, groundSpeedMs: 10) == 0.55, "past a thirty degree climb")
        #expect(LiveAgl.slope(climbMs: -20, groundSpeedMs: 10) == -0.55)
        #expect(LiveAgl.slope(climbMs: 2, groundSpeedMs: 2.9) == 0, "not going anywhere")
        #expect(LiveAgl.slope(climbMs: nil, groundSpeedMs: 20) == 0)
        #expect(LiveAgl.slope(climbMs: 2, groundSpeedMs: nil) == 0)
    }

    @Test func gridlinesFallOnRoundNumbers() {
        #expect(LiveAgl.niceStep(100) == 20)
        #expect(LiveAgl.niceStep(60) == 20)
        #expect(LiveAgl.niceStep(1300) == 500)
        #expect(LiveAgl.niceStep(7) == 2)
        #expect(LiveAgl.niceStep(50) == 10)
        #expect(LiveAgl.niceStep(0) == 1)
    }

    @Test func readsTheHeightHereAndTheGapAhead() throws {
        let picture = try #require(AglPicture(profile: profile(Array(repeating: 400, count: 80)), amslM: 500, slope: 0, track: []))
        #expect(picture.aglM == 100)
        #expect(picture.clearAheadM == 100)
        #expect(picture.alarm == .none)
        // The aircraft's own level is always in the picture, with some room.
        #expect(picture.hi == 12 && picture.lo == -112)
    }

    @Test func rampsUpAsTheGroundRisesAhead() throws {
        // Level with the aircraft behind, rising to 20 m below it at the far end.
        let rising = (0..<80).map { i -> Float in
            let distance = -100 + 400 * Double(i) / 79
            return distance <= 0 ? 400 : Float(400 + 80 * distance / 300)
        }
        let level = try #require(AglPicture(profile: profile(rising), amslM: 500, slope: 0, track: []))
        #expect(abs(level.clearAheadM! - 20) < 0.001)
        #expect(level.alarm == .warn)

        // Descending one in ten, the same ground is in the way.
        let descending = try #require(AglPicture(profile: profile(rising), amslM: 500, slope: -0.1, track: []))
        #expect(descending.clearAheadM! < 0)
        #expect(descending.alarm == .bad)

        // Climbing away from it, nothing to say.
        let climbing = try #require(AglPicture(profile: profile(rising), amslM: 500, slope: 0.1, track: []))
        #expect(climbing.alarm == .none)
    }

    @Test func flatGroundIsNotSquashedIntoASliver() throws {
        let picture = try #require(AglPicture(profile: profile(Array(repeating: 490, count: 80)), amslM: 500, slope: 0, track: []))
        #expect(abs(picture.hi - 7.2) < 1e-9)
        #expect(abs(picture.lo - -67.2) < 1e-9)
    }

    @Test func theTrackFlownFitsBecauseItHappened() throws {
        let track = [AglTrackPoint(asternM: 80, amslM: 700)]
        let picture = try #require(AglPicture(profile: profile(Array(repeating: 400, count: 80)), amslM: 500, slope: 0, track: track))
        #expect(picture.hi > 200)
    }

    @Test func nothingToDrawWithoutGround() {
        #expect(AglPicture(profile: profile(Array(repeating: .nan, count: 80)), amslM: 500, slope: 0, track: []) == nil)
        #expect(AglPicture(profile: profile([400]), amslM: 500, slope: 0, track: []) == nil)
    }

    @Test func aglComesFromTheNearestGroundKnown() throws {
        var elevations = [Float](repeating: .nan, count: 80)
        elevations[30] = 420 // nearest the aircraft of the two
        elevations[70] = 300
        let picture = try #require(AglPicture(profile: profile(elevations), amslM: 500, slope: 0, track: []))
        #expect(picture.aglM == 80)
        #expect(picture.clearAheadM == 80, "both are ahead; the nearer is the tighter")
    }

    @Test func keepsTheTrackFlownForAsFarAsItIsWanted() {
        var track = FlownTrack()
        let started = track.record(lat: 40.5, lon: 30.5, amslM: 500)
        #expect(!started, "the first fix is only a start")
        let crept = track.record(lat: 40.500005, lon: 30.5, amslM: 500)
        #expect(!crept, "half a metre is not going anywhere")
        // North in steps of about 11 m, climbing a metre a step.
        for step in 1...500 {
            track.record(lat: 40.5 + 0.0001 * Double(step), lon: 30.5, amslM: 500 + Double(step))
        }
        let behind = track.astern(within: 100)
        #expect(behind.count == 9)
        #expect(behind.first!.asternM > behind.last!.asternM, "oldest first")
        #expect(behind.last!.asternM == 0 && behind.last!.amslM == 1000)
        // About 5.5 km flown, and no more than 4 km of it kept.
        let all = track.astern(within: 10_000)
        #expect(all.first!.asternM <= FlownTrack.keepM)
        #expect(all.first!.asternM > FlownTrack.keepM - 20)

        track.clear()
        #expect(track.astern(within: 10_000).isEmpty)
    }

    @Test func samplesTheGroundAlongTheTrack() async {
        let dem = CopernicusDEM(source: DemTests.source(), disk: TerrainDiskCache(directory: nil))
        let heights = await dem.trackProfile(lat: 40.5, lon: 30.5, headingDeg: 90, behindM: 0, aheadM: 900)
        #expect(heights.count == TerrainSampler.profileSamples)
        #expect(!heights.contains { $0.isNaN })
        #expect(heights.first == (await dem.elevation(lat: 40.5, lon: 30.5)), "the first sample is under the aircraft")
        #expect(await dem.trackProfile(lat: 40.5, lon: 30.5, headingDeg: 90, behindM: 0, aheadM: 0).isEmpty)
    }
}
