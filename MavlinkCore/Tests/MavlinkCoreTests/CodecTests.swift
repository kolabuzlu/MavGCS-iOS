import Foundation
import Testing
@testable import MavlinkCore

/// The codec checked against frames pymavlink built (tools/make_test_vectors.py).
struct CodecTests {
    /// Read once from the JSON and never changed, so safe to share across
    /// the tests however they are scheduled.
    struct Vector: @unchecked Sendable {
        let name: String
        let system: UInt8
        let component: UInt8
        let raw: [String: Any]

        func bytes(_ key: String) -> [UInt8]? {
            (raw[key] as? String).map(hexBytes)
        }

        func fields(_ key: String) -> [String: Any] {
            raw[key] as? [String: Any] ?? [:]
        }
    }

    static let vectors: [Vector] = {
        guard
            let url = Bundle.module.url(forResource: "frames", withExtension: "json", subdirectory: "Vectors"),
            let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let list = root["vectors"] as? [[String: Any]]
        else { return [] }
        return list.map {
            Vector(
                name: $0["name"] as! String,
                system: UInt8($0["system"] as! Int),
                component: UInt8($0["component"] as! Int),
                raw: $0
            )
        }
    }()

    @Test func vectorsLoaded() {
        #expect(Self.vectors.count == MavlinkRegistry.types.count)
    }

    @Test func checksumMatchesTheStandardCheckValue() {
        // CRC-16/MCRF4XX's published check value for "123456789".
        var crc = Crc16()
        crc.accumulate(Array("123456789".utf8))
        #expect(crc.value == 0x6F91)
    }

    @Test(arguments: vectors.map(\.name))
    func decodesAndReencodesEveryForm(name: String) throws {
        let vector = try #require(Self.vectors.first { $0.name == name })
        for (bytesKey, fieldsKey, version) in [
            ("v2", "fields", MavlinkFrame.Version.v2),
            ("v2_trimmed", "fields_trimmed", .v2),
            ("v2_signed", "fields", .v2),
            ("v1", "fields_v1", .v1),
        ] {
            guard let bytes = vector.bytes(bytesKey) else { continue }
            var parser = FrameParser()
            let packets = parser.push(bytes)
            try #require(packets.count == 1, "\(name) \(bytesKey): \(packets.count) packets")
            let packet = packets[0]
            #expect(packet.frame.version == version)
            #expect(packet.frame.systemId == vector.system)
            #expect(packet.frame.componentId == vector.component)
            #expect(packet.frame.signed == (bytesKey == "v2_signed"))
            expectFields(packet.message, vector.fields(fieldsKey), "\(name) \(bytesKey)")

            // The encoder has to produce exactly what pymavlink did, trailing
            // zeros cut the same way. Signed and v1 frames are not things
            // this app ever sends.
            if bytesKey == "v2" || bytesKey == "v2_trimmed" {
                var encoder = FrameEncoder(systemId: vector.system, componentId: vector.component)
                #expect(encoder.encode(packet.message) == bytes, "\(name) \(bytesKey) re-encoded")
            }
        }
    }

    @Test func findsEveryFrameInANoisyStreamWhateverTheSlicing() {
        var stream: [UInt8] = []
        var expected: [String] = []
        for (index, vector) in Self.vectors.enumerated() {
            // Rubbish between frames, including bytes that look like start
            // markers, and one false start that claims a known message id.
            stream += [0x00, 0xFD, 0x03, 0xFE, UInt8(index)]
            stream += [0xFD, 0x09, 0x00, 0x00, 0x05, 0x01, 0x01, 0x00, 0x00, 0x00]
            for key in ["v2", "v2_signed", "v1", "v2_trimmed"] {
                if let bytes = vector.bytes(key) {
                    stream += bytes
                    expected.append(vector.name)
                }
            }
        }
        for chunk in [1, 2, 7, 64, 1000, stream.count] {
            var parser = FrameParser()
            var found: [String] = []
            var index = 0
            while index < stream.count {
                let end = min(index + chunk, stream.count)
                found += parser.push(stream[index..<end]).map { type(of: $0.message).messageName }
                index = end
            }
            #expect(found == expected, "chunk \(chunk)")
        }
    }

    @Test func rejectsAFrameWithOneBitWrong() throws {
        let vector = try #require(Self.vectors.first { $0.name == "ATTITUDE" })
        var bytes = try #require(vector.bytes("v2"))
        bytes[14] ^= 0x01
        var parser = FrameParser()
        #expect(parser.push(bytes).isEmpty)
    }

    @Test func sequenceNumbersCountUpAndWrap() {
        var encoder = FrameEncoder(systemId: 255, componentId: 190)
        var sequences: [UInt8] = []
        for _ in 0..<258 {
            sequences.append(encoder.encode(Heartbeat())[4])
        }
        #expect(sequences[0] == 0)
        #expect(sequences[255] == 255)
        #expect(sequences[256] == 0)
    }

    @Test func anAllZeroPayloadKeepsOneByte() {
        var encoder = FrameEncoder(systemId: 255, componentId: 190)
        let frame = encoder.encode(MissionCurrent())
        #expect(frame[1] == 1)
        var parser = FrameParser()
        #expect(parser.push(frame).count == 1)
    }
}

// MARK: - Helpers

private func hexBytes(_ text: String) -> [UInt8] {
    var bytes: [UInt8] = []
    var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        bytes.append(UInt8(text[index..<next], radix: 16)!)
        index = next
    }
    return bytes
}

/// The generator's own snake_case to camelCase rule.
private func camel(_ snake: String) -> String {
    let parts = snake.lowercased().split(separator: "_").map(String.init)
    guard let first = parts.first else { return snake }
    return first + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
}

/// Every field pymavlink set, compared with what was decoded.
private func expectFields(
    _ message: any MavlinkMessage,
    _ expected: [String: Any],
    _ context: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    var actual: [String: Any] = [:]
    for child in Mirror(reflecting: message).children {
        if let label = child.label {
            actual[label] = child.value
        }
    }
    #expect(!expected.isEmpty, "\(context): no fields", sourceLocation: sourceLocation)
    for (name, want) in expected where name != "mavlink_version" {
        guard let got = actual[camel(name)] else {
            Issue.record("\(context): no field \(camel(name))", sourceLocation: sourceLocation)
            continue
        }
        #expect(same(got, want), "\(context).\(name): \(got) != \(want)", sourceLocation: sourceLocation)
    }
}

private func same(_ got: Any, _ want: Any) -> Bool {
    if let wants = want as? [String] {
        let gots: [Any]
        switch got {
        case let values as [UInt8]: gots = values
        case let values as [Int8]: gots = values
        case let values as [UInt16]: gots = values
        case let values as [Int16]: gots = values
        case let values as [UInt32]: gots = values
        case let values as [Int32]: gots = values
        case let values as [Float]: gots = values
        case let values as [Double]: gots = values
        default: return false
        }
        return gots.count == wants.count && zip(gots, wants).allSatisfy { same($0, $1) }
    }
    guard let want = want as? String else { return false }
    switch got {
    case let value as Float: return Double(value) == Double(want)
    case let value as Double: return value == Double(want)
    case let value as String: return value == want
    default: return "\(got)" == want
    }
}
