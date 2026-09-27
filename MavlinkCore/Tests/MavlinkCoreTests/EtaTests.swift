import Testing
@testable import MavlinkCore

/// ETA to WP, against the desktop's own rules.
struct EtaTests {
    private func vehicle(mode: String = "AUTO", distance: Float? = 1500, speed: Float? = 20) -> VehicleState {
        var state = VehicleState()
        state.mode = mode
        state.distToWpM = distance
        state.groundSpeedMs = speed
        return state
    }

    @Test func timesTheWayToTheWaypoint() {
        #expect(Eta.text(vehicle()) == "1:15")
        #expect(Eta.text(vehicle(distance: 80_000)) == "1:06:40")
        #expect(Eta.text(vehicle(distance: 1192, speed: 20)) == "1:00", "59.6 s rounds up to a minute")
    }

    @Test func onlyModesThatFlySomewhereAreTimed() {
        for mode in ["AUTO", "GUIDED", "RTL", "AUTOLAND", "QRTL"] {
            #expect(Eta.text(vehicle(mode: mode)) != "--", "\(mode)")
        }
        // Hand-flown modes still report a distance, to a waypoint nothing is
        // flying to. TAKEOFF's distance recedes as it flies.
        for mode in ["LOITER", "MANUAL", "FBWA", "CRUISE", "TAKEOFF", "UNKNOWN"] {
            #expect(Eta.text(vehicle(mode: mode)) == "--", "\(mode)")
        }
    }

    @Test func noHonestAnswerIsADash() {
        #expect(Eta.text(vehicle(distance: nil)) == "--")
        #expect(Eta.text(vehicle(speed: nil)) == "--")
        #expect(Eta.text(vehicle(distance: 0.5)) == "--", "zero distance is no waypoint, not arrival")
        #expect(Eta.text(vehicle(speed: 0.9)) == "--", "standing still")
        #expect(Eta.text(vehicle(distance: 65_000, speed: 1)) != "--", "just under 100 hours")
        #expect(Eta.text(vehicle(distance: 60_000, speed: 1)) != "--")
        #expect(Eta.seconds(vehicle(distance: 65_000, speed: 0.1)) == nil, "past 100 hours")
    }
}
