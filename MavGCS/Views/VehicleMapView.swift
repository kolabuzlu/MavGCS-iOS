import MapKit
import MavlinkCore
import SwiftUI

/// What the app's own controls cover of the map, in points in from its
/// edges: a strip along each side, and the instruments standing in from the
/// right-hand one -- the terrain radar under the top strip, and the Live AGL
/// panel above the bottom one while it is up.
struct MapCover: Equatable {
    var insets = UIEdgeInsets.zero
    var corner: [Block] = []
    /// How much higher than the bottom strip MapKit's logo and Legal link
    /// sit: room kept under them for the imagery's own credit.
    var attributionLift: CGFloat = 0

    /// An instrument flush with the right-hand strip: its size, and how far
    /// down from the map's top edge it starts.
    struct Block: Equatable {
        var width: CGFloat
        var height: CGFloat
        var top: CGFloat
    }

    /// The margins MapKit centres the map within, which is where Follow puts
    /// the aircraft: chosen so that their middle falls on the middle of the
    /// map left clear -- the space between the rows of controls, less the
    /// instruments along its right-hand side -- rather than the middle of
    /// the whole map, much of which is under the controls. The bottom and
    /// left margins are fixed by MapKit's logo and Legal link, which sit
    /// inside them and have to stay clear of the controls, so the top and
    /// right ones do the moving.
    func margins(in size: CGSize) -> UIEdgeInsets {
        let left = insets.left
        let bottom = insets.bottom + 2 + attributionLift
        let clear = CGRect(
            x: insets.left,
            y: insets.top,
            width: size.width - insets.left - insets.right,
            height: size.height - insets.top - insets.bottom
        )
        let blocks = corner.map { block in
            CGRect(x: size.width - insets.right - block.width, y: block.top, width: block.width, height: block.height)
                .intersection(clear)
        }.filter { !$0.isNull && !$0.isEmpty }
        let clearArea = clear.width * clear.height
        let coveredArea = blocks.reduce(0) { $0 + $1.width * $1.height }
        // Before the map has a size, or with a panel up so tall that nothing
        // is left: the middle of whatever is above the controls.
        guard clear.width > 0, clear.height > 0, clearArea > coveredArea else {
            return UIEdgeInsets(top: 0, left: left, bottom: bottom, right: 0)
        }
        // The middle of what is left: the clear rectangle's, with each
        // instrument's corner taken back out, all weighted by their areas.
        let area = clearArea - coveredArea
        let x = (clear.midX * clearArea - blocks.reduce(0) { $0 + $1.midX * $1.width * $1.height }) / area
        let y = (clear.midY * clearArea - blocks.reduce(0) { $0 + $1.midY * $1.width * $1.height }) / area
        return UIEdgeInsets(
            top: max(0, 2 * y - (size.height - bottom)),
            left: left,
            bottom: bottom,
            right: max(0, size.width + left - 2 * x)
        )
    }
}

/// The moving map: the aircraft, home, the trail flown, the guide lines,
/// and the point tapped to fly to.
///
/// MKMapView rather than SwiftUI's Map, for the control a ground station
/// needs over it: overlays replaced on its own schedule, a drag that can be
/// told apart from the app's own re-centring, and tile overlays for when
/// the imagery has to come from somewhere Apple's does not reach.
struct VehicleMapView: UIViewRepresentable {
    let vehicle: VehicleState
    let trail: [CLLocationCoordinate2D]
    let trailVersion: Int
    let flyTarget: CLLocationCoordinate2D?
    @Binding var follow: Bool
    let hybrid: Bool
    let showVectors: Bool
    let weatherTiles: [RadarTile]
    let weatherVersion: Int
    /// What the app's own controls cover of the map. The aircraft is followed
    /// in the middle of what they leave clear, and MapKit's logo and Legal
    /// link, which are required to stay visible, are lifted above them.
    let cover: MapCover
    let onTap: (CLLocationCoordinate2D) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        // Under ESRI's imagery, which replaces it; flat, so nothing of Apple's
        // 3D terrain tilts the tiles out of true.
        map.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .flat)
        map.insertOverlay(context.coordinator.imagery, at: 0, level: .aboveRoads)
        // North up, flat: the guide lines and the wind arrow on the HUD are
        // all read against north, and a map that turns under a finger makes
        // them lie.
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.showsCompass = false
        // The margins below are measured from the map's own edges. Left to
        // itself it would add the home indicator's strip on top.
        map.insetsLayoutMarginsFromSafeArea = false
        map.pointOfInterestFilter = .excludingAll
        map.register(PlaneMarkerView.self, forAnnotationViewWithReuseIdentifier: PlaneMarkerView.reuse)
        map.register(HomeMarkerView.self, forAnnotationViewWithReuseIdentifier: HomeMarkerView.reuse)
        map.register(TargetMarkerView.self, forAnnotationViewWithReuseIdentifier: TargetMarkerView.reuse)
        map.setRegion(
            MKCoordinateRegion(center: Coordinator.startCenter, latitudinalMeters: 8000, longitudinalMeters: 8000),
            animated: false
        )

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.delegate = context.coordinator
        map.addGestureRecognizer(tap)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        // Compared with what was last asked for, not read back: the margins
        // a view reports include its safe area, so they never match.
        let margins = cover.margins(in: map.bounds.size)
        if context.coordinator.appliedMargins != margins {
            context.coordinator.appliedMargins = margins
            map.layoutMargins = margins
            // MapKit places its attribution in a layout pass of its own and
            // does not always schedule one for a margin change.
            map.setNeedsLayout()
            // The middle has moved, so a followed aircraft goes to it now
            // rather than whenever it next moves.
            context.coordinator.recentre()
        }
        context.coordinator.update(map)
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        /// Ankara, where the desktop opens and the test aircraft flies,
        /// until the vehicle says where it is.
        static let startCenter = CLLocationCoordinate2D(latitude: 39.925386, longitude: 32.836524)

        var parent: VehicleMapView
        var appliedMargins: UIEdgeInsets?
        private let plane = MKPointAnnotation()
        private let home = MKPointAnnotation()
        private let target = MKPointAnnotation()
        private var planeShown = false
        private var homeShown = false
        private var targetShown = false
        private var trailLine: MKPolyline?
        private var guides: [MKPolyline] = []
        private var drawnTrailVersion = -1
        private var lastTrailDraw = Date.distantPast
        let imagery = EsriTileOverlay(.imagery)
        /// Drawn over the imagery for Hybrid, in the Android build's order.
        private let references = [EsriTileOverlay(.places), EsriTileOverlay(.transportation)]
        private var hybridShown = false
        private var weatherOverlay: WeatherOverlay?
        private var drawnWeatherVersion = -1
        private var weatherCentre: CLLocationCoordinate2D?
        private var framedFirstFix = false
        /// What the guides were last drawn from. State arrives up to twenty
        /// times a second, most of it about something else entirely, and
        /// four polylines rebuilt for nothing each time is waste.
        private var drawnGuides: [Double] = []
        private var centredOn: CLLocationCoordinate2D?

        init(_ parent: VehicleMapView) {
            self.parent = parent
        }

        /// Follow puts the aircraft back in the middle on the next update,
        /// even if it has not moved.
        func recentre() {
            centredOn = nil
        }


        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard let map = recognizer.view as? MKMapView else { return }
            let point = recognizer.location(in: map)
            // A tap on a marker is about the marker, not the ground under it.
            if map.annotations.contains(where: { map.view(for: $0)?.frame.insetBy(dx: -6, dy: -6).contains(point) == true }) {
                return
            }
            parent.onTap(map.convert(point, toCoordinateFrom: map))
        }

        func update(_ map: MKMapView) {
            if hybridShown != parent.hybrid {
                hybridShown = parent.hybrid
                if hybridShown {
                    // Straight above the imagery and any radar, so the names
                    // stay readable through rain, and the trail and the guide
                    // lines, added later, stay on top of them.
                    var below: MKOverlay = weatherOverlay ?? imagery
                    for layer in references {
                        map.insertOverlay(layer, above: below)
                        below = layer
                    }
                } else {
                    map.removeOverlays(references)
                }
            }
            updateWeather(map)
            updateHome(map)
            updateTarget(map)
            updateTrail(map)
            updatePlane(map)
            updateGuides(map)
        }

        /// The radar, replaced when its tiles change and otherwise only moved
        /// with the aircraft -- and only once it has moved far enough for the
        /// circle's edge to show it, since every move redraws the whole of it.
        private func updateWeather(_ map: MKMapView) {
            let vehicle = parent.vehicle
            var position: CLLocationCoordinate2D?
            if let lat = vehicle.lat, let lon = vehicle.lon, lat != 0 || lon != 0 {
                position = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
            if parent.weatherVersion != drawnWeatherVersion {
                drawnWeatherVersion = parent.weatherVersion
                if let old = weatherOverlay {
                    map.removeOverlay(old)
                    weatherOverlay = nil
                }
                if !parent.weatherTiles.isEmpty, let position {
                    let overlay = WeatherOverlay(tiles: parent.weatherTiles, centre: position)
                    weatherOverlay = overlay
                    weatherCentre = position
                    // On the imagery, under the Hybrid labels, the trail and
                    // the guide lines.
                    map.insertOverlay(overlay, above: imagery)
                }
                return
            }
            guard let overlay = weatherOverlay, let position, let last = weatherCentre else { return }
            let moved = MKMapPoint(last).distance(to: MKMapPoint(position))
            if moved > 250 {
                overlay.move(to: position)
                weatherCentre = position
                map.renderer(for: overlay)?.setNeedsDisplay()
            }
        }

        private func updatePlane(_ map: MKMapView) {
            let vehicle = parent.vehicle
            guard let lat = vehicle.lat, let lon = vehicle.lon, lat != 0 || lon != 0 else { return }
            let position = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            plane.coordinate = position
            if !planeShown {
                planeShown = true
                map.addAnnotation(plane)
            }
            let heading = vehicle.headingDeg ?? vehicle.yawDeg ?? 0
            (map.view(for: plane) as? PlaneMarkerView)?.heading = CGFloat(heading)

            if !framedFirstFix {
                // The first fix is worth a closer look than the starting view.
                framedFirstFix = true
                centredOn = position
                map.setRegion(MKCoordinateRegion(center: position, latitudinalMeters: 1500, longitudinalMeters: 1500), animated: false)
            } else if parent.follow {
                // Only when the aircraft has actually moved: re-centring on
                // the same point over and over makes the map shiver under a
                // finger that is trying to pinch it.
                if centredOn?.latitude != position.latitude || centredOn?.longitude != position.longitude {
                    centredOn = position
                    map.setCenter(position, animated: true)
                }
            } else {
                centredOn = nil
            }
        }

        private func updateHome(_ map: MKMapView) {
            guard let lat = parent.vehicle.homeLat, let lon = parent.vehicle.homeLon else { return }
            home.coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            if !homeShown {
                homeShown = true
                map.addAnnotation(home)
            }
        }

        private func updateTarget(_ map: MKMapView) {
            if let point = parent.flyTarget {
                target.coordinate = point
                if !targetShown {
                    targetShown = true
                    map.addAnnotation(target)
                }
            } else if targetShown {
                targetShown = false
                map.removeAnnotation(target)
            }
        }

        /// Replaced whole rather than extended: MapKit has no way to append
        /// to a polyline. At most twice a second, which is as often as the
        /// position arrives by default and far cheaper than every update.
        private func updateTrail(_ map: MKMapView) {
            guard parent.trailVersion != drawnTrailVersion else { return }
            let now = Date()
            guard now.timeIntervalSince(lastTrailDraw) >= 0.5 || parent.trail.count < 2 else { return }
            drawnTrailVersion = parent.trailVersion
            lastTrailDraw = now
            if let trailLine { map.removeOverlay(trailLine) }
            trailLine = nil
            guard parent.trail.count > 1 else { return }
            let line = TrailLine(coordinates: parent.trail, count: parent.trail.count)
            trailLine = line
            map.addOverlay(line, level: .aboveRoads)
        }

        private func updateGuides(_ map: MKMapView) {
            let vehicle = parent.vehicle
            let overGround = Double(vehicle.groundSpeedMs ?? 0)
            let heading = Double(vehicle.headingDeg ?? vehicle.yawDeg ?? 0)
            let course = Double(vehicle.groundCourseDeg ?? Float(heading))
            let key: [Double] = [
                parent.showVectors ? 1 : 0, vehicle.lat ?? 0, vehicle.lon ?? 0, overGround, heading, course,
                Double(vehicle.yawRateDegSec), Double(vehicle.navBearingDeg ?? -1), Double(vehicle.distToWpM ?? -1),
            ]
            guard key != drawnGuides else { return }
            drawnGuides = key
            map.removeOverlays(guides)
            guides = []
            guard parent.showVectors, let lat = vehicle.lat, let lon = vehicle.lon, lat != 0 || lon != 0 else { return }
            let start = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            let reach = min(max(overGround * Guide.horizonSeconds, Guide.minMetres), Guide.maxMetres)

            // In still air the lines nearly coincide, so they go on widest
            // first and thinnest last, and the heading stops short of the
            // track: where the aeroplane is going matters more than where its
            // nose points, and the step between the two tips shows the crab.
            var lines: [MKPolyline] = [
                GuideLine.predicted(from: start, course: course, speed: overGround, turnRate: Double(vehicle.yawRateDegSec)),
            ]
            // Straight at whatever the navigation controller is steering for,
            // its whole reported length: the point is that it ends on the
            // target. Home under RTL, the waypoint under AUTO.
            if let bearing = vehicle.navBearingDeg, let distance = vehicle.distToWpM, distance > 0 {
                lines.append(GuideLine.straight(.nav, from: start, bearing: Double(bearing), metres: Double(distance)))
            }
            lines.append(GuideLine.straight(.course, from: start, bearing: course, metres: reach))
            lines.append(GuideLine.straight(.heading, from: start, bearing: heading, metres: reach * Guide.headingReach))
            guides = lines
            map.addOverlays(lines, level: .aboveRoads)
        }

        // MARK: - UIGestureRecognizerDelegate

        /// The map's own double tap zooms, and has to win over a single tap
        /// meaning "fly here". Asked of every recogniser as it arrives, so it
        /// holds for the ones MapKit creates after the map is built.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
            (other as? UITapGestureRecognizer)?.numberOfTapsRequired == 2
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        // MARK: - MKMapViewDelegate

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            // A drag takes the map back from Follow; the app's own re-centring
            // does not. Only a gesture in progress tells the two apart.
            let recognizers = (mapView.subviews.first?.gestureRecognizers ?? []) + (mapView.gestureRecognizers ?? [])
            let dragging = recognizers.contains { $0.state == .began || $0.state == .changed }
            if dragging && parent.follow {
                parent.follow = false
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation === plane {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: PlaneMarkerView.reuse, for: annotation)
                // Turned now, not on the next update: a view appears some
                // while after its annotation is added.
                (view as? PlaneMarkerView)?.heading = CGFloat(parent.vehicle.headingDeg ?? parent.vehicle.yawDeg ?? 0)
                return view
            }
            if annotation === home {
                return mapView.dequeueReusableAnnotationView(withIdentifier: HomeMarkerView.reuse, for: annotation)
            }
            if annotation === target {
                return mapView.dequeueReusableAnnotationView(withIdentifier: TargetMarkerView.reuse, for: annotation)
            }
            return nil
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tiles)
            }
            if let weather = overlay as? WeatherOverlay {
                return WeatherRenderer(overlay: weather)
            }
            if let trail = overlay as? TrailLine {
                let renderer = ScreenLineRenderer(polyline: trail)
                renderer.strokeColor = UIColor(Palette.red)
                renderer.lineWidth = 3
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            if let guide = overlay as? GuideLine {
                let renderer = ScreenLineRenderer(polyline: guide)
                renderer.strokeColor = UIColor(guide.kind.color)
                renderer.lineWidth = guide.kind.width
                renderer.lineCap = guide.kind == .heading ? .butt : .round
                if guide.kind == .heading {
                    // A round cap would smear the gaps closed at this width.
                    renderer.lineDashPattern = [7, 5]
                }
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

// MARK: - Guides

private nonisolated enum Guide {
    static let horizonSeconds = 20.0
    static let minMetres = 120.0
    static let maxMetres = 1200.0
    static let headingReach = 0.85
    /// The predicted track looks ten seconds ahead, in steps small enough
    /// that a steady bank draws as an arc.
    static let trackSeconds = 10.0
    static let trackSteps = 24
    static let trackMinMetres = 60.0
}

nonisolated final class TrailLine: MKPolyline {}

/// A polyline whose width and dashes are in screen points, whatever MapKit
/// does with it.
///
/// MapKit draws a plain polyline in screen points, but a dashed one falls
/// back to an older drawing path that scales the width -- and the dashes --
/// like a road at the current zoom. The heading line, the one dashed guide,
/// came out twice the width of the ground track beside it with dashes more
/// than twice as long as asked for. Setting them here, in map points for
/// this zoom, holds them to what was asked for.
nonisolated final class ScreenLineRenderer: MKPolylineRenderer {
    override func applyStrokeProperties(to context: CGContext, atZoomScale zoomScale: MKZoomScale) {
        super.applyStrokeProperties(to: context, atZoomScale: zoomScale)
        context.setLineWidth(lineWidth / zoomScale)
        if let pattern = lineDashPattern, !pattern.isEmpty {
            context.setLineDash(phase: 0, lengths: pattern.map { CGFloat($0.doubleValue) / zoomScale })
        }
    }
}

nonisolated final class GuideLine: MKPolyline {
    enum Kind {
        case predicted, nav, course, heading

        var color: Color {
            switch self {
            case .predicted: return Palette.hudYellow
            case .nav: return Color(hex: 0xFF2FD0)
            case .course: return Palette.cyan
            case .heading: return .white
            }
        }

        var width: CGFloat {
            switch self {
            case .predicted: return 2.8
            case .nav: return 2
            case .course: return 1.8
            case .heading: return 1.8 // the ground track's own width
            }
        }
    }

    private(set) var kind = Kind.heading

    static func straight(_ kind: Kind, from start: CLLocationCoordinate2D, bearing: Double, metres: Double) -> GuideLine {
        let end = Geo.destination(lat: start.latitude, lon: start.longitude, bearingDeg: bearing, distanceM: metres)
        let points = [start, CLLocationCoordinate2D(latitude: end.lat, longitude: end.lon)]
        let line = GuideLine(coordinates: points, count: points.count)
        line.kind = kind
        return line
    }

    /// Where the aircraft ends up if it holds this turn rate: the course is
    /// advanced a step at a time, so a steady bank draws an arc and wings
    /// level draws a line.
    static func predicted(from start: CLLocationCoordinate2D, course: Double, speed: Double, turnRate: Double) -> GuideLine {
        let step = Guide.trackSeconds / Double(Guide.trackSteps)
        let leg = max(speed * step, Guide.trackMinMetres / Double(Guide.trackSteps))
        var heading = course
        var here = start
        var points = [start]
        for _ in 0..<Guide.trackSteps {
            heading += turnRate * step
            let next = Geo.destination(lat: here.latitude, lon: here.longitude, bearingDeg: heading, distanceM: leg)
            here = CLLocationCoordinate2D(latitude: next.lat, longitude: next.lon)
            points.append(here)
        }
        let line = GuideLine(coordinates: points, count: points.count)
        line.kind = .predicted
        return line
    }
}

// MARK: - Markers

final class PlaneMarkerView: MKAnnotationView {
    static let reuse = "plane"

    var heading: CGFloat = 0 {
        didSet { transform = CGAffineTransform(rotationAngle: heading * .pi / 180) }
    }

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        image = Self.icon
        // Ours is the one that matters: nothing is drawn over it, and the map
        // never hides it to make room for something else.
        zPriority = .max
        displayPriority = .required
        collisionMode = .none
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    /// The desktop's plane, nose up, at a size that reads on a phone.
    private static let icon: UIImage? = {
        guard let source = UIImage(named: "Plane") else { return nil }
        let width: CGFloat = 55 // 46 × 1.2
        let size = CGSize(width: width, height: width * source.size.height / source.size.width)
        return UIGraphicsImageRenderer(size: size).image { _ in source.draw(in: CGRect(origin: .zero, size: size)) }
    }()
}

final class HomeMarkerView: MKAnnotationView {
    static let reuse = "home"

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        image = Self.icon
        displayPriority = .required
        // Beneath everything else, as on the desktop: home is a reference
        // point, and must never hide the aircraft flying over it. It was
        // .defaultSelected, which is the same 1000 as the plane's .max --
        // a tie MapKit settled whichever way it liked.
        zPriority = .min
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    /// The desktop's own home marker, drawn from its SVG rather than scaled
    /// up from a bitmap: a dark disc ringed in green, a white house, a green
    /// door. The Android build ships it as a 90-pixel PNG, which at this
    /// size would be enlarged past its own resolution and go soft.
    private static let icon: UIImage = {
        let side: CGFloat = 28
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            let g = context.cgContext
            // The SVG's own coordinates: a 28-unit square.
            g.scaleBy(x: side / 28, y: side / 28)
            let green = UIColor(red: 0x4C / 255, green: 0xAF / 255, blue: 0x50 / 255, alpha: 1)
            let disc = CGRect(x: 2, y: 2, width: 24, height: 24)
            g.setFillColor(UIColor(red: 20 / 255, green: 20 / 255, blue: 20 / 255, alpha: 0.72).cgColor)
            g.fillEllipse(in: disc)
            g.setStrokeColor(green.cgColor)
            g.setLineWidth(2)
            g.strokeEllipse(in: disc)
            g.setFillColor(UIColor.white.cgColor)
            g.move(to: CGPoint(x: 14, y: 6))
            g.addLine(to: CGPoint(x: 22, y: 13.5))
            g.addLine(to: CGPoint(x: 6, y: 13.5))
            g.closePath()
            g.fillPath()
            g.fill(CGRect(x: 8.5, y: 13.5, width: 11, height: 7))
            g.setFillColor(green.cgColor)
            g.fill(CGRect(x: 12.2, y: 16, width: 3.6, height: 4.5))
        }
    }()
}

final class TargetMarkerView: MKAnnotationView {
    static let reuse = "target"

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        image = Self.icon
        displayPriority = .required
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    /// A ring in the fly-to blue with a dot at its centre, so the exact
    /// point is plain at any zoom.
    private static let icon: UIImage = {
        let size = CGSize(width: 26, height: 26)
        return UIGraphicsImageRenderer(size: size).image { context in
            let ring = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
            UIColor(Palette.blue).withAlphaComponent(0.35).setFill()
            context.cgContext.fillEllipse(in: ring)
            UIColor.white.setStroke()
            context.cgContext.setLineWidth(2.5)
            context.cgContext.strokeEllipse(in: ring)
            UIColor(Palette.blue).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 10, y: 10, width: 6, height: 6))
        }
    }()
}
