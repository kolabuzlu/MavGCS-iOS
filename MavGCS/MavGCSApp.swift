import SwiftUI

@main
struct MavGCSApp: App {
    @State private var model = GcsModel()

    var body: some Scene {
        WindowGroup {
            MainScreen()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Palette.green)
        }
    }
}
