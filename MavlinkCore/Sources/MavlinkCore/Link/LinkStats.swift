/// What the link is actually carrying, and what it is losing.
///
/// Four numbers the pilot can act on. Throughput says whether the radio has
/// room: an ELRS downlink is 435 bytes a second, and a GCS that asks for
/// more gets the difference thrown away by the radio, silently and without
/// regard for which messages mattered. Loss says whether what was asked for
/// is arriving.
public struct LinkQuality: Sendable, Equatable {
    public var rxBytesPerSec = 0
    public var txBytesPerSec = 0
    public var rxPerSec: Float = 0
    public var txPerSec: Float = 0
    /// Share of the vehicle's messages that went missing over the last few
    /// seconds, 0...100, or nil until enough have passed to divide by.
    ///
    /// Recent rather than cumulative on purpose: a figure averaged over a
    /// twenty minute flight says nothing about the radio now, which is the
    /// only thing worth knowing while flying it.
    public var lossPercent: Float?
    /// Messages the vehicle sent that did not arrive, this session.
    public var lost = 0
    /// Messages received, this session.
    public var received = 0

    public init() {}
}

/// Counts what crosses the link and works out what went missing.
///
/// Loss is measured rather than guessed. Every MAVLink frame carries a
/// sequence number that steps by one for each message its sender emits, so
/// a jump of more than one is exactly the number that did not make it --
/// the same arithmetic every other ground station uses, and the only way to
/// tell a vehicle that has gone quiet from a radio that is dropping what it
/// sends.
///
/// Kept per sender: an autopilot and a companion computer each number their
/// own messages, and comparing one's sequence against the other's would
/// invent losses that never happened.
///
/// Not thread-safe; the client only touches it from its own queue.
struct LinkStats {
    /// How many completed seconds the reported loss is measured over.
    static let lossWindowSeconds = 10

    /// The gap above which a jump reads as a sender restart, not a loss.
    ///
    /// There is a real ceiling here. The sequence is a single byte, so it
    /// wraps every 256 messages: at about 22 messages a second, an outage
    /// beyond roughly eleven seconds is genuinely indistinguishable from a
    /// short one, and no arithmetic can recover it. This sits below that,
    /// far enough to count every outage the counter can still describe and
    /// still leave a near-full cycle looking like what it almost certainly
    /// is -- an autopilot that rebooted and started again from zero.
    ///
    /// The Android build once had this at 64, which inverted the meter: at
    /// the rates the app asks for, anything over about three seconds off
    /// the air was thrown out of the count, so a link that stuttered read a
    /// few per cent while a link that blacked out read zero. A blackout is
    /// the one a pilot needs to see.
    static let restartGap = 192

    private var windowStart: Double = 0
    private var rxBytes = 0
    private var txBytes = 0
    private var rxCount = 0
    private var txCount = 0

    /// Last sequence seen from each sender, keyed by system and component.
    private var lastSequence: [UInt16: UInt8] = [:]
    private var lost = 0
    private var received = 0

    /// The last few completed seconds, so the reported loss is a recent one.
    private var recentLost: [Int] = []
    private var recentTotal: [Int] = []
    private var windowLost = 0
    private var windowReceived = 0

    private(set) var snapshot = LinkQuality()

    mutating func reset() {
        self = LinkStats()
    }

    /// A frame arrived. [bytes] is the whole frame on the wire, because that
    /// is what the radio had to carry.
    mutating func onRx(bytes: Int, systemId: UInt8, componentId: UInt8, sequence: UInt8) {
        rxBytes += bytes
        rxCount += 1
        received += 1
        windowReceived += 1
        let key = UInt16(systemId) << 8 | UInt16(componentId)
        if let previous = lastSequence[key] {
            // Wraps at 256. A gap of one is the next message, so anything
            // beyond that is the count that went missing.
            let gap = (Int(sequence) - Int(previous) - 1 + 256) % 256
            if gap < Self.restartGap {
                lost += gap
                windowLost += gap
            }
        }
        lastSequence[key] = sequence
    }

    /// Bytes went out. [frame] marks the write that carried a whole message,
    /// so the message count follows frames while the byte count follows bytes.
    mutating func onTx(bytes: Int, frame: Bool) {
        txBytes += bytes
        if frame { txCount += 1 }
    }

    /// Loss over the seconds still in the ring, or nil before there are enough.
    private func recentLossPercent() -> Float? {
        let total = recentTotal.reduce(0, +)
        // A handful of messages can read 50% off a single gap, which would
        // flicker alarmingly on an otherwise sound link.
        guard total >= 20 else { return nil }
        return 100 * Float(recentLost.reduce(0, +)) / Float(total)
    }

    /// Roll the one-second window if it has elapsed, and return the latest.
    mutating func sample(now: Double) -> LinkQuality {
        if windowStart == 0 {
            // The first window starts here, not at connect: counting what
            // arrived before it would put two seconds of traffic over one.
            windowStart = now
            rxBytes = 0
            txBytes = 0
            rxCount = 0
            txCount = 0
            return snapshot
        }
        let elapsed = now - windowStart
        guard elapsed >= 1 else { return snapshot }
        var next = LinkQuality()
        next.rxBytesPerSec = Int(Double(rxBytes) / elapsed)
        next.txBytesPerSec = Int(Double(txBytes) / elapsed)
        next.rxPerSec = Float(Double(rxCount) / elapsed)
        next.txPerSec = Float(Double(txCount) / elapsed)
        next.lost = lost
        next.received = received
        rxBytes = 0
        txBytes = 0
        rxCount = 0
        txCount = 0
        recentLost.append(windowLost)
        recentTotal.append(windowLost + windowReceived)
        if recentLost.count > Self.lossWindowSeconds {
            recentLost.removeFirst()
            recentTotal.removeFirst()
        }
        // Worked out after this second joins the ring, so the first second
        // of a connection is held back like any other short sample.
        next.lossPercent = recentLossPercent()
        windowLost = 0
        windowReceived = 0
        windowStart = now
        snapshot = next
        return next
    }
}

/// Finds frame boundaries in a raw MAVLink byte stream, for the link meter.
///
/// Separate from the parser because the measurement has to see every
/// frame, and the parser only accepts frames of messages it can check. The
/// Android build learned why that matters: counting parsed messages made a
/// hole in the numbering wherever a frame of an unknown message had been,
/// and on a link dropping nothing at all, with ArduPilot streaming the one
/// message that dialect lacked, the meter read 11.2% loss.
///
/// Only the header is read. A frame announces its own length, so there is
/// no need to understand what it carries -- which is the entire point.
struct FrameCounter {
    struct Frame: Equatable {
        var bytes: Int
        var systemId: UInt8
        var componentId: UInt8
        var sequence: UInt8
    }

    /// Bytes taken from the current frame, start marker included. Zero
    /// means hunting for a marker.
    private var index = 0
    private var v2 = false
    private var total = 0
    private var sequence: UInt8 = 0
    private var systemId: UInt8 = 0
    private var componentId: UInt8 = 0

    /// A frame that is complete but not yet counted.
    ///
    /// Held back one byte on purpose. Frames run back to back, so the byte
    /// after one must begin the next; if it does not, this was never a frame
    /// and the counter had latched onto a payload byte that happened to look
    /// like a marker. That happens whenever a connection opens partway
    /// through a frame -- over TCP to a running simulator, the normal case --
    /// and without this check the mistake would go on inventing losses
    /// rather than correcting itself.
    private var pending: Frame?

    mutating func reset() {
        self = FrameCounter()
    }

    /// Feed one byte; returns a frame once the byte after it proves it real.
    mutating func byte(_ b: UInt8) -> Frame? {
        var confirmed: Frame?
        if let frame = pending {
            pending = nil
            if b == Wire.magicV1 || b == Wire.magicV2 {
                confirmed = frame
            } else {
                // Out of step. Drop the supposed frame and hunt for a marker.
                index = 0
                return nil
            }
        }
        if index == 0 {
            switch b {
            case Wire.magicV2:
                v2 = true
                index = 1
            case Wire.magicV1:
                v2 = false
                index = 1
            default:
                break
            }
            return confirmed
        }
        switch (v2, index) {
        case (_, 1):
            total = Int(b) + (v2 ? Wire.headerV2 : Wire.headerV1) + Wire.checksum
        case (true, 2):
            // The flag that adds a signature changes how long the frame is.
            if b & Wire.flagSigned != 0 { total += Wire.signature }
        case (true, 4), (false, 2):
            sequence = b
        case (true, 5), (false, 3):
            systemId = b
        case (true, 6), (false, 4):
            componentId = b
        default:
            break
        }
        index += 1
        if index >= total {
            pending = Frame(bytes: total, systemId: systemId, componentId: componentId, sequence: sequence)
            index = 0
        }
        return confirmed
    }
}
