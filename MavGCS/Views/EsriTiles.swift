import MapKit

/// ESRI's World Imagery, and the two reference layers that make it Hybrid.
///
/// The imagery the desktop and the Android build fly over. It replaces
/// Apple's map outright, so none of Apple's tiles are fetched underneath it.
/// Hybrid is the same imagery with ESRI's reference layers drawn over it;
/// there is no single hybrid service to point at.
nonisolated final class EsriTileOverlay: MKTileOverlay {
    enum Layer: String {
        case imagery = "World_Imagery"
        case places = "Reference/World_Boundaries_and_Places"
        case transportation = "Reference/World_Transportation"
    }

    /// The deepest level fetched, as on Android. Closer in, the tiles of this
    /// level are enlarged rather than asked for: ESRI's deeper levels exist in
    /// some places and in others answer with a grey "no data" tile.
    static let deepestLevel = 19

    let layer: Layer

    init(_ layer: Layer) {
        self.layer = layer
        // ArcGIS orders a tile's address level, row, column -- {z}/{y}/{x} --
        // not the {z}/{x}/{y} most tile servers use. Both orders return a
        // real tile, so getting it wrong draws imagery of the wrong place
        // rather than failing.
        super.init(urlTemplate: "https://server.arcgisonline.com/ArcGIS/rest/services/\(layer.rawValue)/MapServer/tile/{z}/{y}/{x}")
        canReplaceMapContent = layer == .imagery
        tileSize = CGSize(width: 256, height: 256)
        maximumZ = 22
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, (any Error)?) -> Void) {
        guard path.z > Self.deepestLevel else {
            fetch(path, result)
            return
        }
        // Past the deepest level: the matching piece of its tile, enlarged.
        let shift = path.z - Self.deepestLevel
        let parent = MKTileOverlayPath(
            x: path.x >> shift,
            y: path.y >> shift,
            z: Self.deepestLevel,
            contentScaleFactor: path.contentScaleFactor
        )
        let layer = layer
        fetch(parent) { data, error in
            guard let data, let image = UIImage(data: data)?.cgImage else {
                result(nil, error)
                return
            }
            let parts = 1 << shift
            let side = image.width / parts
            let piece = image.cropping(to: CGRect(
                x: (path.x % parts) * side,
                y: (path.y % parts) * side,
                width: side,
                height: side
            ))
            guard let piece else {
                result(nil, nil)
                return
            }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = layer == .imagery
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: image.width, height: image.height), format: format)
            let draw: (UIGraphicsImageRendererContext) -> Void = { context in
                context.cgContext.interpolationQuality = .high
                UIImage(cgImage: piece).draw(in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            // The reference layers are mostly transparent, and JPEG has no
            // transparency to keep.
            result(layer == .imagery ? renderer.jpegData(withCompressionQuality: 0.9, actions: draw) : renderer.pngData(actions: draw), nil)
        }
    }

    private func fetch(_ path: MKTileOverlayPath, _ result: @escaping (Data?, (any Error)?) -> Void) {
        // A tile once fetched is used from the cache whatever its age, and
        // only fetched again if it is not there: the imagery changes over
        // years, not days, and in the field there is often no signal at all.
        let request = URLRequest(url: url(forTilePath: path), cachePolicy: .returnCacheDataElseLoad)
        TileCache.session.dataTask(with: request) { data, response, error in
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            result(ok ? data : nil, error)
        }.resume()
    }

    /// ESRI's own attribution, which its terms ask to be shown with the tiles.
    static let credit = "Esri, Maxar, Earthstar Geographics"
}

/// Where map tiles are kept, so the map still draws where the phone has no
/// signal -- over a field, or joined to a radio bridge's WiFi with nothing
/// behind it.
///
/// The system's own URL cache, given a directory of its own and room for a
/// few regions' worth of flying at every zoom. It evicts the oldest tiles by
/// itself once full, and iOS may clear it when the phone runs short of space.
nonisolated enum TileCache {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MapTiles", isDirectory: true)
        configuration.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 1 << 30, directory: directory)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: configuration)
    }()
}
