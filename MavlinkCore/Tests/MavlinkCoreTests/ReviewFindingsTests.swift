import Foundation
import Testing
@testable import MavlinkCore

/// The problems a verified review of the whole app found in this library,
/// each pinned by the case that showed it.
struct ReviewFindingsTests {
    @Test func readsOnlyThePrimaryBattery() {
        let h = Harness()
        h.receive(Harness.planeHeartbeat())
        h.receive(SysStatus(voltageBattery: 22_400, currentBattery: 1500, batteryRemaining: 60))
        var avionics = [UInt16](repeating: UInt16.max, count: 10)
        avionics[0] = 8200
        // ArduPilot's second monitor, taking its turn: not the flight pack.
        h.receive(BatteryStatus(id: 1, voltages: avionics, currentBattery: 30, batteryRemaining: 95))
        var s = h.state()
        #expect(s.batteryV == 22.4 && s.batteryA == 15 && s.batteryRemainingPct == 60)

        var flight = [UInt16](repeating: UInt16.max, count: 10)
        flight[0] = 22_100
        h.receive(BatteryStatus(id: 0, voltages: flight, currentBattery: 1450, batteryRemaining: 59))
        s = h.state()
        #expect(s.batteryV == 22.1 && s.batteryA == 14.5 && s.batteryRemainingPct == 59)
    }

    @Test func setsTheStreamsUpAgainWhenTheAutopilotRestarts() {
        let h = Harness()
        h.receive(Harness.planeHeartbeat())
        h.receive(Attitude(timeBootMs: 600_000))
        h.clearSent()

        // A frame or two out of order is not a restart.
        h.receive(Attitude(timeBootMs: 599_000))
        #expect(h.sentMessages().isEmpty)

        // The clock back near zero is: a battery swap behind a bridge that
        // stayed up.
        h.receive(Attitude(timeBootMs: 4_000))
        let sent = h.sentMessages()
        #expect(sent.contains { $0 is RequestDataStream })
        #expect(sent.compactMap { $0 as? CommandLong }.contains { $0.command == MavCmd.setMessageInterval })
        #expect(sent.compactMap { $0 as? CommandLong }.contains {
            $0.command == MavCmd.requestMessage && $0.param1 == Float(HomePosition.messageId)
        })
        #expect(h.notes().contains { $0.contains("restarted") })
    }

    @Test func takesNoCommandsOnceTheLinkHasEnded() throws {
        let h = Harness()
        h.receive(Harness.planeHeartbeat(mode: 12))
        h.clearSent()
        h.transport.end(.closedByPeer)
        h.client.flush()

        let rtl = try #require(FlightModes.panel(firmware: .ardupilot, vehicleType: "FIXED_WING").joined().first { $0.label == "RTL" })
        h.client.setFlightMode(rtl)
        h.client.flyTo(lat: 39.9, lon: 32.8, altitudeM: 100)
        h.client.flush()
        let s = h.state()
        #expect(s.modePending == nil, "nothing was sent, so nothing is pending")
        #expect(s.heard, "the last frame stays up")
        #expect(!s.canCommand)
        #expect(h.transport.sentFrames().isEmpty)
    }

    @Test func readsExtensionsAddedSinceTheseDefinitions() throws {
        // PX4 1.14 and later send SYS_STATUS with the 2022 extended sensor
        // fields, which this build's definitions end before.
        let known = SysStatus(voltageBattery: 16_400, currentBattery: 1200, batteryRemaining: 80).payload()
        let payload = known + [0, 0, 0, 0x10, 0, 0, 0, 0x10, 0]
        var frame: [UInt8] = [0xFD, UInt8(payload.count), 0, 0, 7, 1, 1, UInt8(SysStatus.messageId), 0, 0]
        frame += payload
        var crc = Crc16()
        crc.accumulate(frame[1...])
        crc.accumulate(SysStatus.crcExtra)
        frame += [UInt8(crc.value & 0xFF), UInt8(crc.value >> 8)]

        var parser = FrameParser()
        let packets = parser.push(frame)
        let status = try #require(packets.first?.message as? SysStatus)
        #expect(packets.count == 1)
        #expect(status.voltageBattery == 16_400 && status.batteryRemaining == 80)

        // MAVLink 1 has no extensions, so a v1 frame of the wrong length is
        // still not a frame.
        var v1: [UInt8] = [0xFE, UInt8(payload.count), 7, 1, 1, UInt8(SysStatus.messageId)]
        v1 += payload
        var crc1 = Crc16()
        crc1.accumulate(v1[1...])
        crc1.accumulate(SysStatus.crcExtra)
        v1 += [UInt8(crc1.value & 0xFF), UInt8(crc1.value >> 8)]
        var parser1 = FrameParser()
        #expect(parser1.push(v1).isEmpty)
    }

    @Test func noTerrainDataIsNotAHeightOfZero() {
        let h = Harness()
        h.receive(Harness.planeHeartbeat())
        h.receive(TerrainReport(spacing: 0, terrainHeight: 0))
        #expect(h.state().terrainAltM == nil)
        h.receive(TerrainReport(spacing: 100, terrainHeight: 850.5))
        #expect(h.state().terrainAltM == 850.5)
        // Off the edge of the tiles it holds: the last real reading stands.
        h.receive(TerrainReport(spacing: 0, terrainHeight: 0))
        #expect(h.state().terrainAltM == 850.5)
    }

    @Test func namesCopterModesAsArduCopterNumbersThem() {
        #expect(FlightModes.modeName(firmware: .ardupilot, vehicleType: "QUADROTOR", customMode: 25) == "SYSTEMID")
        #expect(FlightModes.modeName(firmware: .ardupilot, vehicleType: "QUADROTOR", customMode: 27) == "AUTO_RTL")
        #expect(FlightModes.modeName(firmware: .ardupilot, vehicleType: "QUADROTOR", customMode: 21) == "SMART_RTL")
    }

    @Test func roundsAbsurdFiguresWithoutTrapping() {
        #expect(MavlinkClient.round(120) == "120")
        #expect(MavlinkClient.round(120.46) == "120.5")
        #expect(MavlinkClient.round(1e19) == "1e+19")
        #expect(MavlinkClient.round(.infinity) == "inf")
    }

    @Test func theFirstSecondIsMeasuredOnItsOwn() {
        var stats = LinkStats()
        for sequence in 0..<10 { stats.onRx(bytes: 100, systemId: 1, componentId: 1, sequence: UInt8(sequence)) }
        _ = stats.sample(now: 1)
        for sequence in 10..<20 { stats.onRx(bytes: 100, systemId: 1, componentId: 1, sequence: UInt8(sequence)) }
        let first = stats.sample(now: 2)
        #expect(first.rxBytesPerSec == 1000)
        #expect(first.rxPerSec == 10)
    }

    @Test func notANumberIsNotAReading() {
        let h = Harness()
        h.receive(Heartbeat(type: MavType.quadrotor, autopilot: MavAutopilot.px4, baseMode: MavModeFlag.customModeEnabled, customMode: 0, systemStatus: MavState.active))
        h.receive(VfrHud(airspeed: .nan, groundspeed: 3, heading: 90, throttle: 40, alt: 120, climb: .nan))
        let s = h.state()
        #expect(s.airSpeedMs == nil && s.climbMs == nil)
        #expect(s.groundSpeedMs == 3 && s.altMslM == 120)
    }
}
