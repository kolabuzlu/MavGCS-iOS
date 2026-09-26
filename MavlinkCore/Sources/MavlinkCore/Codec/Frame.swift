/// One frame as it crossed the link, header fields and all.
public struct MavlinkFrame: Sendable, Equatable {
    public enum Version: Sendable, Equatable {
        case v1
        case v2
    }

    public var version: Version
    public var sequence: UInt8
    public var systemId: UInt8
    public var componentId: UInt8
    public var messageId: UInt32
    /// The payload as carried, which MAVLink 2 may have cut short.
    public var payload: [UInt8]
    public var signed: Bool
}

/// A frame and the message decoded from it.
public struct MavlinkPacket: Sendable {
    public var frame: MavlinkFrame
    public var message: any MavlinkMessage
}

enum Wire {
    static let magicV1: UInt8 = 0xFE
    static let magicV2: UInt8 = 0xFD
    /// Start marker to message id, inclusive.
    static let headerV1 = 6
    static let headerV2 = 10
    static let checksum = 2
    static let signature = 13
    /// The one incompatibility flag defined: a signature follows the checksum.
    static let flagSigned: UInt8 = 0x01
}

/// Finds MAVLink 1 and 2 frames in a byte stream and decodes those it knows.
///
/// Bytes can arrive in any slicing -- a datagram per frame, several frames
/// in one TCP read, a frame split across two -- so nothing is decided until
/// the whole of a frame is here.
///
/// A frame is only accepted once its checksum is proven, and a checksum
/// can only be proven for a message whose CRC_EXTRA is known, so a frame of
/// any other message is stepped over a byte at a time rather than skipped
/// whole. That costs nothing when it really is a frame. When it is not --
/// a payload byte that happened to look like a start marker, which is what
/// a TCP connection opened partway through a stream begins with -- it means
/// a made-up length is never trusted, and the real frames it would have
/// swallowed are found instead. Counting every frame, understood or not, is
/// the link meter's job and it does it separately (FrameCounter).
public struct FrameParser: Sendable {
    private var buffer: [UInt8] = []
    private var head = 0

    public init() {}

    /// Everything that could be decoded from what has arrived so far.
    public mutating func push(_ bytes: some Sequence<UInt8>) -> [MavlinkPacket] {
        buffer.append(contentsOf: bytes)
        var packets: [MavlinkPacket] = []
        while let packet = next() {
            packets.append(packet)
        }
        // Consumed bytes are dropped in bulk rather than one at a time.
        if head == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            head = 0
        } else if head > 4096 {
            buffer.removeFirst(head)
            head = 0
        }
        return packets
    }

    private mutating func next() -> MavlinkPacket? {
        while head < buffer.count {
            let magic = buffer[head]
            guard magic == Wire.magicV2 || magic == Wire.magicV1 else {
                head += 1
                continue
            }
            switch attempt(v2: magic == Wire.magicV2) {
            case .decoded(let packet, let length):
                head += length
                return packet
            case .needMore:
                return nil
            case .notAFrame:
                head += 1
            }
        }
        return nil
    }

    private enum Attempt {
        case decoded(MavlinkPacket, length: Int)
        case needMore
        case notAFrame
    }

    private func attempt(v2: Bool) -> Attempt {
        let available = buffer.count - head
        let header = v2 ? Wire.headerV2 : Wire.headerV1
        guard available >= header else { return .needMore }

        let length = Int(buffer[head + 1])
        let flags = v2 ? buffer[head + 2] : 0
        // A flag this code does not know changes how the frame must be
        // read, which is the meaning of "incompatibility". Nothing sends
        // one yet, so in practice this is a marker that was not a marker.
        if flags & ~Wire.flagSigned != 0 { return .notAFrame }
        let signed = flags & Wire.flagSigned != 0

        let messageId: UInt32
        if v2 {
            messageId = UInt32(buffer[head + 7])
                | UInt32(buffer[head + 8]) << 8
                | UInt32(buffer[head + 9]) << 16
        } else {
            messageId = UInt32(buffer[head + 5])
        }
        guard let type = MavlinkRegistry.types[messageId] else { return .notAFrame }
        // MAVLink 1 always carries exactly the base fields. MAVLink 2 may
        // carry the extensions, and may cut trailing zeros, but never more
        // than the whole message.
        if v2 ? length > type.maxLength : length != type.minLength { return .notAFrame }

        let total = header + length + Wire.checksum + (signed ? Wire.signature : 0)
        guard available >= total else { return .needMore }

        var crc = Crc16()
        crc.accumulate(buffer[(head + 1)..<(head + header + length)])
        crc.accumulate(type.crcExtra)
        let sent = UInt16(buffer[head + header + length])
            | UInt16(buffer[head + header + length + 1]) << 8
        guard crc.value == sent else { return .notAFrame }

        let payload = Array(buffer[(head + header)..<(head + header + length)])
        let frame = MavlinkFrame(
            version: v2 ? .v2 : .v1,
            sequence: buffer[head + (v2 ? 4 : 2)],
            systemId: buffer[head + (v2 ? 5 : 3)],
            componentId: buffer[head + (v2 ? 6 : 4)],
            messageId: messageId,
            payload: payload,
            signed: signed
        )
        let message = type.init(from: PayloadReader(payload, length: type.maxLength))
        return .decoded(MavlinkPacket(frame: frame, message: message), length: total)
    }
}

/// Turns messages into MAVLink 2 frames, from one sender.
///
/// Every frame has its payload's trailing zero bytes cut off, keeping at
/// least the first byte. The format allows this rather than requiring it,
/// and every autopilot accepts either form -- but an ExpressLRS link does
/// not. The Android build learned it the expensive way: the same
/// DO_SET_MODE, same target, sent seconds apart down the same socket, was
/// answered at 44 bytes and silently lost at 45, one trailing zero on the
/// confirmation field being the whole difference. Every command it had
/// ever sent over that radio had been going missing while telemetry
/// poured back the other way and made the link look healthy. Cutting the
/// zeros here, when the frame is built, means there is no untrimmed form
/// to escape.
public struct FrameEncoder: Sendable {
    public var systemId: UInt8
    public var componentId: UInt8
    private var sequence: UInt8 = 0

    public init(systemId: UInt8, componentId: UInt8) {
        self.systemId = systemId
        self.componentId = componentId
    }

    public mutating func encode(_ message: some MavlinkMessage) -> [UInt8] {
        let payload = message.payload()
        var length = payload.count
        while length > 1 && payload[length - 1] == 0 {
            length -= 1
        }
        let id = type(of: message).messageId
        var frame: [UInt8] = [
            Wire.magicV2,
            UInt8(length),
            0, // incompatibility flags: unsigned
            0, // compatibility flags
            sequence,
            systemId,
            componentId,
            UInt8(truncatingIfNeeded: id),
            UInt8(truncatingIfNeeded: id >> 8),
            UInt8(truncatingIfNeeded: id >> 16),
        ]
        frame.append(contentsOf: payload[0..<length])
        var crc = Crc16()
        crc.accumulate(frame[1...])
        crc.accumulate(type(of: message).crcExtra)
        frame.append(UInt8(truncatingIfNeeded: crc.value))
        frame.append(UInt8(truncatingIfNeeded: crc.value >> 8))
        sequence &+= 1
        return frame
    }
}
