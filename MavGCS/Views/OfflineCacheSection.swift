import SwiftUI
import TerrainCore

/// The terrain store: what it holds, how big it may grow, and a way to empty
/// it. The Android build's Offline cache section, without its map row: the
/// map is Apple's, and Apple lets no app keep it.
struct OfflineCacheSection: View {
    @State private var stats = TerrainCacheStats(limitBytes: Int64(TerrainDiskCache.limitMb) << 20)
    @State private var limitMb = TerrainDiskCache.limitMb
    @State private var confirmingClear = false
    /// Bumped by a change, so the readout catches up at once rather than at
    /// its next look.
    @State private var refresh = 0

    private static let bar = Color(hex: 0x37A8DB)
    /// Past 90% the oldest are already being dropped, which is worth seeing
    /// before an area goes missing.
    private static let barFull = Color(hex: 0xE0A030)

    var body: some View {
        Section {
            LabeledContent("Terrain") {
                Picker("Terrain", selection: $limitMb) {
                    ForEach(TerrainDiskCache.limitsMb, id: \.self) { megabytes in
                        Text(verbatim: Self.label(megabytes)).tag(megabytes)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            .onChange(of: limitMb) { _, megabytes in
                Task {
                    await CopernicusDEM.shared.setCacheLimit(megabytes: megabytes)
                    refresh += 1
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                usageBar
                Text(verbatim: statusLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .task(id: refresh) {
                // Every two seconds, as on the desktop and Android: often
                // enough to watch a flight fill it.
                while !Task.isCancelled {
                    stats = await CopernicusDEM.shared.cacheStats()
                    try? await Task.sleep(for: .seconds(2))
                }
            }

            // Worth a question: what it deletes was collected on purpose, and
            // getting it back needs the connection whose absence is the reason
            // for having it.
            Button("Clear terrain cache", role: .destructive) {
                confirmingClear = true
            }
            .disabled(stats.files == 0)
            .alert("Clear terrain cache?", isPresented: $confirmingClear) {
                Button("Clear", role: .destructive) {
                    Task {
                        await CopernicusDEM.shared.clearCache()
                        refresh += 1
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(verbatim: "This deletes \(Self.size(stats.usedBytes)) of saved terrain data. Anywhere that was working offline will need a connection again.")
            }
        } header: {
            Text("Offline cache")
        } footer: {
            Text("Terrain already saved keeps the terrain radar and Live AGL working with no connection. No Cache stops saving anything new and keeps what is there; only Clear removes it. The satellite map is Apple's, and apps may not store it.")
        }
    }

    /// "120 MB / 500 MB   34 files", or what is kept while saving is off.
    private var statusLine: String {
        let files = "\(stats.files) file" + (stats.files == 1 ? "" : "s")
        return stats.limitBytes > 0
            ? "\(Self.size(stats.usedBytes)) / \(Self.size(stats.limitBytes))   \(files)"
            : "\(Self.size(stats.usedBytes)) stored   \(files)   (not saving)"
    }

    private var usageBar: some View {
        let fraction = stats.limitBytes > 0 ? min(1, Double(stats.usedBytes) / Double(stats.limitBytes)) : 0
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.15))
                if fraction > 0 {
                    Capsule()
                        .fill(fraction >= 0.9 ? Self.barFull : Self.bar)
                        .frame(width: max(6, geometry.size.width * fraction))
                }
            }
        }
        .frame(height: 6)
    }

    private static func label(_ megabytes: Int) -> String {
        switch megabytes {
        case 0: "No Cache"
        case let mb where mb >= 1024 && mb % 1024 == 0: "\(mb / 1024) GB"
        default: "\(megabytes) MB"
        }
    }

    /// Sizes written as the desktop and Android write them.
    static func size(_ bytes: Int64) -> String {
        let value = Double(bytes)
        if bytes >= 1 << 30 { return String(format: "%.1f GB", value / Double(1 << 30)) }
        if bytes >= 1 << 20 { return "\(Int((value / Double(1 << 20)).rounded())) MB" }
        if bytes >= 1 << 10 { return "\(Int((value / Double(1 << 10)).rounded())) KB" }
        return "\(bytes) B"
    }
}
