import Foundation

/// A guess at the map's projection from the shape of its graticule.
public struct ProjectionGuess: Sendable, Equatable {
    public enum Family: String, Sendable {
        case cylindrical, conic, pseudocylindrical, curved, unknown
    }

    public var family: Family
    /// The most likely projection, in words.
    public var name: String
    /// What in the graticule points to it.
    public var evidence: [String]
    /// A PROJ string to start from, when the grid's coordinates are known well
    /// enough to fill one in. Parameters are estimates, not read from the map.
    public var proj: String?
    /// Which transformation to pick in the QGIS Georeferencer.
    public var advice: String

    /// The text saved beside the points file.
    public var report: String {
        var lines = ["Projection guess (from the shape of the graticule; an estimate, not read from the map)", ""]
        lines.append("Likely projection: \(name)")
        lines.append("")
        lines.append("Evidence:")
        lines.append(contentsOf: evidence.map { "  - \($0)" })
        if let proj {
            lines.append("")
            lines.append("PROJ string to start from (parameters estimated): \(proj)")
        }
        lines.append("")
        lines.append("Georeferencing: \(advice)")
        lines.append("")
        lines.append("The control points themselves are longitude/latitude in WGS 84 (EPSG:4326) whatever the projection.")
        return lines.joined(separator: "\n") + "\n"
    }
}

private struct LineShape {
    var index: Int
    var length: Double
    /// Bow of the line (signed), as a fraction of its length.
    var bow: Double
    /// Direction, radians, oriented by increasing index along the line.
    var angle: Double
    var points: [(k: Int, p: Vec2, lon: Double?, lat: Double?)]
}

private func shape(index: Int, _ pts: [(k: Int, p: Vec2, lon: Double?, lat: Double?)]) -> LineShape? {
    let sorted = pts.sorted { $0.k < $1.k }
    guard sorted.count >= 3, let first = sorted.first, let last = sorted.last else { return nil }
    let chord = last.p - first.p
    let length = chord.length
    guard length > 1 else { return nil }
    let u = chord * (1 / length)
    // Offset from the chord as a parabola in the distance along it.
    let xs = sorted.map { ($0.p - first.p).dot(u) - length / 2 }
    let ys = sorted.map { ($0.p - first.p).dot(u.perp) }
    let features = xs.map { [1.0, $0, $0 * $0] }
    guard let c = leastSquares(features: features, targets: ys) else { return nil }
    let bow = c[2] * (length / 2) * (length / 2) / length
    return LineShape(index: index, length: length, bow: bow, angle: atan2(u.y, u.x), points: sorted)
}

/// Guesses the projection from the grid points. Uses pixel positions and grid
/// numbers; where points also have coordinates it estimates parameters.
/// Returns nil when there are too few points to judge.
public func guessProjection(points: [MapPoint]) -> ProjectionGuess? {
    let grid = points.filter { $0.isGridPoint && $0.enabled }
    func shapes(byColumn: Bool) -> [LineShape] {
        Dictionary(grouping: grid) { byColumn ? $0.col! : $0.row! }
            .compactMap { key, members in
                shape(index: key, members.map { (byColumn ? $0.row! : $0.col!, Vec2($0.x, $0.y), $0.lon, $0.lat) })
            }
            .sorted { $0.index < $1.index }
    }
    let columns = shapes(byColumn: true), rows = shapes(byColumn: false)
    guard columns.count >= 2, rows.count >= 2 else { return nil }

    let straightLimit = 0.004
    let columnBow = median(columns.map { abs($0.bow) }), rowBow = median(rows.map { abs($0.bow) })
    let columnsStraight = columnBow < straightLimit, rowsStraight = rowBow < straightLimit
    let angles = columns.map { $0.angle }
    let spread = ((angles.max() ?? 0) - (angles.min() ?? 0)) * 180 / .pi
    let columnsParallel = spread < 0.6

    // Spacing of the parallels down the longest column, top to bottom.
    let longest = columns.max { $0.points.count < $1.points.count }!
    var spacings: [Double] = []
    for k in 1..<longest.points.count where longest.points[k].k - longest.points[k - 1].k == 1 {
        spacings.append(longest.points[k].p.distance(to: longest.points[k - 1].p))
    }
    let meanSpacing = spacings.isEmpty ? 0 : spacings.reduce(0, +) / Double(spacings.count)
    var trend = 0.0, curve = 0.0
    if spacings.count >= 2, meanSpacing > 0 {
        trend = (spacings.last! - spacings.first!) / meanSpacing
        if spacings.count >= 3 {
            let mid = spacings[spacings.count / 2]
            curve = (0.5 * (spacings.first! + spacings.last!) - mid) / meanSpacing
        }
    }
    let evenSpacing = abs(trend) < 0.03 && abs(curve) < 0.03

    var evidence: [String] = []
    evidence.append(String(
        format: "Meridians are %@ (bow %.2f%% of their length).", columnsStraight ? "straight" : "curved", columnBow * 100))
    evidence.append(String(
        format: "Parallels are %@ (bow %.2f%% of their length).", rowsStraight ? "straight" : "curved", rowBow * 100))
    evidence.append(String(
        format: "Meridians %@ (directions differ by %.1f° across the sheet).",
        columnsParallel ? "are parallel to each other" : "converge", spread))
    if !spacings.isEmpty {
        evidence.append(
            evenSpacing
                ? "Parallels are evenly spaced along a meridian."
                : String(format: "Spacing of the parallels changes by %.0f%% from top to bottom.", trend * 100))
    }

    // Longitude of the meridian that stands upright, and how fast meridians turn per degree.
    var centralLongitude: Double? = nil, coneConstant: Double? = nil, midLatitude: Double? = nil
    let withLon = columns.compactMap { c -> (lon: Double, angle: Double)? in
        c.points.compactMap { $0.lon }.first.map { ($0, c.angle) }
    }
    if withLon.count >= 2, let lon0 = withLon.first?.lon {
        let xs = withLon.map { p -> Double in
            var l = p.lon
            while l - lon0 > 180 { l -= 360 }
            while l - lon0 < -180 { l += 360 }
            return l
        }
        if let c = leastSquares(features: xs.map { [1.0, $0] }, targets: withLon.map { $0.angle }), c[1] != 0 {
            // c[1] is radians of direction per degree of longitude; the cone
            // constant is the turn per unit of longitude in the same units.
            coneConstant = abs(c[1]) * 180 / .pi
            // Upright is a direction of 90° give or take a half turn; take the
            // solution nearest the middle of the map.
            let middle = xs.reduce(0, +) / Double(xs.count)
            let options = [-1.0, 0.0, 1.0].map { (.pi / 2 + $0 * .pi - c[0]) / c[1] }
            centralLongitude = options.min { abs($0 - middle) < abs($1 - middle) }.map { wrapLongitude($0) }
        }
    }
    let lats = grid.compactMap { $0.lat }
    if let lo = lats.min(), let hi = lats.max() { midLatitude = (lo + hi) / 2 }
    func number(_ v: Double) -> String { String(format: "%g", (v * 10).rounded() / 10) }

    let warpAdvice = "use Thin Plate Spline, or Polynomial 2 or 3, so the curved graticule is followed."
    if columnsStraight && columnsParallel && rowsStraight {
        if evenSpacing {
            return ProjectionGuess(
                family: .cylindrical, name: "Equirectangular (plate carrée), or another cylindrical projection with even parallels",
                evidence: evidence, proj: "+proj=eqc +datum=WGS84",
                advice: "a Linear or Polynomial 1 transformation should fit.")
        }
        // Mercator stretches the parallels towards the pole.
        var name = "Cylindrical with unevenly spaced parallels (Mercator is the usual one)"
        if lats.count >= 2, let top = longest.points.first?.lat, let bottom = longest.points.last?.lat {
            let widerAtTop = trend < 0
            let poleAtTop = abs(top) > abs(bottom)
            name = widerAtTop == poleAtTop
                ? "Mercator (parallels spread out towards the pole)"
                : "Cylindrical with parallels closing up towards the pole (equal-area or Gall type)"
        }
        return ProjectionGuess(
            family: .cylindrical, name: name, evidence: evidence,
            proj: name.hasPrefix("Mercator") ? "+proj=merc +datum=WGS84" : nil,
            advice: "use Polynomial 2 or Thin Plate Spline: the scale changes with latitude.")
    }
    if columnsStraight && !columnsParallel && !rowsStraight {
        var kind = "Conic"
        if !spacings.isEmpty {
            if evenSpacing {
                kind = "Equidistant (simple) conic"
            } else if curve > 0.03 {
                kind = "Conic, probably Lambert conformal (parallels spread out away from the middle)"
            } else if curve < -0.03 {
                kind = "Conic, probably Albers equal-area (parallels close up away from the middle)"
            }
        }
        var proj: String? = nil
        if let n = coneConstant, n > 0, n < 1, let lon0 = centralLongitude {
            let lat0 = asin(n) * 180 / .pi * ((midLatitude ?? 1) < 0 ? -1 : 1)
            evidence.append(String(
                format: "Meridians turn %.2f° per degree of longitude, which fits a cone touching the globe near latitude %@°.",
                n, number(lat0)))
            evidence.append("The upright meridian is near longitude \(number(lon0))°.")
            let code = kind.contains("Lambert") ? "lcc" : (kind.contains("Albers") ? "aea" : "eqdc")
            proj = "+proj=\(code) +lat_1=\(number(lat0)) +lat_2=\(number(lat0)) +lat_0=\(number(lat0)) "
                + "+lon_0=\(number(lon0)) +datum=WGS84"
        }
        return ProjectionGuess(family: .conic, name: kind, evidence: evidence, proj: proj, advice: warpAdvice)
    }
    if !columnsStraight && rowsStraight {
        return ProjectionGuess(
            family: .pseudocylindrical,
            name: "Pseudocylindrical (sinusoidal, Mollweide, Robinson or similar): straight parallels, curved meridians",
            evidence: evidence, proj: nil, advice: warpAdvice)
    }
    if !columnsStraight && !rowsStraight {
        var proj: String? = nil
        if let lon0 = centralLongitude {
            evidence.append("The upright meridian is near longitude \(number(lon0))°.")
            if let lat = midLatitude {
                proj = "+proj=bonne +lat_1=\(number(lat)) +lon_0=\(number(lon0)) +datum=WGS84"
            }
        }
        return ProjectionGuess(
            family: .curved,
            name: "Bonne, polyconic or a similar projection with curved meridians and curved parallels",
            evidence: evidence, proj: proj, advice: warpAdvice)
    }
    return ProjectionGuess(
        family: .unknown, name: "Not recognised (an unusual combination of straight and curved lines)",
        evidence: evidence, proj: nil, advice: warpAdvice)
}
