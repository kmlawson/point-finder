import Foundation

struct CrossRefinement {
    var point: Vec2
    /// Fraction of each of the four arms (A-, A+, B-, B+) on which a line was found.
    var arms: [Double]
    var dirA: Vec2
    var dirB: Vec2
}

/// Result of following one line near a crossing: the line sits at `center +
/// normal * a` and runs along `dir + normal * b`.
private struct LineTrace {
    var a: Double
    var b: Double
    var armNeg: Double
    var armPos: Double
}

/// Centre of the dark dip nearest the middle of a cross-section, or nil when the
/// section has no dip deep enough to be a line.
private func dipCentre(_ profile: [Double], minContrast: Double) -> Double? {
    let n = profile.count
    guard n >= 5, let top = profile.max() else { return nil }
    let mid = Double(n - 1) / 2
    var best: Int? = nil
    for i in 1..<(n - 1) where profile[i] <= profile[i - 1] && profile[i] <= profile[i + 1] {
        if top - profile[i] < minContrast { continue }
        if let b = best {
            if abs(Double(i) - mid) < abs(Double(b) - mid) { best = i }
        } else {
            best = i
        }
    }
    guard let m = best else { return nil }
    // Centroid of the part of the dip below half depth.
    let level = profile[m] + 0.5 * (top - profile[m])
    var lo = m, hi = m
    while lo > 0 && profile[lo - 1] < level { lo -= 1 }
    while hi < n - 1 && profile[hi + 1] < level { hi += 1 }
    var sw = 0.0, swx = 0.0
    for i in lo...hi {
        let w = level - profile[i]
        sw += w
        swx += w * Double(i)
    }
    guard sw > 0 else { return Double(m) - mid }
    return swx / sw - mid
}

private func traceLine(
    gray: GrayImage, center: Vec2, dir: Vec2, otherDir: Vec2,
    halfWidth: Double, startOffset: Double, reach: Double, step: Double, minContrast: Double
) -> LineTrace? {
    let normal = dir.perp
    let along = otherDir.dot(dir), across = otherDir.dot(normal)
    var samples: [(s: Double, w: Double?)] = []
    let half = Int(halfWidth.rounded())
    var profile = [Double](repeating: 0, count: 2 * half + 1)
    var s = startOffset
    while s <= reach {
        for sign in [-1.0, 1.0] {
            let so = s * sign
            // Leave out sections that the other line of the crossing runs through.
            if abs(along) > 1e-6 {
                let wOther = so * across / along
                if abs(wOther) < halfWidth + 3 { continue }
            }
            let q = center + dir * so
            for k in -half...half {
                let p = q + normal * Double(k)
                profile[k + half] = gray.sample(p.x, p.y)
            }
            samples.append((so, dipCentre(profile, minContrast: minContrast)))
        }
        s += step
    }
    let found = samples.compactMap { smp in smp.w.map { (smp.s, $0) } }
    guard found.count >= 4 else { return nil }
    var a = median(found.map { $0.1 }), b = 0.0
    for tol in [3.0, 2.0, 1.5, 1.5] {
        let inliers = found.filter { abs($0.1 - a - b * $0.0) <= tol }
        guard inliers.count >= 4 else { return nil }
        let features = inliers.map { [1.0, $0.0] }
        guard let c = leastSquares(features: features, targets: inliers.map { $0.1 }) else { return nil }
        a = c[0]
        b = c[1]
    }
    var negTotal = 0, negHit = 0, posTotal = 0, posHit = 0
    for smp in samples {
        let hit = smp.w.map { abs($0 - a - b * smp.s) <= 1.5 } ?? false
        if smp.s < 0 {
            negTotal += 1
            if hit { negHit += 1 }
        } else {
            posTotal += 1
            if hit { posHit += 1 }
        }
    }
    return LineTrace(
        a: a, b: b,
        armNeg: negTotal > 0 ? Double(negHit) / Double(negTotal) : 0,
        armPos: posTotal > 0 ? Double(posHit) / Double(posTotal) : 0)
}

private func intersect(_ p1: Vec2, _ d1: Vec2, _ p2: Vec2, _ d2: Vec2) -> Vec2? {
    let den = d1.x * d2.y - d1.y * d2.x
    if abs(den) < 1e-9 { return nil }
    let r = p2 - p1
    let t = (r.x * d2.y - r.y * d2.x) / den
    return p1 + d1 * t
}

/// Pins down a crossing of two lines in the full-resolution image. Starting from
/// an estimate, follows each line outward on both sides, fits a straight line to
/// its centre, and intersects the two fits. Coordinates are pixel indices.
func refineCrossing(
    gray: GrayImage, estimate: Vec2, dirA: Vec2, dirB: Vec2,
    reach: Double, unit: Double, minContrast: Double
) -> CrossRefinement? {
    var p = estimate
    var dA = dirA.normalized, dB = dirB.normalized
    var arms: [Double] = [0, 0, 0, 0]
    for halfWidth in [9.0 * unit, 5.0 * unit] {
        guard
            let ta = traceLine(
                gray: gray, center: p, dir: dA, otherDir: dB, halfWidth: halfWidth,
                startOffset: 6 * unit, reach: reach, step: 2 * unit, minContrast: minContrast),
            let tb = traceLine(
                gray: gray, center: p, dir: dB, otherDir: dA, halfWidth: halfWidth,
                startOffset: 6 * unit, reach: reach, step: 2 * unit, minContrast: minContrast)
        else { return nil }
        let pa = p + dA.perp * ta.a, pb = p + dB.perp * tb.a
        let na = (dA + dA.perp * ta.b).normalized, nb = (dB + dB.perp * tb.b).normalized
        guard let x = intersect(pa, na, pb, nb) else { return nil }
        if x.distance(to: estimate) > 14 * unit { return nil }
        p = x
        dA = na
        dB = nb
        arms = [ta.armNeg, ta.armPos, tb.armNeg, tb.armPos]
    }
    return CrossRefinement(point: p, arms: arms, dirA: dA, dirB: dB)
}
