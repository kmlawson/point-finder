import Foundation

/// A short straight piece of a line found inside one image tile.
struct LineSegment {
    var p: Vec2  // midpoint
    var d: Vec2  // unit direction, pointing into the half-plane angle [0, 180)
    var length: Double
    var coverage: Double
}

/// Finds straight pieces of thin dark lines that run right across overlapping
/// tiles of the mask, using a Hough transform per tile.
func findTileSegments(
    mask: [Bool], width: Int, height: Int, tileSize: Int, minCoverage: Double,
    progress: ((Double) -> Void)? = nil
) -> [LineSegment] {
    let stride = tileSize / 2
    let nx = max(1, (width - tileSize + stride - 1) / stride + 1)
    let ny = max(1, (height - tileSize + stride - 1) / stride + 1)
    let nTheta = 180
    var cosT = [Double](repeating: 0, count: nTheta), sinT = [Double](repeating: 0, count: nTheta)
    for i in 0..<nTheta {
        let a = Double(i) * .pi / Double(nTheta)
        cosT[i] = cos(a)
        sinT[i] = sin(a)
    }
    let lock = NSLock()
    var all: [LineSegment] = []
    var done = 0
    DispatchQueue.concurrentPerform(iterations: nx * ny) { index in
        let tx = index % nx, ty = index / nx
        let x0 = min(tx * stride, max(0, width - tileSize)), y0 = min(ty * stride, max(0, height - tileSize))
        let x1 = min(width, x0 + tileSize), y1 = min(height, y0 + tileSize)
        let found = houghTile(
            mask: mask, width: width, x0: x0, y0: y0, x1: x1, y1: y1,
            cosT: cosT, sinT: sinT, minCoverage: minCoverage)
        lock.lock()
        all.append(contentsOf: found)
        done += 1
        let fraction = Double(done) / Double(nx * ny)
        lock.unlock()
        if done % 32 == 0 { progress?(fraction) }
    }
    // Tiles finish in any order; sort so every run gives the same result.
    all.sort { ($0.p.x, $0.p.y, $0.d.x, $0.d.y) < ($1.p.x, $1.p.y, $1.d.x, $1.d.y) }
    return all
}

private func houghTile(
    mask: [Bool], width: Int, x0: Int, y0: Int, x1: Int, y1: Int,
    cosT: [Double], sinT: [Double], minCoverage: Double
) -> [LineSegment] {
    let tw = x1 - x0, th = y1 - y0
    guard tw >= 16, th >= 16 else { return [] }
    let cx = Double(x0 + x1 - 1) / 2, cy = Double(y0 + y1 - 1) / 2
    var xs: [Double] = [], ys: [Double] = []
    mask.withUnsafeBufferPointer { m in
        for y in y0..<y1 {
            let row = y * width
            for x in x0..<x1 where m[row + x] {
                xs.append(Double(x) - cx)
                ys.append(Double(y) - cy)
            }
        }
    }
    let count = xs.count
    let side = Double(min(tw, th))
    // Too little ink for a full-width line, or so much that any direction would match.
    if Double(count) < side * 0.5 || Double(count) > Double(tw * th) * 0.45 { return [] }

    let nTheta = cosT.count
    let rhoMax = Int((Double(tw * tw + th * th).squareRoot() / 2).rounded(.up)) + 2
    let nRho = 2 * rhoMax + 1
    var acc = [UInt16](repeating: 0, count: nTheta * nRho)
    acc.withUnsafeMutableBufferPointer { a in
        cosT.withUnsafeBufferPointer { c in
            sinT.withUnsafeBufferPointer { s in
                for i in 0..<count {
                    let x = xs[i], y = ys[i]
                    for t in 0..<nTheta {
                        let rho = x * c[t] + y * s[t]
                        let r = Int((rho + Double(rhoMax)).rounded())
                        a[t * nRho + r] &+= 1
                    }
                }
            }
        }
    }

    // Local maxima of the accumulator, strongest first.
    let minVotes = UInt16(side * 0.45)
    var peaks: [(votes: UInt16, theta: Int, rho: Int)] = []
    for t in 0..<nTheta {
        for r in 2..<(nRho - 2) {
            let v = acc[t * nRho + r]
            if v < minVotes { continue }
            var isMax = true
            search: for dt in -2...2 {
                // Stepping past 180 degrees flips the sign of rho.
                var tt = t + dt
                var flip = false
                if tt < 0 {
                    tt += nTheta
                    flip = true
                } else if tt >= nTheta {
                    tt -= nTheta
                    flip = true
                }
                for dr in -2...2 {
                    if dt == 0 && dr == 0 { continue }
                    let rr = flip ? (2 * rhoMax - r) + dr : r + dr
                    if rr < 0 || rr >= nRho { continue }
                    let o = acc[tt * nRho + rr]
                    if o > v || (o == v && (tt, rr) < (t, r)) {
                        isMax = false
                        break search
                    }
                }
            }
            if isMax { peaks.append((v, t, r)) }
        }
    }
    peaks.sort { $0.votes > $1.votes }

    var out: [LineSegment] = []
    let halfW = Double(tw) / 2, halfH = Double(th) / 2
    for peak in peaks.prefix(16) {
        var normal = Vec2(cosT[peak.theta], sinT[peak.theta])
        var rho = Double(peak.rho - rhoMax)
        var centroid = normal * rho
        // Two rounds of total-least-squares refinement on the ink near the line.
        for band in [2.5, 1.6] {
            var sx = 0.0, sy = 0.0, n = 0.0
            for i in 0..<count where abs(xs[i] * normal.x + ys[i] * normal.y - rho) <= band {
                sx += xs[i]
                sy += ys[i]
                n += 1
            }
            if n < 8 { break }
            let mx = sx / n, my = sy / n
            var sxx = 0.0, sxy = 0.0, syy = 0.0
            for i in 0..<count where abs(xs[i] * normal.x + ys[i] * normal.y - rho) <= band {
                let dx = xs[i] - mx, dy = ys[i] - my
                sxx += dx * dx
                sxy += dx * dy
                syy += dy * dy
            }
            let angle = 0.5 * atan2(2 * sxy, sxx - syy)
            let dir = Vec2(cos(angle), sin(angle))
            normal = dir.perp
            centroid = Vec2(mx, my)
            rho = centroid.dot(normal)
        }
        var dir = Vec2(normal.y, -normal.x)
        if dir.y < 0 || (dir.y == 0 && dir.x < 0) { dir = dir * -1 }

        // Clip the line to the tile to get the chord it should cover.
        let base = normal * rho
        var tLo = -Double.infinity, tHi = Double.infinity
        if abs(dir.x) > 1e-9 {
            let a = (-halfW - base.x) / dir.x, b = (halfW - base.x) / dir.x
            tLo = max(tLo, min(a, b))
            tHi = min(tHi, max(a, b))
        } else if abs(base.x) > halfW {
            continue
        }
        if abs(dir.y) > 1e-9 {
            let a = (-halfH - base.y) / dir.y, b = (halfH - base.y) / dir.y
            tLo = max(tLo, min(a, b))
            tHi = min(tHi, max(a, b))
        } else if abs(base.y) > halfH {
            continue
        }
        let chord = tHi - tLo
        if chord < side * 0.6 { continue }

        // Fraction of the chord that actually has ink on it.
        let bins = max(1, Int(chord.rounded(.down)))
        var hit = [Bool](repeating: false, count: bins)
        for i in 0..<count where abs(xs[i] * normal.x + ys[i] * normal.y - rho) <= 1.5 {
            let t = (xs[i] - base.x) * dir.x + (ys[i] - base.y) * dir.y
            let b = Int(t - tLo)
            if b >= 0 && b < bins { hit[b] = true }
        }
        var covered = 0, gap = 0, longestGap = 0
        for b in 0..<bins {
            if hit[b] || (b > 0 && hit[b - 1]) || (b + 1 < bins && hit[b + 1]) {
                covered += 1
                gap = 0
            } else {
                gap += 1
                longestGap = max(longestGap, gap)
            }
        }
        let coverage = Double(covered) / Double(bins)
        if coverage < minCoverage || Double(longestGap) > 0.1 * side { continue }

        // A line stands alone: lettering and hatching have as much ink beside
        // the candidate as on it.
        var onLine = 0, beside = 0
        for i in 0..<count {
            let off = abs(xs[i] * normal.x + ys[i] * normal.y - rho)
            if off <= 2 { onLine += 1 } else if off <= 8 { beside += 1 }
        }
        if Double(beside) > 1.5 * Double(onLine) { continue }

        let mid = base + dir * ((tLo + tHi) / 2)
        let p = Vec2(mid.x + cx, mid.y + cy)
        // Skip repeats of a line already taken from this tile.
        var duplicate = false
        for s in out {
            let off = abs((p - s.p).dot(s.d.perp))
            if off < 2.5 && abs(s.d.dot(dir)) > 0.9994 {
                duplicate = true
                break
            }
        }
        if !duplicate {
            out.append(LineSegment(p: p, d: dir, length: chord, coverage: coverage))
        }
    }
    return out
}
