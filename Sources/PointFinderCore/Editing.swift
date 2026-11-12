import Foundation

/// The points worth a second look, most doubtful first: inferred intersections,
/// then detected ones whose confidence is below `threshold`. Points already
/// reviewed, switched off, or added by hand are left out.
public func reviewQueue(_ points: [MapPoint], threshold: Double) -> [Int] {
    points
        .filter { p in
            guard p.isGridPoint, p.enabled, !p.reviewed else { return false }
            return p.inferred || (p.quality ?? 1) < threshold
        }
        .sorted { a, b in
            if a.inferred != b.inferred { return a.inferred }
            let qa = a.quality ?? 1, qb = b.quality ?? 1
            return qa != qb ? qa < qb : a.id < b.id
        }
        .map { $0.id }
}

public enum GridStep: Sendable {
    case left, right, up, down
}

/// The point to move the selection to from point `id` in a direction. On the
/// grid this is the next intersection along the same parallel or meridian;
/// otherwise (or at the end of a line) the nearest point lying that way.
public func neighbour(of id: Int, in points: [MapPoint], step: GridStep) -> Int? {
    guard let from = points.first(where: { $0.id == id }) else { return nil }
    if let col = from.col, let row = from.row {
        let onLine = points.filter { p in
            guard let c = p.col, let r = p.row, p.id != id else { return false }
            switch step {
            case .left: return r == row && c < col
            case .right: return r == row && c > col
            case .up: return c == col && r < row
            case .down: return c == col && r > row
            }
        }
        let nearest = onLine.min { a, b in
            abs(a.col! - col) + abs(a.row! - row) < abs(b.col! - col) + abs(b.row! - row)
        }
        if let nearest { return nearest.id }
    }
    let dir: Vec2
    switch step {
    case .left: dir = Vec2(-1, 0)
    case .right: dir = Vec2(1, 0)
    case .up: dir = Vec2(0, -1)
    case .down: dir = Vec2(0, 1)
    }
    var best: (id: Int, distance: Double)? = nil
    for p in points where p.id != id {
        let d = Vec2(p.x - from.x, p.y - from.y)
        let along = d.dot(dir)
        if along <= 0 || along < abs(d.dot(dir.perp)) { continue }
        if d.length < (best?.distance ?? .infinity) { best = (p.id, d.length) }
    }
    return best?.id
}

/// Directions of the nearest parallel and meridian drawn through or near `p`.
public func nearestLineDirections(at p: Vec2, lines: [GridLine]) -> (row: Vec2, column: Vec2)? {
    func nearest(_ family: GridLine.Family) -> Vec2? {
        var best: (direction: Vec2, distance: Double)? = nil
        for line in lines where line.family == family {
            for k in 1..<max(1, line.polyline.count) {
                let a = line.polyline[k - 1], b = line.polyline[k]
                let ab = b - a
                let len = ab.length
                if len < 1e-6 { continue }
                let t = min(1, max(0, (p - a).dot(ab) / (len * len)))
                let d = (a + ab * t).distance(to: p)
                if d < (best?.distance ?? .infinity) { best = (ab * (1 / len), d) }
            }
        }
        return best?.direction
    }
    guard let row = nearest(.row), let column = nearest(.column) else { return nil }
    return (row, column)
}

/// The crossing of two lines nearest to `p` and within `radius` of it, or nil.
/// `directions` are the likely directions of the two lines; without any, a
/// range of orientations is tried. Coordinates follow `GridPoint`.
public func snapToCrossing(
    gray: GrayImage, near p: Vec2, directions: [(Vec2, Vec2)] = [], radius: Double,
    contrast: Int = 28, minArm: Double = 0.4
) -> Vec2? {
    let maxDim = max(gray.width, gray.height)
    let unit = max(1, Double(maxDim) / 5000)
    let reach = max(24, 0.012 * Double(maxDim))
    var hints = directions
    if hints.isEmpty {
        for degrees in stride(from: -40.0, through: 40.0, by: 8.0) {
            let a = degrees * .pi / 180
            hints.append((Vec2(cos(a), sin(a)), Vec2(-sin(a), cos(a))))
        }
    }
    let centre = Vec2(p.x - 0.5, p.y - 0.5)
    let step = 6 * unit
    let n = Int((radius / step).rounded(.up))
    var best: (point: Vec2, distance: Double)? = nil
    for i in -n...n {
        for j in -n...n {
            let o = Vec2(Double(i) * step, Double(j) * step)
            if o.length > radius + 0.5 * step { continue }
            for hint in hints {
                guard let r = refineCrossing(
                    gray: gray, estimate: centre + o, dirA: hint.0, dirB: hint.1, reach: reach, unit: unit,
                    minContrast: Double(contrast)),
                    let weakest = r.arms.min(), weakest >= minArm
                else { continue }
                let d = r.point.distance(to: centre)
                if d <= radius, d < (best?.distance ?? .infinity) { best = (r.point, d) }
            }
        }
    }
    return best.map { Vec2($0.point.x + 0.5, $0.point.y + 0.5) }
}
