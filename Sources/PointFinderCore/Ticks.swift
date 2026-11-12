import Foundation

/// A tick found on one side of the map frame.
private struct Tick {
    /// Where the tick meets the frame line (working pixels).
    var point: Vec2
    /// Position along the side, 0 at one corner and 1 at the other.
    var fraction: Double
    var length: Double
}

private func cross(_ a: Vec2, _ b: Vec2) -> Double { a.x * b.y - a.y * b.x }

/// Where two straight segments cross, or nil when they do not.
private func segmentCrossing(_ a0: Vec2, _ a1: Vec2, _ b0: Vec2, _ b1: Vec2) -> Vec2? {
    let r = a1 - a0, s = b1 - b0
    let den = cross(r, s)
    if abs(den) < 1e-9 { return nil }
    let t = cross(b0 - a0, s) / den, u = cross(b0 - a0, r) / den
    if t < 0 || t > 1 || u < 0 || u > 1 { return nil }
    return a0 + r * t
}

/// Finds the short ticks standing on one side of the frame, between two corners.
private func ticks(
    along side: Curve, from cornerA: Vec2, to cornerB: Vec2, inward: Vec2, mask: [Bool], width: Int, height: Int,
    maxLength: Int, minLength: Int
) -> [Tick] {
    func inked(_ p: Vec2) -> Bool {
        let x = Int(p.x.rounded()), y = Int(p.y.rounded())
        return x >= 0 && y >= 0 && x < width && y < height && mask[y * width + x]
    }
    let tA = side.project(cornerA).t, tB = side.project(cornerB).t
    let total = abs(tB - tA)
    guard total > 40 else { return [] }
    let n = Int(total)
    let sign = tB >= tA ? 1.0 : -1.0
    var best: [Tick] = []
    // Ticks may stand inside the frame or outside it; take whichever side has more.
    for facing in [1.0, -1.0] {
        var run = [Int](repeating: 0, count: n + 1)
        for i in 0...n {
            // The neighbouring frame line would look like one enormous tick at each corner.
            if i < 8 || i > n - 8 { continue }
            let t = tA + sign * Double(i)
            let base = side.point(t)
            let tangent = side.tangent(t)
            var normal = tangent.perp
            if normal.dot(inward) < 0 { normal = normal * -1 }
            normal = normal * facing
            var length = 0, misses = 0
            for o in 0...maxLength {
                let p = base + normal * Double(o)
                if inked(p) || inked(p + tangent) || inked(p - tangent) {
                    length = o
                    misses = 0
                } else {
                    misses += 1
                    if misses > 1 { break }
                }
            }
            run[i] = length
        }
        var found: [Tick] = []
        var i = 0
        while i <= n {
            if run[i] < minLength {
                i += 1
                continue
            }
            var j = i
            while j + 1 <= n && run[j + 1] >= minLength { j += 1 }
            // A tick is narrow. Anything wider is lettering or a blot against the frame.
            if j - i + 1 <= 10 {
                var weight = 0.0, sum = 0.0, longest = 0
                for k in i...j {
                    weight += Double(run[k])
                    sum += Double(run[k]) * Double(k)
                    longest = max(longest, run[k])
                }
                let centre = sum / weight
                found.append(Tick(
                    point: side.point(tA + sign * centre), fraction: centre / Double(n), length: Double(longest)))
            }
            i = j + 1
        }
        if found.count > best.count { best = found }
    }
    // Where long and short ticks alternate, keep the long ones (the labelled degrees).
    let lengths = best.map { $0.length }.sorted()
    if lengths.count >= 4, let longest = lengths.last {
        var gapAt = 0, gap = 0.0
        for k in 1..<lengths.count where lengths[k] - lengths[k - 1] > gap {
            gap = lengths[k] - lengths[k - 1]
            gapAt = k
        }
        if gap > 0.35 * longest, lengths.count - gapAt >= 2 {
            let cut = lengths[gapAt]
            best = best.filter { $0.length >= cut }
        }
    }
    return best
}

/// Pairs the ticks of two opposite sides, in order along the side.
private func pair(_ a: [Tick], _ b: [Tick]) -> [(Tick, Tick)] {
    let a = a.sorted { $0.fraction < $1.fraction }, b = b.sorted { $0.fraction < $1.fraction }
    if a.count == b.count { return Array(zip(a, b)) }
    // Different counts: match each tick to the one most nearly opposite it.
    var gaps: [Double] = []
    for k in 1..<max(1, a.count) { gaps.append(a[k].fraction - a[k - 1].fraction) }
    let tolerance = gaps.isEmpty ? 0.05 : 0.5 * median(gaps)
    var used = Set<Int>()
    var out: [(Tick, Tick)] = []
    for t in a {
        var bestIndex: Int? = nil
        for (j, o) in b.enumerated() where !used.contains(j) && abs(o.fraction - t.fraction) <= tolerance {
            if bestIndex == nil || abs(o.fraction - t.fraction) < abs(b[bestIndex!].fraction - t.fraction) {
                bestIndex = j
            }
        }
        if let j = bestIndex {
            used.insert(j)
            out.append((t, b[j]))
        }
    }
    return out
}

/// Detection for maps whose graticule is shown only as ticks on the frame.
/// Finds the frame, the ticks along its four sides, joins each tick to the one
/// opposite with a straight line, and reports where those lines cross.
///
/// The crossings are constructed, not seen: they are right for maps whose
/// meridians and parallels are straight (Mercator, plate carrée and other
/// cylindrical maps), and only approximate where the real lines would curve.
public func detectTickGraticule(
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
    let w = work.width, h = work.height

    progress?("Finding the frame", 0.1)
    let kernel = max(5, Int((9 * Double(max(w, h)) / 4000).rounded()) | 1)
    let mask = thinDarkMask(work, kernel: kernel, threshold: params.contrast)
    var lineMask = mask
    let tile = min(params.tileSize, max(32, min(w, h) / 4))
    removeSmallComponents(&lineMask, width: w, height: h, minExtent: tile / 2)
    let segments = findTileSegments(
        mask: lineMask, width: w, height: h, tileSize: tile, minCoverage: params.minCoverage
    ) { f in progress?("Finding the frame", 0.1 + 0.6 * f) }
    result.segmentCount = segments.count
    let tileD = Double(tile)
    var chains = linkSegments(segments, tileSize: tile).filter { $0.curve.span >= tileD }
    chains = bridgeChains(chains, tile: tileD, maxGap: 0.3 * Double(max(w, h)))
    func polyline(_ c: Curve) -> [Vec2] {
        let n = max(2, Int(c.span / tileD * 4))
        return (0...n).map { fullPoint(c.point(c.tMin + c.span * Double($0) / Double(n))) }
    }
    result.candidateLines = chains.map { polyline($0.curve) }

    // The frame: on each side, the innermost long line.
    func middle(_ c: Curve) -> Vec2 { c.point((c.tMin + c.tMax) / 2) }
    let horizontal = chains.map { $0.curve }.filter { abs($0.u.x) > 0.94 && $0.span >= 0.5 * Double(w) }
    let vertical = chains.map { $0.curve }.filter { abs($0.u.y) > 0.94 && $0.span >= 0.5 * Double(h) }
    guard let top = horizontal.filter({ middle($0).y < Double(h) / 2 }).max(by: { middle($0).y < middle($1).y }),
          let bottom = horizontal.filter({ middle($0).y >= Double(h) / 2 }).min(by: { middle($0).y < middle($1).y }),
          let left = vertical.filter({ middle($0).x < Double(w) / 2 }).max(by: { middle($0).x < middle($1).x }),
          let right = vertical.filter({ middle($0).x >= Double(w) / 2 }).min(by: { middle($0).x < middle($1).x })
    else { return result }
    func corner(_ a: Curve, _ b: Curve) -> Vec2? {
        a.intersections(with: b, margin: 3 * tileD, step: tileD / 2).first?.point
    }
    guard let topLeft = corner(top, left), let topRight = corner(top, right),
          let bottomLeft = corner(bottom, left), let bottomRight = corner(bottom, right)
    else { return result }
    let centre = (topLeft + topRight + bottomLeft + bottomRight) * 0.25

    progress?("Finding ticks on the frame", 0.75)
    let maxLength = max(12, Int(0.02 * Double(max(w, h))))
    let minLength = max(5, Int(0.002 * Double(max(w, h))))
    func side(_ c: Curve, _ a: Vec2, _ b: Vec2) -> [Tick] {
        ticks(
            along: c, from: a, to: b, inward: centre - middle(c), mask: mask, width: w, height: h,
            maxLength: maxLength, minLength: minLength)
    }
    let columns = pair(side(top, topLeft, topRight), side(bottom, bottomLeft, bottomRight))
    let rows = pair(side(left, topLeft, bottomLeft), side(right, topRight, bottomRight))
    guard !columns.isEmpty, !rows.isEmpty else { return result }

    progress?("Joining opposite ticks", 0.9)
    for (i, c) in columns.enumerated() {
        result.lines.append(GridLine(family: .column, index: i, polyline: [fullPoint(c.0.point), fullPoint(c.1.point)]))
    }
    for (j, r) in rows.enumerated() {
        result.lines.append(GridLine(family: .row, index: j, polyline: [fullPoint(r.0.point), fullPoint(r.1.point)]))
    }
    for (i, c) in columns.enumerated() {
        for (j, r) in rows.enumerated() {
            guard let p = segmentCrossing(c.0.point, c.1.point, r.0.point, r.1.point) else { continue }
            let f = fullPoint(p)
            // Confidence follows the shortest of the four ticks the crossing rests on.
            let weakest = min(min(c.0.length, c.1.length), min(r.0.length, r.1.length))
            result.points.append(GridPoint(
                x: f.x, y: f.y, col: i, row: j, quality: min(1, weakest / Double(2 * minLength))))
        }
    }
    result.points.sort { ($0.row, $0.col) < ($1.row, $1.col) }
    progress?("Done", 1)
    return result
}
