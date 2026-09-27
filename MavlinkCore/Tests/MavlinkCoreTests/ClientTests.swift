import Foundation
import Testing
@testable import MavlinkCore

/// The client driven by hand: a fake link, a clock that only moves when
/// told, and the once-a-second housekeeping run on demand.
struct ClientTests {
    // MARK: - First contact

    @Test func firstHeartbeatAsksForStreamsBeforeRates() throws {
        let h = Harness()
        h.receive(Harness.planeHeartbeat())
        let sent = h.sentMessages()
        // REQUEST_DATA_STREAM first: ArduPilot rebuilds its schedule from
        // it, so anything sent before it would be wiped.
        let first = try #require(sent.first as? RequestDataStream)
        #expect(first.reqStreamId == 0 && first.startStop == 1)
        let commands = sent.compactMap { $0 as? CommandLong }
        #expect(commands.first?.command == MavCmd.requestMessage)
        #expect(commands.first?.param1 == Float(HomePosition.messageId))
        let intervals = Dictionary(
            commands.filter { $0.command == MavCmd.setMessageInterval }.map { (UInt32($0.param1), $0.param2) },
            uniquingKeysWith: { $1 }
        )
        #expect(intervals[Attitude.messageId] == 200_000)
        #expect(intervals[GlobalPositionInt.messageId] == 500_000)
        #expect(intervals[Wind.messageId] == 1_000_000)
        #expect(intervals[EkfStatusReport.messageId] == 2_000_000) // the HUD's EKF word, at the desktop's rate
        #expect(intervals[Vibration.messageId] == 2_000_000)
        #expect(intervals[36] == -1) // SERVO_OUTPUT_RAW, never read
        #expect(intervals[11030] == -1) // ESC telemetry, by number

        // Only once per connection.
        h.clearSent()
        h.receive(Harness.planeHeartbeat())
        #expect(h.sentMessages().isEmpty)
    }

    @Test func ratesChangedInFlightAreSentAtOnceAndOnlyThoseTwo() {
        let h = Harness()
        h.receive(Harness.planeHeartbeat())
        h.clearSent()
        h.client.setStreamRates(StreamRates(attitudeHz: 2, positionHz: 1))
        h.client.flush()
        let sent = h.sentCommands()
        #expect(sent.count == 2)
        #expect(sent.allSatisfy { $0.command == MavCmd.setMessageInterval })
        let intervals = Dictionary(sent.map { (UInt32($0.param1), $0.param2) }, uniquingKeysWith: { $1 })
        #expect(intervals[Attitude.messageId] == 500_000)
        #expect(intervals[GlobalPositionInt.messageId] == 1_000_000)
    }

    @Test func ratesChosenBeforeContactAreTheOnesFirstAskedFor() {
        let h = Harness()
        h.client.setStreamRates(StreamRates(attitudeHz: 3, positionHz: 5))
        h.client.flush()
        #expect(h.sentCommands().isEmpty, "nothing to ask before a vehicle is heard")
        h.receive(Harness.planeHeartbeat())
        let intervals = Dictionary(
            h.sentCommands().filter { $0.command == MavCmd.setMessageInterval }.map { (UInt32($0.param1), $0.param2) },
            uniquingKeysWith: { $1 }
        )
        #expect(intervals[Attitude.messageId] == 333_333)
        #expect(intervals[GlobalPositionInt.messageId] == 200_000)
    }

    @Test func fullTelemetryPutsEveryRateBackToTheVehiclesOwn() {
        let h = Harness()
        h.receive(Harness.planeHeartbeat())
        let reduced = h.sentCommands().filter { $0.command == MavCmd.setMessageInterval }
        h.clearSent()

        h.client.setStreamRates(StreamRates(attitudeHz: 5, positionHz: 2, full: true))
        h.client.flush()
        let full = h.sentCommands().filter { $0.command == MavCmd.setMessageInterval }
        // Every message the reduced set touched, each put back to the
        // vehicle's own rate: zero, not -1 for off. Not asking would leave
        // ArduPilot on the reduced set, which it keeps per ground station.
        #expect(Set(full.map(\.param1)) == Set(reduced.map(\.param1)))
        #expect(full.allSatisfy { $0.param2 == 0 })

        // The two rates mean nothing while full is on.
        h.clearSent()
        h.client.setStreamRates(StreamRates(attitudeHz: 1, positionHz: 1, full: true))
        h.client.flush()
        #expect(h.sentCommands().isEmpty)

        // And leaving it asks for the whole reduced set again.
        h.client.setStreamRates(StreamRates(attitudeHz: 3, positionHz: 1, full: false))
        h.client.flush()
        let back = Dictionary(
            h.sentCommands().filter { $0.command == MavCmd.setMessageInterval }.map { (UInt32($0.param1), $0.param2) },
            uniquingKeysWith: { $1 }
        )
        #expect(back.count == full.count)
        #expect(back[Attitude.messageId] == 333_333)
        #expect(back[GlobalPositionInt.messageId] == 1_000_000)
        #expect(back[36] == -1)
    }

    @Test func fullTelemetryFromTheStartAsksForNothingToBeCut() {
        let h = Harness()
        h.client.setStreamRates(StreamRates(full: true))
        h.client.flush()
        h.receive(Harness.planeHeartbeat())
        let sent = h.sentMessages()
        #expect(sent.first is RequestDataStream)
        let intervals = sent.compactMap { $0 as? CommandLong }.filter { $0.command == MavCmd.setMessageInterval }
        #expect(!intervals.isEmpty)
        #expect(intervals.allSatisfy { $0.param2 == 0 })
    }

    @Test func px4IsNotAskedForWind() {
        let h = Harness()
        h.receive(Heartbeat(type: MavType.quadrotor, autopilot: MavAutopilot.px4, customMode: 3 << 16))
        let asked = h.sentCommands().filter { $0.command == MavCmd.setMessageInterval }.map { UInt32($0.param1) }
        #expect(!asked.isEmpty)
        #expect(!asked.contains(Wind.messageId))
        #expect(h.state().mode == "POSITION")
    }

    @Test func heartbeatDescribesTheVehicle() {
        let h = Harness()
        h.receive(Harness.planeHeartbeat(mode: 12, armed: true))
        let state = h.state()
        #expect(state.heard)
        #expect(state.linkUp)
        #expect(state.firmware == .ardupilot)
        #expect(state.vehicleType == "FIXED_WING")
        #expect(state.kind == .plane)
        #expect(state.mode == "LOITER")
        #expect(state.armed)
        #expect(state.autopilot == "ARDUPILOTMEGA")
    }

    @Test func onlyAutopilotsAreListenedTo() {
        let h = Harness()
        // A gimbal and another ground station, neither of them the vehicle.
        h.receive(Heartbeat(type: 26, autopilot: MavAutopilot.invalid))
        h.receive(Heartbeat(type: MavType.gcs, autopilot: MavAutopilot.ardupilotmega))
        #expect(!h.state().heard)
        #expect(h.sentMessages().isEmpty)
        h.send(.arm)
        #expect(h.sentCommands().isEmpty, "nothing is sent before a vehicle is heard")
    }

    @Test func aSecondVehicleIsIgnored() {
        let h = Harness()
        h.receive(Harness.planeHeartbeat(mode: 12))
        var other = FrameEncoder(systemId: 2, componentId: 1)
        h.client.inject(other.encode(Harness.planeHeartbeat(mode: 11)))
        h.client.inject(other.encode(Attitude(roll: 1)))
        #expect(h.state().mode == "LOITER")
        #expect(h.state().rollDeg == nil)
    }

    // MARK: - Modes

    @Test func aModeIsResentUntilAHeartbeatShowsIt() throws {
        let h = Harness()
        h.receive(Harness.planeHeartbeat(mode: 12))
        h.clearSent()
        let auto = try #require(FlightModes.panel(firmware: .ardupilot, vehicleType: "FIXED_WING").joined().first { $0.label == "AUTO" })
        h.client.setFlightMode(auto)
        h.client.flush()
        #expect(h.state().modePending == "AUTO")
        let first = try #require(h.sentCommands().last)
        #expect(first.command == MavCmd.doSetMode)
        #expect(first.param1 == 1 && first.param2 == 10)

        h.advance(1)
        #expect(h.sentCommands().filter { $0.command == MavCmd.doSetMode }.count == 2)

        h.receive(Harness.planeHeartbeat(mode: 10))
        #expect(h.state().modePending == nil)
        #expect(h.state().mode == "AUTO")
        h.advance(1)
        #expect(h.sentCommands().filter { $0.command == MavCmd.doSetMode }.count == 2)
    }

    @Test func aRefusedModeStopsAtOnceAndSaysWhy() throws {
        let h = Harness()
        h.receive(Harness.planeHeartbeat(mode: 12))
        let rtl = try #require(FlightModes.panel(firmware: .ardupilot, vehicleType: "FIXED_WING").joined().first { $0.label == "RTL" })
        h.client.setFlightMode(rtl)
        h.receive(CommandAck(command: MavCmd.doSetMode, result: MavResult.denied))
        #expect(h.state().modePending == nil)
        #expect(h.notes().last == "The aircraft refused: do set mode.")
    }

    @Test func anUnansweredModeBlamesALossyLink() throws {
        let h = Harness()
        h.receive(Harness.planeHeartbeat(mode: 12))
        let auto = try #require(FlightModes.panel(firmware: .ardupilot, vehicleType: "FIXED_WING").joined().first { $0.label == "AUTO" })
        h.client.setFlightMode(auto)
        h.client.flush()
        for _ in 0..<10 { h.advance(1) }
        #expect(h.state().modePending == nil)
        #expect(h.notes().last == "Mode change to AUTO was not acknowledged - too much of the link is being lost. Press it again.")
        let tries = h.sentCommands().filter { $0.command == MavCmd.doSetMode }.count
        #expect(tries == 10)
    }

    @Test func anUnansweredModeOnACleanLinkBlamesTheUplink() throws {
        let h = Harness()
        h.receive(Harness.planeHeartbeat(mode: 12))
        let auto = try #require(FlightModes.panel(firmware: .ardupilot, vehicleType: "FIXED_WING").joined().first { $0.label == "AUTO" })
        h.client.setFlightMode(auto)
        // Telemetry pouring in without a gap while nothing is answered.
        for _ in 0..<11 {
            for _ in 0..<5 { h.receive(Attitude(roll: 0.1)) }
            h.advance(1)
        }
        #expect(h.notes().contains { $0.hasPrefix("Mode change to AUTO was not acknowledged, though telemetry is arriving normally.") })
    }

    @Test func px4ModesCarryMainAndSubMode() throws {
        let h = Harness()
        h.receive(Heartbeat(type: MavType.quadrotor, autopilot: MavAutopilot.px4, customMode: 3 << 16))
        let mission = try #require(FlightModes.panel(firmware: .px4, vehicleType: "QUADROTOR").joined().first { $0.label == "MISSION" })
        h.client.setFlightMode(mission)
        h.client.flush()
        let sent = try #require(h.sentCommands().last)
        #expect(sent.param2 == 4 && sent.param3 == 4)
        #expect(h.state().modePending == "AUTO MISSION")
        h.receive(Heartbeat(type: MavType.quadrotor, autopilot: MavAutopilot.px4, customMode: 4 << 16 | 4 << 24))
        #expect(h.state().modePending == nil)
        #expect(FlightModes.guided(firmware: .px4, vehicleType: "QUADROTOR") == nil)
    }

    @Test func copterModesAreCopterNumbers() {
        let panel = FlightModes.panel(firmware: .ardupilot, vehicleType: "QUADROTOR").joined()
        #expect(panel.first { $0.label == "LOITER" }?.request.param2 == 5)
        #expect(panel.first { $0.label == "RTL" }?.request.param2 == 6)
        #expect(FlightModes.guided(firmware: .ardupilot, vehicleType: "QUADROTOR")?.request.param2 == 4)
        #expect(FlightModes.guided(firmware: .ardupilot, vehicleType: "FIXED_WING")?.request.param2 == 15)
    }

    // MARK: - Commands and answers

    @Test func anUnansweredCommandIsReportedOnceAndNotResent() {
        let h = Harness()
        h.receive(Harness.planeHeartbeat())
        h.clearSent()
        h.send(.arm)
        #expect(h.sentCommands().count == 1)
        for _ in 0..<5 { h.advance(1) }
        #expect(h.notes().last == "The aircraft did not answer component arm disarm - too much of the link is being lost. Try it again.")
        for _ in 0..<5 { h.advance(1) }
        #expect(h.sentCommands().count == 1)
        #expect(h.notes().filter { $0.contains("did not answer") }.count == 1)
    }

    @Test func anAcceptedCommandIsQuiet() {
        let h = Harness()
        h.receive(Harness.planeHeartbeat())
        h.send(.forceArm)
        let arm = h.sentCommands().last
        #expect(arm?.param2 == 21196)
        h.receive(CommandAck(command: MavCmd.componentArmDisarm, result: MavResult.accepted))
        for _ in 0..<6 { h.advance(1) }
        #expect(h.notes().isEmpty)
    }

    @Test func anAnswerMeantForAnotherGroundStationIsIgnored() {
        let h = Harness()
        h.receive(Harness.planeHeartbeat())
        h.send(.arm)
        h.receive(CommandAck(command: MavCmd.componentArmDisarm, result: MavResult.denied, targetSystem: 254))
        #expect(h.notes().isEmpty)
        h.receive(CommandAck(command: MavCmd.componentArmDisarm, result: MavResult.temporarilyRejected, targetSystem: 255))
        #expect(h.notes().last == "The aircraft not right now - the aircraft is busy or not in a state to do it: component arm disarm.")
    }

    @Test func aClampedLoiterRadiusIsSaidOutLoud() throws {
        let h = Harness()
        h.receive(Harness.planeHeartbeat())
        h.clearSent()
        h.client.setLoiterRadius(30)
        h.client.flush()
        let set = try #require(h.sentMessages().last as? ParamSet)
        #expect(set.paramId == "WP_LOITER_RAD" && set.paramValue == 30 && set.paramType == MavParamType.real32)
        h.receive(ParamValue(paramId: "WP_LOITER_RAD", paramValue: 80, paramType: MavParamType.real32))
        #expect(h.notes().last == "Loiter radius is now 80 m - the aircraft would not take 30 m.")
    }

    @Test func flyToKeepsEveryDigitOfTheCoordinates() throws {
        let h = Harness()
        h.receive(Harness.planeHeartbeat())
        h.client.flyTo(lat: 39.9253861, lon: 32.8365235, altitudeM: 120)
        h.client.flush()
        let command = try #require(h.sentMessages().last as? CommandInt)
        #expect(command.command == MavCmd.doReposition)
        #expect(command.frame == MavFrame.globalRelativeAltInt)
        #expect(command.x == 399_253_861 && command.y == 328_365_235)
        #expect(command.z == 120)
        #expect(command.param2 == 1)
    }

    @Test func everyFrameSentHasItsTrailingZerosCut() {
        let h = Harness()
        h.receive(Harness.planeHeartbeat())
        h.send(.arm)
        for frame in h.transport.sentFrames() {
            let length = Int(frame[1])
            #expect(frame[0] == 0xFD)
            #expect(length == 1 || frame[10 + length - 1] != 0, "a trailing zero went out")
        }
    }

    // MARK: - Silence

    @Test func aSilentLinkIsReportedOnce() {
        let h = Harness()
        for _ in 0..<15 { h.advance(1) }
        #expect(h.notes() == ["Link is open but no vehicle has been heard in 10 seconds. Check the address, the port, and that the vehicle is powered."])
    }

    @Test func theLinkGoesStaleButTheControlsStayLive() {
        let h = Harness()
        h.receive(Harness.planeHeartbeat())
        h.advance(2)
        #expect(h.state().linkUp)
        h.advance(2)
        #expect(!h.state().linkUp)
        #expect(h.state().heard)
    }

    @Test func disconnectingForgetsTheVehicle() {
        let h = Harness()
        h.receive(Harness.planeHeartbeat())
        h.client.disconnect()
        h.client.connect(LinkConfig())
        h.client.flush()
        h.clearSent()
        h.receive(Harness.planeHeartbeat())
        #expect(h.sentMessages().first is RequestDataStream, "stream rates asked for again")
    }

    @Test func aFailedLinkSaysWhyAndCloses() {
        let h = Harness()
        h.transport.end(.errno(ECONNREFUSED, opening: true))
        h.client.flush()
        #expect(!h.state().linkOpen)
        #expect(h.notes().last?.hasPrefix("Could not reach UDP port 14550 - nothing is listening there.") == true)
    }

    // MARK: - Telemetry

    @Test func telemetryIsDecodedIntoState() {
        let h = Harness()
        h.receive(Harness.planeHeartbeat())
        h.receive(Attitude(roll: .pi / 6, pitch: -.pi / 18, yaw: -.pi / 2, yawspeed: 0.1))
        h.receive(GlobalPositionInt(lat: 399_253_861, lon: 328_365_235, alt: 990_000, relativeAlt: 100_000, vx: 0, vy: 2000, hdg: 9000))
        h.receive(HomePosition(latitude: 399_253_861, longitude: 328_355_235, altitude: 890_000))
        h.receive(GpsRawInt(fixType: 3, eph: 121, satellitesVisible: 14))
        h.receive(RcChannels(rssi: 127))
        h.receive(SysStatus(voltageBattery: 16_400, currentBattery: 1250, batteryRemaining: 76))
        h.receive(Wind(direction: -13, speed: 4))
        h.receive(DistanceSensor(currentDistance: 350, orientation: MavSensorOrientation.pitch270))
        h.receive(DistanceSensor(currentDistance: 999, orientation: 0))
        let s = h.state()
        #expect(abs((s.rollDeg ?? 0) - 30) < 0.001)
        #expect(abs((s.pitchDeg ?? 0) + 10) < 0.001)
        #expect(abs((s.yawDeg ?? 0) - 270) < 0.001)
        #expect(s.altRelM == 100)
        #expect(s.headingDeg == 90)
        #expect(abs((s.groundCourseDeg ?? 0) - 90) < 0.001)
        #expect(s.homeAltM == 890)
        #expect(abs((s.distToHomeM ?? 0) - 85.3) < 1)
        #expect(s.satellites == 14 && s.hdop == 1.21 && s.gpsFix == "3D")
        #expect(abs((s.rssiPercent ?? 0) - 50) < 0.001)
        #expect(s.batteryV == 16.4 && s.batteryA == 12.5 && s.batteryRemainingPct == 76)
        #expect(s.windDirectionDeg == 347)
        #expect(s.rangefinderM == 3.5)
    }

    @Test func noReadingIsNotZero() {
        let h = Harness()
        h.receive(Harness.planeHeartbeat())
        h.receive(GpsRawInt(eph: UInt16.max, satellitesVisible: 255))
        h.receive(SysStatus(voltageBattery: UInt16.max, currentBattery: -1, batteryRemaining: -1))
        h.receive(RcChannels(rssi: 255))
        h.receive(GlobalPositionInt(hdg: UInt16.max))
        let s = h.state()
        #expect(s.satellites == nil && s.hdop == nil)
        #expect(s.batteryV == nil && s.batteryA == nil && s.batteryRemainingPct == nil)
        #expect(s.rssiPercent == nil)
        #expect(s.headingDeg == nil)
    }

    @Test func readyToArmIsThePrearmBit() {
        let h = Harness()
        h.receive(Harness.planeHeartbeat())
        #expect(!h.state().readyToArm, "unknown is not ready")
        let prearm = MavSysStatusSensor.prearmCheck
        h.receive(SysStatus(onboardControlSensorsPresent: prearm | 1, onboardControlSensorsHealth: 1))
        #expect(!h.state().readyToArm)
        h.receive(SysStatus(onboardControlSensorsPresent: prearm | 1, onboardControlSensorsHealth: prearm | 1))
        #expect(h.state().readyToArm)
    }

    @Test func aPackIsTheSumOfItsCells() {
        let h = Harness()
        h.receive(Harness.planeHeartbeat())
        var cells = [UInt16](repeating: UInt16.max, count: 10)
        cells[0] = 16_800
        h.receive(BatteryStatus(voltages: cells))
        #expect(h.state().batteryV == 16.8)
        cells[0] = 4100; cells[1] = 4100; cells[2] = 4100; cells[3] = 4100
        h.receive(BatteryStatus(voltages: cells))
        #expect(h.state().batteryV == 16.4)
    }

    @Test func aLongMessageIsJoinedFromItsChunks() {
        let h = Harness()
        h.receive(Harness.planeHeartbeat())
        h.receive(Statustext(severity: MavSeverity.critical, text: "PreArm: Throttle below failsafe, ", id: 7, chunkSeq: 0))
        h.receive(Statustext(severity: MavSeverity.critical, text: "check calibration", id: 7, chunkSeq: 1))
        h.receive(Statustext(severity: MavSeverity.info, text: "Ready", id: 0, chunkSeq: 0))
        let messages = h.state().messages
        #expect(messages.map(\.text) == ["PreArm: Throttle below failsafe, check calibration", "Ready"])
        #expect(messages[0].isError)
    }

    @Test func lossIsCountedFromTheSequence() {
        let h = Harness()
        var vehicle = FrameEncoder(systemId: 1, componentId: 1)
        h.client.inject(vehicle.encode(Harness.planeHeartbeat()))
        h.advance(1) // opens the meter's first window
        // 30 frames sent, every third one lost on the way.
        for index in 1...30 {
            let frame = vehicle.encode(Attitude())
            if index % 3 != 0 { h.client.inject(frame) }
        }
        // The counter confirms a frame only when the next one starts, so the
        // frame after the last lost one (31) needs one more behind it (32)
        // before the gap in front of it is counted.
        h.client.inject(vehicle.encode(Attitude()))
        h.client.inject(vehicle.encode(Attitude()))
        h.advance(1)
        let link = h.state().link
        #expect(link.lost == 10)
        #expect(link.received == 22) // the heartbeat, 20 of the 30, and 31
        let loss = link.lossPercent ?? -1
        #expect(abs(loss - 100 * 10 / 32) < 0.01)
    }
}

// MARK: - Harness

final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 1000.0

    var now: Double {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ seconds: Double) {
        lock.lock()
        value += seconds
        lock.unlock()
    }
}

final class FakeTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [[UInt8]] = []
    private var onEnd: (@Sendable (LinkFailure) -> Void)?

    func start(onBytes: @escaping @Sendable ([UInt8]) -> Void, onEnd: @escaping @Sendable (LinkFailure) -> Void) {
        lock.lock()
        self.onEnd = onEnd
        lock.unlock()
    }

    func send(_ bytes: [UInt8]) -> SendResult {
        lock.lock()
        sent.append(bytes)
        lock.unlock()
        return .sent
    }

    func stop() {}

    func sentFrames() -> [[UInt8]] {
        lock.lock()
        defer { lock.unlock() }
        return sent
    }

    func clear() {
        lock.lock()
        sent.removeAll()
        lock.unlock()
    }

    func end(_ failure: LinkFailure) {
        lock.lock()
        let handler = onEnd
        lock.unlock()
        handler?(failure)
    }
}

struct Harness {
    let clock = ManualClock()
    let transport = FakeTransport()
    let client: MavlinkClient
    private let vehicle = VehicleSender()

    init() {
        let clock = clock
        let transport = transport
        client = MavlinkClient(clock: { clock.now }, transport: { _ in transport }, runsTimer: false)
        client.connect(LinkConfig())
        client.flush()
    }

    static func planeHeartbeat(mode: UInt32 = 12, armed: Bool = false) -> Heartbeat {
        Heartbeat(
            type: MavType.fixedWing,
            autopilot: MavAutopilot.ardupilotmega,
            baseMode: armed ? MavModeFlag.safetyArmed | MavModeFlag.customModeEnabled : MavModeFlag.customModeEnabled,
            customMode: mode,
            systemStatus: MavState.active
        )
    }

    func receive(_ message: some MavlinkMessage) {
        client.inject(vehicle.encode(message))
    }

    func send(_ command: GcsCommand) {
        client.send(command)
        client.flush()
    }

    func advance(_ seconds: Double) {
        clock.advance(seconds)
        client.tick()
    }

    func state() -> VehicleState {
        client.snapshot()
    }

    func notes() -> [String] {
        state().messages.filter { $0.severity == nil }.map(\.text)
    }

    func clearSent() {
        client.flush()
        transport.clear()
    }

    func sentMessages() -> [any MavlinkMessage] {
        client.flush()
        var parser = FrameParser()
        return parser.push(transport.sentFrames().joined()).map(\.message).filter { !($0 is Heartbeat) }
    }

    func sentCommands() -> [CommandLong] {
        sentMessages().compactMap { $0 as? CommandLong }
    }
}

/// The vehicle's side of the fake link: its own sequence numbering.
final class VehicleSender: @unchecked Sendable {
    private let lock = NSLock()
    private var encoder = FrameEncoder(systemId: 1, componentId: 1)

    func encode(_ message: some MavlinkMessage) -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return encoder.encode(message)
    }
}
