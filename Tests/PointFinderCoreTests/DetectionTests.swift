import CoreGraphics
import XCTest

@testable import PointFinderCore

final class DetectionTests: XCTestCase {
    /// Draws a conic graticule (converging meridians, arcs for parallels) inside
    /// a frame, with some stray strokes, and returns it with the true crossings.
    /// `interior` counts the crossings far enough inside the frame that all four arms exist.
    /// `erase` lists rectangles (image pixels) wiped back to paper after drawing.
    private func syntheticMap(erase: [CGRect] = []) -> (
        image: GrayImage, truth: [(lon: Int, lat: Int, p: Vec2)], interior: Int
    ) {
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
            ctx.setFillColor(gray: 0.92, alpha: 1)
            for r in erase { ctx.fill(r) }
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
            XCTAssertLessThan(
                nearest.p.distance(to: Vec2(p.x, p.y)), p.inferred ? 3 : 0.75, "point at \(p.x),\(p.y)")
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

    /// The detected point nearest to a true crossing, with its distance from it.
    private func nearest(_ result: DetectionResult, to p: Vec2) -> (point: GridPoint, distance: Double)? {
        result.points.map { ($0, p.distance(to: Vec2($0.x, $0.y))) }.min { $0.1 < $1.1 }
    }

    func testInfersACrossingHiddenUnderABlot() throws {
        // Meridian 3 and parallel 2 cross at about (696, 487); wipe the crossing out.
        let (image, truth, _) = syntheticMap(erase: [CGRect(x: 661, y: 452, width: 70, height: 70)])
        let target = try XCTUnwrap(truth.first { $0.lon == 3 && $0.lat == 2 })
        let neighbour = try XCTUnwrap(truth.first { $0.lon == 4 && $0.lat == 3 })

        var off = DetectionParams()
        off.inferMissing = false
        let without = detectGraticule(gray: image, params: off)
        XCTAssertGreaterThan(try XCTUnwrap(nearest(without, to: target.p)).distance, 50)
        XCTAssertFalse(without.points.contains { $0.inferred })

        let with = detectGraticule(gray: image)
        let found = try XCTUnwrap(nearest(with, to: target.p))
        XCTAssertLessThan(found.distance, 2.5)
        XCTAssertTrue(found.point.inferred)
        // It is numbered as part of the grid.
        let other = try XCTUnwrap(nearest(with, to: neighbour.p))
        XCTAssertLessThan(other.distance, 0.75)
        XCTAssertFalse(other.point.inferred)
        XCTAssertEqual(other.point.col - found.point.col, 1)
        XCTAssertEqual(other.point.row - found.point.row, 1)
        XCTAssertEqual(with.points.count, without.points.count + 1)
    }

    func testInfersCrossingsAlongALineWhereTheOtherLineIsBroken() throws {
        // Wipe out 600 px of parallel 2, too long a gap for the two ends to be joined
        // into one line. Meridians 2, 3 and 4 still run through the gap.
        let (image, truth, _) = syntheticMap(erase: [CGRect(x: 400, y: 440, width: 600, height: 62)])
        let result = detectGraticule(gray: image)
        let anchor = try XCTUnwrap(nearest(result, to: try XCTUnwrap(truth.first { $0.lon == 3 && $0.lat == 3 }).p))
        XCTAssertLessThan(anchor.distance, 0.75)
        for lon in 2...4 {
            let target = try XCTUnwrap(truth.first { $0.lon == lon && $0.lat == 2 })
            let found = try XCTUnwrap(nearest(result, to: target.p))
            XCTAssertLessThan(found.distance, 3, "meridian \(lon)")
            XCTAssertTrue(found.point.inferred, "meridian \(lon)")
            XCTAssertEqual(found.point.col - anchor.point.col, lon - 3)
            XCTAssertEqual(found.point.row - anchor.point.row, -1)
        }
        XCTAssertEqual(Set(result.points.map { [$0.col, $0.row] }).count, result.points.count)
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
