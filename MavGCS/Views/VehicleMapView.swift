import MapKit
import MavlinkCore
import SwiftUI

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
    /// How far up from the bottom of the map the app's own controls reach.
    /// MapKit puts its logo and Legal link at the bottom left, and they are
    /// required to stay visible, so they are lifted clear of them.
    let bottomClearance: CGFloat
    let onTap: (CLLocationCoordinate2D) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.preferredConfiguration = context.coordinator.configuration(hybrid: hybrid)
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
        if context.coordinator.appliedClearance != bottomClearance {
            context.coordinator.appliedClearance = bottomClearance
            map.layoutMargins = UIEdgeInsets(top: 0, left: 6, bottom: bottomClearance + 2, right: 0)
            // MapKit places its attribution in a layout pass of its own and
            // does not always schedule one for a margin change.
            map.setNeedsLayout()
        }
        context.coordinator.update(map)
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        /// Ankara, where the desktop opens and the test aircraft flies,
        /// until the vehicle says where it is.
        static let startCenter = CLLocationCoordinate2D(latitude: 39.925386, longitude: 32.836524)

        var parent: VehicleMapView
        var appliedClearance: CGFloat = -1
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
        private var hybrid: Bool?
        private var framedFirstFix = false
        /// What the guides were last drawn from. State arrives up to twenty
        /// times a second, most of it about something else entirely, and
        /// four polylines rebuilt for nothing each time is waste.
        private var drawnGuides: [Double] = []
        private var centredOn: CLLocationCoordinate2D?

        init(_ parent: VehicleMapView) {
            self.parent = parent
        }

        func configuration(hybrid: Bool) -> MKMapConfiguration {
            hybrid ? MKHybridMapConfiguration(elevationStyle: .flat) : MKImageryMapConfiguration(elevationStyle: .flat)
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
            if hybrid != parent.hybrid {
                hybrid = parent.hybrid
                map.preferredConfiguration = configuration(hybrid: parent.hybrid)
            }
            updateHome(map)
            updateTarget(map)
            updateTrail(map)
            updatePlane(map)
            updateGuides(map)
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
            if let trail = overlay as? TrailLine {
                let renderer = MKPolylineRenderer(polyline: trail)
                renderer.strokeColor = UIColor(Palette.red)
                renderer.lineWidth = 3
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            if let guide = overlay as? GuideLine {
                let renderer = MKPolylineRenderer(polyline: guide)
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
            case .heading: return 1.5
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
        let width: CGFloat = 46
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
        zPriority = .defaultSelected
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    private static let icon: UIImage? = {
        guard let source = UIImage(named: "Home") else { return nil }
        let size = CGSize(width: 28, height: 28 * source.size.height / source.size.width)
        return UIGraphicsImageRenderer(size: size).image { _ in source.draw(in: CGRect(origin: .zero, size: size)) }
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
