import Foundation

/// Where a point's latitude and longitude came from.
public enum CoordinateSource: String, Sendable {
    /// Typed in by the user.
    case user
    /// Worked out from the grid and the user's reference points.
    case calculated
    /// Interpolated from surrounding points (a point that is not on the grid).
    case estimated
}

/// A ground control point: a place on the image and, once known, on the globe.
/// `x`/`y` are image pixels from the top-left corner, y down.
public struct MapPoint: Identifiable, Equatable, Sendable {
    public var id: Int
    public var x: Double
    public var y: Double
    /// Grid position for detected graticule intersections; nil for points the user added.
    public var col: Int?
    public var row: Int?
    public var lon: Double?
    public var lat: Double?
    public var source: CoordinateSource?
    public var enabled = true
    /// A grid point placed from the fitted lines, not from a crossing seen in the image.
    public var inferred = false

    public init(id: Int, x: Double, y: Double, col: Int? = nil, row: Int? = nil) {
        self.id = id
        self.x = x
        self.y = y
        self.col = col
        self.row = row
    }

    public var isGridPoint: Bool { col != nil && row != nil }
    public var hasCoordinate: Bool { lon != nil && lat != nil }
}

public struct GridAnchor: Sendable {
    public var col: Int
    public var row: Int
    public var lon: Double
    public var lat: Double
    public init(col: Int, row: Int, lon: Double, lat: Double) {
        self.col = col
        self.row = row
        self.lon = lon
        self.lat = lat
    }
}

/// Longitude and latitude as straight-line functions of grid position.
public struct GridSolution: Equatable, Sendable {
    public var lonOrigin: Double
    public var lonStep: Double
    public var latOrigin: Double
    public var latStep: Double
    /// True when columns are meridians (the usual north-up map); false when the
    /// map is turned so that rows are meridians.
    public var columnsAreMeridians: Bool

    public func coordinate(col: Int, row: Int) -> (lon: Double, lat: Double) {
        let i = Double(columnsAreMeridians ? col : row), j = Double(columnsAreMeridians ? row : col)
        return (wrapLongitude(lonOrigin + lonStep * i), latOrigin + latStep * j)
    }

    /// The nearest graticule crossing to a coordinate.
    public func snapped(lon: Double, lat: Double) -> (lon: Double, lat: Double) {
        var d = lon - lonOrigin
        d -= (d / 360).rounded() * 360
        let sLon = lonOrigin + (d / lonStep).rounded() * lonStep
        let sLat = latOrigin + ((lat - latOrigin) / latStep).rounded() * latStep
        return (wrapLongitude(sLon), sLat)
    }
}

public enum SolveError: Error, LocalizedError, Equatable {
    case tooFewAnchors
    case sameLine(String)
    case inconsistent(String)

    public var errorDescription: String? {
        switch self {
        case .tooFewAnchors:
            return "Give latitude and longitude to at least two detected intersections first."
        case .sameLine(let s): return s
        case .inconsistent(let s): return s
        }
    }
}

private func fitLine(_ xs: [Double], _ ys: [Double]) -> (origin: Double, step: Double, worst: Double)? {
    guard Set(xs).count >= 2 else { return nil }
    let n = Double(xs.count)
    let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
    var sxx = 0.0, sxy = 0.0
    for (x, y) in zip(xs, ys) {
        sxx += (x - mx) * (x - mx)
        sxy += (x - mx) * (y - my)
    }
    let step = sxy / sxx
    let origin = my - step * mx
    let worst = zip(xs, ys).map { abs($1 - origin - step * $0) }.max() ?? 0
    return (origin, step, worst)
}

/// Works out the latitude and longitude of every grid line from reference
/// points. Needs points on at least two different meridians and two different
/// parallels — two points diagonal from each other are enough.
public func solveGrid(anchors: [GridAnchor]) throws -> GridSolution {
    guard anchors.count >= 2 else { throw SolveError.tooFewAnchors }
    // Keep longitudes continuous across the 180° meridian.
    let lon0 = anchors[0].lon
    let lons = anchors.map { a -> Double in
        var l = a.lon
        while l - lon0 > 180 { l -= 360 }
        while l - lon0 < -180 { l += 360 }
        return l
    }
    let lats = anchors.map { $0.lat }
    let cols = anchors.map { Double($0.col) }, rows = anchors.map { Double($0.row) }

    struct Candidate {
        var solution: GridSolution
        var error: Double
    }
    var candidates: [Candidate] = []
    for columnsAreMeridians in [true, false] {
        let i = columnsAreMeridians ? cols : rows, j = columnsAreMeridians ? rows : cols
        guard let lonFit = fitLine(i, lons), let latFit = fitLine(j, lats),
              lonFit.step != 0, latFit.step != 0 else { continue }
        let error = max(lonFit.worst / abs(lonFit.step), latFit.worst / abs(latFit.step))
        candidates.append(Candidate(
            solution: GridSolution(
                lonOrigin: lonFit.origin, lonStep: lonFit.step, latOrigin: latFit.origin, latStep: latFit.step,
                columnsAreMeridians: columnsAreMeridians),
            error: error))
    }
    guard var best = candidates.first else {
        if Set(anchors.map { $0.col }).count < 2 || Set(anchors.map { $0.row }).count < 2 {
            throw SolveError.sameLine(
                "The reference points share a grid line, so the spacing of the other direction is unknown. "
                    + "Pick two intersections that are diagonal from each other.")
        }
        throw SolveError.sameLine(
            "The reference points share a latitude or longitude. "
                + "Pick two intersections with different latitudes and different longitudes.")
    }
    for c in candidates.dropFirst() where c.error < best.error - 1e-9 { best = c }
    // Every reference point must sit on the fitted grid.
    if best.error > 0.02 {
        throw SolveError.inconsistent(
            "The reference points do not agree with a regular grid. Check the values you entered, "
                + "and that the map's lines are evenly spaced in degrees.")
    }
    return best.solution
}

/// Estimates the coordinate of an arbitrary image position from nearby points
/// whose coordinates are known, using a local quadratic (or planar) fit.
public func estimateCoordinate(
    at p: Vec2, known: [(position: Vec2, lon: Double, lat: Double)]
) -> (lon: Double, lat: Double)? {
    guard known.count >= 3 else { return nil }
    let nearest = known.sorted { $0.position.distance(to: p) < $1.position.distance(to: p) }.prefix(12)
    let scale = max(1, nearest.map { $0.position.distance(to: p) }.max() ?? 1)
    let lonRef = nearest[nearest.startIndex].lon
    func features(_ q: Vec2, quadratic: Bool) -> [Double] {
        let dx = (q.x - p.x) / scale, dy = (q.y - p.y) / scale
        return quadratic ? [1, dx, dy, dx * dx, dx * dy, dy * dy] : [1, dx, dy]
    }
    for quadratic in [nearest.count >= 9, false] {
        let rows = nearest.map { features($0.position, quadratic: quadratic) }
        let lons = nearest.map { k -> Double in
            var l = k.lon
            while l - lonRef > 180 { l -= 360 }
            while l - lonRef < -180 { l += 360 }
            return l
        }
        if let a = leastSquares(features: rows, targets: lons),
           let b = leastSquares(features: rows, targets: nearest.map { $0.lat }) {
            // The fit is centred on p, so the constant term is the value there.
            return (wrapLongitude(a[0]), min(90, max(-90, b[0])))
        }
    }
    return nil
}

public struct CalculationSummary: Equatable, Sendable {
    public var solution: GridSolution
    public var gridPointsFilled: Int
    public var addedPointsEstimated: Int
}

/// Fills in coordinates for every point from the ones the user has entered:
/// grid points exactly from the grid, added points by interpolation. Values the
/// user typed are never changed.
public func calculateCoordinates(_ points: inout [MapPoint]) throws -> CalculationSummary {
    let anchors: [GridAnchor] = points.compactMap { p in
        guard p.source == .user, let c = p.col, let r = p.row, let lon = p.lon, let lat = p.lat else { return nil }
        return GridAnchor(col: c, row: r, lon: lon, lat: lat)
    }
    let solution = try solveGrid(anchors: anchors)
    var filled = 0
    for i in points.indices where points[i].source != .user {
        guard let c = points[i].col, let r = points[i].row else { continue }
        let v = solution.coordinate(col: c, row: r)
        points[i].lon = v.lon
        points[i].lat = v.lat
        points[i].source = .calculated
        filled += 1
    }
    let known = points.compactMap { p -> (position: Vec2, lon: Double, lat: Double)? in
        guard p.source == .user || p.source == .calculated, let lon = p.lon, let lat = p.lat else { return nil }
        return (Vec2(p.x, p.y), lon, lat)
    }
    var estimated = 0
    for i in points.indices where !points[i].isGridPoint && points[i].source != .user {
        if let v = estimateCoordinate(at: Vec2(points[i].x, points[i].y), known: known) {
            points[i].lon = v.lon
            points[i].lat = v.lat
            points[i].source = .estimated
            estimated += 1
        }
    }
    return CalculationSummary(solution: solution, gridPointsFilled: filled, addedPointsEstimated: estimated)
}

/// Combines a fresh detection with the points already on the map. Points the
/// user added, moved in from a file, or gave coordinates to are kept; earlier
/// detected points are replaced. A detected intersection that lands on a kept
/// point takes over that point's coordinates instead of duplicating it.
public func mergeDetection(existing: [MapPoint], detected: [GridPoint], nextID: Int, tolerance: Double = 4)
    -> [MapPoint]
{
    var kept = existing.filter { !$0.isGridPoint || $0.source == .user }
    var out: [MapPoint] = []
    var id = nextID
    for g in detected {
        var p = MapPoint(id: id, x: g.x, y: g.y, col: g.col, row: g.row)
        p.inferred = g.inferred
        id += 1
        if let k = kept.indices.min(by: {
            Vec2(kept[$0].x, kept[$0].y).distance(to: Vec2(g.x, g.y))
                < Vec2(kept[$1].x, kept[$1].y).distance(to: Vec2(g.x, g.y))
        }), Vec2(kept[k].x, kept[k].y).distance(to: Vec2(g.x, g.y)) <= tolerance {
            let old = kept.remove(at: k)
            p.id = old.id
            p.lon = old.lon
            p.lat = old.lat
            p.source = old.hasCoordinate ? old.source : nil
            p.enabled = old.enabled
        }
        out.append(p)
    }
    // Kept points that no intersection claimed stay as free points.
    for var k in kept {
        k.col = nil
        k.row = nil
        out.append(k)
    }
    return out
}
