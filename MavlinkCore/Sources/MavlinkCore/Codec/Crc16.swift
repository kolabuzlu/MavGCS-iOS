/// CRC-16/MCRF4XX, which MAVLink calls X.25: the checksum on every frame.
///
/// Run over everything after the start marker, then over the message's
/// CRC_EXTRA, which is never sent -- both ends have to already agree on it.
public struct Crc16: Sendable {
    public private(set) var value: UInt16 = 0xFFFF

    public init() {}

    public mutating func accumulate(_ byte: UInt8) {
        // The shifts on an 8-bit value drop what falls off the top, exactly
        // as the reference C does by storing back into a uint8_t.
        var tmp = byte ^ UInt8(truncatingIfNeeded: value)
        tmp ^= tmp << 4
        value = (value >> 8) ^ (UInt16(tmp) << 8) ^ (UInt16(tmp) << 3) ^ (UInt16(tmp) >> 4)
    }

    public mutating func accumulate(_ bytes: some Sequence<UInt8>) {
        for byte in bytes {
            accumulate(byte)
        }
    }
}
