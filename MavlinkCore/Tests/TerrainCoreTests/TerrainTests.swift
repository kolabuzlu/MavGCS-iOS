import Compression
import Foundation
import Testing
@testable import TerrainCore

/// The terrain reader against a tile made here, in the same shape as a
/// Copernicus one: little-endian, deflated floats behind predictor 3, cut
/// into blocks. Small enough to reason about, 8 by 8 pixels in 4 by 4
/// blocks, spread over a whole degree.
struct DemTests {
    static let key = "Copernicus_DSM_COG_10_N40_00_E030_00_DEM"
    static let size = 8
    static let blockSize = 4
    static let pixel = 1.0 / 8

    /// A height for every pixel that says where it came from.
    static func height(_ column: Int, _ row: Int) -> Float {
        100 + Float(column) * 10 + Float(row)
    }

    /// Latitude and longitude of a pixel's centre. The tie point sits on
    /// pixel (0, 0) at 41 N, 30 E.
    static func place(_ column: Double, _ row: Double) -> (lat: Double, lon: Double) {
        (41 - row * pixel, 30 + column * pixel)
    }

    @Test func namesTilesAfterTheCellTheyCover() {
        #expect(CopernicusDEM.tileKey(lat: 40.5, lon: 30.5) == Self.key)
        #expect(CopernicusDEM.tileKey(lat: 51.6, lon: 7.0) == "Copernicus_DSM_COG_10_N51_00_E007_00_DEM")
        #expect(CopernicusDEM.tileKey(lat: -0.5, lon: -0.5) == "Copernicus_DSM_COG_10_S01_00_W001_00_DEM")
        #expect(CopernicusDEM.tileKey(lat: -33.9, lon: 151.2) == "Copernicus_DSM_COG_10_S34_00_E151_00_DEM")
    }

    @Test func readsTheHeader() throws {
        let header = try #require(CogHeader.parse(Self.tiff()))
        #expect(header.width == 8 && header.height == 8)
        #expect(header.blockWidth == 4 && header.blockHeight == 4)
        #expect(header.blocksAcross == 2)
        #expect(header.blockOffsets.count == 4)
        #expect(header.originLat == 41 && header.originLon == 30)
        #expect(header.pixelLat == Self.pixel && header.pixelLon == Self.pixel)
    }

    @Test func refusesWhatItCannotDecode() {
        var tiff = Self.tiff()
        #expect(CogHeader.parse(Array(tiff.prefix(6))) == nil)
        tiff[2] = 43 // BigTIFF
        #expect(CogHeader.parse(tiff) == nil)
        #expect(CogHeader.parse(Self.tiff(predictor: 2)) == nil, "integer predictor")
        #expect(CogHeader.parse(Self.tiff(compression: 5)) == nil, "LZW")
    }

    @Test func undoesThePredictor() {
        let values: [Float] = [0, -1.5, 812.25, 812.5, .greatestFiniteMagnitude, 3, 4, 5]
        var bytes = Self.predicted(values, width: 4)
        CogBlock.undoFloatPredictor(&bytes, width: 4, height: 2)
        let back = stride(from: 0, to: bytes.count, by: 4).map { i in
            Float(bitPattern: UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24)
        }
        #expect(back == values)
    }

    @Test func refusesABlockOfTheWrongSize() {
        let block = Self.compressedBlock(column: 0, row: 0)
        #expect(CogBlock.decode(block, width: 4, height: 4) != nil)
        #expect(CogBlock.decode(block, width: 4, height: 5) == nil)
        #expect(CogBlock.decode(Array(block.dropFirst(2)), width: 4, height: 4) == nil, "no zlib header")
    }

    @Test func readsHeightsAtPixelCentres() async {
        let dem = CopernicusDEM(source: Self.source(), disk: TerrainDiskCache(directory: nil))
        for row in 1..<Self.size {
            for column in 0..<Self.size {
                let at = Self.place(Double(column), Double(row))
                let height = await dem.elevation(lat: at.lat, lon: at.lon)
                #expect(height == Self.height(column, row), "pixel \(column), \(row)")
            }
        }
    }

    @Test func interpolatesBetweenThem() async throws {
        let dem = CopernicusDEM(source: Self.source(), disk: TerrainDiskCache(directory: nil))
        let at = Self.place(1.5, 1.25)
        let height = try #require(await dem.elevation(lat: at.lat, lon: at.lon))
        let expected = Self.height(1, 1) * 0.375 + Self.height(2, 1) * 0.375
            + Self.height(1, 2) * 0.125 + Self.height(2, 2) * 0.125
        #expect(abs(height - expected) < 0.001)
    }

    /// Across a block seam the neighbour is taken from the same block, the
    /// edge pixel repeated -- not from column zero of that block, 30 km away
    /// on a real tile, which is how the Android radar once drew a hot cell.
    @Test func holdsTheEdgeAtABlockSeam() async throws {
        let dem = CopernicusDEM(source: Self.source(), disk: TerrainDiskCache(directory: nil))
        let across = Self.place(3.5, 2)
        #expect(await dem.elevation(lat: across.lat, lon: across.lon) == Self.height(3, 2))
        let down = Self.place(2, 3.5)
        #expect(await dem.elevation(lat: down.lat, lon: down.lon) == Self.height(2, 3))
    }

    /// Tiles are chosen by the floor of the coordinate, so each one owns its
    /// whole degree -- including the last pixel's width past its last centre.
    @Test func coversTheWholeDegree() async {
        let dem = CopernicusDEM(source: Self.source(), disk: TerrainDiskCache(directory: nil))
        #expect(await dem.elevation(lat: 40.0001, lon: 30.9999) == Self.height(7, 7))
    }

    @Test func fetchesEachPieceOnce() async {
        let log = FetchLog()
        let dem = CopernicusDEM(source: Self.source(log), disk: TerrainDiskCache(directory: nil))
        for row in 1..<Self.size {
            for column in 0..<Self.size {
                let at = Self.place(Double(column), Double(row))
                _ = await dem.elevation(lat: at.lat, lon: at.lon)
            }
        }
        // The header, then each of the four blocks, and nothing twice.
        #expect(log.count == 5)
        #expect(await dem.activity == .idle)
    }

    @Test func asksForAMissingTileOnce() async {
        let log = FetchLog()
        let dem = CopernicusDEM(source: Self.source(log), disk: TerrainDiskCache(directory: nil))
        #expect(await dem.elevation(lat: 10.5, lon: 10.5) == nil)
        #expect(await dem.elevation(lat: 10.6, lon: 10.6) == nil)
        #expect(log.count == 1)
    }

    /// A failure is not remembered for good -- a timeout says nothing about
    /// whether the tile exists -- but nor is it asked again at once, or a
    /// hung network would be asked by every cell of a fan in turn.
    @Test func waitsBeforeTryingAgainAfterAFailure() async {
        let log = FetchLog()
        let dem = CopernicusDEM(source: { _, _, _ in log.add(); return .failed }, disk: TerrainDiskCache(directory: nil))
        let fan = await dem.fan(lat: 40.5, lon: 30.5, headingDeg: 0, rangeM: 300)
        #expect(!fan.hasData)
        #expect(log.count == 1)
        #expect(await dem.activity == .retrying)

        let eager = CopernicusDEM(source: { _, _, _ in log.add(); return .failed }, disk: TerrainDiskCache(directory: nil), retryAfterS: 0)
        #expect(await eager.elevation(lat: 40.5, lon: 30.5) == nil)
        #expect(await eager.elevation(lat: 40.5, lon: 30.5) == nil)
        #expect(log.count == 3)
    }

    /// What was read once is there with no signal at all, in a later run.
    @Test func worksOfflineFromDisk() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let at = Self.place(5, 5)

        let online = CopernicusDEM(source: Self.source(), disk: TerrainDiskCache(directory: folder))
        #expect(await online.elevation(lat: at.lat, lon: at.lon) == Self.height(5, 5))

        let log = FetchLog()
        let offline = CopernicusDEM(source: { _, _, _ in log.add(); return .failed }, disk: TerrainDiskCache(directory: folder))
        #expect(await offline.elevation(lat: at.lat, lon: at.lon) == Self.height(5, 5))
        #expect(log.count == 0)

        // A block spoiled on disk is thrown away and fetched again, rather
        // than failing on the same bytes for good.
        let saved = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".blk") }
        #expect(saved.count == 1)
        try Data([1, 2, 3]).write(to: folder.appendingPathComponent(saved[0]))
        let refetch = CopernicusDEM(source: Self.source(), disk: TerrainDiskCache(directory: folder))
        #expect(await refetch.elevation(lat: at.lat, lon: at.lon) == nil, "the bad block is not believed")
        #expect(await refetch.elevation(lat: at.lat, lon: at.lon) == Self.height(5, 5))
    }

    @Test func samplesAFanAhead() async {
        let dem = CopernicusDEM(source: Self.source(), disk: TerrainDiskCache(directory: nil))
        let fan = await dem.fan(lat: 40.5, lon: 30.5, headingDeg: 90, rangeM: 900)
        #expect(fan.elevations.count == TerrainSampler.angCells * TerrainSampler.radCells)
        #expect(fan.hasData)
        #expect(!fan.elevations.contains { $0.isNaN })

        // Out to sea: nothing, but a fan all the same.
        let sea = await dem.fan(lat: 10.5, lon: 10.5, headingDeg: 0, rangeM: 300)
        #expect(!sea.hasData)
        #expect(sea == TerrainFan(elevations: sea.elevations, rangeM: 300), "NaN fans still compare equal")
    }

    // MARK: - A tile of our own

    /// A tile, whole, as it would sit in the bucket.
    static func tiff(compression: UInt16 = 8, predictor: UInt16 = 3) -> [UInt8] {
        let blocks = (0..<2).flatMap { row in (0..<2).map { column in compressedBlock(column: column, row: row) } }

        var out: [UInt8] = [0x49, 0x49]
        out += le16(42) + le32(8)
        let entries: [(tag: UInt16, type: UInt16, values: [UInt64])] = [
            (256, 3, [UInt64(size)]),
            (257, 3, [UInt64(size)]),
            (258, 3, [32]),
            (259, 3, [UInt64(compression)]),
            (317, 3, [UInt64(predictor)]),
            (322, 3, [UInt64(blockSize)]),
            (323, 3, [UInt64(blockSize)]),
            (324, 4, []), // offsets, filled in below
            (325, 4, blocks.map { UInt64($0.count) }),
            (339, 3, [3]),
            (33550, 12, []),
            (33922, 12, []),
        ]
        let scale = [pixel, pixel, 0]
        let tie: [Double] = [0, 0, 0, 30, 41, 0]

        // Everything that does not fit in an entry follows the directory.
        let directoryEnd = 8 + 2 + entries.count * 12 + 4
        let offsetsAt = directoryEnd
        let countsAt = offsetsAt + 16
        let scaleAt = countsAt + 16
        let tieAt = scaleAt + 24
        var blockAt = tieAt + 48
        var offsets: [UInt32] = []
        for block in blocks {
            offsets.append(UInt32(blockAt))
            blockAt += block.count
        }

        out += le16(UInt16(entries.count))
        for entry in entries {
            out += le16(entry.tag) + le16(entry.type)
            switch entry.tag {
            case 324: out += le32(4) + le32(UInt32(offsetsAt))
            case 325: out += le32(4) + le32(UInt32(countsAt))
            case 33550: out += le32(3) + le32(UInt32(scaleAt))
            case 33922: out += le32(6) + le32(UInt32(tieAt))
            default: out += le32(1) + le16(UInt16(entry.values[0])) + le16(0)
            }
        }
        out += le32(0)
        out += offsets.flatMap(le32)
        out += blocks.flatMap { le32(UInt32($0.count)) }
        out += scale.flatMap { le64($0.bitPattern) }
        out += tie.flatMap { le64($0.bitPattern) }
        out += blocks.flatMap { $0 }
        return out
    }

    /// One block's pixels, predicted and deflated behind a zlib header.
    static func compressedBlock(column: Int, row: Int) -> [UInt8] {
        var values: [Float] = []
        for y in 0..<blockSize {
            for x in 0..<blockSize {
                values.append(height(column * blockSize + x, row * blockSize + y))
            }
        }
        let raw = predicted(values, width: blockSize)
        var deflated = [UInt8](repeating: 0, count: raw.count + 256)
        let written = compression_encode_buffer(&deflated, deflated.count, raw, raw.count, nil, COMPRESSION_ZLIB)
        return [0x78, 0x9C] + deflated.prefix(written)
    }

    /// TIFF predictor 3, forwards: each row split into byte planes, most
    /// significant first, then differenced byte by byte.
    static func predicted(_ values: [Float], width: Int) -> [UInt8] {
        let rowBytes = width * 4
        var out: [UInt8] = []
        for start in stride(from: 0, to: values.count, by: width) {
            var row = [UInt8](repeating: 0, count: rowBytes)
            for (column, value) in values[start..<start + width].enumerated() {
                let bits = value.bitPattern
                for plane in 0..<4 {
                    row[plane * width + column] = UInt8(truncatingIfNeeded: bits >> (8 * (3 - plane)))
                }
            }
            for i in stride(from: rowBytes - 1, through: 1, by: -1) {
                row[i] = row[i] &- row[i - 1]
            }
            out += row
        }
        return out
    }

    /// Serves the tile above by byte range, and nothing else.
    static func source(_ log: FetchLog? = nil) -> CopernicusDEM.Source {
        let tiff = tiff()
        return { key, from, to in
            log?.add()
            guard key == DemTests.key else { return .missing }
            let end = min(Int(to), tiff.count - 1)
            return .got(Array(tiff[Int(from)...end]))
        }
    }

    static func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
    static func le32(_ value: UInt32) -> [UInt8] { le16(UInt16(value & 0xFFFF)) + le16(UInt16(value >> 16)) }
    static func le64(_ value: UInt64) -> [UInt8] { le32(UInt32(value & 0xFFFF_FFFF)) + le32(UInt32(value >> 32)) }
}

final class FetchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func add() {
        lock.lock()
        calls += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

/// The fan's shape and the rules for retaking it, against the desktop's.
struct SamplerTests {
    @Test func picksARangeFromSpeed() {
        #expect(TerrainSampler.nextRange(current: 300, speedMs: 0) == 300)
        #expect(TerrainSampler.nextRange(current: 300, speedMs: 2.5) == 300, "300 m is 2 min at 2.5 m/s")
        #expect(TerrainSampler.nextRange(current: 300, speedMs: 10) == 1800)
        #expect(TerrainSampler.nextRange(current: 300, speedMs: 40) == 3600, "the last step is as far as it goes")
    }

    @Test func stepsDownOnlyWellClearOfTheBoundary() {
        // 7 m/s wants 900 m, but 840 m is not yet under 70% of the step below.
        #expect(TerrainSampler.nextRange(current: 1800, speedMs: 7) == 1800)
        #expect(TerrainSampler.nextRange(current: 1800, speedMs: 5) == 900)
        #expect(TerrainSampler.nextRange(current: 900, speedMs: 1) == 300)
        #expect(TerrainSampler.nextRange(current: 900, speedMs: 2) == 900)
    }

    @Test func measuresTurnsTheShortWayRound() {
        #expect(TerrainSampler.angleDiff(350, 10) == 20)
        #expect(TerrainSampler.angleDiff(10, 350) == 20)
        #expect(TerrainSampler.angleDiff(0, 180) == 180)
        #expect(TerrainSampler.angleDiff(90, 90) == 0)
    }

    @Test func goesWhereItIsPointed() {
        let east = TerrainSampler.destination(lat: 40.5, lon: 30.5, bearingDeg: 90, distanceM: 1000)
        #expect(abs(east.lat - 40.5) < 1e-4 && east.lon > 30.5)
        let back = TerrainSampler.distanceM(lat1: 40.5, lon1: 30.5, lat2: east.lat, lon2: east.lon)
        #expect(abs(back - 1000) < 0.01)
    }
}

/// Colour by clearance, as the desktop's trColorFor has it.
struct ClearanceTests {
    private func fraction(_ elevation: Float, alt: Float = 500, distance: Double = 1000, slope: Double = 0, predictive: Bool = false) -> Float? {
        TerrainClearance.fraction(elevation: elevation, distanceM: distance, altMslM: alt, slope: slope, predictive: predictive, scaleM: 120)
    }

    @Test func leavesSafeGroundUnpainted() {
        #expect(fraction(380) == nil, "exactly the scale below")
        #expect(fraction(0) == nil)
        #expect(fraction(.nan) == nil)
    }

    @Test func rampsFromRedToGreen() {
        #expect(fraction(500) == 0)
        #expect(fraction(700) == 0, "ground above the aircraft is simply red")
        #expect(fraction(440) == 0.5)
        #expect(fraction(381)! > 0.99)
    }

    @Test func predictsFromTheGradientFlown() {
        // Descending one in ten: a kilometre on, 100 m lower, level with the
        // ground there.
        #expect(fraction(400, slope: -0.1, predictive: true) == 0)
        #expect(fraction(400, slope: -0.1, predictive: false)! > 0.8)
        // Climbing one in ten clears ground that flying level would not.
        #expect(fraction(450, slope: 0.1, predictive: true) == nil)
        #expect(fraction(450, slope: 0.1, predictive: false) != nil)
    }

    @Test func slopeIsClimbOverSpeed() {
        #expect(TerrainClearance.slope(climbSamples: [2, 2, 2], groundSpeedMs: 20) == 0.1)
        #expect(TerrainClearance.slope(climbSamples: [4, 0], groundSpeedMs: 20) == 0.1)
        #expect(TerrainClearance.slope(climbSamples: [5], groundSpeedMs: 2) == 0, "hovering has no gradient")
        #expect(TerrainClearance.slope(climbSamples: [], groundSpeedMs: 20) == 0)
    }
}
