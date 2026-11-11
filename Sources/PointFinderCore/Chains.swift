import Foundation

/// A long smooth line assembled from tile segments.
struct Chain {
    var curve: Curve
    var points: [Vec2]
    /// Segment end points, used to measure how far the evidence reaches.
    var ends: [Vec2]
    /// Chains with the same group are pieces of one map line that do not join
    /// smoothly (for example either side of a book gutter).
    var group = 0

    static func build(points: [Vec2], ends: [Vec2], tile: Double) -> (chain: Chain, rms: Double, maxResidual: Double)? {
        guard let fit = Curve.fit(points: points, knotStep: tile / 4, window: 1.5 * tile) else { return nil }
        var curve = fit.curve
        var lo = Double.infinity, hi = -Double.infinity
        for e in ends {
            let t = (e - curve.origin).dot(curve.u)
            lo = min(lo, t)
            hi = max(hi, t)
        }
        curve.tMin = lo
        curve.tMax = hi
        return (Chain(curve: curve, points: points, ends: ends), fit.rms, fit.maxResidual)
    }
}

struct UnionFind {
    var parent: [Int]
    init(_ n: Int) { parent = Array(0..<n) }
    mutating func find(_ i: Int) -> Int {
        var r = i
        while parent[r] != r { r = parent[r] }
        var c = i
        while parent[c] != r {
            let next = parent[c]
            parent[c] = r
            c = next
        }
        return r
    }
    mutating func union(_ a: Int, _ b: Int) {
        let ra = find(a), rb = find(b)
        if ra != rb { parent[ra] = rb }
    }
}

/// Joins tile segments that continue one another into chains.
func linkSegments(_ segments: [LineSegment], tileSize: Int) -> [Chain] {
    let stride = Double(tileSize) / 2
    let linkDistance = 2.2 * stride
    var buckets: [Int64: [Int]] = [:]
    func key(_ bx: Int, _ by: Int) -> Int64 { Int64(bx) &* 1_000_003 &+ Int64(by) }
    for (i, s) in segments.enumerated() {
        buckets[key(Int(s.p.x / linkDistance), Int(s.p.y / linkDistance)), default: []].append(i)
    }
    var uf = UnionFind(segments.count)
    for (i, s) in segments.enumerated() {
        let bx = Int(s.p.x / linkDistance), by = Int(s.p.y / linkDistance)
        for dy in -1...1 {
            for dx in -1...1 {
                guard let list = buckets[key(bx + dx, by + dy)] else { continue }
                for j in list where j > i {
                    let t = segments[j]
                    let delta = t.p - s.p
                    let dist = delta.length
                    if dist > linkDistance { continue }
                    var dt = t.d
                    let dot = s.d.dot(dt)
                    if dot < 0 { dt = dt * -1 }
                    let angle = acos(min(1, abs(dot)))
                    if angle > 2 * .pi / 180 + dist / 800 { continue }
                    // On an arc the chord is symmetric about the mean direction, so this
                    // offset stays near zero however much the line curves.
                    let mean = (s.d + dt).normalized
                    if abs(delta.dot(mean.perp)) > 1.5 + 0.008 * dist { continue }
                    uf.union(i, j)
                }
            }
        }
    }
    var groups: [Int: [Int]] = [:]
    for i in 0..<segments.count { groups[uf.find(i), default: []].append(i) }
    var chains: [Chain] = []
    for (_, members) in groups.sorted(by: { $0.key < $1.key }) where members.count >= 2 {
        var pts: [Vec2] = [], ends: [Vec2] = []
        for m in members {
            let s = segments[m]
            pts.append(s.p)
            pts.append(s.p + s.d * (0.35 * s.length))
            pts.append(s.p - s.d * (0.35 * s.length))
            ends.append(s.p + s.d * (0.5 * s.length))
            ends.append(s.p - s.d * (0.5 * s.length))
        }
        if let built = Chain.build(points: pts, ends: ends, tile: Double(tileSize)), built.rms < 2.5 {
            chains.append(built.chain)
        }
    }
    chains.sort { ($0.curve.origin.x, $0.curve.origin.y) < ($1.curve.origin.x, $1.curve.origin.y) }
    return chains
}

/// How well chain `b` carries on from chain `a`.
struct Continuation {
    /// Distance between the facing ends along a's axis (0 when they overlap).
    var gap: Double
    /// Typical sideways miss of b from a's projected path.
    var deviation: Double
    /// Difference in direction, radians.
    var angle: Double
    var overlapping: Bool
    /// Which end of `a` faces `b`: +1 its high end, -1 its low end.
    var side: Int
}

func continuation(from a: Chain, to b: Chain, tile: Double) -> Continuation? {
    let ca = a.curve
    let bSamples: [(t: Double, n: Double)] = b.points.map {
        let r = $0 - ca.origin
        return (r.dot(ca.u), r.dot(ca.v))
    }
    guard let lo = bSamples.map({ $0.t }).min(), let hi = bSamples.map({ $0.t }).max() else { return nil }
    let overlap = min(hi, ca.tMax) - max(lo, ca.tMin)
    if overlap > tile {
        let inside = bSamples.filter { $0.t >= ca.tMin && $0.t <= ca.tMax }
        guard !inside.isEmpty else { return nil }
        let dev = median(inside.map { abs($0.n - ca.offset($0.t)) })
        return Continuation(gap: 0, deviation: dev, angle: 0, overlapping: true, side: 0)
    }
    let side = (lo + hi) / 2 > (ca.tMin + ca.tMax) / 2 ? 1 : -1
    let endT = side > 0 ? ca.tMax : ca.tMin
    let gap = max(0, side > 0 ? lo - ca.tMax : ca.tMin - hi)

    // Project a's last stretch forward with a local fit.
    let aSamples: [(t: Double, n: Double)] = a.points.map {
        let r = $0 - ca.origin
        return (r.dot(ca.u), r.dot(ca.v))
    }
    let aNear = aSamples.filter { abs($0.t - endT) <= 5 * tile }
    guard aNear.count >= 2 else { return nil }
    let aSpan = (aNear.map { $0.t }.max() ?? 0) - (aNear.map { $0.t }.min() ?? 0)
    guard let ac = fitQuadratic(
        aNear.map { $0.t - endT }, aNear.map { $0.n }, maxOrder: aSpan >= 3 * tile ? 2 : 1)
    else { return nil }

    let bFacing = side > 0 ? lo : hi
    let bNear = bSamples.filter { abs($0.t - bFacing) <= 2.5 * tile }
    guard bNear.count >= 2 else { return nil }
    let deviations = bNear.map { smp -> Double in
        let x = smp.t - endT
        return abs(smp.n - (ac[0] + ac[1] * x + ac[2] * x * x))
    }
    guard let bc = fitQuadratic(bNear.map { $0.t - endT }, bNear.map { $0.n }, maxOrder: 1) else { return nil }
    let xMid = bNear.map { $0.t - endT }.reduce(0, +) / Double(bNear.count)
    let predictedSlope = ac[1] + 2 * ac[2] * xMid
    return Continuation(
        gap: gap, deviation: median(deviations), angle: abs(atan(bc[1]) - atan(predictedSlope)),
        overlapping: false, side: side)
}

/// Merges chains that are pieces of the same line separated by a gap (a label,
/// dense linework), nearest pieces first. Pieces that line up only roughly —
/// the two halves of a line broken at a book gutter — keep their own shape but
/// are put in the same group.
func bridgeChains(_ input: [Chain], tile: Double, maxGap: Double) -> [Chain] {
    var chains = input
    func candidates() -> [(i: Int, j: Int, c: Continuation)] {
        var out: [(Int, Int, Continuation)] = []
        for i in 0..<chains.count {
            for j in 0..<chains.count where i != j {
                let a = chains[i].curve, b = chains[j].curve
                // Test each pair once, projecting from the longer chain.
                if a.span < b.span || (a.span == b.span && i > j) { continue }
                if abs(a.u.dot(b.u)) < 0.9 { continue }
                let mid = b.point((b.tMin + b.tMax) / 2)
                let pr = a.project(mid)
                let reach = max(0, max(pr.t - a.tMax, a.tMin - pr.t))
                if reach > maxGap + b.span || abs(pr.d) > 20 + 0.15 * reach { continue }
                if let c = continuation(from: chains[i], to: chains[j], tile: tile), c.gap <= maxGap {
                    out.append((i, j, c))
                }
            }
        }
        return out
    }

    var merged = true
    while merged {
        merged = false
        var used = Set<Int>(), remove = Set<Int>()
        for cand in candidates().sorted(by: { ($0.c.gap, $0.i, $0.j) < ($1.c.gap, $1.i, $1.j) }) {
            if used.contains(cand.i) || used.contains(cand.j) { continue }
            let c = cand.c
            let fits = c.overlapping
                ? c.deviation <= 1.5
                : c.deviation <= 2 + 0.012 * c.gap && c.angle <= (1.5 + 0.004 * c.gap) * .pi / 180
            if !fits { continue }
            let pts = chains[cand.i].points + chains[cand.j].points
            let ends = chains[cand.i].ends + chains[cand.j].ends
            guard let built = Chain.build(points: pts, ends: ends, tile: tile), built.rms <= 1.5 else { continue }
            chains[cand.i] = built.chain
            remove.insert(cand.j)
            used.insert(cand.i)
            used.insert(cand.j)
            merged = true
        }
        if !remove.isEmpty {
            chains = chains.enumerated().filter { !remove.contains($0.offset) }.map { $0.element }
        }
    }

    // Group the rougher continuations; each end of a chain joins at most one other.
    var uf = UnionFind(chains.count)
    var endTaken = Set<[Int]>()
    let loose = candidates().filter {
        !$0.c.overlapping && $0.c.deviation <= 12 + 0.04 * $0.c.gap && $0.c.angle <= 4 * .pi / 180
    }
    for cand in loose.sorted(by: { ($0.c.deviation, $0.i, $0.j) < ($1.c.deviation, $1.i, $1.j) }) {
        // The end of j that faces i is the opposite of i's facing side when the axes agree.
        let sameSense = chains[cand.i].curve.u.dot(chains[cand.j].curve.u) >= 0
        let endI = [cand.i, cand.c.side]
        let endJ = [cand.j, sameSense ? -cand.c.side : cand.c.side]
        if endTaken.contains(endI) || endTaken.contains(endJ) { continue }
        if uf.find(cand.i) == uf.find(cand.j) { continue }
        endTaken.insert(endI)
        endTaken.insert(endJ)
        uf.union(cand.i, cand.j)
    }
    for i in 0..<chains.count { chains[i].group = uf.find(i) }
    return chains
}
