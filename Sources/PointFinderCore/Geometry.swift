import Foundation

public struct Vec2: Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.y * s) }
    public func dot(_ o: Vec2) -> Double { x * o.x + y * o.y }
    public var length: Double { (x * x + y * y).squareRoot() }
    public var normalized: Vec2 {
        let l = length
        return l > 0 ? Vec2(x / l, y / l) : Vec2(1, 0)
    }
    /// The vector rotated by +90 degrees.
    public var perp: Vec2 { Vec2(-y, x) }
    public func distance(to o: Vec2) -> Double { (self - o).length }
}

/// Solves the dense linear system `a · x = b` by Gaussian elimination with
/// partial pivoting. Returns nil when the matrix is singular.
func solveLinear(_ a: [[Double]], _ b: [Double]) -> [Double]? {
    let n = b.count
    var m = a
    var r = b
    for col in 0..<n {
        var pivot = col
        for row in (col + 1)..<max(n, col + 1) where abs(m[row][col]) > abs(m[pivot][col]) {
            pivot = row
        }
        if abs(m[pivot][col]) < 1e-12 { return nil }
        if pivot != col {
            m.swapAt(pivot, col)
            r.swapAt(pivot, col)
        }
        for row in (col + 1)..<max(n, col + 1) {
            let f = m[row][col] / m[col][col]
            if f == 0 { continue }
            for k in col..<n { m[row][k] -= f * m[col][k] }
            r[row] -= f * r[col]
        }
    }
    var x = [Double](repeating: 0, count: n)
    for row in stride(from: n - 1, through: 0, by: -1) {
        var s = r[row]
        for k in (row + 1)..<max(n, row + 1) { s -= m[row][k] * x[k] }
        x[row] = s / m[row][row]
    }
    return x
}

/// Least-squares solution of an over-determined system whose rows are
/// `features[i] · coef = targets[i]`.
func leastSquares(features: [[Double]], targets: [Double]) -> [Double]? {
    guard let k = features.first?.count, features.count >= k else { return nil }
    var ata = [[Double]](repeating: [Double](repeating: 0, count: k), count: k)
    var atb = [Double](repeating: 0, count: k)
    for (row, t) in zip(features, targets) {
        for i in 0..<k {
            atb[i] += row[i] * t
            for j in 0..<k { ata[i][j] += row[i] * row[j] }
        }
    }
    return solveLinear(ata, atb)
}

func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let s = values.sorted()
    let n = s.count
    return n % 2 == 1 ? s[n / 2] : 0.5 * (s[n / 2 - 1] + s[n / 2])
}

/// Fits `y = c0 + c1 x + c2 x^2` (or a lower order when points are few) with
/// optional weights and returns the coefficients, padded with zeros.
func fitQuadratic(_ xs: [Double], _ ys: [Double], weights: [Double]? = nil, maxOrder: Int = 2) -> [Double]? {
    let n = xs.count
    guard n >= 1 else { return nil }
    var order = min(maxOrder, n >= 6 ? 2 : (n >= 2 ? 1 : 0))
    if order >= 1, let lo = xs.min(), let hi = xs.max(), hi - lo < 1e-6 { order = 0 }
    var features = [[Double]](), targets = [Double]()
    for i in 0..<n {
        let w = (weights?[i] ?? 1).squareRoot()
        var row = [w]
        if order >= 1 { row.append(w * xs[i]) }
        if order >= 2 { row.append(w * xs[i] * xs[i]) }
        features.append(row)
        targets.append(w * ys[i])
    }
    guard var c = leastSquares(features: features, targets: targets) else { return nil }
    while c.count < 3 { c.append(0) }
    return c
}

/// A smooth, gently curving line: an offset from a straight axis, stored as
/// evenly spaced knots smoothed from the evidence around each one. Straight
/// meridians and the arcs of parallels are both represented this way.
public struct Curve: Sendable {
    public var origin: Vec2
    /// Unit vector along the axis.
    public var u: Vec2
    /// Unit normal of the axis.
    public var v: Vec2
    var knotStart: Double
    var knotStep: Double
    var knots: [Double]
    var slopes: [Double]
    /// Extent of the image evidence along the axis.
    public var tMin: Double
    public var tMax: Double

    public var span: Double { tMax - tMin }

    func offset(_ t: Double) -> Double {
        let last = knots.count - 1
        let x = (t - knotStart) / knotStep
        if x <= 0 { return knots[0] + slopes[0] * (t - knotStart) }
        if x >= Double(last) { return knots[last] + slopes[last] * (t - knotStart - Double(last) * knotStep) }
        let i = Int(x)
        let f = x - Double(i)
        // Cubic Hermite between knots keeps position and direction continuous.
        let h00 = (1 + 2 * f) * (1 - f) * (1 - f), h10 = f * (1 - f) * (1 - f)
        let h01 = f * f * (3 - 2 * f), h11 = f * f * (f - 1)
        return h00 * knots[i] + h10 * knotStep * slopes[i] + h01 * knots[i + 1] + h11 * knotStep * slopes[i + 1]
    }

    func slope(_ t: Double) -> Double {
        let last = knots.count - 1
        let x = (t - knotStart) / knotStep
        if x <= 0 { return slopes[0] }
        if x >= Double(last) { return slopes[last] }
        let i = Int(x)
        let f = x - Double(i)
        return slopes[i] * (1 - f) + slopes[i + 1] * f
    }

    public func point(_ t: Double) -> Vec2 { origin + u * t + v * offset(t) }

    public func tangent(_ t: Double) -> Vec2 { (u + v * slope(t)).normalized }

    /// Axis position of `p` and its signed distance from the curve along the normal.
    public func project(_ p: Vec2) -> (t: Double, d: Double) {
        let r = p - origin
        let t = r.dot(u)
        return (t, r.dot(v) - offset(t))
    }

    /// Fits a curve to points. Each knot is a local quadratic fit to the points
    /// within `window` of it, so the curve follows any gentle shape without a
    /// global formula. Points far from the fit are dropped and the fit repeated.
    static func fit(points: [Vec2], knotStep: Double, window: Double, outlierTolerance: Double = 2.0)
        -> (curve: Curve, rms: Double, maxResidual: Double)?
    {
        guard points.count >= 2 else { return nil }
        let n = Double(points.count)
        var mean = Vec2(0, 0)
        for p in points { mean = mean + p }
        mean = mean * (1 / n)
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for p in points {
            let d = p - mean
            sxx += d.x * d.x
            sxy += d.x * d.y
            syy += d.y * d.y
        }
        let angle = 0.5 * atan2(2 * sxy, sxx - syy)
        let u = Vec2(cos(angle), sin(angle))
        let v = u.perp
        var samples: [(t: Double, n: Double)] = points.map {
            let d = $0 - mean
            return (d.dot(u), d.dot(v))
        }
        samples.sort { $0.t < $1.t }
        guard let tMin = samples.first?.t, let tMax = samples.last?.t, tMax - tMin >= 1 else { return nil }
        let knotCount = max(2, Int(((tMax - tMin) / knotStep).rounded(.up)) + 1)
        let step = (tMax - tMin) / Double(knotCount - 1)
        var keep = [Bool](repeating: true, count: samples.count)
        var curve = Curve(
            origin: mean, u: u, v: v, knotStart: tMin, knotStep: step,
            knots: [Double](repeating: 0, count: knotCount), slopes: [Double](repeating: 0, count: knotCount),
            tMin: tMin, tMax: tMax)
        var rms = 0.0, maxRes = 0.0
        for pass in 0..<3 {
            let used = samples.indices.filter { keep[$0] }
            guard used.count >= 2 else { return nil }
            for k in 0..<knotCount {
                let tk = tMin + Double(k) * step
                var near = used.filter { abs(samples[$0].t - tk) <= window }
                if near.count < 6 {
                    // Sparse here (a gap in the evidence): bridge it from both sides.
                    let below = used.filter { samples[$0].t <= tk }.suffix(4)
                    let above = used.filter { samples[$0].t > tk }.prefix(4)
                    near = Array(below) + Array(above)
                }
                let reach = max(1, near.map { abs(samples[$0].t - tk) }.max() ?? 1) * 1.05
                let xs = near.map { samples[$0].t - tk }
                let ys = near.map { samples[$0].n }
                let ws = xs.map { x -> Double in
                    let r = abs(x) / reach
                    let w = 1 - r * r * r
                    return max(0.02, w * w * w)
                }
                guard let c = fitQuadratic(xs, ys, weights: ws) else { return nil }
                curve.knots[k] = c[0]
                curve.slopes[k] = c[1]
            }
            var sum = 0.0
            maxRes = 0
            var residuals = [Double](repeating: 0, count: samples.count)
            for i in samples.indices {
                residuals[i] = abs(samples[i].n - curve.offset(samples[i].t))
                if keep[i] {
                    sum += residuals[i] * residuals[i]
                    maxRes = max(maxRes, residuals[i])
                }
            }
            rms = (sum / Double(used.count)).squareRoot()
            if pass == 2 { break }
            let limit = max(outlierTolerance, 2.5 * rms)
            var changed = false
            for i in samples.indices {
                let k = residuals[i] <= limit
                if k != keep[i] { changed = true }
                keep[i] = k
            }
            if !changed || keep.filter({ $0 }).count < 3 { break }
        }
        return (curve, rms, maxRes)
    }

    /// Points where this curve crosses `other`, searching `margin` beyond the ends of both.
    func intersections(with other: Curve, margin: Double, step: Double) -> [(tSelf: Double, tOther: Double, point: Vec2)] {
        var out: [(Double, Double, Vec2)] = []
        let lo = tMin - margin, hi = tMax + margin
        let n = max(2, Int(((hi - lo) / step).rounded(.up)))
        let h = (hi - lo) / Double(n)
        func f(_ t: Double) -> (d: Double, tb: Double) {
            let r = other.project(point(t))
            return (r.d, r.t)
        }
        var t0 = lo
        var f0 = f(t0)
        for i in 1...n {
            let t1 = lo + Double(i) * h
            let f1 = f(t1)
            if (f0.d <= 0) != (f1.d <= 0) {
                var a = t0, b = t1, fa = f0.d
                for _ in 0..<30 {
                    let m = 0.5 * (a + b)
                    let fm = f(m).d
                    if (fa <= 0) != (fm <= 0) {
                        b = m
                    } else {
                        a = m
                        fa = fm
                    }
                }
                let t = 0.5 * (a + b)
                let tb = f(t).tb
                if tb >= other.tMin - margin && tb <= other.tMax + margin {
                    out.append((t, tb, point(t)))
                }
            }
            t0 = t1
            f0 = f1
        }
        return out
    }
}
