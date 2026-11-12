import Foundation

/// A rectangle in image pixels (origin top-left, y down).
public struct PixelRect: Sendable, Equatable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = min(minX, maxX)
        self.minY = min(minY, maxY)
        self.maxX = max(minX, maxX)
        self.maxY = max(minY, maxY)
    }

    public func contains(_ p: Vec2) -> Bool { p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY }
}

public struct CompletionParams: Sendable {
    /// How much darker than its surroundings a line must be (grey levels, 0-255).
    public var contrast = 28
    /// Fraction of each of a crossing's four arms that must show a line.
    public var minArm = 0.4
    /// Fraction of each line that must show over three times the usual distance,
    /// both sides of the crossing taken together.
    public var minLine = 0.5
    /// How far from the predicted place a crossing may be, as a fraction of the grid spacing there.
    public var searchFraction = 0.12
    /// Only look for crossings predicted inside this rectangle.
    public var region: PixelRect?
    /// Also look one step beyond the outermost known lines.
    public var allowNewLines = false
    /// Where the image shows no crossing, still add a point at the predicted place, marked inferred.
    public var placeInferred = false
    /// Long lines known not to be graticule lines (image pixels). A crossing that
    /// one of them runs through, along one of the crossing's own lines, is ignored.
    public var avoidLines: [[Vec2]] = []

    public init() {}

    /// Settings for a second look at one area the user has picked out: more
    /// lenient than the automatic pass, allowed to start a new line just outside
    /// the known grid, and (if inference is on) to mark what it cannot confirm.
    public static func secondOpinion(
        region: PixelRect, detection: DetectionParams, avoidLines: [[Vec2]] = []
    ) -> CompletionParams {
        let l = min(1, max(0, detection.secondOpinionLeniency))
        var p = CompletionParams()
        p.contrast = max(8, Int(Double(detection.contrast) * (1 - 0.6 * l)))
        p.minArm = detection.minArm * (1 - 0.5 * l)
        p.minLine = detection.searchMinLine * (1 - 0.4 * l)
        p.searchFraction = min(0.45, detection.searchFraction * (1 + 1.4 * l))
        p.allowNewLines = detection.secondOpinionNewLines
        p.placeInferred = detection.inferMissing
        p.region = region
        p.avoidLines = avoidLines
        return p
    }
}

private struct Cell: Hashable {
    var col: Int
    var row: Int
}

private struct Prediction {
    var point: Vec2
    /// Direction of the line the prediction was made along.
    var direction: Vec2
    var alongRow: Bool
    var twoSided: Bool
}

/// Predicts where position `k` falls on a line known at other positions, from
/// the nearest known positions on both sides, and from each side alone. The
/// one-sided guesses matter where a line is broken between its two sides, as at
/// a book gutter.
private func predictAlong(_ line: [(k: Int, p: Vec2)], at k: Int) -> [(point: Vec2, direction: Vec2, twoSided: Bool)] {
    let lower = line.filter { $0.k < k && k - $0.k <= 4 }.sorted { $0.k > $1.k }
    let upper = line.filter { $0.k > k && $0.k - k <= 4 }.sorted { $0.k < $1.k }
    func fit(_ pts: [(k: Int, p: Vec2)]) -> (Vec2, Vec2)? {
        guard pts.count >= 2 else { return nil }
        let degree = min(2, pts.count - 1)
        let features = pts.map { q -> [Double] in
            let x = Double(q.k - k)
            return degree == 2 ? [1, x, x * x] : [1, x]
        }
        guard let cx = leastSquares(features: features, targets: pts.map { $0.p.x }),
              let cy = leastSquares(features: features, targets: pts.map { $0.p.y }) else { return nil }
        return (Vec2(cx[0], cy[0]), Vec2(cx[1], cy[1]).normalized)
    }
    var out: [(Vec2, Vec2, Bool)] = []
    if let l = lower.first, let u = upper.first, u.k - l.k <= 4,
       let f = fit(Array(lower.prefix(2)) + Array(upper.prefix(2))) {
        out.append((f.0, f.1, true))
    }
    for side in [lower, upper] where side.count >= 2 && abs(side[0].k - k) == 1 {
        if let f = fit(Array(side.prefix(3))) { out.append((f.0, f.1, false)) }
    }
    return out
}

/// Looks for graticule crossings that the line search missed, using the grid
/// that is already known. For every empty grid position it predicts where the
/// crossing should be from its neighbours along the row and along the column,
/// then looks for a real crossing of two lines near that spot in the image.
/// Newly found crossings help predict further ones, so a line that was missed
/// on one page is followed out from the page where it was found.
///
/// Returns only the new points. Coordinates follow `GridPoint`.
public func completeGrid(
    gray: GrayImage, known: [GridPoint], params: CompletionParams = CompletionParams()
) -> [GridPoint] {
    guard known.count >= 3 else { return [] }
    let maxDim = max(gray.width, gray.height)
    let unit = max(1, Double(maxDim) / 5000)
    let reach = max(24, 0.012 * Double(maxDim))

    // Pixel-index coordinates internally (GridPoint is half a pixel on from those).
    var grid: [Cell: Vec2] = [:]
    for p in known { grid[Cell(col: p.col, row: p.row)] = Vec2(p.x - 0.5, p.y - 0.5) }
    let cols = grid.keys.map { $0.col }, rows = grid.keys.map { $0.row }
    let grow = params.allowNewLines ? 1 : 0
    let colRange = (cols.min()! - grow)...(cols.max()! + grow)
    let rowRange = (rows.min()! - grow)...(rows.max()! + grow)

    func predictions(for cell: Cell, in grid: [Cell: Vec2]) -> [Prediction] {
        let rowLine = grid.filter { $0.key.row == cell.row }.map { (k: $0.key.col, p: $0.value) }
        let colLine = grid.filter { $0.key.col == cell.col }.map { (k: $0.key.row, p: $0.value) }
        var out: [Prediction] = []
        for p in predictAlong(colLine, at: cell.row) {
            out.append(Prediction(point: p.point, direction: p.direction, alongRow: false, twoSided: p.twoSided))
        }
        for p in predictAlong(rowLine, at: cell.col) {
            out.append(Prediction(point: p.point, direction: p.direction, alongRow: true, twoSided: p.twoSided))
        }
        // Guesses made from both sides first.
        return out.filter { $0.twoSided } + out.filter { !$0.twoSided }
    }

    /// Direction of a row (or column) line at a cell. Taken from the line itself
    /// when it is known nearby; otherwise from the neighbouring lines, carrying
    /// on the turn from one line to the next (meridians converge).
    func direction(ofRow: Bool, near cell: Cell, in grid: [Cell: Vec2]) -> Vec2? {
        func lineDirection(_ offset: Int) -> Vec2? {
            let line: [(k: Int, p: Vec2)] = ofRow
                ? grid.filter { $0.key.row == cell.row + offset }.map { ($0.key.col, $0.value) }
                : grid.filter { $0.key.col == cell.col + offset }.map { ($0.key.row, $0.value) }
            let k = ofRow ? cell.col : cell.row
            let nearest = Array(
                line.filter { abs($0.k - k) <= 4 }.sorted { (abs($0.k - k), $0.k) < (abs($1.k - k), $1.k) }.prefix(4))
            guard nearest.count >= 2 else { return nil }
            if nearest.count >= 3 {
                // The line may curve: take the slope of a parabola through its nearest points.
                let features = nearest.map { q -> [Double] in
                    let x = Double(q.k - k)
                    return [1, x, x * x]
                }
                if let cx = leastSquares(features: features, targets: nearest.map { $0.p.x }),
                   let cy = leastSquares(features: features, targets: nearest.map { $0.p.y }) {
                    return Vec2(cx[1], cy[1]).normalized
                }
            }
            // Two points give a chord, which is only a fair guide close to the cell.
            let a = nearest[0], b = nearest[1]
            if abs(a.k - k) > 1 && (a.k < k) == (b.k < k) { return nil }
            return ((b.p - a.p) * (b.k > a.k ? 1 : -1)).normalized
        }
        if let d = lineDirection(0) { return d }
        if let a = lineDirection(-1), let b = lineDirection(1) { return (a + b).normalized }
        for side in [1, -1] {
            guard let d1 = lineDirection(side) else { continue }
            guard let d2 = lineDirection(2 * side) else { return d1 }
            let turn = atan2(d2.x * d1.y - d2.y * d1.x, d2.dot(d1))
            return Vec2(d1.x * cos(turn) - d1.y * sin(turn), d1.x * sin(turn) + d1.y * cos(turn))
        }
        for side in [2, -2] {
            if let d = lineDirection(side) { return d }
        }
        return nil
    }

    /// Grid spacing around a predicted point: the nearest neighbour in its row or column, per step.
    func spacing(at p: Vec2, cell: Cell, in grid: [Cell: Vec2]) -> Double? {
        var best: Double? = nil
        for (c, q) in grid where c.row == cell.row || c.col == cell.col {
            let steps = Double(abs(c.col - cell.col) + abs(c.row - cell.row))
            if steps == 0 || steps > 3 { continue }
            let s = p.distance(to: q) / steps
            if s < (best ?? .infinity) { best = s }
        }
        return best
    }

    func angle(_ a: Vec2, _ b: Vec2) -> Double { acos(min(1, abs(a.dot(b)))) }

    /// True when a line already ruled out (the frame, a route) passes through
    /// `p` along one of the two directions: the "crossing" is with that line.
    func onAvoidedLine(_ p: Vec2, _ dirA: Vec2, _ dirB: Vec2) -> Bool {
        let q = Vec2(p.x + 0.5, p.y + 0.5)
        for line in params.avoidLines {
            for k in 1..<max(1, line.count) {
                let a = line[k - 1], b = line[k]
                let ab = b - a
                let len = ab.length
                if len < 1e-6 { continue }
                let t = (q - a).dot(ab) / (len * len)
                if t < -0.02 || t > 1.02 { continue }
                if (a + ab * t).distance(to: q) > 4 * unit { continue }
                let d = ab * (1 / len)
                if angle(d, dirA) < 4 * Double.pi / 180 || angle(d, dirB) < 4 * Double.pi / 180 { return true }
            }
        }
        return false
    }

    /// All four arms of a crossing must show a line. One may be short (the line
    /// runs into the gutter or the frame just past the crossing) when the other
    /// three are clear; an arm that is missing altogether means a line that
    /// stops on another, not a crossing.
    func fourArms(_ arms: [Double]) -> Bool {
        let s = arms.sorted()
        return s[0] >= params.minArm || (s[0] >= 0.6 * params.minArm && s[1] >= 0.75)
    }

    func inImage(_ p: Vec2) -> Bool {
        p.x >= reach && p.y >= reach && p.x <= Double(gray.width - 1) - reach && p.y <= Double(gray.height - 1) - reach
    }
    func inRegion(_ p: Vec2) -> Bool { params.region?.contains(Vec2(p.x + 0.5, p.y + 0.5)) ?? true }

    /// A real crossing of two lines near a predicted spot, or nil.
    func search(_ prediction: Prediction, cell: Cell, in grid: [Cell: Vec2]) -> (point: Vec2, quality: Double)? {
        guard let space = spacing(at: prediction.point, cell: cell, in: grid),
              let other = direction(ofRow: !prediction.alongRow, near: cell, in: grid) else { return nil }
        let rowDir = prediction.alongRow ? prediction.direction : other
        let colDir = prediction.alongRow ? other : prediction.direction
        let radius = min(60 * unit, max(10 * unit, params.searchFraction * space))
        let step = 8 * unit
        let n = Int((radius / step).rounded(.up))
        var starts: [Vec2] = []
        for i in -n...n {
            for j in -n...n {
                let o = Vec2(Double(i) * step, Double(j) * step)
                if o.length <= radius + 0.5 * step { starts.append(o) }
            }
        }
        starts.sort { ($0.length, $0.x, $0.y) < ($1.length, $1.x, $1.y) }
        let maxTurn = 8 * Double.pi / 180
        // Lettering and rivers near the spot can pass for a crossing, so look at
        // every candidate in reach and keep the clearest one.
        var best: (point: Vec2, quality: Double)? = nil
        var bestScore = -Double.infinity
        for o in starts {
            let start = prediction.point + o
            guard let r = refineCrossing(
                gray: gray, estimate: start, dirA: rowDir, dirB: colDir, reach: reach, unit: unit,
                minContrast: Double(params.contrast)),
                let weakest = r.arms.min(), fourArms(r.arms),
                r.point.distance(to: prediction.point) <= radius + 4 * unit,
                angle(r.dirA, rowDir) <= maxTurn, angle(r.dirB, colDir) <= maxTurn
            else { continue }
            // A short stroke, or a row of lettering, can look like a line close up.
            // Both lines must also carry on over three times the distance. Each
            // line is judged with its two sides together, so a crossing beside
            // the gutter or the frame, where one side is cut short, still counts.
            guard let far = refineCrossing(
                gray: gray, estimate: r.point, dirA: r.dirA, dirB: r.dirB, reach: 3 * reach, unit: unit,
                minContrast: Double(params.contrast)),
                far.point.distance(to: r.point) <= 3 * unit
            else { continue }
            let farWeakest = min(0.5 * (far.arms[0] + far.arms[1]), 0.5 * (far.arms[2] + far.arms[3]))
            if farWeakest < params.minLine { continue }
            if onAvoidedLine(r.point, r.dirA, r.dirB) { continue }
            // Never a second point on a crossing that is already known.
            if grid.values.contains(where: { $0.distance(to: r.point) < 0.4 * space }) { continue }
            // Clearer is better; so is closer to where the grid says it should be.
            let quality = min(weakest, farWeakest)
            let score = r.arms.reduce(0, +) / 4 + farWeakest
                - 0.3 * r.point.distance(to: prediction.point) / radius
            if score > bestScore {
                bestScore = score
                best = (r.point, quality)
            }
        }
        return best
    }

    var found: [GridPoint] = []
    var tried: [Cell: [Vec2]] = [:]
    for _ in 0..<12 {
        var jobs: [(cell: Cell, prediction: Prediction)] = []
        for col in colRange {
            for row in rowRange {
                let cell = Cell(col: col, row: row)
                if grid[cell] != nil { continue }
                for p in predictions(for: cell, in: grid) {
                    if !inImage(p.point) || !inRegion(p.point) { continue }
                    // Skip a spot that has already been searched for this cell.
                    if tried[cell, default: []].contains(where: { $0.distance(to: p.point) < 4 * unit }) { continue }
                    tried[cell, default: []].append(p.point)
                    jobs.append((cell, p))
                }
            }
        }
        if jobs.isEmpty { break }
        var hits = [(point: Vec2, quality: Double)?](repeating: nil, count: jobs.count)
        let snapshot = grid
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
            let hit = search(jobs[i].prediction, cell: jobs[i].cell, in: snapshot)
            lock.lock()
            hits[i] = hit
            lock.unlock()
        }
        var added = false
        for (i, job) in jobs.enumerated() {
            guard let hit = hits[i], grid[job.cell] == nil else { continue }
            grid[job.cell] = hit.point
            found.append(GridPoint(
                x: hit.point.x + 0.5, y: hit.point.y + 0.5, col: job.cell.col, row: job.cell.row,
                quality: hit.quality))
            added = true
        }
        if !added { break }
    }

    if params.placeInferred {
        // Guesses for what is still empty, from confirmed points only, and only
        // for a gap with known points on both sides of it along its row or its
        // column. Beyond the last known point there may be no map at all.
        let confirmed = grid
        for col in cols.min()!...cols.max()! {
            for row in rows.min()!...rows.max()! {
                let cell = Cell(col: col, row: row)
                if grid[cell] != nil { continue }
                guard let p = predictions(for: cell, in: confirmed).first(where: {
                    $0.twoSided && inImage($0.point) && inRegion($0.point)
                }) else { continue }
                grid[cell] = p.point
                found.append(GridPoint(
                    x: p.point.x + 0.5, y: p.point.y + 0.5, col: col, row: row, quality: 0, inferred: true))
            }
        }
    }
    return found.sorted { ($0.row, $0.col) < ($1.row, $1.col) }
}

/// Straight-sided lines through runs of neighbouring points, for display: the
/// stretches of line that the points of a guided search lie on.
public func linesThrough(_ points: [GridPoint]) -> [GridLine] {
    var out: [GridLine] = []
    for family in [GridLine.Family.row, .column] {
        let isRow = family == .row
        let byLine = Dictionary(grouping: points) { isRow ? $0.row : $0.col }
        for (index, members) in byLine.sorted(by: { $0.key < $1.key }) {
            let sorted = members.sorted { (isRow ? $0.col : $0.row) < (isRow ? $1.col : $1.row) }
            var run: [GridPoint] = []
            func flush() {
                if run.count >= 2 {
                    out.append(GridLine(family: family, index: index, polyline: run.map { Vec2($0.x, $0.y) }))
                }
                run = []
            }
            for p in sorted {
                if let last = run.last, (isRow ? p.col - last.col : p.row - last.row) != 1 { flush() }
                run.append(p)
            }
            flush()
        }
    }
    return out
}
