import Foundation
import Testing
@testable import TerrainCore

/// The terrain store held to the size chosen in Settings, as the Android
/// build holds its own.
struct TerrainCacheTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("TerrainCacheTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func age(_ name: String, in folder: URL, _ seconds: Double) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: seconds)],
            ofItemAtPath: folder.appendingPathComponent(name).path
        )
    }

    @Test func noCacheKeepsWhatIsThereAndSavesNothingNew() {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        TerrainDiskCache(directory: folder, limitMb: { 1 }).write("a", [UInt8](repeating: 1, count: 1000))

        let off = TerrainDiskCache(directory: folder, limitMb: { 0 })
        off.write("b", [UInt8](repeating: 2, count: 1000))
        #expect(off.read("a") != nil, "what was saved is still used")
        #expect(off.read("b") == nil, "nothing new joins it")
        #expect(off.stats() == TerrainCacheStats(files: 1, usedBytes: 1000, limitBytes: 0))
    }

    @Test func trimsTheOldestToNinetyPercentWhenOver() throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = TerrainDiskCache(directory: folder, limitMb: { 1 })
        for (index, name) in ["a", "b", "c"].enumerated() {
            cache.write(name, [UInt8](repeating: 0, count: 300_000))
            try age(name, in: folder, 1000 + Double(index))
        }
        #expect(cache.stats().files == 3, "900 kB is under 1 MB")

        // 1.2 MB is over: the oldest goes, which brings it under 90%.
        cache.write("d", [UInt8](repeating: 0, count: 300_000))
        #expect(cache.read("a") == nil)
        #expect(cache.read("b") != nil && cache.read("c") != nil && cache.read("d") != nil)
        #expect(cache.stats() == TerrainCacheStats(files: 3, usedBytes: 900_000, limitBytes: 1 << 20))
    }

    @Test func aSmallerSizeTrimsAtOnce() throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for (index, name) in ["a", "b", "c", "d"].enumerated() {
            TerrainDiskCache(directory: folder, limitMb: { 5 }).write(name, [UInt8](repeating: 0, count: 400_000))
            try age(name, in: folder, 1000 + Double(index))
        }
        TerrainDiskCache(directory: folder, limitMb: { 1 }).enforceLimit()
        let left = TerrainDiskCache(directory: folder, limitMb: { 1 })
        #expect(left.stats().usedBytes <= 943_718, "at or under 90% of 1 MB")
        #expect(left.read("d") != nil && left.read("a") == nil, "the newest kept, the oldest gone")
    }

    @Test func clearEmptiesIt() {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = TerrainDiskCache(directory: folder, limitMb: { 5 })
        cache.write("a", [1, 2, 3])
        cache.write("b", [4, 5, 6])
        cache.clear()
        #expect(cache.stats() == TerrainCacheStats(files: 0, usedBytes: 0, limitBytes: 5 << 20))
        #expect(cache.read("a") == nil)
    }

    @Test func theChosenSizeIsRemembered() throws {
        // A store of its own: the app's real one is read by the other tests,
        // which run alongside this, and a moment of No Cache there would stop
        // them saving.
        let suite = "TerrainCacheTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(TerrainDiskCache.limitMb(in: defaults) == 500, "the Android build's default")
        TerrainDiskCache.setLimitMb(250, in: defaults)
        #expect(TerrainDiskCache.limitMb(in: defaults) == 250)
        TerrainDiskCache.setLimitMb(0, in: defaults)
        #expect(TerrainDiskCache.limitMb(in: defaults) == 0, "No Cache is a choice, not a missing value")
        TerrainDiskCache.setLimitMb(-5, in: defaults)
        #expect(TerrainDiskCache.limitMb(in: defaults) == 0)
    }
}
