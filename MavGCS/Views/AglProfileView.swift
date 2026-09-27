import SwiftUI
import TerrainCore

/// Height above the ground along the track: behind on the left, ahead on the
/// right. The desktop's Live AGL panel, drawn the same way and reading the
/// same. It belongs with the terrain radar because the two answer
/// neighbouring questions: the radar says where the ground is around the
/// aircraft, this says where it is along the line the aircraft is actually
/// making good. Wider than tall because it is a side-on slice: distance runs
/// a long way, height does not.
///
/// Not there at all until there is ground to draw and a height to measure it
/// from, as on the desktop.
struct AglProfileView: View {
    let radar: TerrainRadar
    var width: CGFloat = 300

    /// The panel's height at a width: the desktop's 300 by 140.
    static func height(for width: CGFloat) -> CGFloat {
        width * AglPainter.frame.height / AglPainter.frame.width
    }

    var body: some View {
        // Read so the panel redraws as the track flown grows.
        let _ = radar.flownVersion
        if radar.showsAgl, let profile = radar.profile, let amsl = radar.altMslM,
           let picture = AglPicture(
               profile: profile,
               amslM: Double(amsl),
               slope: radar.aglSlope,
               track: radar.flownTrack(within: profile.behindM)
           ) {
            Canvas { context, size in
                AglPainter(picture: picture).draw(&context, size: size)
            }
            .frame(width: width, height: Self.height(for: width))
            .background(Color(hex: 0x1E1E1E, opacity: 0.75))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08), lineWidth: 1))
            // An instrument, not more map: a tap on it is not a place to fly to.
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture {}
        }
    }
}

/// The panel, laid out in the desktop's own 300 by 140 frame and scaled to
/// fit, so its geometry reads straight across from map_view.py.
///
/// Painted in order, so what comes last sits on top: grid, ground, path,
/// marker, then every piece of text. The flight path is scaled to the ground
/// rather than to itself, so a climb or descent runs out of the plot box --
/// and it carries on to the edge of the panel, passing behind the readouts
/// rather than stopping dead at an invisible line. Nothing clips it but the
/// panel's own edge.
private struct AglPainter {
    let picture: AglPicture

    static let frame = CGSize(width: 300, height: 140)
    /// The plot box inside it.
    static let left = 34.0
    static let right = 292.0
    static let top = 30.0
    static let bottom = 116.0

    // The desktop's sizes, 10, 15, 13 and 8, would come out at barely half
    // that on a phone once the frame is scaled down, so the writing keeps
    // sizes of its own, in the same order of importance.
    static let captionSize: CGFloat = 8
    static let aglSize: CGFloat = 12
    static let aheadSize: CGFloat = 11
    static let tickSize: CGFloat = 7

    static let blue = Color(hex: 0x37A8DB)
    static let tick = Color(hex: 0x8E9AA4)

    private enum Align {
        case leading, centre, trailing
    }

    func draw(_ context: inout GraphicsContext, size: CGSize) {
        let s = size.width / Self.frame.width
        let rel = picture.relative
        let n = rel.count
        let span = picture.behindM + picture.aheadM
        let lo = picture.lo
        let hi = picture.hi

        func xOf(_ distance: Double) -> Double {
            Self.left + (Self.right - Self.left) * (distance + picture.behindM) / span
        }
        func yOf(_ r: Double) -> Double {
            Self.bottom - (Self.bottom - Self.top) * (r - lo) / (hi - lo)
        }
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: x * s, y: y * s)
        }
        func text(_ string: String, size: CGFloat, bold: Bool = false, colour: Color, x: Double, baseline: Double, align: Align) {
            let resolved = context.resolve(
                Text(verbatim: string)
                    .font(.system(size: size, weight: bold ? .bold : .regular))
                    .foregroundStyle(colour)
            )
            let measured = resolved.measure(in: CGSize(width: 1000, height: 1000))
            let ascent = resolved.firstBaseline(in: measured)
            let at = x * s
            let leftEdge = switch align {
            case .leading: at
            case .centre: at - measured.width / 2
            case .trailing: at - measured.width
            }
            context.draw(resolved, in: CGRect(x: leftEdge, y: baseline * s - ascent, width: measured.width, height: measured.height))
        }

        // Gridlines under everything, so a flight path crossing them passes
        // over.
        let vstep = LiveAgl.niceStep(hi - lo)
        let levels = stride(from: (lo / vstep).rounded(.up) * vstep, through: hi, by: vstep).map { $0 }
        var grid = Path()
        for v in levels {
            grid.move(to: point(Self.left, yOf(v)))
            grid.addLine(to: point(Self.right, yOf(v)))
        }
        context.stroke(grid, with: .color(.white.opacity(0.14)), lineWidth: s)

        // The ground, filled down to the bottom of the box. Gaps where no
        // tile has arrived break it rather than being bridged with a straight
        // line, which would draw ground that was never measured.
        var runs: [[CGPoint]] = []
        var run: [CGPoint] = []
        for i in 0..<n {
            if rel[i].isNaN {
                if run.count > 1 { runs.append(run) }
                run = []
                continue
            }
            run.append(point(xOf(picture.distance(ofSample: i)), yOf(rel[i])))
        }
        if run.count > 1 { runs.append(run) }

        let boxBottom = Self.bottom * s
        var ground = Path()
        for segment in runs {
            ground.move(to: CGPoint(x: segment[0].x, y: boxBottom))
            for p in segment { ground.addLine(to: p) }
            ground.addLine(to: CGPoint(x: segment[segment.count - 1].x, y: boxBottom))
            ground.closeSubpath()
        }
        context.fill(ground, with: .color(Color(hex: 0xB5A07A, opacity: 0.55)))
        context.stroke(ground, with: .color(Color(hex: 0xB5A07A)), lineWidth: s)

        // Ground standing above the aircraft is not scenery, it is the thing
        // you hit, so it has a colour of its own, cut off at the aircraft's
        // level so the part that is actually a problem is the part in red.
        let level = yOf(0) * s
        var high = Path()
        for segment in runs {
            var above: [CGPoint] = []
            func close() {
                guard let first = above.first, let last = above.last else { return }
                high.move(to: CGPoint(x: first.x, y: level))
                for p in above { high.addLine(to: p) }
                high.addLine(to: CGPoint(x: last.x, y: level))
                high.closeSubpath()
                above = []
            }
            for p in segment {
                // Smaller y is higher up.
                if p.y <= level { above.append(p) } else { close() }
            }
            close()
        }
        context.fill(high, with: .color(Color(hex: 0xC85050, opacity: 0.45)))
        context.stroke(high, with: .color(Color(hex: 0xE06060)), lineWidth: s)

        // The flight path: solid behind, where it has been, dashed ahead,
        // because ahead is a projection of the present climb rate rather than
        // a fact.
        let here = CGPoint(x: xOf(0) * s, y: level)
        var behind = Path()
        if picture.track.count > 1 {
            // Oldest first, so this runs left to right and finishes at the
            // aircraft. Anything older than the panel's span is dropped
            // rather than drawn off the edge.
            for flown in picture.track {
                let x = xOf(-flown.asternM)
                if x < Self.left { continue }
                let p = point(x, yOf(flown.amslM - picture.amslM))
                if behind.isEmpty { behind.move(to: p) } else { behind.addLine(to: p) }
            }
        }
        if behind.isEmpty {
            // Nothing flown yet -- just connected, or stationary. The
            // gradient at least says which way it is going.
            behind.move(to: point(Self.left, yOf(picture.slope * -picture.behindM)))
        }
        behind.addLine(to: here)
        context.stroke(behind, with: .color(Self.blue), lineWidth: 1.5 * s)

        var ahead = Path()
        ahead.move(to: here)
        ahead.addLine(to: point(Self.right, yOf(picture.slope * picture.aheadM)))
        context.stroke(ahead, with: .color(Self.blue), style: StrokeStyle(lineWidth: 1.5 * s, dash: [5 * s, 4 * s]))

        var now = Path()
        now.move(to: CGPoint(x: here.x, y: Self.top * s))
        now.addLine(to: CGPoint(x: here.x, y: boxBottom))
        context.stroke(now, with: .color(.white.opacity(0.30)), style: StrokeStyle(lineWidth: s, dash: [3 * s, 3 * s]))

        let ring = Path(ellipseIn: CGRect(x: here.x - 6 * s, y: here.y - 6 * s, width: 12 * s, height: 12 * s))
        context.fill(ring, with: .color(Color(hex: 0x37A8DB, opacity: 0.25)))
        context.stroke(ring, with: .color(.white), lineWidth: 2 * s)
        context.fill(Path(ellipseIn: CGRect(x: here.x - 2 * s, y: here.y - 2 * s, width: 4 * s, height: 4 * s)), with: .color(.white))

        // Every piece of text last, over the picture, so a path crossing the
        // foot of the panel passes behind the distances rather than through
        // them.
        for v in levels {
            text("\(Int(v.rounded()))", size: Self.tickSize, colour: Self.tick, x: Self.left - 4, baseline: yOf(v) + 3, align: .trailing)
        }
        let hstep = LiveAgl.niceStep(span)
        var distance = -(picture.behindM / hstep).rounded(.down) * hstep
        while distance <= picture.aheadM {
            text("\(abs(Int(distance.rounded())))", size: Self.tickSize, colour: Self.tick, x: xOf(distance), baseline: Self.bottom + 12, align: .centre)
            distance += hstep
        }

        // The two numbers. AGL is the gap right here; the one on the right is
        // the smallest gap anywhere ahead.
        text("AGL", size: Self.captionSize, bold: true, colour: Self.blue, x: 96, baseline: 18, align: .trailing)
        text(
            picture.aglM.map { "\(Int($0.rounded())) m" } ?? "--",
            size: Self.aglSize, bold: true, colour: .white, x: 100, baseline: 19, align: .leading
        )
        let aheadColour = switch picture.alarm {
        case .bad: Color(hex: 0xFF6B6B)
        case .warn: Color(hex: 0xE8C33A)
        case .none: Color(hex: 0xCFD8E0)
        }
        text(
            picture.clearAheadM.map { "▸ \(Int($0.rounded())) m" } ?? "--",
            size: Self.aheadSize, bold: true, colour: aheadColour, x: 292, baseline: 18, align: .trailing
        )
    }
}
