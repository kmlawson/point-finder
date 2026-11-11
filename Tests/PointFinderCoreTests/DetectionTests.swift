import CoreGraphics
import XCTest

@testable import PointFinderCore

final class DetectionTests: XCTestCase {
    /// Draws a conic graticule (converging meridians, arcs for parallels) inside
    /// a frame, with some stray strokes, and returns it with the true crossings.
    /// `interior` counts the crossings far enough inside the frame that all four arms exist.
    private func syntheticMap() -> (image: GrayImage, truth: [(lon: Int, lat: Int, p: Vec2)], interior: Int) {
        let w = 1600, h = 1100
        var data = [UInt8](repeating: 0, count: w * h)
        let apex = Vec2(800, -1500)
        var truth: [(Int, Int, Vec2)] = []
        var interior = 0
        data.withUnsafeMutableBytes { buf in
            let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            // Flip so that y runs down, as in image coordinates.
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            ctx.setFillColor(gray: 0.92, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let frame = CGRect(x: 60, y: 60, width: 1480, height: 980)
            ctx.setStrokeColor(gray: 0.1, alpha: 1)
            ctx.setLineWidth(3)
            ctx.stroke(frame)
            ctx.saveGState()
            ctx.clip(to: frame)
            ctx.setLineWidth(2)
            for m in 0..<8 {
                let a = (-21 + 6 * Double(m)) * .pi / 180
                ctx.move(to: CGPoint(x: apex.x + 1000 * sin(a), y: apex.y + 1000 * cos(a)))
                ctx.addLine(to: CGPoint(x: apex.x + 3000 * sin(a), y: apex.y + 3000 * cos(a)))
                ctx.strokePath()
            }
            for k in 0..<6 {
                let r = 1650 + 170 * Double(k)
                ctx.addArc(
                    center: CGPoint(x: apex.x, y: apex.y), radius: r, startAngle: 0, endAngle: .pi, clockwise: false)
                ctx.strokePath()
            }
            // Clutter: a wandering "river" and a diagonal "route".
            ctx.setLineWidth(2)
            ctx.move(to: CGPoint(x: 100, y: 900))
            for i in 1...60 {
                let x = 100 + Double(i) * 22
                ctx.addLine(to: CGPoint(x: x, y: 760 + 60 * sin(Double(i) * 0.9) - Double(i) * 6))
            }
            ctx.strokePath()
            ctx.move(to: CGPoint(x: 900, y: 120))
            ctx.addLine(to: CGPoint(x: 1500, y: 700))
            ctx.strokePath()
            ctx.restoreGState()
            for m in 0..<8 {
                for k in 0..<6 {
                    let a = (-21 + 6 * Double(m)) * .pi / 180, r = 1650 + 170 * Double(k)
                    let p = Vec2(apex.x + r * sin(a), apex.y + r * cos(a))
                    truth.append((m, k, p))
                    if frame.insetBy(dx: 70, dy: 70).contains(CGPoint(x: p.x, y: p.y)) { interior += 1 }
                }
            }
        }
        return (GrayImage(width: w, height: h, data: data), truth, interior)
    }

    func testFindsAndNumbersAConicGraticule() throws {
        let (image, truth, interior) = syntheticMap()
        let result = detectGraticule(gray: image)
        XCTAssertGreaterThanOrEqual(result.points.count, interior - 2)

        // Every detected point lies on a true crossing, to well under a pixel.
        var matched: [(point: GridPoint, lon: Int, lat: Int)] = []
        for p in result.points {
            let nearest = truth.min { $0.p.distance(to: Vec2(p.x, p.y)) < $1.p.distance(to: Vec2(p.x, p.y)) }!
            XCTAssertLessThan(nearest.p.distance(to: Vec2(p.x, p.y)), 0.75, "point at \(p.x),\(p.y)")
            matched.append((p, nearest.lon, nearest.lat))
        }
        XCTAssertEqual(Set(matched.map { [$0.lon, $0.lat] }).count, matched.count)

        // Grid numbers step with the true meridian and parallel numbers.
        let first = matched[0]
        for m in matched {
            XCTAssertEqual(m.point.col - first.point.col, m.lon - first.lon)
            XCTAssertEqual(m.point.row - first.point.row, m.lat - first.lat)
        }
    }

    func testIndicesLeaveAGapForAMissedLine() {
        // Three transversals crossed by lines 0,1,2,3 at 0,100,300,400: line "2" of an even grid is missing.
        let transversal: [(line: Int, pos: Double)] = [(0, 0), (1, 100), (2, 300), (3, 400)]
        let index = assignIndices(count: 4, transversals: [transversal, transversal, transversal])
        XCTAssertEqual(index, [0, 1, 3, 4])
    }

    func testCurveFollowsAnArc() throws {
        let r = 3000.0
        let pts = stride(from: -0.3, through: 0.3, by: 0.01).map { Vec2(r * sin($0), r - r * cos($0)) }
        let fit = try XCTUnwrap(Curve.fit(points: pts, knotStep: 40, window: 240))
        XCTAssertLessThan(fit.maxResidual, 0.05)
        let mid = fit.curve.project(Vec2(r * sin(0.105), r - r * cos(0.105)))
        XCTAssertLessThan(abs(mid.d), 0.05)
    }
}
