import Foundation

/// Writes ground control points in the `.points` format of the QGIS Georeferencer.
///
/// Each row is `mapX,mapY,sourceX,sourceY,enable,dX,dY,residual`. Map
/// coordinates are longitude and latitude in WGS 84. Source coordinates are
/// image pixels measured from the top-left corner, with Y negative downwards,
/// which is how the Georeferencer addresses an image that has no georeference.
public enum GCPFile {
    static let wgs84 =
        "GEOGCRS[\"WGS 84\",DATUM[\"World Geodetic System 1984\","
        + "ELLIPSOID[\"WGS 84\",6378137,298.257223563,LENGTHUNIT[\"metre\",1]]],"
        + "PRIMEM[\"Greenwich\",0,ANGLEUNIT[\"degree\",0.0174532925199433]],"
        + "CS[ellipsoidal,2],AXIS[\"geodetic latitude (Lat)\",north,ORDER[1],ANGLEUNIT[\"degree\",0.0174532925199433]],"
        + "AXIS[\"geodetic longitude (Lon)\",east,ORDER[2],ANGLEUNIT[\"degree\",0.0174532925199433]],"
        + "ID[\"EPSG\",4326]]"

    private static func number(_ v: Double, decimals: Int) -> String {
        var s = String(format: "%.\(decimals)f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s == "-0" ? "0" : s
    }

    /// The file text for the points that have a coordinate. Points without one are left out.
    public static func contents(for points: [MapPoint]) -> String {
        var lines = ["#CRS: \(wgs84)", "mapX,mapY,sourceX,sourceY,enable,dX,dY,residual"]
        for p in points {
            guard let lon = p.lon, let lat = p.lat else { continue }
            lines.append([
                number(lon, decimals: 10), number(lat, decimals: 10),
                number(p.x, decimals: 3), number(-p.y, decimals: 3),
                p.enabled ? "1" : "0", "0", "0", "0",
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func write(_ points: [MapPoint], to url: URL) throws {
        try contents(for: points).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Reads a `.points` file. Each point comes back as one the user entered,
    /// numbered from `firstID`. Lines that are not points are skipped.
    public static func parse(_ text: String, firstID: Int = 0) -> [MapPoint] {
        var points: [MapPoint] = []
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(separator: line.contains(",") ? "," : "\t", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 4, let mapX = Double(fields[0]), let mapY = Double(fields[1]),
                  let srcX = Double(fields[2]), let srcY = Double(fields[3]) else { continue }
            var p = MapPoint(id: firstID + points.count, x: srcX, y: -srcY)
            p.lon = mapX
            p.lat = mapY
            p.source = .user
            if fields.count >= 5, let flag = Int(fields[4]) { p.enabled = flag != 0 }
            points.append(p)
        }
        return points
    }

    /// The control-point file that belongs to an image, if one exists beside it:
    /// `map.jpg.points` (the name QGIS looks for) or `map.points`.
    public static func existingFile(for image: URL) -> URL? {
        let candidates = [
            image.appendingPathExtension("points"),
            image.deletingPathExtension().appendingPathExtension("points"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Where a new control-point file for an image is saved by default.
    public static func defaultFile(for image: URL) -> URL {
        existingFile(for: image) ?? image.appendingPathExtension("points")
    }
}
