import Foundation

/// A simulated ArduPlane, for trying MavGCS with no aircraft at hand -- and
/// for Apple's reviewers, who have none.
///
/// It speaks MAVLink as the real thing does, through a transport like any
/// other (DemoTransport), so everything above the link -- the instruments,
/// the map, the buttons -- runs exactly as it would in flight. It flies the
/// modes on the app's panel, answers the commands the app sends, and says
/// plainly that it is a simulation.
///
/// Kinematics only, and not many of them: a course that turns at a bounded
/// rate towards where the mode wants to go, a wind triangle so heading and
/// track part as they do in the air, and a climb that eases onto its target.
struct DemoVehicle {
    // Where it flies: over Ankara, where the desktop opens and its test
    // aircraft has always flown.
    static let home = (lat: 39.925386, lon: 32.836524)
    static let homeAltMsl = 890.0
    static let cruiseAltitude = 100.0
    static let cruiseAirspeed = 19.0
    /// Blowing from the south-west, enough to set heading and track apart.
    static let windFromDeg = 220.0
    static let windSpeed = 5.0
    /// The autopilot had been running this long before the app connected.
    static let bootedBefore = 95.0

    /// ArduPlane's own mode numbers.
    enum Mode {
        static let manual: UInt32 = 0
        static let circle: UInt32 = 1
        static let stabilize: UInt32 = 2
        static let training: UInt32 = 3
        static let acro: UInt32 = 4
        static let fbwa: UInt32 = 5
        static let fbwb: UInt32 = 6
        static let cruise: UInt32 = 7
        static let autotune: UInt32 = 8
        static let auto: UInt32 = 10
        static let rtl: UInt32 = 11
        static let loiter: UInt32 = 12
        static let takeoff: UInt32 = 13
        static let guided: UInt32 = 15
        static let autoland: UInt32 = 26

        /// Flown with a pilot on the sticks: the simulation holds course.
        static let piloted: Set<UInt32> = [manual, stabilize, training, acro, fbwa, fbwb, cruise, autotune]
        static let all: Set<UInt32> = piloted.union([circle, auto, rtl, loiter, takeoff, guided, autoland])
    }

    /// A circuit around the field, as metres north and east of home.
    static let mission: [(north: Double, east: Double)] = [
        (900, -200), (1100, 900), (200, 1500), (-700, 900), (-600, -300),
    ]
    static let missionAltitude = 120.0

    // MARK: State

    private(set) var time = 0.0
    private(set) var lat = DemoVehicle.home.lat
    private(set) var lon = DemoVehicle.home.lon - 0.0017
    private(set) var altRel = DemoVehicle.cruiseAltitude
    /// The track over the ground, and where the nose points.
    private(set) var course = 0.0
    private(set) var heading = 0.0
    private(set) var airspeed = DemoVehicle.cruiseAirspeed
    private(set) var groundSpeed = DemoVehicle.cruiseAirspeed
    private(set) var climb = 0.0
    /// Degrees a second, positive to the right.
    private(set) var turnRate = 0.0
    private(set) var armed = true
    private(set) var onGround = false
    private(set) var mode = Mode.loiter
    private(set) var battery = 92.0

    private(set) var loiterCentre = DemoVehicle.home
    private(set) var loiterRadius = 150.0
    private(set) var guidedTarget: (lat: Double, lon: Double)?
    private(set) var targetAltitude = DemoVehicle.cruiseAltitude
    private(set) var targetAirspeed = DemoVehicle.cruiseAirspeed
    private(set) var missionIndex = 0
    /// Where it is steering for, for NAV_CONTROLLER_OUTPUT.
    private var navBearing = 0.0
    private var navTarget: (lat: Double, lon: Double)?
    private var landedAt: Double?

    /// Seconds between messages, by message id; nil is off.
    private var intervals: [UInt32: Double?] = [:]
    private var nextDue: [UInt32: Double] = [:]
    private var texts: [(severity: UInt8, text: String)] = []

    init() {
        texts.append((MavSeverity.notice, "DEMO: a simulated aircraft, nothing is flying"))
        texts.append((MavSeverity.info, "Try the modes, Fly Here and the instruments"))
    }

    static let defaultIntervals: [UInt32: Double] = [
        Heartbeat.messageId: 1,
        Attitude.messageId: 0.1,
        GlobalPositionInt.messageId: 0.2,
        VfrHud.messageId: 0.25,
        SysStatus.messageId: 1,
        GpsRawInt.messageId: 1,
        NavControllerOutput.messageId: 0.5,
        Wind.messageId: 1,
        BatteryStatus.messageId: 2,
        EkfStatusReport.messageId: 2,
        Vibration.messageId: 2,
        ScaledPressure.messageId: 2,
        MissionCurrent.messageId: 1,
        RcChannels.messageId: 1,
        HomePosition.messageId: 5,
    ]

    // MARK: Flying

    /// Moves the simulation on by [dt] seconds.
    mutating func step(_ dt: Double) {
        time += dt
        drainBattery(dt)

        if onGround {
            stepOnGround(dt)
            return
        }

        let desired = steer()
        // Turn towards the course wanted, at a rate a plane can bank to.
        let error = Self.wrap180(desired - course)
        turnRate = max(-15, min(15, error * 0.8))
        course = Self.wrap360(course + turnRate * dt)

        // Unpowered, it glides; powered, it holds its speed and height.
        let wantedSpeed = armed ? targetAirspeed : 15
        airspeed += max(-1.5 * dt, min(1.5 * dt, wantedSpeed - airspeed))
        let wantedClimb = armed ? max(-4, min(4, (targetAltitude - altRel) * 0.35)) : -3
        climb += max(-2 * dt, min(2 * dt, wantedClimb - climb))

        windTriangle()
        let north = cos(course * .pi / 180) * groundSpeed * dt
        let east = sin(course * .pi / 180) * groundSpeed * dt
        move(north: north, east: east)
        altRel += climb * dt

        if altRel <= 0 || (mode == Mode.autoland && altRel < 3 && distance(to: Self.home) < 60) {
            touchDown()
        }
    }

    /// The course the mode wants, and the height and target it is flying to.
    private mutating func steer() -> Double {
        navTarget = nil
        switch mode {
        case Mode.loiter, Mode.circle:
            return orbit(loiterCentre)
        case Mode.guided:
            return goThenOrbit(guidedTarget ?? loiterCentre)
        case Mode.rtl:
            targetAltitude = Self.cruiseAltitude
            return goThenOrbit(Self.home)
        case Mode.auto:
            targetAltitude = Self.missionAltitude
            let wp = waypoint(missionIndex)
            if distance(to: wp) < 60 {
                texts.append((MavSeverity.info, "Reached waypoint #\(missionIndex + 1)"))
                missionIndex = (missionIndex + 1) % Self.mission.count
            }
            return head(to: waypoint(missionIndex))
        case Mode.takeoff:
            if altRel < Self.cruiseAltitude - 3 {
                targetAltitude = Self.cruiseAltitude
                return course
            }
            return orbit(loiterCentre)
        case Mode.autoland:
            // Straight in to home, gliding down so as to meet the ground
            // there.
            let d = distance(to: Self.home)
            targetAltitude = min(altRel, max(0, (d - 40) * 0.09))
            return head(to: Self.home)
        default:
            // A pilot flying by hand: hold the course, and turn for home if
            // it strays so far that the map would lose it.
            if distance(to: Self.home) > 2500 {
                return head(to: Self.home)
            }
            return course
        }
    }

    private mutating func head(to point: (lat: Double, lon: Double)) -> Double {
        navTarget = point
        navBearing = bearing(to: point)
        return navBearing
    }

    /// Circles a point clockwise, as ArduPlane does with a positive radius.
    private mutating func orbit(_ centre: (lat: Double, lon: Double)) -> Double {
        let d = distance(to: centre)
        let fromCentre = Self.wrap360(bearing(to: centre) + 180)
        // Along the circle, and in towards it the further out it is.
        let inward = max(-45, min(90, (d - loiterRadius) * 0.9))
        navTarget = centre
        navBearing = Self.wrap360(fromCentre + 90 + inward)
        return navBearing
    }

    private mutating func goThenOrbit(_ point: (lat: Double, lon: Double)) -> Double {
        distance(to: point) > loiterRadius + 40 ? head(to: point) : orbit(point)
    }

    private mutating func stepOnGround(_ dt: Double) {
        turnRate = 0
        climb = 0
        // Only the modes that fly themselves take off.
        if armed && (mode == Mode.takeoff || mode == Mode.auto) {
            airspeed = min(Self.cruiseAirspeed, airspeed + 3 * dt)
            groundSpeed = airspeed
            heading = course
            move(north: cos(course * .pi / 180) * airspeed * dt, east: sin(course * .pi / 180) * airspeed * dt)
            if airspeed > 13 {
                onGround = false
                landedAt = nil
                climb = 2
                altRel = 0.5
                targetAltitude = mode == Mode.auto ? Self.missionAltitude : Self.cruiseAltitude
                loiterCentre = (lat, lon)
            }
            return
        }
        airspeed = max(0, airspeed - 4 * dt)
        groundSpeed = airspeed
        if armed, mode == Mode.autoland, airspeed == 0, let at = landedAt, time - at > 2 {
            armed = false
            texts.append((MavSeverity.info, "Throttle disarmed"))
        }
    }

    private mutating func touchDown() {
        altRel = 0
        climb = 0
        onGround = true
        landedAt = time
        texts.append((MavSeverity.info, "Landed"))
    }

    /// Heading and ground speed from the track wanted and the wind.
    private mutating func windTriangle() {
        let towards = (Self.windFromDeg + 180) * .pi / 180
        let windNorth = cos(towards) * Self.windSpeed
        let windEast = sin(towards) * Self.windSpeed
        let c = course * .pi / 180
        let along = windNorth * cos(c) + windEast * sin(c)
        let right = windEast * cos(c) - windNorth * sin(c)
        let crab = asin(max(-1, min(1, right / max(airspeed, 1))))
        heading = Self.wrap360(course - crab * 180 / .pi)
        groundSpeed = max(0, airspeed * cos(crab) + along)
    }

    private mutating func drainBattery(_ dt: Double) {
        let perSecond = armed ? (onGround ? 1.0 / 300 : 1.0 / 40) : 0
        battery = max(5, battery - perSecond * dt)
    }

    private mutating func move(north: Double, east: Double) {
        lat += north / 111_320
        lon += east / (111_320 * cos(lat * .pi / 180))
    }

    private func waypoint(_ index: Int) -> (lat: Double, lon: Double) {
        let offset = Self.mission[index]
        return (
            Self.home.lat + offset.north / 111_320,
            Self.home.lon + offset.east / (111_320 * cos(Self.home.lat * .pi / 180))
        )
    }

    func distance(to point: (lat: Double, lon: Double)) -> Double {
        Double(Geo.distance(lat, lon, point.lat, point.lon) ?? 0)
    }

    func bearing(to point: (lat: Double, lon: Double)) -> Double {
        Geo.bearing(fromLat: lat, lon: lon, toLat: point.lat, lon: point.lon)
    }

    static func wrap360(_ degrees: Double) -> Double {
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }

    static func wrap180(_ degrees: Double) -> Double {
        let wrapped = wrap360(degrees)
        return wrapped > 180 ? wrapped - 360 : wrapped
    }

    // MARK: Commands

    /// The answer to a message from the ground station, if it earns one.
    mutating func handle(_ packet: MavlinkPacket) -> [any MavlinkMessage] {
        let from = packet.frame
        switch packet.message {
        case let long as CommandLong:
            return [perform(long.command, long.param1, long.param2, from: from)]
        case let reposition as CommandInt:
            if reposition.command == MavCmd.doReposition {
                guidedTarget = (Double(reposition.x) / 1e7, Double(reposition.y) / 1e7)
                if reposition.z > 0 { targetAltitude = max(20, min(400, Double(reposition.z))) }
                if mode != Mode.guided { setMode(Mode.guided) }
                return [ack(reposition.command, MavResult.accepted, from)]
            }
            return [ack(reposition.command, MavResult.unsupported, from)]
        case let param as ParamSet:
            guard param.paramId == "WP_LOITER_RAD", param.paramValue.isFinite else { return [] }
            // An Int16 in ArduPlane, held to what it can store.
            let stored = max(-32767, min(32767, param.paramValue.rounded()))
            loiterRadius = max(25, Double(abs(stored)))
            return [ParamValue(paramId: param.paramId, paramValue: stored, paramType: MavParamType.int16, paramCount: 1, paramIndex: 0)]
        default:
            return []
        }
    }

    private mutating func perform(_ id: UInt16, _ param1: Float, _ param2: Float, from: MavlinkFrame) -> any MavlinkMessage {
        switch id {
        case MavCmd.doSetMode:
            guard let wanted = Self.whole(param2), Mode.all.contains(wanted) else { return ack(id, MavResult.denied, from) }
            setMode(wanted)
            return ack(id, MavResult.accepted, from)

        case MavCmd.componentArmDisarm:
            if param1 == 1 {
                if !armed {
                    armed = true
                    texts.append((MavSeverity.info, "Throttle armed"))
                }
                return ack(id, MavResult.accepted, from)
            }
            // As ArduPlane: not in the air, unless forced.
            if !onGround && param2 != 21196 {
                texts.append((MavSeverity.warning, "DEMO: land first - try AUTOLAND"))
                return ack(id, MavResult.failed, from)
            }
            if armed {
                armed = false
                texts.append((MavSeverity.info, "Throttle disarmed"))
            }
            return ack(id, MavResult.accepted, from)

        case MavCmd.doChangeSpeed:
            guard param2.isFinite else { return ack(id, MavResult.denied, from) }
            targetAirspeed = max(12, min(30, Double(param2)))
            return ack(id, MavResult.accepted, from)

        case MavCmd.doChangeAltitude:
            guard param1.isFinite else { return ack(id, MavResult.denied, from) }
            targetAltitude = max(20, min(400, Double(param1)))
            return ack(id, MavResult.accepted, from)

        case MavCmd.setMessageInterval:
            guard let message = Self.whole(param1), Self.defaultIntervals[message] != nil,
                  message != Heartbeat.messageId, param2.isFinite
            else {
                return ack(id, MavResult.accepted, from)
            }
            if param2 == 0 {
                intervals[message] = nil
            } else if param2 < 0 {
                intervals[message] = .some(nil)
            } else {
                intervals[message] = .some(Double(param2) / 1_000_000)
            }
            nextDue[message] = time
            return ack(id, MavResult.accepted, from)

        case MavCmd.requestMessage:
            guard let message = Self.whole(param1), Self.defaultIntervals[message] != nil else {
                return ack(id, MavResult.unsupported, from)
            }
            nextDue[message] = time
            return ack(id, MavResult.accepted, from)

        default:
            return ack(id, MavResult.unsupported, from)
        }
    }

    private mutating func setMode(_ wanted: UInt32) {
        mode = wanted
        switch wanted {
        case Mode.loiter, Mode.circle, Mode.guided:
            loiterCentre = (lat, lon)
            if wanted == Mode.guided, guidedTarget == nil { guidedTarget = loiterCentre }
        case Mode.takeoff:
            loiterCentre = (lat, lon)
            targetAltitude = Self.cruiseAltitude
        case Mode.auto:
            // Resume the circuit at whichever waypoint is nearest.
            missionIndex = Self.mission.indices.min { distance(to: waypoint($0)) < distance(to: waypoint($1)) } ?? 0
        default:
            break
        }
        if wanted != Mode.guided { guidedTarget = nil }
        // Told at once, rather than at the next second's heartbeat.
        nextDue[Heartbeat.messageId] = time
    }

    /// A parameter that should hold a small whole number, or nil for one
    /// that does not.
    private static func whole(_ value: Float) -> UInt32? {
        value.isFinite && value >= 0 && value < 16_777_216 ? UInt32(value) : nil
    }

    private func ack(_ command: UInt16, _ result: UInt8, _ from: MavlinkFrame) -> CommandAck {
        CommandAck(command: command, result: result, targetSystem: from.systemId, targetComponent: from.componentId)
    }

    // MARK: Telemetry

    /// Everything due to be sent by now.
    mutating func due() -> [any MavlinkMessage] {
        var out: [any MavlinkMessage] = []
        for (id, standard) in Self.defaultIntervals.sorted(by: { $0.key < $1.key }) {
            let chosen: Double? = intervals[id] ?? standard
            guard let every = chosen else { continue }
            if time >= nextDue[id, default: 0] {
                nextDue[id] = time + every
                if let message = telemetry(id) { out.append(message) }
            }
        }
        for text in texts {
            out.append(Statustext(severity: text.severity, text: text.text))
        }
        texts.removeAll()
        return out
    }

    private func telemetry(_ id: UInt32) -> (any MavlinkMessage)? {
        let bootMs = UInt32((Self.bootedBefore + time) * 1000)
        let altMsl = Self.homeAltMsl + altRel
        switch id {
        case Heartbeat.messageId:
            return Heartbeat(
                type: MavType.fixedWing,
                autopilot: MavAutopilot.ardupilotmega,
                baseMode: MavModeFlag.customModeEnabled | (armed ? MavModeFlag.safetyArmed : 0),
                customMode: mode,
                systemStatus: armed ? MavState.active : MavState.standby
            )
        case Attitude.messageId:
            let bank = atan(groundSpeed * turnRate * .pi / 180 / 9.81)
            let pitch = asin(max(-0.5, min(0.5, climb / max(airspeed, 1)))) + (onGround ? 0 : 0.035)
            let yaw = Self.wrap180(heading) * .pi / 180
            return Attitude(
                timeBootMs: bootMs, roll: Float(max(-0.8, min(0.8, bank))), pitch: Float(pitch), yaw: Float(yaw),
                yawspeed: Float(turnRate * .pi / 180)
            )
        case GlobalPositionInt.messageId:
            let north = cos(course * .pi / 180) * groundSpeed
            let east = sin(course * .pi / 180) * groundSpeed
            return GlobalPositionInt(
                timeBootMs: bootMs, lat: Int32((lat * 1e7).rounded()), lon: Int32((lon * 1e7).rounded()),
                alt: Int32(altMsl * 1000), relativeAlt: Int32(altRel * 1000),
                vx: Int16(north * 100), vy: Int16(east * 100), vz: Int16(-climb * 100),
                hdg: UInt16(heading * 100) % 36000
            )
        case VfrHud.messageId:
            return VfrHud(
                airspeed: Float(airspeed), groundspeed: Float(groundSpeed), heading: Int16(heading.rounded()) % 360,
                throttle: UInt16(throttle), alt: Float(altMsl), climb: Float(climb)
            )
        case SysStatus.messageId:
            return SysStatus(
                onboardControlSensorsPresent: 0x3FFF_FFFF, onboardControlSensorsEnabled: 0x3FFF_FFFF,
                onboardControlSensorsHealth: 0x3FFF_FFFF, load: 350,
                voltageBattery: UInt16(voltage * 1000), currentBattery: Int16(current * 100),
                batteryRemaining: Int8(battery.rounded(.down))
            )
        case BatteryStatus.messageId:
            var cells = [UInt16](repeating: UInt16.max, count: 10)
            cells[0] = UInt16(voltage * 1000)
            return BatteryStatus(
                id: 0, batteryFunction: 1, type: 1, temperature: 2900, voltages: cells,
                currentBattery: Int16(current * 100), currentConsumed: Int32((100 - battery) * 50),
                energyConsumed: -1, batteryRemaining: Int8(battery.rounded(.down))
            )
        case GpsRawInt.messageId:
            return GpsRawInt(
                timeUsec: UInt64(bootMs) * 1000, fixType: GpsFixType._3dFix,
                lat: Int32((lat * 1e7).rounded()), lon: Int32((lon * 1e7).rounded()), alt: Int32(altMsl * 1000),
                eph: 90, epv: 120, vel: UInt16(groundSpeed * 100), cog: UInt16(course * 100) % 36000,
                satellitesVisible: 14
            )
        case NavControllerOutput.messageId:
            let target = navTarget
            return NavControllerOutput(
                navBearing: Int16(navBearing.rounded()) % 360,
                targetBearing: Int16((target.map { bearing(to: $0) } ?? navBearing).rounded()) % 360,
                wpDist: UInt16(min(65535, target.map { distance(to: $0) } ?? 0)),
                altError: Float(targetAltitude - altRel)
            )
        case Wind.messageId:
            return Wind(direction: Float(Self.windFromDeg), speed: Float(Self.windSpeed))
        case EkfStatusReport.messageId:
            let flags = EkfStatusFlags.attitude | EkfStatusFlags.velocityHoriz | EkfStatusFlags.velocityVert
                | EkfStatusFlags.posHorizRel | EkfStatusFlags.posHorizAbs | EkfStatusFlags.posVertAbs
                | EkfStatusFlags.predPosHorizRel | EkfStatusFlags.predPosHorizAbs
            return EkfStatusReport(
                flags: flags, velocityVariance: 0.12, posHorizVariance: 0.08, posVertVariance: 0.1,
                compassVariance: 0.05, terrainAltVariance: 0, airspeedVariance: 0.1
            )
        case Vibration.messageId:
            let buzz = armed && !onGround ? 1.0 : 0.2
            return Vibration(
                timeUsec: UInt64(bootMs) * 1000, vibrationX: Float(6 * buzz + sin(time) * buzz),
                vibrationY: Float(7 * buzz), vibrationZ: Float(9 * buzz + cos(time * 0.7) * buzz)
            )
        case ScaledPressure.messageId:
            let pressure = 1013.25 * pow(1 - 2.25577e-5 * altMsl, 5.25588)
            return ScaledPressure(timeBootMs: bootMs, pressAbs: Float(pressure), temperature: 2150)
        case MissionCurrent.messageId:
            return MissionCurrent(seq: UInt16(missionIndex + 1), total: UInt16(Self.mission.count + 1))
        case RcChannels.messageId:
            return RcChannels(
                timeBootMs: bootMs, chancount: 8, chan1Raw: 1500, chan2Raw: 1500, chan3Raw: UInt16(1000 + throttle * 10),
                chan4Raw: 1500, chan5Raw: 1100, chan6Raw: 1500, chan7Raw: 1100, chan8Raw: 1100, rssi: 230
            )
        case HomePosition.messageId:
            return HomePosition(
                latitude: Int32((Self.home.lat * 1e7).rounded()), longitude: Int32((Self.home.lon * 1e7).rounded()),
                altitude: Int32(Self.homeAltMsl * 1000)
            )
        default:
            return nil
        }
    }

    /// A 4S pack: 16.8 V full, sagging a little under load.
    private var voltage: Double {
        13.6 + 3.2 * battery / 100 - (armed && !onGround ? 0.3 : 0)
    }

    private var current: Double {
        guard armed else { return 0.4 }
        return onGround ? 0.9 : 12.4 + max(0, climb) * 1.5
    }

    private var throttle: Double {
        guard armed else { return 0 }
        if onGround { return airspeed > 0 ? 70 : 0 }
        return max(0, min(100, 45 + climb * 6 + (targetAirspeed - Self.cruiseAirspeed) * 3))
    }
}

/// The simulated aircraft on the other end of a link: telemetry out on a
/// timer, commands in as they arrive, all on one queue of its own.
final class DemoTransport: Transport, @unchecked Sendable {
    /// How often the simulation moves on.
    static let tickSeconds = 0.05

    private let queue = DispatchQueue(label: "mavgcs.demo")
    private var vehicle = DemoVehicle()
    private var encoder = FrameEncoder(systemId: 1, componentId: 1)
    private var parser = FrameParser()
    private var timer: DispatchSourceTimer?
    private var onBytes: (@Sendable ([UInt8]) -> Void)?
    private var last = 0.0

    func start(onBytes: @escaping @Sendable ([UInt8]) -> Void, onEnd: @escaping @Sendable (LinkFailure) -> Void) {
        queue.async { [self] in
            self.onBytes = onBytes
            last = ProcessInfo.processInfo.systemUptime
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: Self.tickSeconds)
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    func send(_ bytes: [UInt8]) -> SendResult {
        queue.async { [self] in
            for packet in parser.push(bytes) {
                emit(vehicle.handle(packet))
            }
        }
        return .sent
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            onBytes = nil
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        // Never more than a second at once, so a phone that slept does not
        // wake to find the aircraft teleported.
        vehicle.step(min(1, max(0, now - last)))
        last = now
        emit(vehicle.due())
    }

    private func emit(_ messages: [any MavlinkMessage]) {
        guard let onBytes, !messages.isEmpty else { return }
        var bytes: [UInt8] = []
        for message in messages {
            bytes += encoder.encode(message)
        }
        onBytes(bytes)
    }
}
