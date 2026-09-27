import Foundation

/// Terrain elevation from the Copernicus GLO-30 DEM: the same free source the
/// desktop and the Android build use. No key and no sign-up; the tiles sit in
/// a public S3 bucket, one GeoTIFF per one-degree cell.
///
/// The desktop downloads a whole tile, 36 MB, and decodes it to a 3600 by
/// 3600 grid. That is not something to do on a phone, and not necessary: the
/// files are cloud-optimised, their pixels stored as 1024 by 1024 blocks that
/// can be fetched one at a time with a range request. A radar fan reaches
/// 3.6 km at most, about 117 pixels, so one block -- four where the fan
/// crosses a boundary -- covers everything drawn. This is the Android build's
/// reader, ported.
public actor CopernicusDEM {
    public static let shared = CopernicusDEM()

    private static let base = "https://copernicus-dem-30m.s3.amazonaws.com"
    /// Enough for the first directory and the tag arrays hanging off it.
    private static let headerBytes: UInt64 = 65_536
    /// Decoded blocks held in memory, 4 MB each. A fan spans at most 2 by 2
    /// blocks, so this holds one fan's worth without thrashing.
    private static let maxCachedBlocks = 4

    /// Tiles whose header has been read. A nil value marks a cell the bucket
    /// does not have -- ocean, mostly -- so it is asked for once and not
    /// again. A transient failure is not recorded, and so is retried.
    private var headers: [String: CogHeader?] = [:]
    private var blocks: [String: [Float]] = [:]
    private var blockOrder: [String] = []
    /// Pieces whose last fetch failed in a way that might not last, and when
    /// they are worth asking for again. Without it a network that hangs
    /// would be asked for the same header by every cell of a fan in turn, 20
    /// seconds apiece. The desktop's TILE_RETRY_S.
    private var retryAt: [String: Date] = [:]
    private let retryAfterS: TimeInterval
    private let disk: TerrainDiskCache
    private let source: Source

    /// A download is in flight.
    private var downloading = false

    /// What the radar should say while it has nothing to draw. "No data" for
    /// the whole of a download reads as a broken program rather than a busy
    /// one, as the desktop found.
    public var activity: TerrainActivity {
        if downloading { return .downloading }
        let now = Date()
        return retryAt.values.contains { $0 > now } ? .retrying : .idle
    }

    /// Where the bytes come from: a tile's name and an inclusive byte range.
    /// The network unless a test says otherwise.
    public typealias Source = @Sendable (_ key: String, _ from: UInt64, _ to: UInt64) async -> RangeResult

    public init(source: Source? = nil, disk: TerrainDiskCache = TerrainDiskCache(), retryAfterS: TimeInterval = 15) {
        self.disk = disk
        self.retryAfterS = retryAfterS
        self.source = source ?? { key, from, to in
            await RangeFetcher.shared.fetch(CopernicusDEM.url(for: key), from: from, to: to)
        }
    }

    /// What is saved on disk, for the Settings readout.
    public func cacheStats() -> TerrainCacheStats {
        disk.stats()
    }

    /// A new size, remembered, and the store trimmed to it now rather than
    /// at the next download.
    public func setCacheLimit(megabytes: Int) {
        TerrainDiskCache.limitMb = megabytes
        disk.enforceLimit()
    }

    /// Everything saved deleted, and whatever was read from it forgotten, so
    /// the next look at the ground asks the network again, as the Android
    /// build's clear does.
    public func clearCache() {
        disk.clear()
        headers = [:]
        blocks = [:]
        blockOrder = []
    }

    /// Terrain height in metres above the sea at a point, or nil where there
    /// is none to be had. May wait on the network.
    public func elevation(lat: Double, lon: Double) async -> Float? {
        let key = Self.tileKey(lat: lat, lon: lon)
        guard let header = await header(for: key) else { return nil }

        let column = (lon - header.originLon) / header.pixelLon
        let row = (header.originLat - lat) / header.pixelLat
        // The extent is the cell the tile covers, not its last pixel centre:
        // a 3600-pixel grid at one arcsecond spans the full degree, so its
        // furthest centre sits a pixel short of the far edge. Rejecting past
        // that left a 30 m strip of every boundary reading as no data.
        guard column >= 0, row >= 0, column <= Double(header.width), row <= Double(header.height) else {
            return nil
        }
        let c0 = min(max(Int(column), 0), header.width - 1)
        let r0 = min(max(Int(row), 0), header.height - 1)
        let c1 = min(c0 + 1, header.width - 1)
        let r1 = min(r0 + 1, header.height - 1)

        // Interpolating across a block boundary would need two blocks for one
        // reading, so the neighbour is clamped into this one instead. It
        // costs at most half a pixel, 15 m on the ground, on the seam itself.
        let blockX = c0 / header.blockWidth
        let blockY = r0 / header.blockHeight
        guard let pixels = await block(key, header, blockX, blockY) else { return nil }

        // A pixel is read from the block it was fetched in, clamped to that
        // block's own extent. Worked out from the pixel instead, a neighbour
        // one past the block's last column belongs to the next block, and the
        // read wraps back to column zero -- a pixel some 30 km away, which the
        // Android radar once drew as a stray hot cell.
        func at(_ c: Int, _ r: Int) -> Float {
            let x = min(max(c - blockX * header.blockWidth, 0), header.blockWidth - 1)
            let y = min(max(r - blockY * header.blockHeight, 0), header.blockHeight - 1)
            return pixels[y * header.blockWidth + x]
        }
        let fc = Float(min(max(column - Double(c0), 0), 1))
        let fr = Float(min(max(row - Double(r0), 0), 1))
        let top = at(c0, r0) * (1 - fc) + at(c1, r0) * fc
        let bottom = at(c0, r1) * (1 - fc) + at(c1, r1) * fc
        return top * (1 - fr) + bottom * fr
    }

    /// Heights over the fan ahead of a point, at every cell centre. See
    /// TerrainSampler for the shape. May wait on the network.
    public func fan(lat: Double, lon: Double, headingDeg: Double, rangeM: Double) async -> TerrainFan {
        let cells = TerrainSampler.angCells * TerrainSampler.radCells
        var elevations = [Float](repeating: .nan, count: cells)
        for a in 0..<TerrainSampler.angCells {
            let fraction = (Double(a) + 0.5) / Double(TerrainSampler.angCells)
            let bearing = headingDeg - TerrainSampler.halfAngleDeg + 2 * TerrainSampler.halfAngleDeg * fraction
            for b in 0..<TerrainSampler.radCells {
                let distance = rangeM * (Double(b) + 0.5) / Double(TerrainSampler.radCells)
                let point = TerrainSampler.destination(lat: lat, lon: lon, bearingDeg: bearing, distanceM: distance)
                elevations[a * TerrainSampler.radCells + b] = await elevation(lat: point.lat, lon: point.lon) ?? .nan
            }
        }
        return TerrainFan(elevations: elevations, rangeM: rangeM)
    }

    /// The ground along the track, as a side-on slice for the Live AGL
    /// panel: heights above the sea, evenly spaced from `behindM` astern to
    /// `aheadM` ahead, NaN where no tile has arrived. May wait on the network.
    ///
    /// Along the course being made good rather than where the nose points:
    /// over a couple of kilometres a crosswind puts those far enough apart to
    /// matter, and it is the ground actually flown over that counts. The
    /// aircraft's own height is not taken off here, so a fresh altitude can
    /// redraw the panel without the ground being read again.
    public func trackProfile(
        lat: Double,
        lon: Double,
        headingDeg: Double,
        behindM: Double,
        aheadM: Double,
        samples: Int = TerrainSampler.profileSamples
    ) async -> [Float] {
        let span = behindM + aheadM
        guard samples >= 2, span > 0 else { return [] }
        var heights: [Float] = []
        heights.reserveCapacity(samples)
        for i in 0..<samples {
            let distance = -behindM + span * Double(i) / Double(samples - 1)
            let point = distance == 0
                ? (lat: lat, lon: lon)
                : TerrainSampler.destination(lat: lat, lon: lon, bearingDeg: headingDeg, distanceM: distance)
            heights.append(await elevation(lat: point.lat, lon: point.lon) ?? .nan)
        }
        return heights
    }

    /// The Copernicus tile name for the one-degree cell holding a point.
    static func tileKey(lat: Double, lon: Double) -> String {
        let latIndex = Int(floor(lat))
        let lonIndex = Int(floor(lon))
        let north = (latIndex >= 0 ? "N" : "S") + String(format: "%02d", abs(latIndex))
        let east = (lonIndex >= 0 ? "E" : "W") + String(format: "%03d", abs(lonIndex))
        return "Copernicus_DSM_COG_10_\(north)_00_\(east)_00_DEM"
    }

    static func url(for key: String) -> URL {
        URL(string: "\(base)/\(key)/\(key).tif")!
    }

    private func header(for key: String) async -> CogHeader? {
        if let known = headers[key] { return known }
        let name = key + ".hdr"
        // A saved header that will not parse is worse than none: it would pin
        // the tile as unreadable for as long as it sat there.
        if let saved = disk.read(name), let parsed = CogHeader.parse(saved) {
            headers[key] = parsed
            return parsed
        }
        switch await download(name, key, from: 0, to: Self.headerBytes - 1) {
        case .missing:
            headers[key] = .some(nil)
            return nil
        case .failed:
            return nil
        case .got(let bytes):
            guard let parsed = CogHeader.parse(bytes) else { return nil }
            disk.write(name, bytes)
            headers[key] = parsed
            return parsed
        }
    }

    private func block(_ key: String, _ header: CogHeader, _ blockX: Int, _ blockY: Int) async -> [Float]? {
        let index = blockY * header.blocksAcross + blockX
        guard index >= 0, index < header.blockOffsets.count else { return nil }
        let cacheKey = "\(key)/\(index)"
        if let held = blocks[cacheKey] {
            touch(cacheKey)
            return held
        }

        let name = "\(key).\(index).blk"
        let saved = disk.read(name)
        var compressed = saved
        if compressed == nil {
            let offset = header.blockOffsets[index]
            let length = header.blockLengths[index]
            guard length > 0 else { return nil }
            guard case .got(let bytes) = await download(name, key, from: offset, to: offset + length - 1) else { return nil }
            compressed = bytes
        }
        guard let compressed,
              let values = CogBlock.decode(compressed, width: header.blockWidth, height: header.blockHeight)
        else {
            // A saved block that will not decode is one to be rid of, so the
            // next look fetches rather than failing on the same bytes again.
            if saved != nil { disk.remove(name) }
            return nil
        }
        if saved == nil { disk.write(name, compressed) }
        blocks[cacheKey] = values
        touch(cacheKey)
        return values
    }

    private func touch(_ key: String) {
        blockOrder.removeAll { $0 == key }
        blockOrder.append(key)
        while blockOrder.count > Self.maxCachedBlocks {
            blocks[blockOrder.removeFirst()] = nil
        }
    }

    /// One piece of a tile, named as it is saved, unless it failed a moment
    /// ago -- which is reported as another failure without asking again.
    private func download(_ piece: String, _ key: String, from: UInt64, to: UInt64) async -> RangeResult {
        if let at = retryAt[piece] {
            guard Date() >= at else { return .failed }
            retryAt[piece] = nil
        }
        downloading = true
        let result = await source(key, from, to)
        downloading = false
        if case .failed = result {
            retryAt[piece] = Date().addingTimeInterval(retryAfterS)
        }
        return result
    }
}

/// What the terrain reader is busy with.
public enum TerrainActivity: Sendable {
    case idle
    case downloading
    /// A fetch failed, and will be tried again shortly.
    case retrying
}

/// What a range request came back with.
public enum RangeResult: Sendable {
    case got([UInt8])
    /// The file is not there: a cell the DEM does not cover.
    case missing
    case failed
}

/// Byte ranges of a remote file, and nothing more.
///
/// A delegate-driven task rather than a plain data request, because the
/// response has to be judged before any of its body arrives: a server that
/// ignored the range would answer 200 with the whole 36 MB file, and the
/// only right thing to do with that is not download it.
final class RangeFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = RangeFetcher()

    private let lock = NSLock()
    private var pending: [Int: (data: Data, result: RangeResult?, continuation: CheckedContinuation<RangeResult, Never>)] = [:]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func fetch(_ url: URL, from: UInt64, to: UInt64) async -> RangeResult {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
        return await withCheckedContinuation { continuation in
            let task = session.dataTask(with: request)
            lock.lock()
            pending[task.taskIdentifier] = (Data(), nil, continuation)
            lock.unlock()
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        lock.lock()
        switch status {
        case 206:
            lock.unlock()
            completionHandler(.allow)
            return
        case 403, 404:
            pending[dataTask.taskIdentifier]?.result = .missing
        default:
            pending[dataTask.taskIdentifier]?.result = .failed
        }
        lock.unlock()
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        pending[dataTask.taskIdentifier]?.data.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let entry = pending.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let entry else { return }
        if let result = entry.result {
            entry.continuation.resume(returning: result)
        } else if error == nil {
            entry.continuation.resume(returning: .got([UInt8](entry.data)))
        } else {
            entry.continuation.resume(returning: .failed)
        }
    }
}

/// What the terrain store holds, for the Settings readout.
public struct TerrainCacheStats: Sendable, Equatable {
    public var files = 0
    public var usedBytes: Int64 = 0
    /// Zero when saving is off: what is there is still used, nothing joins it.
    public var limitBytes: Int64 = 0

    public init(files: Int = 0, usedBytes: Int64 = 0, limitBytes: Int64 = 0) {
        self.files = files
        self.usedBytes = usedBytes
        self.limitBytes = limitBytes
    }
}

/// Elevation data kept on disk, so the radar works with no signal and a
/// restart does not fetch again what was already read.
///
/// The two pieces the reader fetches -- a tile's header, and each block of
/// pixels -- stored exactly as they arrived. In Application Support rather
/// than Caches, as the Android build keeps it out of its cache directory:
/// this is an offline map collected by flying, and iOS empties Caches
/// whenever it wants the space. Held to the size chosen in Settings, and
/// trimmed oldest first to 90% of that when over.
public struct TerrainDiskCache: Sendable {
    /// The sizes offered, the Android build's. Smaller steps than the
    /// desktop's on purpose: the desktop stores whole 40 MB tiles, while this
    /// keeps only the blocks it actually reads, about 2.4 MB each and some
    /// 30 km square, so 500 MB here covers far more ground. Zero is No Cache.
    public static let limitsMb = [0, 100, 250, 500, 1024, 2048]
    public static let defaultLimitMb = 500
    /// Named as the desktop and Android name it, so the three stay
    /// recognisably the same setting.
    static let limitKey = "terrain_cache_mb"
    static let trimFraction = 0.9

    /// The chosen size in megabytes, remembered across runs. Zero keeps what
    /// is already saved and saves nothing new; only a clear removes it.
    public static var limitMb: Int {
        get { limitMb(in: .standard) }
        set { setLimitMb(newValue, in: .standard) }
    }

    static func limitMb(in defaults: UserDefaults) -> Int {
        defaults.object(forKey: limitKey) == nil ? defaultLimitMb : max(0, defaults.integer(forKey: limitKey))
    }

    static func setLimitMb(_ megabytes: Int, in defaults: UserDefaults) {
        defaults.set(max(0, megabytes), forKey: limitKey)
    }

    private let directory: URL?
    private let limitBytes: @Sendable () -> Int64

    /// The app's own store, or another folder for a test; nil keeps nothing.
    /// The limit is the one chosen in Settings unless a test gives its own.
    public init(
        directory: URL? = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Terrain", isDirectory: true),
        limitMb: (@Sendable () -> Int)? = nil
    ) {
        let limit = limitMb ?? { TerrainDiskCache.limitMb }
        limitBytes = { Int64(max(0, limit())) << 20 }
        guard var directory else {
            self.directory = nil
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // It can all be fetched again, so it has no business in a backup.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        self.directory = directory
    }

    func read(_ name: String) -> [UInt8]? {
        guard let directory, let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return [UInt8](data)
    }

    /// Written whole or not at all: a block is megabytes, and a file cut
    /// short by the app being killed would fail to decode from then on.
    /// Nothing is written while saving is off.
    func write(_ name: String, _ bytes: [UInt8]) {
        guard let directory, limitBytes() > 0 else { return }
        try? Data(bytes).write(to: directory.appendingPathComponent(name), options: .atomic)
        enforceLimit()
    }

    func remove(_ name: String) {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }

    /// Files held and bytes on disk. Reads the filesystem, so not for the
    /// main thread.
    public func stats() -> TerrainCacheStats {
        let files = savedFiles()
        return TerrainCacheStats(files: files.count, usedBytes: files.reduce(0) { $0 + $1.size }, limitBytes: limitBytes())
    }

    /// Every saved header and block deleted.
    public func clear() {
        for file in savedFiles() {
            try? FileManager.default.removeItem(at: file.url)
        }
    }

    /// Trimmed back under the limit, oldest first. Only when actually over,
    /// and then to 90%, so a store sitting on the boundary is not scanned
    /// again after every block written.
    public func enforceLimit() {
        let limit = limitBytes()
        guard limit > 0 else { return }
        let files = savedFiles()
        var total = files.reduce(0) { $0 + $1.size }
        guard total > limit else { return }
        let target = Int64(Double(limit) * Self.trimFraction)
        for file in files.sorted(by: { $0.date < $1.date }) where total > target {
            if (try? FileManager.default.removeItem(at: file.url)) != nil {
                total -= file.size
            }
        }
    }

    private func savedFiles() -> [(url: URL, size: Int64, date: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let directory,
              let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
        else { return [] }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
    }
}
