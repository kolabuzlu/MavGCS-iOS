import SwiftUI
import UIKit

/// A button whose hold does something its tap does not.
///
/// Disarming cuts the motors and force arming skips the pre-arm checks, so
/// neither should be one careless press away. The hold fires only on
/// reaching the full duration with the finger still down; letting go early
/// sends nothing but the tap, if the button has one. A completed hold
/// swallows the release that ends it, which would otherwise fire both.
/// Lifting the finger well off the button cancels, the way any iOS button
/// does.
///
/// Whether a finger is down is gesture state, which SwiftUI resets however
/// the touch ends -- including when iOS takes the touch away, as its home
/// bar gesture does at the bottom edge. The first version kept its own
/// flag, cleared only by a touch ending normally: a taken touch left the
/// button reading FORCE… and its timer running, and three seconds later
/// the hold fired with no finger on the screen.
struct HoldButton: View {
    static let holdSeconds = 3.0
    /// How long a press lasts before it reads as the start of a hold. A tap
    /// is over well before this, so a tap never flashes the hold label.
    static let holdShowsAfter = 0.35

    let label: String
    /// A quieter word or two before the label, at the same size, in lighter
    /// ink, so the button still reads as one line.
    var labelPrefix: String?
    let holdLabel: String
    let enabled: Bool
    let fill: Color
    let ink: Color
    var bordered = false
    var fontSize: CGFloat = 12
    let onHold: () -> Void
    var onTap: (() -> Void)?

    @GestureState private var touching = false
    /// The press has lasted long enough to be a hold, and is showing as one.
    @State private var holding = false
    @State private var fired = false
    @State private var progress = 0.0
    @State private var holdTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Solid even when disabled: these sit over the map, and a
                // faded button lets the imagery show through its label.
                RoundedRectangle(cornerRadius: controlCorner).fill(enabled ? fill : Palette.surfaceVariant)
                // White works as the fill over both the red and the grey.
                Rectangle()
                    .fill(Color.white.opacity(0.28))
                    .frame(width: geometry.size.width * progress)
                title
                    .frame(maxWidth: .infinity)
            }
            .clipShape(RoundedRectangle(cornerRadius: controlCorner))
            .overlay {
                if bordered || !enabled {
                    RoundedRectangle(cornerRadius: controlCorner).stroke(Palette.outline, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .gesture(press(in: geometry.size))
        }
        .onChange(of: touching) { _, down in
            if down {
                beginPress()
            } else {
                endPress()
            }
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
    }

    private var title: some View {
        Group {
            if holding {
                Text(holdLabel)
            } else if let labelPrefix {
                Text(labelPrefix + " ").foregroundColor(ink.opacity(0.45)) + Text(label)
            } else {
                Text(label)
            }
        }
        .font(.system(size: fontSize, weight: .semibold))
        .foregroundStyle(enabled ? ink : Palette.onSurface.opacity(0.35))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, 4)
    }

    private func press(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($touching) { _, down, _ in
                down = true
            }
            .onEnded { value in
                // Only a touch that finished here is a tap. One that iOS
                // took away never arrives at all.
                let inside = CGRect(origin: .zero, size: size).insetBy(dx: -24, dy: -24).contains(value.location)
                if enabled, !fired, inside, let onTap {
                    Haptics.light()
                    onTap()
                }
            }
    }

    private func beginPress() {
        guard enabled else { return }
        fired = false
        holdTask?.cancel()
        holdTask = Task {
            try? await Task.sleep(for: .seconds(Self.holdShowsAfter))
            guard !Task.isCancelled else { return }
            holding = true
            withAnimation(.linear(duration: Self.holdSeconds - Self.holdShowsAfter)) { progress = 1 }
            try? await Task.sleep(for: .seconds(Self.holdSeconds - Self.holdShowsAfter))
            // Cancelled the moment the finger is gone, however it went.
            guard !Task.isCancelled else { return }
            fired = true
            Haptics.heavy()
            onHold()
        }
    }

    private func endPress() {
        holdTask?.cancel()
        holdTask = nil
        holding = false
        var snap = Transaction()
        snap.disablesAnimations = true
        withTransaction(snap) { progress = 0 }
    }
}

/// One flight mode, lit for what the vehicle is doing: green when it is in
/// the mode, amber while a request for it is waiting to be confirmed.
struct ModeButtonView: View {
    let label: String
    let active: Bool
    let pending: Bool
    let enabled: Bool
    /// RTL is the get-home-now action, so it carries the warning colour
    /// until it is the mode actually engaged.
    var alert = false
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.light()
            action()
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(PanelButtonStyle(fill: fill, ink: ink, bordered: !active && !pending && !alert))
        .disabled(!enabled)
    }

    private var fill: Color {
        if active { return Palette.green }
        if pending { return Palette.amber }
        if alert { return Palette.red }
        return Palette.surfaceVariant
    }

    private var ink: Color {
        if active { return Palette.onGreen }
        if pending { return Palette.onAmber }
        if alert { return .white }
        return Palette.onSurface
    }
}

/// The panel's one button shape: the shared corner, a flat fill, and a
/// press that darkens rather than bounces.
struct PanelButtonStyle: ButtonStyle {
    var fill: Color = Palette.surfaceVariant
    var ink: Color = Palette.onSurface
    var bordered = true

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        // Disabled reads as a quiet grey with a dim label, and stays solid:
        // over the map, a faded button is a hole in the imagery.
        configuration.label
            .foregroundStyle(isEnabled ? ink : Palette.onSurface.opacity(0.35))
            .background(isEnabled ? fill : Palette.surfaceVariant, in: RoundedRectangle(cornerRadius: controlCorner))
            .overlay {
                if bordered || !isEnabled {
                    RoundedRectangle(cornerRadius: controlCorner).stroke(Palette.outline, lineWidth: 1)
                }
                if configuration.isPressed {
                    RoundedRectangle(cornerRadius: controlCorner).fill(Color.black.opacity(0.25))
                }
            }
    }
}

enum Haptics {
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func heavy() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }
}
