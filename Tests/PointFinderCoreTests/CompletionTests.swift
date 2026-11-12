import CoreGraphics
import XCTest

@testable import PointFinderCore

final class CompletionTests: XCTestCase {
    /// A conic graticule: 8 meridians, 6 parallels, inside a frame.
    /// `erase` lists rectangles (image pixels) wiped back to paper after drawing.
    private func syntheticMap(erase: [CGRect] = []) -> (image: GrayImage, truth: [(lon: Int, lat: Int, p: Vec2)]) {
        let w = 1600, h = 1100
        var data = [UInt8](repeating: 0, count: w * h)
        let apex = Vec2(800, -1500)
        var truth: [(Int, Int, Vec2)] = []
        data.withUnsafeMutableBytes { buf in
            let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
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
                ctx.addArc(
                    center: CGPoint(x: apex.x, y: apex.y), radius: 1650 + 170 * Double(k), startAngle: 0,
                    endAngle: .pi, clockwise: false)
                ctx.strokePath()
            }
            ctx.restoreGState()
            ctx.setFillColor(gray: 0.92, alpha: 1)
            for r in erase { ctx.fill(r) }
            for m in 0..<8 {
                for k in 0..<6 {
                    let a = (-21 + 6 * Double(m)) * .pi / 180, r = 1650 + 170 * Double(k)
                    truth.append((m, k, Vec2(apex.x + r * sin(a), apex.y + r * cos(a))))
                }
            }
        }
        return (GrayImage(width: w, height: h, data: data), truth)
    }

    /// Grid points at the true crossings inside the frame, numbered by meridian and parallel.
    private func knownPoints(_ truth: [(lon: Int, lat: Int, p: Vec2)]) -> [GridPoint] {
        truth.filter { $0.p.x > 75 && $0.p.x < 1525 && $0.p.y > 75 && $0.p.y < 1025 }
            .map { GridPoint(x: $0.p.x, y: $0.p.y, col: $0.lon, row: $0.lat, quality: 1) }
    }

    func testFindsCrossingsOfALineMissingFromHalfTheMap() throws {
        let (image, truth) = syntheticMap()
        let all = knownPoints(truth)
        // Parallel 1 is known only east of meridian 3, and one interior crossing is missing too.
        let dropped = all.filter { ($0.row == 1 && $0.col <= 3) || ($0.row == 3 && $0.col == 5) }
        XCTAssertGreaterThanOrEqual(dropped.count, 4)
        let known = all.filter { !dropped.contains($0) }
        let found = completeGrid(gray: image, known: known)
        XCTAssertEqual(found.count, dropped.count)
        for d in dropped {
            let f = try XCTUnwrap(found.first { $0.col == d.col && $0.row == d.row }, "cell \(d.col),\(d.row)")
            XCTAssertLessThan(Vec2(f.x, f.y).distance(to: Vec2(d.x, d.y)), 0.75)
            XCTAssertFalse(f.inferred)
        }
    }

    func testAddsNothingWhereTheImageShowsNoCrossing() {
        // The crossing of meridian 3 and parallel 2 is wiped out.
        let (image, truth) = syntheticMap(erase: [CGRect(x: 661, y: 452, width: 70, height: 70)])
        let known = knownPoints(truth).filter { !($0.col == 3 && $0.row == 2) }
        XCTAssertTrue(completeGrid(gray: image, known: known).isEmpty)
    }

    func testPlacesAnInferredPointWhenAsked() throws {
        let (image, truth) = syntheticMap(erase: [CGRect(x: 661, y: 452, width: 70, height: 70)])
        let target = try XCTUnwrap(truth.first { $0.lon == 3 && $0.lat == 2 })
        let known = knownPoints(truth).filter { !($0.col == 3 && $0.row == 2) }
        var params = CompletionParams()
        params.placeInferred = true
        params.region = PixelRect(minX: 600, minY: 400, maxX: 800, maxY: 580)
        let found = completeGrid(gray: image, known: known, params: params)
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found[0].inferred)
        XCTAssertEqual([found[0].col, found[0].row], [3, 2])
        XCTAssertLessThan(Vec2(found[0].x, found[0].y).distance(to: target.p), 3)
    }

    func testRegionLimitsTheSearch() {
        let (image, truth) = syntheticMap()
        let all = knownPoints(truth)
        let dropped = all.filter { $0.row == 3 && ($0.col == 2 || $0.col == 5) }
        XCTAssertEqual(dropped.count, 2)
        let known = all.filter { !dropped.contains($0) }
        let keep = dropped.first { $0.col == 5 }!
        var params = CompletionParams()
        params.region = PixelRect(minX: keep.x - 60, minY: keep.y - 60, maxX: keep.x + 60, maxY: keep.y + 60)
        let found = completeGrid(gray: image, known: known, params: params)
        XCTAssertEqual(found.map { [$0.col, $0.row] }, [[5, 3]])
    }

    func testNewLinesOnlyWhenAllowedAndNeverOnTheFrame() {
        let (image, truth) = syntheticMap()
        let all = knownPoints(truth)
        // Forget the westernmost and the southernmost known lines entirely.
        let minCol = all.map { $0.col }.min()!, maxRow = all.map { $0.row }.max()!
        let known = all.filter { $0.col != minCol && $0.row != maxRow }
        XCTAssertTrue(completeGrid(gray: image, known: known).isEmpty)

        var params = CompletionParams()
        params.allowNewLines = true
        let found = completeGrid(gray: image, known: known, params: params)
        // A crossing right beside the frame has arms too short to confirm; the rest must be found.
        for d in all where !known.contains(d) && d.x > 160 && d.x < 1440 && d.y > 160 && d.y < 940 {
            XCTAssertTrue(found.contains { $0.col == d.col && $0.row == d.row }, "cell \(d.col),\(d.row)")
        }
        XCTAssertGreaterThanOrEqual(found.count, 5)
        for f in found {
            // Every point found is a real crossing with the right numbers, not a line meeting the frame.
            let t = truth.min { $0.p.distance(to: Vec2(f.x, f.y)) < $1.p.distance(to: Vec2(f.x, f.y)) }!
            XCTAssertLessThan(t.p.distance(to: Vec2(f.x, f.y)), 0.75, "cell \(f.col),\(f.row)")
            XCTAssertEqual([f.col, f.row], [t.lon, t.lat])
        }
    }
}
