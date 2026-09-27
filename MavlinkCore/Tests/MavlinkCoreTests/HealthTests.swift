import Foundation
import Testing
@testable import MavlinkCore

/// The HUD's EKF and VIBE words against the desktop's own rules, edge by
/// edge, and the rates handed back when a link closes.
struct HealthTests {
    private static let healthy = EkfStatusFlags.attitude | EkfStatusFlags.velocityHoriz

    private func ekf(_ variance: Float, flags: UInt16 = healthy, fix: UInt8? = 3, worstIs: Int = 0) -> HealthTint {
        var v: [Float] = [0.1, 0.1, 0.1, 0.1, 0.1]
        v[worstIs] = variance
        return HealthVerdict.ekf(
            EkfStatusReport(
                flags: flags,
                velocityVariance: v[0],
                posHorizVariance: v[2],
                posVertVariance: v[3],
                compassVariance: v[1],
                terrainAltVariance: v[4]
            ),
            gpsFixType: fix
        )
    }

    @Test func ekfBandsAtHalfAndPointEight() {
        #expect(ekf(0.5) == .white, "not over 0.5")
        #expect(ekf(0.51) == .yellow)
        #expect(ekf(0.8) == .yellow, "not over 0.8")
        #expect(ekf(0.81) == .red)
    }

    @Test func ekfTakesTheWorstOfAllFiveVariances() {
        for index in 0..<5 {
            #expect(ekf(0.9, worstIs: index) == .red, "variance \(index)")
            #expect(ekf(0.6, worstIs: index) == .yellow, "variance \(index)")
        }
    }

    @Test func ekfFlagsForceRedWhateverTheVariances() {
        #expect(ekf(0.1, flags: EkfStatusFlags.velocityHoriz) == .red, "no attitude")
        #expect(ekf(0.1, flags: EkfStatusFlags.attitude, fix: 3) == .red, "no velocity, with a fix")
        #expect(ekf(0.1, flags: Self.healthy | EkfStatusFlags.uninitialized) == .red, "uninitialised")
    }

    @Test func ekfIgnoresMissingVelocityWithoutAFix() {
        #expect(ekf(0.1, flags: EkfStatusFlags.attitude, fix: 0) == .white)
        #expect(ekf(0.1, flags: EkfStatusFlags.attitude, fix: nil) == .white)
        // Mission Planner's "a fix" is anything above zero -- NO_FIX (1) too.
        #expect(ekf(0.1, flags: EkfStatusFlags.attitude, fix: 1) == .red)
    }

    @Test func ekfIgnoresTheFlagsMissionPlannerIgnores() {
        #expect(ekf(0.1, flags: Self.healthy | EkfStatusFlags.gpsGlitching) == .white)
        #expect(ekf(0.1, flags: Self.healthy | EkfStatusFlags.constPosMode) == .white)
    }

    @Test func vibeBandsAtThirtyAndSixtyOnTheWorstAxis() {
        func vibe(_ x: Float, _ y: Float, _ z: Float, clipping: UInt32 = 0) -> HealthTint {
            HealthVerdict.vibration(Vibration(vibrationX: x, vibrationY: y, vibrationZ: z, clipping0: clipping, clipping1: clipping, clipping2: clipping))
        }
        #expect(vibe(30, 5, 5) == .white, "not over 30")
        #expect(vibe(5, 30.1, 5) == .yellow)
        #expect(vibe(5, 5, 60) == .yellow, "not over 60")
        #expect(vibe(5, 5, 60.1) == .red)
        #expect(vibe(10, 10, 10, clipping: 5000) == .white, "clipping is not counted")
    }

    @Test func theWordsFollowTheReports() {
        let h = Harness()
        h.receive(Harness.planeHeartbeat())
        #expect(h.state().ekfTint == nil && h.state().vibeTint == nil, "nothing reported yet")
        h.receive(GpsRawInt(fixType: 3))
        h.receive(EkfStatusReport(flags: EkfStatusFlags.attitude))
        h.receive(Vibration(vibrationX: 45))
        #expect(h.state().ekfTint == .red)
        #expect(h.state().vibeTint == .yellow)
    }

    // MARK: - Rates handed back

    @Test func disconnectingHandsEveryRateBack() {
        let h = Harness()
        h.receive(Harness.planeHeartbeat())
        let reduced = h.sentCommands().filter { $0.command == MavCmd.setMessageInterval }
        h.clearSent()
        h.client.disconnect()
        let restored = h.sentCommands().filter { $0.command == MavCmd.setMessageInterval }
        #expect(!restored.isEmpty)
        #expect(Set(restored.map(\.param1)) == Set(reduced.map(\.param1)))
        #expect(restored.allSatisfy { $0.param2 == 0 })
    }

    @Test func nothingIsHandedBackWithFullTelemetryOrNoVehicle() {
        let full = Harness()
        full.client.setStreamRates(StreamRates(full: true))
        full.receive(Harness.planeHeartbeat())
        full.clearSent()
        full.client.disconnect()
        #expect(full.sentCommands().isEmpty, "full telemetry changed nothing")

        let silent = Harness()
        silent.client.disconnect()
        #expect(silent.sentCommands().isEmpty, "no vehicle was ever heard")
    }

    @Test func reconnectingHandsTheOldLinksRatesBackFirst() {
        let h = Harness()
        h.receive(Harness.planeHeartbeat())
        h.clearSent()
        h.client.connect(LinkConfig(type: .tcp, host: "127.0.0.1", port: 5760))
        let restored = h.sentCommands().filter { $0.command == MavCmd.setMessageInterval }
        #expect(!restored.isEmpty)
        #expect(restored.allSatisfy { $0.param2 == 0 })
    }
}
