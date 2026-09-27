import SwiftUI

@main
struct MavGCSApp: App {
    @State private var model = GcsModel()

    init() {
        // Up to 1.0.1 the map was ESRI's, and its tiles were kept here, up to
        // a gigabyte of them, for flying without a signal. ESRI's terms allow
        // no such store, and the map is Apple's now, so what is left goes.
        Task.detached(priority: .background) {
            let old = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MapTiles", isDirectory: true)
            try? FileManager.default.removeItem(at: old)
        }
    }

    var body: some Scene {
        WindowGroup {
            MainScreen()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Palette.green)
        }
    }
}
