import Foundation

/// The conversation with one vehicle: the link, the heartbeat, the commands
/// and what the vehicle says back.
///
/// Ported from the Android build's MavlinkClient, which carries most of
/// what MavGCS has learned about real radios -- the comments say where.
///
/// Everything mutable lives on one serial queue. Bytes arrive from the
/// transport's thread and are handed onto it; the public methods hop onto
/// it; the once-a-second housekeeping runs on it. Nothing is locked because
/// nothing is shared.
public final class MavlinkClient: @unchecked Sendable {
    public static let gcsSystemId: UInt8 = 255
    public static let gcsComponentId: UInt8 = 190

    /// How long a command has to be answered before the app says it was not.
    ///
    /// An autopilot answers the moment it has read one, so this is almost
    /// all link: long enough for a slow radio's downlink to find room for
    /// the acknowledgement, short enough that the pilot is not left
    /// believing a button worked.
    static let commandAnswerTime = 5.0
    /// How often an unconfirmed mode request goes back on the wire.
    static let modeRetryEvery = 1.0
    /// How long to keep trying before admitting a mode is not getting
    /// through: long enough to ride out the burst losses and handover
    /// stalls these links produce, short enough that a button does not sit
    /// lit when the link has genuinely gone.
    static let modeRetryFor = 10.0
    /// How long a link may be open and silent before saying so. Long enough
    /// that a vehicle still booting is not accused of being absent, short
    /// enough to catch a mistyped port before the pilot has given up on it.
    static let silentLinkTime = 10.0
    static let staleAfter = 3.0
    /// Below this much loss a silent command is not the link dropping it.
    ///
    /// Every retry inside the window has to vanish for a command to be
    /// abandoned at all, which chance alone will not do at a few percent.
    /// Set well above the couple of percent a healthy radio shows and well
    /// below the third or more that actually swallows a whole burst.
    static let oneWayLossPercent: Float = 15
    static let paramSameEnough: Float = 0.05
    static let maxMessages = 200
    /// State goes to the screen at most this often.
    static let publishInterval = 0.05
    /// What ARM_DISARM wants in param2 to skip the pre-arm checks.
    static let forceArmMagic: Float = 21196
    static let minCourseSpeedMs: Float = 1
    static let loiterRadiusParam = "WP_LOITER_RAD"

    /// What the app reads, and how often it needs it. Anything not named
    /// here or in the disabled lists keeps whatever rate the vehicle chose.
    static let supportingRates: [(id: UInt32, hz: Float)] = [
        (VfrHud.messageId, 2),             // airspeed, altitude, climb
        (SysStatus.messageId, 1),          // battery
        (GpsRawInt.messageId, 1),          // satellites, HDOP
        (NavControllerOutput.messageId, 2), // distance and bearing to target
        (Wind.messageId, 1),               // the wind arrow
        (TerrainReport.messageId, 1),      // terrain altitude
        (BatteryStatus.messageId, 0.5),
        (ScaledPressure.messageId, 0.5),   // QNH
        (MissionCurrent.messageId, 1),     // which waypoint is being flown
        // The only thing either firmware will say about the radio. Neither
        // puts link quality or signal-to-noise in any standard field, so the
        // receiver's RSSI is the whole of what can be known.
        (RcChannels.messageId, 1),
        // Home is announced once, at arming. Once is no guarantee on a radio
        // that drops packets, and missing it means no home marker and no
        // distance-to-home for the rest of the flight. The explicit request
        // on connect still goes out; this is the slow repeat that catches the
        // case where the answer to it was lost.
        (HomePosition.messageId, 0.2),
        (Rangefinder.messageId, 1),
        (DistanceSensor.messageId, 0.5),
    ]

    /// Streamed by ArduPilot but never read here. On a link with bandwidth to
    /// spare they are harmless; on a slow radio they crowd out the messages
    /// that matter, and the radio drops whatever overflows without caring
    /// which.
    ///
    /// Every id here must be one the firmware can actually schedule.
    /// ArduPilot maps a MAVLink id to an internal slot before it will change
    /// a rate, and for an id with none it answers "No ap_message for mavlink
    /// id (n)" into the pilot's messages on every connect. 165 HWSTATUS and
    /// 182 AHRS3 are obsolete that way and must not be added.
    static let disabledMessages: [UInt32] = [
        164,   // SIMSTATE
        11020, // AOA_SSA
        163,   // AHRS
        178,   // AHRS2
        27,    // RAW_IMU
        116,   // SCALED_IMU2
        129,   // SCALED_IMU3
        137,   // SCALED_PRESSURE2
        36,    // SERVO_OUTPUT_RAW
        152,   // MEMINFO
        125,   // POWER_STATUS
        32,    // LOCAL_POSITION_NED
        87,    // POSITION_TARGET_GLOBAL_INT
        2,     // SYSTEM_TIME
        // Measured on a plane at the rates this app asks for, the first two
        // were 316 B/s of an 891 B/s stream -- a third of everything the
        // vehicle sent, for data nothing displays. On ELRS at 435 B/s that is
        // most of the budget.
        11030, // ESC_TELEMETRY_1_TO_4, 4 Hz and 220 B/s of it
        295,   // AIRSPEED, whose figure VFR_HUD already carries
        143,   // SCALED_PRESSURE3, a third barometer
        // Read by the Android build's Systems panel, which this app does not
        // have yet. Until it does they are bandwidth for nothing.
        193,   // EKF_STATUS_REPORT
        241,   // VIBRATION
    ]

    /// The requests the app makes for itself, not for the pilot.
    static let housekeeping: Set<UInt16> = [MavCmd.setMessageInterval, MavCmd.requestMessage]

    private let queue = DispatchQueue(label: "mavgcs.mavlink", qos: .userInitiated)
    private let clock: @Sendable () -> Double
    private let makeTransport: @Sendable (LinkConfig) -> any Transport
    private let runsTimer: Bool

    // Everything below is touched only on `queue`.
    private var state = VehicleState()
    private var observer: (@Sendable (VehicleState) -> Void)?
    private var transport: (any Transport)?
    private var config = LinkConfig()
    /// Bumped by every connect and disconnect, so a callback from a link
    /// that has since been replaced is recognised and dropped.
    private var session = 0
    private var parser = FrameParser()
    private var counter = FrameCounter()
    private var encoder = FrameEncoder(systemId: gcsSystemId, componentId: gcsComponentId)
    private var stats = LinkStats()
    /// Who to address, learned from the vehicle's own heartbeat, or nil
    /// before one has arrived.
    ///
    /// Nothing is sent while this is nil. A guess is the wrong thing to arm:
    /// on a routed network with more than one airframe, system 1 is
    /// somebody, and not necessarily the aircraft in front of the pilot.
    private var target: (system: UInt8, component: UInt8)?
    private var timer: DispatchSourceTimer?
    private var openedAt = 0.0
    private var silenceReported = false
    private var sendFailureReported = false
    private var rates = StreamRates()
    private var modeWanted: PendingMode?
    private var awaited: [UInt16: Awaited] = [:]
    private var paramAwaited: ParamAwaited?
    private var chunkId: UInt16 = 0
    private var chunkSequence = -1
    private var messageCount = 0
    private var publishScheduled = false

    private struct PendingMode {
        var mode: String
        var request: ModeRequest
        var nextRetry: Double
        var until: Double
    }

    private struct Awaited {
        var what: String
        var due: Double
    }

    /// A parameter write waiting to be confirmed.
    ///
    /// A parameter is not a command and gets no COMMAND_ACK; the autopilot
    /// answers with the value it ended up holding. Worth reading rather than
    /// merely counting, because the value that comes back is often not the
    /// one asked for: ArduPilot holds WP_LOITER_RAD to its own limits, and a
    /// plane quietly orbiting at a radius the pilot did not choose is the
    /// thing to say out loud.
    private struct ParamAwaited {
        var id: String
        var what: String
        var asked: Float
        var unit: String
        var due: Double
    }

    public convenience init() {
        self.init(
            clock: { ProcessInfo.processInfo.systemUptime },
            transport: { SocketTransport(config: $0) },
            runsTimer: true
        )
    }

    init(
        clock: @escaping @Sendable () -> Double,
        transport: @escaping @Sendable (LinkConfig) -> any Transport,
        runsTimer: Bool
    ) {
        self.clock = clock
        self.makeTransport = transport
        self.runsTimer = runsTimer
    }

    // MARK: - Public

    /// Receive the state after every change, at most twenty times a second,
    /// on a background queue. Called once straight away with the current one.
    public func observe(_ handler: @escaping @Sendable (VehicleState) -> Void) {
        queue.async { [self] in
            observer = handler
            handler(state)
        }
    }

    public func connect(_ config: LinkConfig, rates: StreamRates = StreamRates()) {
        queue.async { [self] in
            closeTransport()
            session += 1
            let session = session
            self.config = config
            self.rates = rates
            state = VehicleState()
            state.linkOpen = true
            stats.reset()
            counter.reset()
            parser = FrameParser()
            target = nil
            modeWanted = nil
            awaited = [:]
            paramAwaited = nil
            silenceReported = false
            sendFailureReported = false
            chunkId = 0
            chunkSequence = -1
            openedAt = clock()

            let transport = makeTransport(config)
            self.transport = transport
            transport.start(
                onBytes: { [weak self] bytes in
                    guard let self else { return }
                    queue.async { self.receive(bytes, session: session) }
                },
                onEnd: { [weak self] failure in
                    guard let self else { return }
                    queue.async { self.ended(failure, session: session) }
                }
            )
            if runsTimer { startTimer() }
            publishNow()
        }
    }

    public func disconnect() {
        queue.async { [self] in
            closeTransport()
            session += 1
            // Forget who the vehicle was. The stream rates are applied once,
            // on first contact, and first contact is decided by this being
            // nil -- so leaving it set would have every reconnect silently
            // keep whatever rates the vehicle happened to have. On a link
            // that drops and is redialled, which is the normal life of an
            // LTE modem, that is the reconnect quietly going back to flooding.
            target = nil
            modeWanted = nil
            awaited = [:]
            paramAwaited = nil
            // The meter describes a link. With none open there is nothing
            // for it to describe, and leaving the last live figures up would
            // report a healthy 400 B/s for a connection that ended minutes ago.
            stats.reset()
            state.linkOpen = false
            state.linkUp = false
            state.modePending = nil
            state.link = LinkQuality()
            state.rssiPercent = nil
            publishNow()
        }
    }

    public func send(_ command: GcsCommand) {
        queue.async { [self] in
            switch command {
            case .arm:
                sendCommand(MavCmd.componentArmDisarm, param1: 1)
            case .forceArm:
                sendCommand(MavCmd.componentArmDisarm, param1: 1, param2: Self.forceArmMagic)
            case .disarm:
                sendCommand(MavCmd.componentArmDisarm, param1: 0)
            }
        }
    }

    /// Ask for a mode, and keep asking until a heartbeat says it took.
    ///
    /// A second press replaces the first rather than queueing behind it, so
    /// there is only ever one mode outstanding.
    public func setFlightMode(_ button: ModeButton) {
        queue.async { [self] in
            guard target != nil else { return }
            sendModeChange(button.request)
            let now = clock()
            modeWanted = PendingMode(
                mode: button.mode,
                request: button.request,
                nextRetry: now + Self.modeRetryEvery,
                until: now + Self.modeRetryFor
            )
            state.modePending = button.mode
            schedulePublish()
        }
    }

    /// Target speed in m/s, leaving the throttle to the autopilot.
    public func changeSpeed(_ metersPerSecond: Float) {
        queue.async { [self] in
            sendCommand(MavCmd.doChangeSpeed, param1: 0, param2: metersPerSecond, param3: -1)
        }
    }

    /// Target altitude in metres above home.
    public func changeAltitude(_ meters: Float) {
        queue.async { [self] in
            sendCommand(MavCmd.doChangeAltitude, param1: meters, param2: Float(MavFrame.globalRelativeAlt))
        }
    }

    /// Loiter radius is a parameter rather than a command, so this is a
    /// PARAM_SET of WP_LOITER_RAD, checked against what comes back.
    public func setLoiterRadius(_ meters: Float) {
        queue.async { [self] in
            guard let target else { return }
            transmit(ParamSet(
                targetSystem: target.system,
                targetComponent: target.component,
                paramId: Self.loiterRadiusParam,
                paramValue: meters,
                paramType: MavParamType.real32
            ))
            paramAwaited = ParamAwaited(
                id: Self.loiterRadiusParam,
                what: "Loiter radius",
                asked: meters,
                unit: " m",
                due: clock() + Self.commandAnswerTime
            )
        }
    }

    /// Guided goto, as COMMAND_INT rather than COMMAND_LONG: that message
    /// carries its parameters as float32, which cannot hold a 1e7-scaled
    /// latitude without losing metres of it. COMMAND_INT has int32 x and y.
    public func flyTo(lat: Double, lon: Double, altitudeM: Float) {
        queue.async { [self] in
            guard let target else { return }
            transmit(CommandInt(
                targetSystem: target.system,
                targetComponent: target.component,
                frame: MavFrame.globalRelativeAltInt,
                command: MavCmd.doReposition,
                current: 0,
                autocontinue: 0,
                param1: -1, // the vehicle's own speed
                param2: 1, // MAV_DO_REPOSITION_FLAGS_CHANGE_MODE: go to guided
                param3: 0,
                param4: .nan, // keep the current yaw behaviour
                x: Int32((lat * 1e7).rounded()),
                y: Int32((lon * 1e7).rounded()),
                z: altitudeM
            ))
            expect(MavCmd.doReposition)
        }
    }

    // MARK: - Testing hooks

    /// The state as it stands, after everything queued so far has run.
    func snapshot() -> VehicleState {
        queue.sync { state }
    }

    /// Run the once-a-second housekeeping now.
    func tick() {
        queue.sync { housekeeping() }
    }

    /// Feed bytes as if they had arrived on the current link.
    func inject(_ bytes: [UInt8]) {
        queue.sync { receive(bytes, session: session) }
    }

    /// Wait for everything queued so far.
    func flush() {
        queue.sync {}
    }

    // MARK: - Link

    private func closeTransport() {
        transport?.stop()
        transport = nil
        timer?.cancel()
        timer = nil
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.housekeeping() }
        timer.resume()
        self.timer = timer
    }

    private func receive(_ bytes: [UInt8], session: Int) {
        guard session == self.session, transport != nil else { return }
        // Counted before the parser is free to throw any of it away.
        for byte in bytes {
            if let frame = counter.byte(byte) {
                stats.onRx(bytes: frame.bytes, systemId: frame.systemId, componentId: frame.componentId, sequence: frame.sequence)
            }
        }
        for packet in parser.push(bytes) {
            handle(packet)
        }
        schedulePublish()
    }

    private func ended(_ failure: LinkFailure, session: Int) {
        guard session == self.session, transport != nil else { return }
        closeTransport()
        modeWanted = nil
        state.linkOpen = false
        state.linkUp = false
        state.modePending = nil
        // Said out loud, not just logged. A refused port and a quiet vehicle
        // look identical on a panel that holds its last reading, so the one
        // case the app can be certain about is worth stating.
        if failure == .closedByPeer {
            note("The link closed at the other end.")
        } else if failure.opening {
            note("Could not reach \(config.description) - \(failure.reason).\(hint(for: failure))")
        } else {
            note("The link to \(config.description) failed - \(failure.reason).")
        }
        publishNow()
    }

    /// The once-a-second work: heartbeat, retries, and noticing silence.
    ///
    /// Driven by a timer rather than by what arrives, so it ticks whether or
    /// not anything is arriving -- which is exactly when it matters.
    private func housekeeping() {
        guard transport != nil else { return }
        let now = clock()
        sendHeartbeat()
        driveModeRequest(now: now)
        sweepAwaited(now: now)
        sweepParam(now: now)
        state.link = stats.sample(now: now)
        // A socket that opened onto nothing. Said once: the address was
        // probably wrong, and repeating it every second would bury the log.
        if !silenceReported && target == nil && now - openedAt > Self.silentLinkTime {
            silenceReported = true
            note("Link is open but no vehicle has been heard in \(Int(Self.silentLinkTime)) seconds. Check the address, the port, and that the vehicle is powered.")
        }
        if state.lastHeartbeat != 0 && now - state.lastHeartbeat > Self.staleAfter {
            state.linkUp = false
        }
        schedulePublish()
    }

    private func transmit(_ message: some MavlinkMessage) {
        guard let transport else { return }
        let bytes = encoder.encode(message)
        switch transport.send(bytes) {
        case .sent:
            // Counted here, past the point where UDP decides whether there is
            // anywhere to send. A counter further up could see only the
            // attempt and not the silence, which once had the Android meter
            // reporting an uplink of 21 B/s on the same screen that said no
            // vehicle had ever been heard.
            stats.onTx(bytes: bytes.count, frame: true)
        case .noPeer:
            break
        case .failed(let failure):
            if !sendFailureReported {
                sendFailureReported = true
                note("Could not send to \(config.description) - \(failure.reason).\(hint(for: failure))")
            }
        }
    }

    private func hint(for failure: LinkFailure) -> String {
        #if os(iOS)
        if failure.mayBeLocalNetworkPermission {
            return " If it is on this WiFi, check that MavGCS is allowed under Settings > Privacy & Security > Local Network."
        }
        #endif
        return ""
    }

    private func sendHeartbeat() {
        transmit(Heartbeat(
            type: MavType.gcs,
            autopilot: MavAutopilot.invalid,
            baseMode: 0,
            customMode: 0,
            systemStatus: MavState.active
        ))
    }

    private func sendCommand(
        _ command: UInt16,
        param1: Float = 0, param2: Float = 0, param3: Float = 0, param4: Float = 0,
        param5: Float = 0, param6: Float = 0, param7: Float = 0
    ) {
        guard let target else { return }
        transmit(CommandLong(
            targetSystem: target.system,
            targetComponent: target.component,
            command: command,
            confirmation: 0,
            param1: param1, param2: param2, param3: param3, param4: param4,
            param5: param5, param6: param6, param7: param7
        ))
        expect(command)
    }

    /// DO_SET_MODE alone. The deprecated SET_MODE used to go out beside it,
    /// and ArduPilot answered both, so every refused mode change was
    /// reported twice in the vehicle's own messages.
    private func sendModeChange(_ request: ModeRequest) {
        sendCommand(
            MavCmd.doSetMode,
            param1: Float(MavModeFlag.customModeEnabled),
            param2: request.param2,
            param3: request.param3
        )
    }

    // MARK: - Stream setup

    /// Ask for the streams, then for the rates this app actually wants.
    ///
    /// Order matters, and getting it wrong silently undid everything.
    /// REQUEST_DATA_STREAM is the old blunt instrument -- one rate for a
    /// whole group of messages -- kept because firmware too old for
    /// per-message intervals still understands it. But ArduPilot rebuilds
    /// its message schedule from the stream rates when it arrives, so sent
    /// afterwards it wipes every interval set here and puts the disabled
    /// messages back on air. The Android build sent it second for a while,
    /// which is why its rate settings appeared to do nothing on a fresh
    /// connection.
    private func setUpStreams(firmware: Firmware) {
        guard let target else { return }
        transmit(RequestDataStream(
            targetSystem: target.system,
            targetComponent: target.component,
            reqStreamId: 0,
            reqMessageRate: 4,
            startStop: 1
        ))
        // HOME_POSITION is only sent when home is set, so connecting to a
        // vehicle already flying never sees it. Ask rather than wait for one
        // that will not come.
        sendCommand(MavCmd.requestMessage, param1: Float(HomePosition.messageId))
        applyStreamRates(firmware: firmware)
    }

    /// SET_MESSAGE_INTERVAL for each message, best effort: a vehicle that
    /// ignores these behaves exactly as it did before.
    ///
    /// [firmware] is passed rather than read, because on first contact this
    /// runs inside the heartbeat that identifies the vehicle, before that
    /// heartbeat has been written into the state. Reading the state would
    /// read .unknown every time, on exactly the connection the test was
    /// written for.
    private func applyStreamRates(firmware: Firmware) {
        var intervals: [(UInt32, Float)] = []
        if rates.full {
            // Everything at the vehicle's own rate. Zero means "your
            // default", a different thing from -1 for off.
            for (id, _) in Self.supportingRates { intervals.append((id, 0)) }
            intervals.append((Attitude.messageId, 0))
            intervals.append((GlobalPositionInt.messageId, 0))
            for id in Self.disabledMessages { intervals.append((id, 0)) }
        } else {
            for (id, hz) in Self.supportingRates { intervals.append((id, interval(hz))) }
            intervals.append((Attitude.messageId, interval(rates.attitudeHz)))
            intervals.append((GlobalPositionInt.messageId, interval(rates.positionHz)))
            for id in Self.disabledMessages { intervals.append((id, -1)) }
        }
        // The wind estimate arrives as WIND on ArduPilot and as WIND_COV on
        // PX4, and neither implements the other's. Asking PX4 for WIND earns
        // a complaint back on every connect, so it is left out rather than
        // disabled -- there is nothing there to turn off.
        if firmware == .px4 {
            intervals.removeAll { $0.0 == Wind.messageId }
        }
        for (id, microseconds) in intervals {
            sendCommand(MavCmd.setMessageInterval, param1: Float(id), param2: microseconds)
        }
    }

    private func interval(_ hz: Float) -> Float {
        hz > 0 ? (1_000_000 / hz).rounded() : -1
    }

    // MARK: - Answers and retries

    private func expect(_ command: UInt16) {
        // The mode has its own watcher, which also resends; two would talk
        // over each other. The stream setup is not the pilot's business.
        guard command != MavCmd.doSetMode, !Self.housekeeping.contains(command) else { return }
        awaited[command] = Awaited(what: spoken(command), due: clock() + Self.commandAnswerTime)
    }

    /// Resend the outstanding mode, or give up on it.
    private func driveModeRequest(now: Double) {
        guard var wanted = modeWanted else { return }
        if now >= wanted.until {
            modeWanted = nil
            state.modePending = nil
            // Two very different failures, reported apart. A command can go
            // unanswered because the link is dropping frames, and then
            // pressing again is the right advice. It can also go unanswered
            // because the radio carries telemetry down and nothing up -- on
            // which the Android build once said "too much of the link is
            // being lost" while its own meter read 1.5%, and sent the search
            // to the wrong end of the problem.
            if linkSoundsOneWay() {
                note("Mode change to \(wanted.mode) was not acknowledged, though telemetry is arriving normally. The aircraft is being heard but is not hearing this app - check that the radio link carries both directions.")
            } else {
                note("Mode change to \(wanted.mode) was not acknowledged - too much of the link is being lost. Press it again.")
            }
        } else if now >= wanted.nextRetry {
            wanted.nextRetry = now + Self.modeRetryEvery
            modeWanted = wanted
            sendModeChange(wanted.request)
        }
    }

    /// Say so about anything that has run out of time to answer.
    ///
    /// Reported, never resent. An autopilot answers a command it has already
    /// obeyed, so a missing answer can mean the command arrived and the
    /// answer did not -- and re-arming behind the pilot's back is worse than
    /// saying so once.
    private func sweepAwaited(now: Double) {
        for (command, entry) in awaited where now >= entry.due {
            awaited[command] = nil
            if linkSoundsOneWay() {
                note("The aircraft did not answer \(entry.what), though telemetry is arriving normally. It is being heard but is not hearing this app - check that the radio link carries both directions.")
            } else {
                note("The aircraft did not answer \(entry.what) - too much of the link is being lost. Try it again.")
            }
        }
    }

    private func sweepParam(now: Double) {
        guard let late = paramAwaited, now >= late.due else { return }
        paramAwaited = nil
        if linkSoundsOneWay() {
            note("The aircraft did not answer the \(late.what.lowercased()) change, though telemetry is arriving normally. It is being heard but is not hearing this app - check that the radio link carries both directions.")
        } else {
            note("The aircraft did not answer the \(late.what.lowercased()) change - too much of the link is being lost. Try it again.")
        }
    }

    /// Telemetry arriving cleanly while nothing answers what is sent.
    ///
    /// The two ways a request goes unanswered want opposite advice, and the
    /// link meter is what separates them. A radio dropping a third of its
    /// frames will swallow a command now and then, and pressing again is
    /// the cure. A radio carrying telemetry down and nothing up will swallow
    /// every one of them, and pressing again wastes the pilot's attention.
    private func linkSoundsOneWay() -> Bool {
        let quality = state.link
        guard let loss = quality.lossPercent else { return false }
        return quality.rxPerSec > 1 && loss < Self.oneWayLossPercent
    }

    /// A command's name as it should be read out.
    private func spoken(_ command: UInt16) -> String {
        guard let name = MavCmd.name(command) else { return "command \(command)" }
        return name.replacingOccurrences(of: "MAV_CMD_", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .lowercased()
    }

    // MARK: - Inbound

    private func handle(_ packet: MavlinkPacket) {
        let frame = packet.frame
        state.packetsIn += 1
        if let heartbeat = packet.message as? Heartbeat {
            onHeartbeat(heartbeat, frame: frame)
            return
        }
        // Once a vehicle has been chosen, only it is listened to. A second
        // airframe on the same network would otherwise have its attitude
        // drawn on this one's horizon.
        if let target, frame.systemId != target.system { return }

        switch packet.message {
        case let m as Attitude:
            state.rollDeg = m.roll * 180 / .pi
            state.pitchDeg = m.pitch * 180 / .pi
            // Arrives in -pi...pi; stored as a compass bearing like heading.
            state.yawDeg = Geo.normaliseBearing(m.yaw * 180 / .pi)
            state.yawRateDegSec = m.yawspeed * 180 / .pi

        case let m as GlobalPositionInt:
            let lat = Double(m.lat) / 1e7
            let lon = Double(m.lon) / 1e7
            // Course from the velocity, not the heading: in a crosswind the
            // aircraft points one way and travels another.
            let north = Float(m.vx) / 100
            let east = Float(m.vy) / 100
            if hypotf(north, east) >= Self.minCourseSpeedMs {
                state.groundCourseDeg = Geo.normaliseBearing(atan2f(east, north) * 180 / .pi)
            } // Below walking pace the direction is noise; keep the last.
            state.lat = lat
            state.lon = lon
            state.altMslM = Float(m.alt) / 1000
            state.altRelM = Float(m.relativeAlt) / 1000
            state.headingDeg = m.hdg < 36000 ? Float(m.hdg) / 100 : nil
            state.distToHomeM = Geo.distance(lat, lon, state.homeLat, state.homeLon)

        case let m as GpsRawInt:
            state.gpsFix = gpsFixName(m.fixType)
            state.gpsFixType = m.fixType
            // 255 is the receiver's "did not say", not a count.
            state.satellites = m.satellitesVisible == 255 ? nil : Int(m.satellitesVisible)
            state.hdop = m.eph == UInt16.max ? nil : Float(m.eph) / 100
            if state.lat == nil && m.lat != 0 {
                state.lat = Double(m.lat) / 1e7
                state.lon = Double(m.lon) / 1e7
            }

        case let m as VfrHud:
            state.airSpeedMs = m.airspeed
            state.groundSpeedMs = m.groundspeed
            state.headingDeg = Float(m.heading)
            state.throttlePct = Int(m.throttle)
            state.altMslM = m.alt
            state.climbMs = m.climb

        case let m as RcChannels:
            // 0...254, with 255 meaning nothing to report -- not the same as
            // no signal, and what a MAVLink-injected RC link leaves there.
            state.rssiPercent = m.rssi == 255 ? nil : Float(m.rssi) * 100 / 254

        case let m as CommandAck:
            onCommandAck(m)

        case let m as ParamValue:
            onParamValue(m)

        case let m as SysStatus:
            state.sensorsPresent = m.onboardControlSensorsPresent
            state.sensorsHealth = m.onboardControlSensorsHealth
            state.batteryV = (1...65534).contains(m.voltageBattery) ? Float(m.voltageBattery) / 1000 : nil
            state.batteryA = m.currentBattery == -1 ? nil : Float(m.currentBattery) / 100
            state.batteryRemainingPct = (0...100).contains(m.batteryRemaining) ? Int(m.batteryRemaining) : nil

        case let m as BatteryStatus:
            if (0...100).contains(m.batteryRemaining) {
                state.batteryRemainingPct = Int(m.batteryRemaining)
            }
            if m.currentBattery != -1 {
                state.batteryA = Float(m.currentBattery) / 100
            }
            // Cell 0 holds the whole pack when the cells are not measured
            // separately, and the rest say UINT16_MAX. When they are
            // measured, the pack is their sum -- reading cell 0 alone would
            // put one cell's 4.1 V where the pack voltage belongs.
            let cells = m.voltages.filter { $0 != UInt16.max && $0 > 0 }
            if !cells.isEmpty {
                state.batteryV = Float(cells.reduce(0) { $0 + Int($1) }) / 1000
            }

        case let m as MissionCurrent:
            state.currentWaypointSeq = Int(m.seq)

        case let m as NavControllerOutput:
            // One message carries both which way the controller is steering
            // and how far it has left to go.
            state.distToWpM = Float(m.wpDist)
            state.navBearingDeg = Geo.normaliseBearing(Float(m.targetBearing))

        case let m as HomePosition:
            let lat = Double(m.latitude) / 1e7
            let lon = Double(m.longitude) / 1e7
            state.homeLat = lat
            state.homeLon = lon
            state.homeAltM = Double(m.altitude) / 1000
            state.distToHomeM = Geo.distance(state.lat, state.lon, lat, lon)

        case let m as Wind:
            // ArduPilot wraps this to -180...180, so a westerly reads -13
            // rather than 347.
            state.windDirectionDeg = Geo.normaliseBearing(m.direction)
            state.windSpeedMs = m.speed

        case let m as Rangefinder:
            state.rangefinderM = m.distance

        case let m as DistanceSensor:
            // Only the downward sensor is the altitude rangefinder; a
            // proximity ring reports on other orientations. Only zero means
            // no reading: max_distance is the sensor's configured range, not
            // a cap on what ArduPilot will send.
            if m.orientation == MavSensorOrientation.pitch270 {
                state.rangefinderM = m.currentDistance > 0 ? Float(m.currentDistance) / 100 : nil
            }

        case let m as ScaledPressure:
            state.qnhHpa = Geo.qnh(pressAbsHpa: m.pressAbs, altMslM: state.altMslM)

        case let m as TerrainReport:
            state.terrainAltM = m.terrainHeight

        case let m as Statustext:
            appendVehicleMessage(m)

        default:
            break
        }
    }

    private func onHeartbeat(_ heartbeat: Heartbeat, frame: MavlinkFrame) {
        // Other ground stations, and the components that are not autopilots
        // -- a gimbal, a camera, a companion computer. Commands go to whoever
        // sent the heartbeat, and the Android build found that a second
        // component appearing on the link silently takes them over: the
        // vehicle is heard perfectly and obeys nothing.
        if heartbeat.type == MavType.gcs || heartbeat.autopilot == MavAutopilot.invalid { return }
        // The first autopilot heard is the one this session flies.
        if let target, target.system != frame.systemId { return }

        let firstContact = target == nil
        target = (frame.systemId, frame.componentId)
        let firmware: Firmware
        switch heartbeat.autopilot {
        case MavAutopilot.ardupilotmega: firmware = .ardupilot
        case MavAutopilot.px4: firmware = .px4
        default: firmware = .unknown
        }
        if firstContact {
            setUpStreams(firmware: firmware)
        }
        let vehicleType = MavType.name(heartbeat.type)?.replacingOccurrences(of: "MAV_TYPE_", with: "")
            ?? "TYPE \(heartbeat.type)"
        let mode = FlightModes.modeName(firmware: firmware, vehicleType: vehicleType, customMode: heartbeat.customMode)
        // The aircraft saying which mode it is in is the only confirmation
        // worth having. A COMMAND_ACK says the request was received, not
        // that the mode took.
        if let wanted = modeWanted, wanted.mode == mode {
            modeWanted = nil
            state.modePending = nil
        }
        state.linkUp = true
        state.lastHeartbeat = clock()
        state.systemId = frame.systemId
        state.componentId = frame.componentId
        state.autopilot = MavAutopilot.name(heartbeat.autopilot)?.replacingOccurrences(of: "MAV_AUTOPILOT_", with: "") ?? "—"
        state.vehicleType = vehicleType
        state.firmware = firmware
        state.mode = mode
        state.customMode = heartbeat.customMode
        state.armed = heartbeat.baseMode & MavModeFlag.safetyArmed != 0
        state.systemStatus = MavState.name(heartbeat.systemStatus)?.replacingOccurrences(of: "MAV_STATE_", with: "") ?? "UNINIT"
    }

    /// The aircraft's verdict on a command, said out loud unless it is a
    /// plain yes. An accepted command proves itself soon enough, and
    /// narrating every success would bury the vehicle's own messages.
    private func onCommandAck(_ ack: CommandAck) {
        // Addressed to another ground station on the same link.
        if ack.targetSystem != 0 && ack.targetSystem != Self.gcsSystemId { return }
        awaited[ack.command] = nil
        if ack.result == MavResult.accepted || ack.result == MavResult.inProgress { return }
        // The app asked for these itself. A refused one is not worth a row of
        // identical complaints where the aircraft's PreArm messages should be.
        if Self.housekeeping.contains(ack.command) { return }
        let why: String
        switch ack.result {
        case MavResult.temporarilyRejected: why = "not right now - the aircraft is busy or not in a state to do it"
        case MavResult.denied: why = "refused"
        case MavResult.unsupported: why = "not supported by this firmware"
        case MavResult.failed: why = "tried and failed"
        // MAV_RESULT_CANCELLED, newer than the definitions this app's
        // messages were generated from.
        case 6: why = "cancelled"
        default: why = "answered \(MavResult.name(ack.result) ?? "with something unrecognised")"
        }
        note("The aircraft \(why): \(spoken(ack.command)).")
        // Holding the button amber and resending for ten more seconds is
        // pointless once the aircraft has said no.
        if ack.command == MavCmd.doSetMode {
            modeWanted = nil
            state.modePending = nil
        }
    }

    /// What the aircraft says it is holding for a parameter that was set.
    private func onParamValue(_ value: ParamValue) {
        guard let wanted = paramAwaited, value.paramId.trimmingCharacters(in: .whitespaces) == wanted.id else { return }
        paramAwaited = nil
        let got = value.paramValue
        if abs(got - wanted.asked) < Self.paramSameEnough {
            note("\(wanted.what) is now \(Self.round(got))\(wanted.unit).")
        } else {
            note("\(wanted.what) is now \(Self.round(got))\(wanted.unit) - the aircraft would not take \(Self.round(wanted.asked))\(wanted.unit).")
        }
    }

    /// Metres, without a trailing zero nobody needs.
    static func round(_ value: Float) -> String {
        abs(value - value.rounded()) < 0.05 ? String(Int(value.rounded())) : String(format: "%.1f", value)
    }

    /// The vehicle's own STATUSTEXT. ArduPilot splits a long message across
    /// chunks sharing an id with an increasing sequence, so a continuation
    /// is joined onto the line before rather than logged as a fragment.
    ///
    /// Taken exactly as sent, spaces included. ArduPilot cuts a long line
    /// at 50 characters wherever that falls, and when it falls just after a
    /// space, trimming each chunk -- which the Android build does -- glues
    /// the two words either side of the cut together.
    private func appendVehicleMessage(_ text: Statustext) {
        let line = text.text
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let continues = text.id != 0 && text.id == chunkId && Int(text.chunkSeq) == chunkSequence + 1
        chunkId = text.id
        chunkSequence = Int(text.chunkSeq)
        if continues, !state.messages.isEmpty {
            state.messages[state.messages.count - 1].text += line
        } else {
            append(line, severity: text.severity)
        }
    }

    /// A line for the Messages panel that did not come from the vehicle.
    private func note(_ text: String) {
        append(text, severity: nil)
    }

    private func append(_ text: String, severity: UInt8?) {
        messageCount += 1
        state.messages.append(VehicleMessage(id: messageCount, text: text, severity: severity, time: Date()))
        if state.messages.count > Self.maxMessages {
            state.messages.removeFirst(state.messages.count - Self.maxMessages)
        }
        schedulePublish()
    }

    private func gpsFixName(_ fix: UInt8) -> String {
        switch fix {
        case 0, 1: return "NO FIX"
        case 2: return "2D"
        case 3: return "3D"
        case 4: return "DGPS"
        case 5: return "RTK FLOAT"
        case 6: return "RTK FIXED"
        default: return "FIX \(fix)"
        }
    }

    // MARK: - Publishing

    private func schedulePublish() {
        guard !publishScheduled, observer != nil else { return }
        publishScheduled = true
        queue.asyncAfter(deadline: .now() + Self.publishInterval) { [self] in
            publishScheduled = false
            observer?(state)
        }
    }

    private func publishNow() {
        observer?(state)
    }
}
