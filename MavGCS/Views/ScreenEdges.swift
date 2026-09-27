import SwiftUI
import UIKit

/// The screen's unsafe edges, and which side the Dynamic Island is on.
///
/// In landscape iOS reports the same inset on both sides, whichever way up
/// the phone is held, so the safe area alone cannot say which side actually
/// has the island. The layout wants to know: the side without it has only a
/// rounded corner to keep clear of, and the instruments can run almost to
/// the edge there.
struct ScreenEdges: Equatable {
    var insets = UIEdgeInsets.zero
    /// The top of the phone, where the island or notch is, is on the left.
    var islandOnLeft = false
    /// The screen has been read. Until it has, the layout is the one the app
    /// has always opened with, edges or none: the map settles its opening
    /// view in that first moment, and a different one moves it.
    var measured = false

    /// The strip down the left-hand edge: enough to keep a panel's corner out
    /// of the display's rounded one, and where the battery gauge stands.
    /// Kept on square-cornered screens too, for the gauge.
    static let cornerMargin: CGFloat = 16

    var leading: CGFloat {
        if islandOnLeft { return max(insets.left, 6) }
        return measured ? Self.cornerMargin : min(insets.left, Self.cornerMargin)
    }
    var trailing: CGFloat { islandOnLeft ? min(insets.right, Self.cornerMargin + 8) : max(insets.right, 6) }
}

/// Reports ScreenEdges as the window and its orientation change.
///
/// Turning the phone from one landscape to the other changes nothing
/// SwiftUI lays out by -- same size, same insets -- so the scene's geometry
/// is watched directly.
struct ScreenEdgesReader: UIViewRepresentable {
    @Binding var edges: ScreenEdges

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        probe.onChange = { edges = $0 }
        return probe
    }

    func updateUIView(_ uiView: Probe, context: Context) {}

    final class Probe: UIView {
        var onChange: ((ScreenEdges) -> Void)?
        private var observation: NSKeyValueObservation?
        private var last: ScreenEdges?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            observation = window?.windowScene?.observe(\.effectiveGeometry, options: [.initial, .new]) { [weak self] _, _ in
                // UIKit reports its own geometry on the main thread.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.report() }
                }
            }
            report()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            report()
        }

        private func report() {
            guard let window, let scene = window.windowScene else { return }
            let edges = ScreenEdges(
                insets: window.safeAreaInsets,
                // Home button on the right, in the old terms, puts the top of
                // the phone on the left.
                islandOnLeft: scene.effectiveGeometry.interfaceOrientation == .landscapeRight,
                measured: true
            )
            guard edges != last else { return }
            last = edges
            onChange?(edges)
        }
    }
}
