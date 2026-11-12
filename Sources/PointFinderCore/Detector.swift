import Foundation

public struct DetectionParams: Sendable {
    /// Longest side of the image the line search works on; larger images are reduced.
    public var maxWorkDimension = 4000
    public var ink = InkMode.anyDark
    /// How much darker than its surroundings a line must be (grey levels, 0-255).
    public var contrast = 28
    /// Tile edge for the local line search, in working pixels.
    public var tileSize = 160
    /// Fraction of a tile-crossing line that must be inked.
    public var minCoverage = 0.8
    /// Shortest line kept, as a fraction of the image's shorter side.
    public var minLineFraction = 0.25
    /// Fraction of each of a crossing's four arms that must show a line.
    public var minArm = 0.4
    /// Also mark crossings the image does not confirm: where two found lines
    /// cross under lettering or a blot, and where a found line passes through a
    /// gap in another. These points are flagged `inferred`.
    public var inferMissing = true
    /// After the lines are numbered, look for crossings they predict but the
    /// line search missed (a line found on one page only, a short or broken line).
    public var searchMissing = true
    /// How far from the predicted place that search may accept a crossing, as a
    /// fraction of the grid spacing there.
    public var searchFraction = 0.12
    /// Fraction of each line that the search must see over a long stretch.
    public var searchMinLine = 0.5
    /// Second opinion: how much more lenient than the automatic search (0 = the same, 1 = most).
    public var secondOpinionLeniency = 0.5
    /// Second opinion: may add a line one step outside the known grid.
    public var secondOpinionNewLines = true

    /// Keep the line mask in the result (diagnostics only).
    public var keepDebugMask = false

    public init() {}
}

/// An intersection of two graticule lines. Coordinates are in image pixels with
/// the origin at the top-left corner of the image and y pointing down.
public struct GridPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double
    /// Position of the meridian-like line, counted left to right.
    public var col: Int
    /// Position of the parallel-like line, counted top to bottom.
    public var row: Int
    /// Weakest arm of the crossing, 0...1.
    public var quality: Double
    /// True when the position comes from the fitted lines rather than from a
    /// crossing seen in the image.
    public var inferred = false

    public init(x: Double, y: Double, col: Int, row: Int, quality: Double, inferred: Bool = false) {
        self.x = x
        self.y = y
        self.col = col
        self.row = row
        self.quality = quality
        self.inferred = inferred
    }
}

public struct GridLine: Sendable {
    public enum Family: Sendable { case column, row }
    public var family: Family
    public var index: Int
    public var polyline: [Vec2]
}

public struct DetectionResult: Sendable {
    public var points: [GridPoint] = []
    public var lines: [GridLine] = []
    /// Every long line found before graticule filtering, for diagnostics.
    public var candidateLines: [[Vec2]] = []
    /// Long lines judged not to be part of the graticule (the frame, borders,
    /// routes). A later search must not take a crossing with one of these for a
    /// graticule crossing.
    public var rejectedLines: [[Vec2]] = []
    public var segmentCount = 0
    /// Diagnostics: tile segments, crossings that failed the arm test, and the
    /// lines dropped for crossing others of their own family.
    public var debugSegments: [[Vec2]] = []
    public var debugMask: GrayImage?
    public var debugRejectedCrossings: [Vec2] = []
    public var debugConflictLines: [[Vec2]] = []
}

/// Gives each line of one family an integer position from the spacing of its
/// crossings along the lines of the other family. A missed line leaves a gap in
/// the numbering rather than shifting it.
func assignIndices(count: Int, transversals: [[(line: Int, pos: Double)]]) -> [Int?] {
    var units: [Double?] = []
    var sortedCrossings: [[(line: Int, pos: Double)]] = []
    for crossings in transversals {
        let s = crossings.sorted { $0.pos < $1.pos }
        sortedCrossings.append(s)
        var gaps: [Double] = []
        for k in 1..<max(1, s.count) { gaps.append(s[k].pos - s[k - 1].pos) }
        if gaps.count >= 3 {
            let m = median(gaps)
            let near = gaps.filter { $0 > 0.75 * m && $0 < 1.25 * m }
            units.append(near.isEmpty ? m : near.reduce(0, +) / Double(near.count))
        } else {
            units.append(nil)
        }
    }
    let known = units.compactMap { $0 }
    let fallback = known.isEmpty ? nil : Optional(median(known))

    // votes[a][b][d] = how many transversals say line b is d steps after line a.
    var votes: [Int: [Int: [Int: Int]]] = [:]
    for (ti, s) in sortedCrossings.enumerated() {
        guard let unit = units[ti] ?? fallback, unit > 0 else { continue }
        let weight = units[ti] == nil ? 1 : 2
        for k in 1..<max(1, s.count) {
            let ratio = (s[k].pos - s[k - 1].pos) / unit
            let d = Int(ratio.rounded())
            if d < 1 || abs(ratio - Double(d)) > 0.3 { continue }
            let a = s[k - 1].line, b = s[k].line
            votes[a, default: [:]][b, default: [:]][d, default: 0] += weight
            votes[b, default: [:]][a, default: [:]][-d, default: 0] += weight
        }
    }
    var edges: [Int: [(to: Int, d: Int)]] = [:]
    for (a, targets) in votes {
        for (b, ds) in targets {
            if let best = ds.max(by: { ($0.value, -abs($0.key), $0.key) < ($1.value, -abs($1.key), $1.key) }) {
                edges[a, default: []].append((b, best.key))
            }
        }
    }
    var index = [Int?](repeating: nil, count: count)
    guard let start = edges.max(by: { ($0.value.count, -$0.key) < ($1.value.count, -$1.key) })?.key else { return index }
    index[start] = 0
    var queue = [start]
    while !queue.isEmpty {
        let a = queue.removeFirst()
        for e in edges[a] ?? [] where index[e.to] == nil {
            index[e.to] = index[a]! + e.d
            queue.append(e.to)
        }
    }
    if let lowest = index.compactMap({ $0 }).min() {
        index = index.map { $0.map { $0 - lowest } }
    }
    return index
}

public func detectGraticule(
    gray: GrayImage, params: DetectionParams = DetectionParams(),
    progress: ((String, Double) -> Void)? = nil
) -> DetectionResult {
    var result = DetectionResult()
    let maxDim = max(gray.width, gray.height)
    let scale = min(1, Double(params.maxWorkDimension) / Double(maxDim))
    progress?("Preparing image", 0.02)
    let work = gray.downscaled(by: scale)
    let toFull = 1 / scale
    func fullPoint(_ p: Vec2) -> Vec2 { Vec2((p.x + 0.5) * toFull, (p.y + 0.5) * toFull) }

    progress?("Finding thin dark lines", 0.08)
    let kernel = max(5, Int((9 * Double(max(work.width, work.height)) / 4000).rounded()) | 1)
    var mask = thinDarkMask(work, kernel: kernel, threshold: params.contrast)
    let tile = min(params.tileSize, max(32, min(work.width, work.height) / 4))
    removeSmallComponents(&mask, width: work.width, height: work.height, minExtent: tile / 2)
    if params.keepDebugMask {
        result.debugMask = GrayImage(width: work.width, height: work.height, data: mask.map { $0 ? 0 : 255 })
    }

    progress?("Searching for straight runs", 0.15)
    let segments = findTileSegments(
        mask: mask, width: work.width, height: work.height, tileSize: tile,
        minCoverage: params.minCoverage
    ) { f in progress?("Searching for straight runs", 0.15 + 0.5 * f) }
    result.segmentCount = segments.count
    result.debugSegments = segments.map {
        [fullPoint($0.p - $0.d * ($0.length / 2)), fullPoint($0.p + $0.d * ($0.length / 2))]
    }

    progress?("Joining runs into lines", 0.68)
    let tileD = Double(tile)
    var chains = linkSegments(segments, tileSize: tile)
    chains = chains.filter { $0.curve.span >= tileD }
    chains = bridgeChains(chains, tile: tileD, maxGap: 0.3 * Double(max(work.width, work.height)))
    // A line must be long, counting all the pieces of its group together.
    let minSpan = params.minLineFraction * Double(min(work.width, work.height))
    var groupSpan: [Int: Double] = [:]
    for c in chains { groupSpan[c.group, default: 0] += c.curve.span }
    chains = chains.filter { groupSpan[$0.group, default: 0] >= minSpan }

    func polyline(_ c: Curve) -> [Vec2] {
        let n = max(2, Int(c.span / tileD * 4))
        return (0...n).map { fullPoint(c.point(c.tMin + c.span * Double($0) / Double(n))) }
    }
    result.candidateLines = chains.map { polyline($0.curve) }
    guard chains.count >= 2 else { return result }

    // Split the lines into two roughly perpendicular families.
    progress?("Sorting lines into meridians and parallels", 0.74)
    var c4 = 0.0, s4 = 0.0
    for c in chains {
        let a = atan2(c.curve.u.y, c.curve.u.x)
        c4 += cos(4 * a) * c.curve.span
        s4 += sin(4 * a) * c.curve.span
    }
    let theta0 = atan2(s4, c4) / 4
    let axis0 = Vec2(cos(theta0), sin(theta0))
    // Family 0 runs along axis0. The more vertical family supplies the columns.
    let columnFamily = abs(axis0.y) >= abs(axis0.x) ? 0 : 1
    let familyAxis = [axis0, axis0.perp]
    var familyOf = [Int](repeating: 0, count: chains.count)
    for (i, c) in chains.enumerated() { familyOf[i] = abs(c.curve.u.dot(axis0)) >= 0.7071 ? 0 : 1 }
    var alive = [Bool](repeating: true, count: chains.count)

    // Graticule lines of one family never cross each other. Drop the lines that
    // do (routes, borders, rules), worst offenders first.
    let step = tileD / 2
    var conflicts: [Int: Set<Int>] = [:]
    for a in 0..<chains.count {
        for b in (a + 1)..<chains.count where familyOf[a] == familyOf[b] {
            // Only a crossing well inside both lines counts; a line that merely
            // ends on another (a meridian meeting the map frame) does not.
            let ca = chains[a].curve, cb = chains[b].curve
            let crosses = ca.intersections(with: cb, margin: 0, step: step).contains {
                $0.tSelf > ca.tMin + tileD && $0.tSelf < ca.tMax - tileD
                    && $0.tOther > cb.tMin + tileD && $0.tOther < cb.tMax - tileD
            }
            if crosses {
                conflicts[a, default: []].insert(b)
                conflicts[b, default: []].insert(a)
            }
        }
    }
    while let worst = conflicts.filter({ !$0.value.isEmpty }).max(by: {
        ($0.value.count, -chains[$0.key].curve.span, $0.key) < ($1.value.count, -chains[$1.key].curve.span, $1.key)
    }) {
        alive[worst.key] = false
        result.debugConflictLines.append(polyline(chains[worst.key].curve))
        for other in worst.value { conflicts[other]?.remove(worst.key) }
        conflicts[worst.key] = nil
    }

    // Cross every line of one family with every line of the other and pin each
    // crossing down in the full-resolution image.
    progress?("Locating intersections", 0.78)
    struct Crossing {
        var a: Int, b: Int  // chain indices: family 0, family 1
        var estimate: Vec2
        var dirA: Vec2, dirB: Vec2
        var tA: Double, tB: Double  // position along each chain's axis
        var point = Vec2(0, 0)
        var quality = 0.0
        var accepted = false
    }
    var crossings: [Crossing] = []
    for a in 0..<chains.count where alive[a] && familyOf[a] == 0 {
        for b in 0..<chains.count where alive[b] && familyOf[b] == 1 {
            let ca = chains[a].curve, cb = chains[b].curve
            for hit in ca.intersections(with: cb, margin: 0.6 * tileD, step: step) {
                if hit.point.x < 0 || hit.point.y < 0 || hit.point.x > Double(work.width - 1)
                    || hit.point.y > Double(work.height - 1) { continue }
                crossings.append(Crossing(
                    a: a, b: b, estimate: hit.point,
                    dirA: ca.tangent(hit.tSelf), dirB: cb.tangent(hit.tOther),
                    tA: hit.tSelf, tB: hit.tOther))
            }
        }
    }
    let unit = max(1, Double(maxDim) / 5000)
    let reach = max(24, 0.012 * Double(maxDim))
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: crossings.count) { i in
        let c = crossings[i]
        // Working pixel index -> full-resolution pixel index.
        let est = Vec2((c.estimate.x + 0.5) * toFull - 0.5, (c.estimate.y + 0.5) * toFull - 0.5)
        guard let r = refineCrossing(
            gray: gray, estimate: est, dirA: c.dirA, dirB: c.dirB,
            reach: reach, unit: unit, minContrast: Double(params.contrast)),
            let weakest = r.arms.min(), weakest >= params.minArm
        else { return }
        lock.lock()
        crossings[i].point = Vec2(r.point.x + 0.5, r.point.y + 0.5)
        crossings[i].quality = weakest
        crossings[i].accepted = true
        lock.unlock()
    }

    // A graticule line crosses the others cleanly. A line whose crossings are
    // mostly dead ends (a map frame, a box edge) is not part of the graticule.
    while true {
        var total = [Int](repeating: 0, count: chains.count), good = [Int](repeating: 0, count: chains.count)
        for c in crossings where alive[c.a] && alive[c.b] {
            total[c.a] += 1
            total[c.b] += 1
            if c.accepted {
                good[c.a] += 1
                good[c.b] += 1
            }
        }
        var worst: Int? = nil
        var worstRatio = 0.5
        for i in 0..<chains.count where alive[i] {
            let ratio = total[i] == 0 ? 0 : Double(good[i]) / Double(total[i])
            if ratio < worstRatio || (worst == nil && good[i] == 0) {
                worst = i
                worstRatio = ratio
            }
        }
        guard let drop = worst else { break }
        alive[drop] = false
    }
    for c in crossings where !(c.accepted && alive[c.a] && alive[c.b]) {
        result.debugRejectedCrossings.append(fullPoint(c.estimate))
    }
    let accepted = crossings.filter { $0.accepted && alive[$0.a] && alive[$0.b] }

    // Number the lines of each family. Pieces in one group share a number.
    progress?("Numbering the grid", 0.95)
    var groupIDs: [[Int]] = [[], []]
    var slot: [Int: Int] = [:]  // group -> position in its family's list
    var groupAxis: [Int: Vec2] = [:]
    var longest: [Int: Double] = [:]
    for (i, c) in chains.enumerated() where alive[i] {
        let f = familyOf[i]
        if slot[c.group] == nil {
            slot[c.group] = groupIDs[f].count
            groupIDs[f].append(c.group)
        }
        if c.curve.span > longest[c.group, default: 0] {
            longest[c.group] = c.curve.span
            groupAxis[c.group] = c.curve.u.dot(familyAxis[f]) >= 0 ? c.curve.u : c.curve.u * -1
        }
    }
    var along: [[[(line: Int, pos: Double)]]] = [
        [[(line: Int, pos: Double)]](repeating: [], count: groupIDs[0].count),
        [[(line: Int, pos: Double)]](repeating: [], count: groupIDs[1].count),
    ]
    for c in accepted {
        let ga = chains[c.a].group, gb = chains[c.b].group
        guard let sa = slot[ga], let sb = slot[gb], let ua = groupAxis[ga], let ub = groupAxis[gb] else { continue }
        along[0][sa].append((sb, c.estimate.dot(ua)))
        along[1][sb].append((sa, c.estimate.dot(ub)))
    }
    // Lines of family 0 are numbered from their order along family 1, and vice versa.
    var index: [[Int?]] = [
        assignIndices(count: groupIDs[0].count, transversals: along[1]),
        assignIndices(count: groupIDs[1].count, transversals: along[0]),
    ]
    // Number columns left to right and rows top to bottom.
    for f in 0..<2 {
        let isColumn = f == columnFamily
        var lowKey = 0.0, highKey = 0.0, lowIndex = Int.max, highIndex = Int.min
        for (i, c) in chains.enumerated() where alive[i] && familyOf[i] == f {
            guard let s = slot[c.group], let ix = index[f][s] else { continue }
            let mid = c.curve.point((c.curve.tMin + c.curve.tMax) / 2)
            let keyValue = isColumn ? mid.x : mid.y
            if ix < lowIndex {
                lowIndex = ix
                lowKey = keyValue
            }
            if ix > highIndex {
                highIndex = ix
                highKey = keyValue
            }
        }
        if highIndex > lowIndex && highKey < lowKey {
            index[f] = index[f].map { $0.map { highIndex - $0 } }
        }
    }

    var seen = Set<[Int]>()
    for c in accepted.sorted(by: { $0.quality > $1.quality }) {
        guard let sa = slot[chains[c.a].group], let sb = slot[chains[c.b].group],
              let ia = index[0][sa], let ib = index[1][sb] else { continue }
        let col = columnFamily == 0 ? ia : ib, row = columnFamily == 0 ? ib : ia
        if !seen.insert([col, row]).inserted { continue }
        result.points.append(GridPoint(x: c.point.x, y: c.point.y, col: col, row: row, quality: c.quality))
    }

    for (i, c) in chains.enumerated() {
        let numbered = alive[i] && slot[c.group].flatMap { index[familyOf[i]][$0] } != nil
        if !numbered { result.rejectedLines.append(polyline(c.curve)) }
    }

    if params.searchMissing {
        progress?("Looking for missed crossings", 0.96)
        var completion = CompletionParams()
        completion.contrast = params.contrast
        completion.minArm = params.minArm
        completion.searchFraction = params.searchFraction
        completion.minLine = params.searchMinLine
        completion.avoidLines = result.rejectedLines
        let extra = completeGrid(gray: gray, known: result.points, params: completion)
        for p in extra { seen.insert([p.col, p.row]) }
        result.points.append(contentsOf: extra)
        result.lines.append(contentsOf: linesThrough(extra))
    }

    if params.inferMissing {
        func lineIndex(_ chain: Int) -> Int? {
            slot[chains[chain].group].flatMap { index[familyOf[chain]][$0] }
        }
        /// Grid cell of a family-0 line number and a family-1 line number.
        func cell(_ i0: Int, _ i1: Int) -> [Int] { columnFamily == 0 ? [i0, i1] : [i1, i0] }

        // Two found lines cross, but the crossing itself is hidden.
        // Only inside the stretch where both lines were actually seen: beyond a
        // line's end there may be no map (the frame, a title box).
        let slack = 4.0
        for c in crossings where !c.accepted && alive[c.a] && alive[c.b] {
            let ca = chains[c.a].curve, cb = chains[c.b].curve
            if c.tA < ca.tMin - slack || c.tA > ca.tMax + slack || c.tB < cb.tMin - slack
                || c.tB > cb.tMax + slack { continue }
            guard let ia = lineIndex(c.a), let ib = lineIndex(c.b) else { continue }
            let key = cell(ia, ib)
            if !seen.insert(key).inserted { continue }
            let p = fullPoint(c.estimate)
            result.points.append(GridPoint(x: p.x, y: p.y, col: key[0], row: key[1], quality: 0, inferred: true))
        }

        // A found line runs through a gap in a line of the other family. The
        // crossing lies on the found line, spaced like its neighbours along it.
        for i in 0..<chains.count where alive[i] {
            guard let own = lineIndex(i) else { continue }
            let f = familyOf[i]
            let curve = chains[i].curve
            var tAt: [Int: Double] = [:]
            for c in accepted {
                if f == 0, c.a == i, let k = lineIndex(c.b) { tAt[k] = c.tA }
                if f == 1, c.b == i, let k = lineIndex(c.a) { tAt[k] = c.tB }
            }
            guard let low = tAt.keys.min(), let high = tAt.keys.max(), high - low >= 2 else { continue }
            for k in (low + 1)..<high where tAt[k] == nil {
                let key = f == 0 ? cell(own, k) : cell(k, own)
                if seen.contains(key) { continue }
                // The other line must exist somewhere; take its direction from the nearest piece.
                var otherDir: Vec2? = nil
                let near = tAt.sorted { (abs($0.key - k), $0.key) < (abs($1.key - k), $1.key) }.prefix(4)
                let features = near.map { n -> [Double] in
                    let x = Double(n.key - k)
                    return near.count >= 3 ? [1, x, x * x] : [1, x]
                }
                guard let fit = leastSquares(features: features, targets: near.map { $0.value }) else { continue }
                let t = fit[0]
                if t < curve.tMin || t > curve.tMax { continue }
                let estimate = curve.point(t)
                if estimate.x < 0 || estimate.y < 0 || estimate.x > Double(work.width - 1)
                    || estimate.y > Double(work.height - 1) { continue }
                var bestDistance = Double.infinity
                for j in 0..<chains.count where alive[j] && familyOf[j] != f && lineIndex(j) == k {
                    let cj = chains[j].curve
                    let tj = min(cj.tMax, max(cj.tMin, cj.project(estimate).t))
                    let d = cj.point(tj).distance(to: estimate)
                    if d < bestDistance {
                        bestDistance = d
                        otherDir = cj.tangent(tj)
                    }
                }
                guard let otherDir else { continue }
                seen.insert(key)
                var p = fullPoint(estimate)
                var quality = 0.0, inferred = true
                // If the image does show a clean crossing here after all, use it.
                let est = Vec2((estimate.x + 0.5) * toFull - 0.5, (estimate.y + 0.5) * toFull - 0.5)
                if let r = refineCrossing(
                    gray: gray, estimate: est, dirA: curve.tangent(t), dirB: otherDir,
                    reach: reach, unit: unit, minContrast: Double(params.contrast)),
                    let weakest = r.arms.min(), weakest >= params.minArm
                {
                    p = Vec2(r.point.x + 0.5, r.point.y + 0.5)
                    quality = weakest
                    inferred = false
                }
                result.points.append(
                    GridPoint(x: p.x, y: p.y, col: key[0], row: key[1], quality: quality, inferred: inferred))
            }
        }
    }
    result.points.sort { ($0.row, $0.col) < ($1.row, $1.col) }
    for (i, c) in chains.enumerated() where alive[i] {
        let f = familyOf[i]
        guard let s = slot[c.group], let ix = index[f][s] else { continue }
        result.lines.append(GridLine(
            family: f == columnFamily ? .column : .row, index: ix, polyline: polyline(c.curve)))
    }
    progress?("Done", 1)
    return result
}
