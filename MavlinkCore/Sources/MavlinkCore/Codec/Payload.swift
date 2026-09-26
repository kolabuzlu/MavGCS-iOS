/// One MAVLink message: its identity, and how its fields sit in a payload.
///
/// The conforming types are generated from the official definitions by
/// tools/generate_mavlink.py; nothing here knows a byte offset.
public protocol MavlinkMessage: Sendable {
    static var messageId: UInt32 { get }
    static var messageName: String { get }
    /// The seed mixed into the checksum, which changes whenever the
    /// message's layout does, so two ends that disagree about a message
    /// reject it rather than misread it.
    static var crcExtra: UInt8 { get }
    static var minLength: Int { get }
    static var maxLength: Int { get }

    init(from reader: PayloadReader)
    func write(to writer: inout PayloadWriter)
}

extension MavlinkMessage {
    /// Decode from a payload as it arrived, however short.
    public init(payload: [UInt8]) {
        self.init(from: PayloadReader(payload, length: Self.maxLength))
    }

    /// Every field in place, extensions included, before any truncation.
    public func payload() -> [UInt8] {
        var writer = PayloadWriter(length: Self.maxLength)
        write(to: &writer)
        return writer.bytes
    }
}

/// A payload read field by field, little-endian, at fixed offsets.
///
/// Always padded out to the full length of the message. MAVLink 2 drops
/// trailing zero bytes on the wire and MAVLink 1 never carries extension
/// fields at all, so what arrives is often shorter than the message it
/// holds. The missing tail is zeros by definition, and filling it in once
/// here means no field ever has to ask whether it was sent.
public struct PayloadReader: Sendable {
    public let bytes: [UInt8]

    public init(_ bytes: [UInt8], length: Int) {
        if bytes.count >= length {
            self.bytes = bytes
        } else {
            self.bytes = bytes + [UInt8](repeating: 0, count: length - bytes.count)
        }
    }

    public func u8(at offset: Int) -> UInt8 { bytes[offset] }

    public func i8(at offset: Int) -> Int8 { Int8(bitPattern: bytes[offset]) }

    public func u16(at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    public func i16(at offset: Int) -> Int16 { Int16(bitPattern: u16(at: offset)) }

    public func u32(at offset: Int) -> UInt32 {
        UInt32(u16(at: offset)) | UInt32(u16(at: offset + 2)) << 16
    }

    public func i32(at offset: Int) -> Int32 { Int32(bitPattern: u32(at: offset)) }

    public func u64(at offset: Int) -> UInt64 {
        UInt64(u32(at: offset)) | UInt64(u32(at: offset + 4)) << 32
    }

    public func i64(at offset: Int) -> Int64 { Int64(bitPattern: u64(at: offset)) }

    public func f32(at offset: Int) -> Float { Float(bitPattern: u32(at: offset)) }

    public func f64(at offset: Int) -> Double { Double(bitPattern: u64(at: offset)) }

    /// A fixed-width text field, which ends at its first NUL or at its
    /// width, whichever comes first. A field exactly as long as its text
    /// carries no terminator at all.
    public func string(at offset: Int, length: Int) -> String {
        let field = bytes[offset..<(offset + length)]
        let end = field.firstIndex(of: 0) ?? field.endIndex
        return String(decoding: field[field.startIndex..<end], as: UTF8.self)
    }
}

/// A payload written field by field, little-endian, into a zeroed buffer.
public struct PayloadWriter: Sendable {
    public private(set) var bytes: [UInt8]

    public init(length: Int) {
        bytes = [UInt8](repeating: 0, count: length)
    }

    public mutating func u8(_ value: UInt8, at offset: Int) { bytes[offset] = value }

    public mutating func i8(_ value: Int8, at offset: Int) { bytes[offset] = UInt8(bitPattern: value) }

    public mutating func u16(_ value: UInt16, at offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    public mutating func i16(_ value: Int16, at offset: Int) { u16(UInt16(bitPattern: value), at: offset) }

    public mutating func u32(_ value: UInt32, at offset: Int) {
        u16(UInt16(truncatingIfNeeded: value), at: offset)
        u16(UInt16(truncatingIfNeeded: value >> 16), at: offset + 2)
    }

    public mutating func i32(_ value: Int32, at offset: Int) { u32(UInt32(bitPattern: value), at: offset) }

    public mutating func u64(_ value: UInt64, at offset: Int) {
        u32(UInt32(truncatingIfNeeded: value), at: offset)
        u32(UInt32(truncatingIfNeeded: value >> 32), at: offset + 4)
    }

    public mutating func i64(_ value: Int64, at offset: Int) { u64(UInt64(bitPattern: value), at: offset) }

    public mutating func f32(_ value: Float, at offset: Int) { u32(value.bitPattern, at: offset) }

    public mutating func f64(_ value: Double, at offset: Int) { u64(value.bitPattern, at: offset) }

    /// Text cut to the field's width. The rest of the field is already
    /// zero, which is the terminator when there is room for one.
    public mutating func string(_ value: String, at offset: Int, length: Int) {
        for (index, byte) in value.utf8.prefix(length).enumerated() {
            bytes[offset + index] = byte
        }
    }
}
