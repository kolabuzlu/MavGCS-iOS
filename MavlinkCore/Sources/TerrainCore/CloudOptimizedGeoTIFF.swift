import Compression
import Foundation

/// What the reader needs from a cloud-optimised GeoTIFF's first directory:
/// how the pixels are cut into blocks, where each block is in the file, and
/// where on the earth the grid sits.
///
/// Ported from the Android build's TerrainProvider, which reads the same
/// Copernicus tiles the same way.
struct CogHeader: Sendable, Equatable {
    let width: Int
    let height: Int
    let blockWidth: Int
    let blockHeight: Int
    let blockOffsets: [UInt64]
    let blockLengths: [UInt64]
    /// The north-west corner of the grid, and the size of one pixel.
    let originLat: Double
    let originLon: Double
    let pixelLat: Double
    let pixelLon: Double

    /// Blocks across one row of the grid.
    var blocksAcross: Int { (width + blockWidth - 1) / blockWidth }

    private enum Tag {
        static let imageWidth = 256
        static let imageLength = 257
        static let bitsPerSample = 258
        static let compression = 259
        static let predictor = 317
        static let tileWidth = 322
        static let tileLength = 323
        static let tileOffsets = 324
        static let tileByteCounts = 325
        static let sampleFormat = 339
        static let pixelScale = 33550
        static let tiePoint = 33922
    }

    /// The header from the first bytes of the file, or nil if they are not a
    /// tile this reader can decode.
    static func parse(_ bytes: [UInt8]) -> CogHeader? {
        guard bytes.count >= 8 else { return nil }
        let little: Bool
        switch (bytes[0], bytes[1]) {
        case (0x49, 0x49): little = true // "II"
        case (0x4D, 0x4D): little = false // "MM"
        default: return nil
        }
        let read = ByteReader(bytes: bytes, little: little)
        // BigTIFF (43) lays its entries out differently; Copernicus is classic.
        guard read.u16(2) == 42 else { return nil }

        let ifd = Int(read.u32(4))
        guard ifd + 2 <= bytes.count else { return nil }
        let entries = Int(read.u16(ifd))
        var values: [Int: [UInt64]] = [:]
        var doubles: [Int: [Double]] = [:]

        for i in 0..<entries {
            let entry = ifd + 2 + i * 12
            guard entry + 12 <= bytes.count else { return nil }
            let tag = Int(read.u16(entry))
            let type = read.u16(entry + 2)
            let count = Int(read.u32(entry + 4))
            let unit: Int
            switch type {
            case 1, 2, 6, 7: unit = 1
            case 3, 8: unit = 2
            case 4, 9, 11: unit = 4
            case 5, 10, 12: unit = 8
            default: continue
            }
            let size = unit * count
            let at = size <= 4 ? entry + 8 : Int(read.u32(entry + 8))
            // A tag pointing past what was fetched means the header runs
            // longer than assumed, not that the file is broken: skip that tag.
            guard count > 0, at >= 0, at + size <= bytes.count else { continue }
            switch type {
            case 12: doubles[tag] = (0..<count).map { read.f64(at + $0 * 8) }
            case 3: values[tag] = (0..<count).map { UInt64(read.u16(at + $0 * 2)) }
            case 4: values[tag] = (0..<count).map { UInt64(read.u32(at + $0 * 4)) }
            default: break
            }
        }

        guard let width = values[Tag.imageWidth]?.first.map(Int.init),
              let height = values[Tag.imageLength]?.first.map(Int.init),
              let blockWidth = values[Tag.tileWidth]?.first.map(Int.init),
              let blockHeight = values[Tag.tileLength]?.first.map(Int.init),
              let offsets = values[Tag.tileOffsets],
              let lengths = values[Tag.tileByteCounts],
              let scale = doubles[Tag.pixelScale],
              let tie = doubles[Tag.tiePoint],
              offsets.count == lengths.count, scale.count >= 2, tie.count >= 5,
              width > 0, height > 0, blockWidth > 0, blockHeight > 0
        else { return nil }

        // Anything but deflated 32-bit floats with the floating-point
        // predictor would need another decoder: refuse it rather than draw
        // noise.
        let compression = values[Tag.compression]?.first ?? 1
        let bits = values[Tag.bitsPerSample]?.first ?? 0
        let format = values[Tag.sampleFormat]?.first ?? 1
        let predictor = values[Tag.predictor]?.first ?? 1
        guard compression == 8 || compression == 32946,
              bits == 32, format == 3, predictor == 3
        else { return nil }

        let pixelLon = abs(scale[0])
        let pixelLat = abs(scale[1])
        return CogHeader(
            width: width,
            height: height,
            blockWidth: blockWidth,
            blockHeight: blockHeight,
            blockOffsets: offsets,
            blockLengths: lengths,
            originLat: tie[4] + tie[1] * pixelLat,
            originLon: tie[3] - tie[0] * pixelLon,
            pixelLat: pixelLat,
            pixelLon: pixelLon
        )
    }
}

/// One block of pixels, decoded.
enum CogBlock {
    /// The block's heights, row by row, from its bytes as stored: a zlib
    /// stream of floats run through TIFF's floating-point predictor. Nil if
    /// the bytes do not decode to exactly one block.
    static func decode(_ compressed: [UInt8], width: Int, height: Int) -> [Float]? {
        let expected = width * height * 4
        guard var raw = inflate(compressed, expected: expected) else { return nil }
        undoFloatPredictor(&raw, width: width, height: height)
        return raw.withUnsafeBytes { buffer in
            (0..<(width * height)).map { index in
                Float(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)))
            }
        }
    }

    /// Deflate as TIFF stores it: a zlib stream, whose two-byte header the
    /// Compression framework does not want -- it reads bare DEFLATE.
    static func inflate(_ stream: [UInt8], expected: Int) -> [UInt8]? {
        guard stream.count > 2,
              stream[0] & 0x0F == 8, // deflate
              (Int(stream[0]) << 8 | Int(stream[1])) % 31 == 0, // header checksum
              stream[1] & 0x20 == 0 // no preset dictionary
        else { return nil }
        var out = [UInt8](repeating: 0, count: expected)
        let written = stream.withUnsafeBufferPointer { source in
            out.withUnsafeMutableBufferPointer { destination in
                compression_decode_buffer(
                    destination.baseAddress!, expected,
                    source.baseAddress! + 2, source.count - 2,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        return written == expected ? out : nil
    }

    /// Undoes TIFF predictor 3, which the Copernicus tiles use. Each row holds
    /// byte-wise differences, and is split into planes: every float's most
    /// significant byte first, then every second byte, and so on. Deflate
    /// compresses that far better than raw floats, because neighbouring
    /// ground heights share their high bytes and so difference to zero.
    static func undoFloatPredictor(_ bytes: inout [UInt8], width: Int, height: Int) {
        let rowBytes = width * 4
        var scratch = [UInt8](repeating: 0, count: rowBytes)
        for row in 0..<height {
            let base = row * rowBytes
            var running = bytes[base]
            for i in 1..<rowBytes {
                running = bytes[base + i] &+ running
                bytes[base + i] = running
            }
            for i in 0..<rowBytes {
                scratch[i] = bytes[base + i]
            }
            for column in 0..<width {
                let out = base + column * 4
                bytes[out + 3] = scratch[column]
                bytes[out + 2] = scratch[width + column]
                bytes[out + 1] = scratch[2 * width + column]
                bytes[out] = scratch[3 * width + column]
            }
        }
    }
}

/// Reads fixed-width values from a TIFF in its own byte order.
private struct ByteReader {
    let bytes: [UInt8]
    let little: Bool

    func u16(_ at: Int) -> UInt16 {
        let a = UInt16(bytes[at]), b = UInt16(bytes[at + 1])
        return little ? a | b << 8 : a << 8 | b
    }

    func u32(_ at: Int) -> UInt32 {
        let a = UInt32(u16(at)), b = UInt32(u16(at + 2))
        return little ? a | b << 16 : a << 16 | b
    }

    func f64(_ at: Int) -> Double {
        let a = UInt64(u32(at)), b = UInt64(u32(at + 4))
        return Double(bitPattern: little ? a | b << 32 : a << 32 | b)
    }
}
