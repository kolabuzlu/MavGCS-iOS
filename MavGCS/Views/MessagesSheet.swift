import MavlinkCore
import SwiftUI

/// The Messages panel in full: the vehicle's own words, and the app's.
struct MessagesSheet: View {
    let messages: [VehicleMessage]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { reader in
                List(messages) { message in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(message.time, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute().second())
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Palette.onSurfaceVariant)
                        Text(message.text)
                            .font(.system(size: 13))
                            .foregroundStyle(message.color)
                            .textSelection(.enabled)
                    }
                    .id(message.id)
                    .listRowBackground(Palette.surface)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Palette.background)
                .overlay {
                    if messages.isEmpty {
                        Text("Nothing from the vehicle yet")
                            .foregroundStyle(Palette.onSurfaceVariant)
                    }
                }
                .onAppear {
                    // Newest at the bottom, like a log, and opened there.
                    if let last = messages.last {
                        reader.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .navigationTitle("Messages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
