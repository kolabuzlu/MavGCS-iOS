import Foundation
import Testing
@testable import MavlinkCore

/// Holds the Systems strip to the desktop's behaviour.
///
/// health_cases.txt is the Android build's table, produced by running MavGCS
/// Desktop's own SensorHealthPanel methods -- extracted from main.py, not
/// paraphrased -- over every present/enabled/health combination for each of
/// the eight cells, boundary sweeps on the GPS, HDOP, satellite and variance
/// thresholds, and twelve hundred random combinations for breadth.
///
/// SITL reports everything healthy, so the amber and red paths never run on
/// a live link. This is what covers them.
struct SystemHealthTests {
    @Test func verdictsMatchTheDesktop() throws {
        let url = try #require(Bundle.module.url(forResource: "health_cases", withExtension: "txt", subdirectory: "Vectors"))
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        // A silently empty table would make every check below vacuous.
        #expect(lines.count > 1000, "expected a full case table, got \(lines.count)")

        var mismatches: [String] = []
        var checked = 0
        var seen: Set<String> = []
        for line in lines {
            let halves = line.split(separator: ">", maxSplits: 1).map(String.init)
            let field = halves[0].split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            var vehicle = VehicleState()
            vehicle.sensorsPresent = mask(field[0])
            vehicle.sensorsEnabled = mask(field[1])
            vehicle.sensorsHealth = mask(field[2])
            vehicle.gpsFixType = Int(field[3]).map { UInt8(truncatingIfNeeded: $0) }
            vehicle.satellites = Int(field[4])
            vehicle.hdop = Float(field[5])
            vehicle.ekfCompassVariance = Float(field[6])
            vehicle.ekfPosHorizVariance = Float(field[7])
            vehicle.ekfPosVertVariance = Float(field[8])
            vehicle.ekfTerrainVariance = Float(field[9])
            vehicle.ekfTint = tint(field[10])
            vehicle.vibeTint = tint(field[11])

            let actual = SystemHealth.cells(vehicle)
            let wanted = halves[1].split(separator: "~").map { $0.split(separator: "=", maxSplits: 2).map(String.init) }
            #expect(actual.count == wanted.count, "cell count")
            for (want, got) in zip(wanted, actual) {
                checked += 1
                seen.insert(name(got.state))
                if got.label != want[0] || name(got.state) != want[1] || got.detail != want[2] {
                    mismatches.append("\(halves[0])  \(want[0]): desktop=\(want[1])/'\(want[2])' ios=\(name(got.state))/'\(got.detail)'")
                }
            }
        }

        // Every verdict must actually occur, or a table that only ever said
        // "ok" would pass while proving nothing.
        #expect(seen == ["absent", "off", "ok", "warn", "failed"], "every verdict should be exercised")
        #expect(checked > 8000, "expected thousands of checks, got \(checked)")
        #expect(mismatches.isEmpty, "\(mismatches.count) of \(checked) cells disagree:\n\(mismatches.prefix(20).joined(separator: "\n"))")
    }

    @Test func blankUntilSysStatusHasSpoken() {
        var vehicle = VehicleState()
        vehicle.gpsFixType = 3
        vehicle.ekfTint = .red
        #expect(SystemHealth.cells(vehicle) == SystemHealth.noTelemetry)
        #expect(SystemHealth.noTelemetry.map(\.label) == ["GYRO", "ACC", "MAG", "BARO", "GPS", "RNGFND", "PITOT", "EKF"])
    }

    @Test func theClientCarriesWhatTheStripReads() throws {
        // The two inputs the HUD never needed: the enabled mask, and the
        // variances one by one rather than folded into the EKF word.
        let rig = Harness()
        rig.receive(Harness.planeHeartbeat())
        rig.receive(SysStatus(
            onboardControlSensorsPresent: 0x21_002F,
            onboardControlSensorsEnabled: 0x21_000F,
            onboardControlSensorsHealth: 0x21_002F
        ))
        rig.receive(EkfStatusReport(
            flags: EkfStatusFlags.attitude | EkfStatusFlags.velocityHoriz,
            velocityVariance: 0.1, posHorizVariance: 0.6, posVertVariance: 0.2,
            compassVariance: 0.9, terrainAltVariance: 0.3
        ))
        let state = rig.state()
        #expect(state.sensorsEnabled == 0x21_000F)
        #expect(state.ekfCompassVariance == 0.9 && state.ekfPosHorizVariance == 0.6)
        #expect(state.ekfPosVertVariance == 0.2 && state.ekfTerrainVariance == 0.3)
        let cells = Dictionary(uniqueKeysWithValues: SystemHealth.cells(state).map { ($0.label, $0) })
        #expect(cells["GPS"]?.state == .off, "present but not enabled")
        #expect(cells["MAG"]?.state == .failed && cells["MAG"]?.detail == "MAG variance high")
    }

    private func mask(_ text: String) -> UInt32? {
        Int64(text).map { UInt32(truncatingIfNeeded: $0) }
    }

    private func tint(_ text: String) -> HealthTint? {
        switch text {
        case "white": .white
        case "yellow": .yellow
        case "red": .red
        default: nil
        }
    }

    private func name(_ state: HealthState) -> String {
        switch state {
        case .absent: "absent"
        case .off: "off"
        case .ok: "ok"
        case .warn: "warn"
        case .failed: "failed"
        }
    }
}
