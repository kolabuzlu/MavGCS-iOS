import CoreGraphics
import Foundation
import MapKit
import Observation
import UIKit

/// RainViewer's precipitation radar around the aircraft, as the desktop and
/// the Android build draw it: the newest frame, 50 km either side of the
/// aircraft, laid lightly over the imagery.
///
/// RainViewer publishes an index of the frames it holds, each named by an
/// opaque id rather than a predictable timestamp, so the newest has to be
/// looked up, and looked up again as frames age out of the index.
@Observable
final class WeatherRadar {
    static let refreshSeconds = 5 * 60.0

    var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            if enabled { start() } else { stop() }
        }
    }

    /// The tiles now drawn, and a count bumped whenever they change.
    private(set) var tiles: [RadarTile] = []
    private(set) var version = 0

    private var frame: (host: String, path: String)?
    private var position: (lat: Double, lon: Double)?
    /// What the tiles on screen were fetched for: the frame and which tiles.
    private var fetchedKey: String?
    private var indexTask: Task<Void, Never>?
    private var tileTask: Task<Void, Never>?

    /// Keep the radar over the aircraft. Only fetches when it has crossed
    /// into different tiles, which at this zoom is rare.
    func follow(lat: Double?, lon: Double?) {
        guard let lat, let lon, lat != 0 || lon != 0 else { return }
        position = (lat, lon)
        if enabled { fetchTilesIfNeeded() }
    }

    private func start() {
        indexTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.readIndex()
                try? await Task.sleep(for: .seconds(Self.refreshSeconds))
            }
        }
    }

    /// Switched off, nothing is left drawn and nothing is left fetching.
    private func stop() {
        indexTask?.cancel()
        tileTask?.cancel()
        indexTask = nil
        tileTask = nil
        fetchedKey = nil
        if !tiles.isEmpty {
            tiles = []
            version += 1
        }
    }

    private func readIndex() async {
        guard let url = URL(string: "https://api.rainviewer.com/public/weather-maps.json") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let index = try JSONDecoder().decode(Index.self, from: data)
            guard enabled, let newest = index.radar.past.last else { return }
            frame = (index.host, newest.path)
            fetchTilesIfNeeded()
        } catch {
            // Keep drawing the frame already shown; the next read may work.
        }
    }

    private func fetchTilesIfNeeded() {
        guard let frame, let position else { return }
        let wanted = RadarGeometry.tilesCovering(lat: position.lat, lon: position.lon)
        let key = frame.path + "|" + wanted.map { "\($0.x)/\($0.y)" }.joined(separator: ",")
        guard key != fetchedKey else { return }
        fetchedKey = key
        tileTask?.cancel()
        tileTask = Task { [weak self] in
            var fetched: [RadarTile] = []
            for (x, y) in wanted {
                // The trailing parts are the colour scheme, then smoothing and
                // snow. Scheme 2, Universal Blue, is the only one RainViewer
                // still draws since 2026; the 4 the Android build asks for now
                // comes back as the same tiles.
                guard let url = URL(string: "\(frame.host)\(frame.path)/\(RadarGeometry.tilePixels)/\(RadarGeometry.zoom)/\(x)/\(y)/2/1_1.png"),
                      let answer = try? await URLSession.shared.data(from: url),
                      (answer.1 as? HTTPURLResponse)?.statusCode == 200,
                      let image = UIImage(data: answer.0)?.cgImage
                else { continue }
                fetched.append(RadarTile(x: x, y: y, image: image))
            }
            guard !Task.isCancelled, let self, self.enabled else { return }
            if fetched.isEmpty {
                // Nothing came: forget the key so the next position or frame
                // tries again, rather than holding an empty radar forever.
                self.fetchedKey = nil
                return
            }
            self.tiles = fetched
            self.version += 1
        }
    }

    private struct Index: Decodable {
        struct Radar: Decodable {
            struct Frame: Decodable {
                let path: String
            }

            let past: [Frame]
        }

        let host: String
        let radar: Radar
    }
}

/// One radar tile as fetched, and where it belongs.
nonisolated struct RadarTile: Sendable {
    let x: Int
    let y: Int
    let image: CGImage
}

/// The radar's reach and tile arithmetic, shared by the fetching on the main
/// thread and the drawing on MapKit's.
nonisolated enum RadarGeometry {
    static let radiusMetres = 50_000.0
    /// The deepest zoom RainViewer serves for free. Deeper asks come back as
    /// a "Zoom Level Not Supported" placard with a 200 status, so the limit
    /// has to be kept to rather than discovered from the response. At this
    /// zoom one tile spans a few hundred kilometres, so the 50 km around the
    /// aircraft is usually one tile and never more than four.
    static let zoom = 7
    /// Pixels along a tile's side. RainViewer draws its tiles at 256 or 512,
    /// and 512 is twice the detail over the same ground -- at this zoom, half
    /// a kilometre a pixel rather than a whole one, which is the difference
    /// between the shape of a shower and a block of colour. The zoom stays
    /// the free limit; only the drawing is finer.
    static let tilePixels = 512

    /// The tiles at the radar's zoom that the box 50 km around a point touches.
    static func tilesCovering(lat: Double, lon: Double) -> [(x: Int, y: Int)] {
        let latSpan = radiusMetres / 111_320
        let lonSpan = latSpan / max(cos(lat * .pi / 180), 0.01)
        let xs = tileX(lon - lonSpan)...tileX(lon + lonSpan)
        let ys = tileY(lat + latSpan)...tileY(lat - latSpan)
        return xs.flatMap { x in ys.map { y in (x, y) } }
    }

    static func tileX(_ lon: Double) -> Int {
        let count = 1 << zoom
        return min(max(Int(floor((lon + 180) / 360 * Double(count))), 0), count - 1)
    }

    static func tileY(_ lat: Double) -> Int {
        let count = 1 << zoom
        let radians = lat * .pi / 180
        let value = (1 - log(tan(radians) + 1 / cos(radians)) / .pi) / 2 * Double(count)
        return min(max(Int(floor(value)), 0), count - 1)
    }

    /// Where a tile sits in MapKit's own coordinates. Both are the same Web
    /// Mercator square, so a tile is simply a fraction of the world.
    static func mapRect(x: Int, y: Int) -> MKMapRect {
        let side = MKMapSize.world.width / Double(1 << zoom)
        return MKMapRect(x: Double(x) * side, y: Double(y) * side, width: side, height: side)
    }
}

/// The radar tiles on the map, cut to a circle around the aircraft.
///
/// Its extent is the tiles' own, which always hold the whole circle, so it
/// never has to change as the aircraft moves: the circle's centre is moved
/// instead, and the renderer asked to draw again.
nonisolated final class WeatherOverlay: NSObject, MKOverlay, @unchecked Sendable {
    let tiles: [(rect: MKMapRect, image: CGImage)]
    let boundingMapRect: MKMapRect
    private let lock = NSLock()
    private var centre: CLLocationCoordinate2D

    init(tiles: [RadarTile], centre: CLLocationCoordinate2D) {
        self.tiles = tiles.map { (RadarGeometry.mapRect(x: $0.x, y: $0.y), $0.image) }
        self.boundingMapRect = self.tiles.map(\.rect).reduce(MKMapRect.null) { $0.union($1) }
        self.centre = centre
    }

    var coordinate: CLLocationCoordinate2D {
        lock.lock()
        defer { lock.unlock() }
        return centre
    }

    func move(to point: CLLocationCoordinate2D) {
        lock.lock()
        centre = point
        lock.unlock()
    }
}

nonisolated final class WeatherRenderer: MKOverlayRenderer {
    /// Light enough to read the ground through: flying inside a cell fills
    /// the whole view with one colour. The Android build's own strength.
    private static let strength: CGFloat = 120 / 255

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let weather = overlay as? WeatherOverlay else { return }
        let centre = weather.coordinate
        let radius = RadarGeometry.radiusMetres * MKMapPointsPerMeterAtLatitude(centre.latitude)
        let middle = MKMapPoint(centre)
        let circle = rect(for: MKMapRect(x: middle.x - radius, y: middle.y - radius, width: radius * 2, height: radius * 2))
        context.saveGState()
        context.addEllipse(in: circle)
        context.clip()
        context.interpolationQuality = .high
        UIGraphicsPushContext(context)
        for tile in weather.tiles where tile.rect.intersects(mapRect) {
            // The strength goes to the drawing itself: UIImage sets the
            // context's alpha for its own draw, to 1 unless told otherwise,
            // so one set on the context beforehand never reached the tiles
            // and the radar went down as a solid sheet over the imagery.
            UIImage(cgImage: tile.image).draw(in: rect(for: tile.rect), blendMode: .normal, alpha: Self.strength)
        }
        UIGraphicsPopContext()
        context.restoreGState()
    }
}
