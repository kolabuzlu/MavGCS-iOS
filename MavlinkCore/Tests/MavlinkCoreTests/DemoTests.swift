import Foundation
import Testing
@testable import MavlinkCore

/// The built-in demo aircraft: that it flies the modes on the app's panel,
/// answers what the app sends, and talks to the app like a real one.
struct DemoTests {
    private func packet(_ message: some MavlinkMessage) -> MavlinkPacket {
        MavlinkPacket(
            frame: MavlinkFrame(
                version: .v2, sequence: 0, systemId: 255, componentId: 190,
                messageId: type(of: message).messageId, payload: [], signed: false
            ),
            message: message
        )
    }

    private func command(_ id: UInt16, _ param1: Float = 0, _ param2: Float = 0) -> MavlinkPacket {
        packet(CommandLong(targetSystem: 1, targetComponent: 1, command: id, param1: param1, param2: param2))
    }

    private func fly(_ vehicle: inout DemoVehicle, seconds: Double, until done: (DemoVehicle) -> Bool = { _ in false }) {
        for _ in 0..<Int(seconds / 0.05) {
            vehicle.step(0.05)
            _ = vehicle.due()
            if done(vehicle) { return }
        }
    }

    private func result(_ replies: [any MavlinkMessage]) -> UInt8? {
        (replies.first as? CommandAck)?.result
    }

    @Test func startsInTheAirCirclingHome() throws {
        var vehicle = DemoVehicle()
        let first = vehicle.due()
        let heartbeat = try #require(first.first as? Heartbeat)
        #expect(heartbeat.type == MavType.fixedWing && heartbeat.autopilot == MavAutopilot.ardupilotmega)
        #expect(heartbeat.customMode == DemoVehicle.Mode.loiter)
        #expect(heartbeat.baseMode & MavModeFlag.safetyArmed != 0)
        #expect(first.contains { ($0 as? Statustext)?.text.hasPrefix("DEMO") == true }, "it says it is a simulation")

        for _ in 0..<6 {
            fly(&vehicle, seconds: 10)
            let d = vehicle.distance(to: DemoVehicle.home)
            #expect(d > 90 && d < 230, "orbiting at \(d) m")
            #expect(abs(vehicle.altRel - DemoVehicle.cruiseAltitude) < 5)
        }
    }

    @Test func fliesToThePointTappedAndCirclesIt() {
        var vehicle = DemoVehicle()
        let target = (lat: DemoVehicle.home.lat, lon: DemoVehicle.home.lon + 0.012) // about 1 km east
        let replies = vehicle.handle(packet(CommandInt(
            targetSystem: 1, targetComponent: 1, frame: MavFrame.globalRelativeAltInt, command: MavCmd.doReposition,
            param1: -1, param2: 1, x: Int32(target.lat * 1e7), y: Int32(target.lon * 1e7), z: 150
        )))
        #expect(result(replies) == MavResult.accepted)
        #expect(vehicle.mode == DemoVehicle.Mode.guided)
        fly(&vehicle, seconds: 150)
        #expect(vehicle.distance(to: target) < vehicle.loiterRadius + 70)
        #expect(abs(vehicle.altRel - 150) < 8)
    }

    @Test func comesHomeOnRtl() {
        var vehicle = DemoVehicle()
        _ = vehicle.handle(packet(CommandInt(
            command: MavCmd.doReposition, x: Int32((DemoVehicle.home.lat + 0.015) * 1e7), y: Int32(DemoVehicle.home.lon * 1e7)
        )))
        fly(&vehicle, seconds: 120)
        #expect(vehicle.distance(to: DemoVehicle.home) > 1200)
        #expect(result(vehicle.handle(command(MavCmd.doSetMode, 1, Float(DemoVehicle.Mode.rtl)))) == MavResult.accepted)
        fly(&vehicle, seconds: 150)
        #expect(vehicle.distance(to: DemoVehicle.home) < 250)
    }

    @Test func landsDisarmsAndTakesOffAgain() {
        var vehicle = DemoVehicle()
        // Not in the air, unless forced -- as ArduPlane.
        #expect(result(vehicle.handle(command(MavCmd.componentArmDisarm, 0))) == MavResult.failed)
        #expect(vehicle.armed)

        _ = vehicle.handle(command(MavCmd.doSetMode, 1, Float(DemoVehicle.Mode.autoland)))
        fly(&vehicle, seconds: 400) { $0.onGround && !$0.armed }
        #expect(vehicle.onGround && !vehicle.armed, "landed and disarmed itself")
        #expect(vehicle.distance(to: DemoVehicle.home) < 200)

        #expect(result(vehicle.handle(command(MavCmd.componentArmDisarm, 1))) == MavResult.accepted)
        _ = vehicle.handle(command(MavCmd.doSetMode, 1, Float(DemoVehicle.Mode.takeoff)))
        fly(&vehicle, seconds: 60)
        #expect(!vehicle.onGround && vehicle.altRel > 85)
    }

    @Test func refusesModesItDoesNotHave() {
        var vehicle = DemoVehicle()
        #expect(result(vehicle.handle(command(MavCmd.doSetMode, 1, 99))) == MavResult.denied)
        #expect(result(vehicle.handle(command(MavCmd.doSetMode, 1, .nan))) == MavResult.denied)
        #expect(vehicle.mode == DemoVehicle.Mode.loiter)
    }

    @Test func holdsTheLoiterRadiusToWhatArduPlaneCanStore() throws {
        var vehicle = DemoVehicle()
        var reply = try #require(vehicle.handle(packet(ParamSet(paramId: "WP_LOITER_RAD", paramValue: 250))).first as? ParamValue)
        #expect(reply.paramValue == 250 && vehicle.loiterRadius == 250)
        reply = try #require(vehicle.handle(packet(ParamSet(paramId: "WP_LOITER_RAD", paramValue: 40_000))).first as? ParamValue)
        #expect(reply.paramValue == 32767)
    }

    @Test func sendsWhatItIsAskedForAtTheRateAsked() {
        var vehicle = DemoVehicle()
        _ = vehicle.handle(command(MavCmd.setMessageInterval, Float(Attitude.messageId), 200_000))
        _ = vehicle.handle(command(MavCmd.setMessageInterval, Float(Wind.messageId), -1))
        var attitudes = 0
        var winds = 0
        for _ in 0..<40 {
            vehicle.step(0.05)
            for message in vehicle.due() {
                if message is Attitude { attitudes += 1 }
                if message is Wind { winds += 1 }
            }
        }
        #expect((9...11).contains(attitudes), "5 Hz over 2 s: \(attitudes)")
        #expect(winds == 0)
    }

    @Test func flightTestThroughTheAppsOwnLink() async throws {
        let client = MavlinkClient()
        client.connect(LinkConfig(type: .demo))
        defer { client.disconnect() }

        var state = client.snapshot()
        for _ in 0..<50 where !(state.heard && state.mode == "LOITER") {
            try await Task.sleep(for: .milliseconds(100))
            state = client.snapshot()
        }
        #expect(state.heard && state.linkUp && state.mode == "LOITER")
        #expect(state.vehicleType == "FIXED_WING" && state.readyToArm)
        #expect(state.messages.contains { $0.text.hasPrefix("DEMO") })

        let rtl = try #require(FlightModes.panel(firmware: .ardupilot, vehicleType: "FIXED_WING").joined().first { $0.label == "RTL" })
        client.setFlightMode(rtl)
        for _ in 0..<30 where client.snapshot().mode != "RTL" {
            try await Task.sleep(for: .milliseconds(100))
        }
        state = client.snapshot()
        #expect(state.mode == "RTL" && state.modePending == nil)
        #expect(state.lat != nil && state.homeLat != nil && state.batteryRemainingPct != nil)

        // A plane with no rangefinder, and everything else in order.
        let systems = SystemHealth.cells(state)
        #expect(systems.first { $0.label == "RNGFND" }?.state == .absent)
        #expect(systems.filter { $0.label != "RNGFND" }.allSatisfy { $0.state == .ok }, "\(systems)")
    }
}
