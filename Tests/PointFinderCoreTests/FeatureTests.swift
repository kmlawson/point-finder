import CoreGraphics
import XCTest

@testable import PointFinderCore

final class FeatureTests: XCTestCase {
    private func gridPoint(_ id: Int, _ col: Int, _ row: Int, x: Double? = nil, y: Double? = nil) -> MapPoint {
        MapPoint(id: id, x: x ?? Double(col) * 100, y: y ?? Double(row) * 100, col: col, row: row)
    }

    // MARK: Review

    func testReviewQueuePutsInferredFirstThenLowConfidence() {
        var a = gridPoint(1, 0, 0), b = gridPoint(2, 1, 0), c = gridPoint(3, 2, 0), d = gridPoint(4, 3, 0)
        var e = gridPoint(5, 4, 0), f = gridPoint(6, 5, 0)
        a.quality = 0.9
        b.quality = 0.45
        c.inferred = true
        c.quality = 0
        d.quality = 0.3
        e.quality = 0.2
        e.reviewed = true
        f.quality = 0.1
        f.enabled = false
        let added = MapPoint(id: 7, x: 5, y: 5)
        XCTAssertEqual(reviewQueue([a, b, c, d, e, f, added], threshold: 0.5), [3, 4, 2])
        XCTAssertEqual(reviewQueue([a, b, c, d], threshold: 0.4), [3, 4])
    }

    // MARK: Navigation

    func testNeighbourFollowsTheGridAndSkipsGaps() {
        // Row 0 has columns 0, 1 and 3 (2 is missing); column 1 also has row 1.
        let points = [gridPoint(1, 0, 0), gridPoint(2, 1, 0), gridPoint(3, 3, 0), gridPoint(4, 1, 1)]
        XCTAssertEqual(neighbour(of: 1, in: points, step: .right), 2)
        XCTAssertEqual(neighbour(of: 2, in: points, step: .right), 3)
        XCTAssertEqual(neighbour(of: 3, in: points, step: .left), 2)
        XCTAssertEqual(neighbour(of: 2, in: points, step: .down), 4)
        XCTAssertEqual(neighbour(of: 4, in: points, step: .up), 2)
        XCTAssertNil(neighbour(of: 1, in: points, step: .left))
    }

    func testNeighbourOfAFreePointIsTheNearestInThatDirection() {
        let points = [
            MapPoint(id: 1, x: 100, y: 100), MapPoint(id: 2, x: 300, y: 120), MapPoint(id: 3, x: 200, y: 90),
            MapPoint(id: 4, x: 110, y: 400),
        ]
        XCTAssertEqual(neighbour(of: 1, in: points, step: .right), 3)
        XCTAssertEqual(neighbour(of: 1, in: points, step: .down), 4)
        XCTAssertNil(neighbour(of: 1, in: points, step: .up))
    }

    // MARK: Snapping

    /// Two straight lines crossing at (300.4, 250.7) on paper.
    private func crossImage() -> GrayImage {
        let w = 600, h = 500
        var data = [UInt8](repeating: 0, count: w * h)
        data.withUnsafeMutableBytes { buf in
            let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            ctx.setFillColor(gray: 0.92, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setStrokeColor(gray: 0.1, alpha: 1)
            ctx.setLineWidth(2)
            ctx.move(to: CGPoint(x: 20, y: 250.7 - 280.4 * 0.1))
            ctx.addLine(to: CGPoint(x: 580, y: 250.7 + 279.6 * 0.1))
            ctx.strokePath()
            ctx.move(to: CGPoint(x: 300.4 + 230 * 0.15, y: 20.7))
            ctx.addLine(to: CGPoint(x: 300.4 - 230 * 0.15, y: 480.7))
            ctx.strokePath()
        }
        return GrayImage(width: w, height: h, data: data)
    }

    func testSnapFindsTheCrossingNearbyButNotFarAway() throws {
        let image = crossImage()
        let snapped = try XCTUnwrap(snapToCrossing(gray: image, near: Vec2(306, 245), radius: 12))
        XCTAssertLessThan(snapped.distance(to: Vec2(300.4, 250.7)), 0.75)
        XCTAssertNil(snapToCrossing(gray: image, near: Vec2(340, 300), radius: 12))
    }

    func testNearestLineDirections() throws {
        let lines = [
            GridLine(family: .row, index: 0, polyline: [Vec2(0, 100), Vec2(500, 100)]),
            GridLine(family: .row, index: 1, polyline: [Vec2(0, 300), Vec2(500, 400)]),
            GridLine(family: .column, index: 0, polyline: [Vec2(200, 0), Vec2(200, 500)]),
        ]
        let d = try XCTUnwrap(nearestLineDirections(at: Vec2(250, 340), lines: lines))
        XCTAssertEqual(abs(d.row.dot(Vec2(500, 100).normalized)), 1, accuracy: 1e-9)
        XCTAssertEqual(abs(d.column.y), 1, accuracy: 1e-9)
        XCTAssertNil(nearestLineDirections(at: Vec2(0, 0), lines: [lines[0]]))
    }

    // MARK: Margin labels

    func testParsesDegreeLabelsOnly() {
        XCTAssertEqual(parseDegreeLabel("75"), 75)
        XCTAssertEqual(parseDegreeLabel("105°"), 105)
        XCTAssertEqual(parseDegreeLabel(" 35° N"), 35)
        XCTAssertNil(parseDegreeLabel("4650"))
        XCTAssertNil(parseDegreeLabel("185"))
        XCTAssertNil(parseDegreeLabel("Kobdo"))
        XCTAssertNil(parseDegreeLabel("3a"))
        XCTAssertNil(parseDegreeLabel(""))
    }

    func testLabelSequenceOutvotesStrayLabels() throws {
        // Columns 0...5 are 75...100; an inset contributes 110 and 115 to columns 1 and 2, and a stray 8.
        let candidates: [(index: Int, value: Double)] = [
            (0, 75), (1, 80), (1, 110), (2, 85), (2, 115), (3, 90), (4, 8), (4, 95), (5, 100),
        ]
        let fit = try XCTUnwrap(fitLabelSequence(candidates))
        XCTAssertEqual(fit.origin, 75)
        XCTAssertEqual(fit.step, 5)
        XCTAssertEqual(fit.support, 6)
        XCTAssertNil(fitLabelSequence([(0, 75), (1, 80)]))
    }

    func testProposesTheGridFromLabelsAtTheLineEnds() throws {
        // Four vertical meridians and three horizontal parallels, labelled above and to the left.
        var lines: [GridLine] = [], labels: [TextLabel] = []
        for c in 0..<4 {
            let x = 200 + 150 * Double(c)
            lines.append(GridLine(family: .column, index: c, polyline: [Vec2(x, 100), Vec2(x, 600)]))
            labels.append(TextLabel(text: "\(120 - 10 * c)", center: Vec2(x + 6, 70), height: 16))
        }
        for r in 0..<3 {
            let y = 200 + 150 * Double(r)
            lines.append(GridLine(family: .row, index: r, polyline: [Vec2(100, y), Vec2(800, y)]))
            labels.append(TextLabel(text: "\(40 - 10 * r)°", center: Vec2(70, y - 4), height: 16))
        }
        labels.append(TextLabel(text: "Lake", center: Vec2(400, 300), height: 16))
        labels.append(TextLabel(text: "7", center: Vec2(275, 70), height: 16))  // between two meridians
        let p = try XCTUnwrap(proposeGrid(lines: lines, labels: labels, imageSize: 1000))
        // Longitudes fall from left to right, so they are west.
        XCTAssertEqual(p.coordinate(col: 0, row: 0).lon, -120)
        XCTAssertEqual(p.coordinate(col: 3, row: 2).lon, -90)
        XCTAssertEqual(p.coordinate(col: 0, row: 0).lat, 40)
        XCTAssertEqual(p.coordinate(col: 3, row: 2).lat, 20)
    }

    func testReferencePairIsDiagonalAndAvoidsInferredPoints() throws {
        var points: [MapPoint] = []
        var id = 1
        for r in 0..<3 {
            for c in 0..<4 {
                points.append(gridPoint(id, c, r))
                id += 1
            }
        }
        points[0].inferred = true  // the corner (0, 0)
        let pair = try XCTUnwrap(referencePair(in: points))
        let a = points.first { $0.id == pair.0 }!, b = points.first { $0.id == pair.1 }!
        XCTAssertFalse(a.inferred || b.inferred)
        XCTAssertEqual(abs(a.row! - b.row!), 2)
        XCTAssertEqual(abs(a.col! - b.col!), 3)
        XCTAssertNil(referencePair(in: Array(points.prefix(4))))  // one row only
    }

    // MARK: Projection guess

    /// Grid points for a map drawn with `project` (degrees in, pixels out; y grows downwards).
    private func grid(_ project: (Double, Double) -> Vec2, lons: [Double], lats: [Double], coordinates: Bool = true)
        -> [MapPoint]
    {
        var out: [MapPoint] = []
        for (r, lat) in lats.enumerated() {
            for (c, lon) in lons.enumerated() {
                let p = project(lon, lat)
                var m = MapPoint(id: out.count + 1, x: p.x, y: p.y, col: c, row: r)
                if coordinates {
                    m.lon = lon
                    m.lat = lat
                    m.source = .calculated
                }
                out.append(m)
            }
        }
        return out
    }

    private let lons = stride(from: 70.0, through: 140.0, by: 10.0).map { $0 }
    private let lats = stride(from: 60.0, through: 10.0, by: -10.0).map { $0 }

    func testGuessesPlateCarree() throws {
        let g = try XCTUnwrap(guessProjection(points: grid({ Vec2($0 * 20, -$1 * 20) }, lons: lons, lats: lats)))
        XCTAssertEqual(g.family, .cylindrical)
        XCTAssertTrue(g.name.hasPrefix("Equirectangular"), g.name)
    }

    func testGuessesMercator() throws {
        let g = try XCTUnwrap(guessProjection(points: grid({ lon, lat in
            Vec2(lon * 20, -1146 * log(tan(.pi / 4 + lat * .pi / 360)))
        }, lons: lons, lats: lats)))
        XCTAssertEqual(g.family, .cylindrical)
        XCTAssertTrue(g.name.hasPrefix("Mercator"), g.name)
    }

    func testGuessesAConicAndItsCone() throws {
        // Equidistant conic touching the globe at 40°N, central meridian 105°E.
        let n = sin(40 * Double.pi / 180)
        let g = try XCTUnwrap(guessProjection(points: grid({ lon, lat in
            let rho = 1146 * (1 / tan(40 * Double.pi / 180) - (lat - 40) * .pi / 180)
            let theta = n * (lon - 105) * .pi / 180
            return Vec2(rho * sin(theta), rho * cos(theta))
        }, lons: lons, lats: lats)))
        XCTAssertEqual(g.family, .conic)
        XCTAssertTrue(g.name.hasPrefix("Equidistant"), g.name)
        let proj = try XCTUnwrap(g.proj)
        XCTAssertTrue(proj.contains("+proj=eqdc"), proj)
        XCTAssertTrue(proj.contains("+lon_0=105"), proj)
        XCTAssertTrue(proj.contains("+lat_0=40"), proj)
    }

    func testGuessesPseudocylindricalAndCurved() throws {
        let sinusoidal = try XCTUnwrap(guessProjection(points: grid({ lon, lat in
            Vec2((lon - 105) * 20 * cos(lat * .pi / 180), -lat * 20)
        }, lons: lons, lats: lats)))
        XCTAssertEqual(sinusoidal.family, .pseudocylindrical)

        // Bonne: curved parallels and curved meridians.
        let phi1 = 35 * Double.pi / 180
        let bonne = try XCTUnwrap(guessProjection(points: grid({ lon, lat in
            let phi = lat * .pi / 180
            let rho = 1146 * (1 / tan(phi1) + phi1 - phi)
            let e = 1146 * (lon - 105) * .pi / 180 * cos(phi) / rho
            return Vec2(rho * sin(e), rho * cos(e))
        }, lons: lons, lats: lats)))
        XCTAssertEqual(bonne.family, .curved)
    }

    func testProjectionGuessNeedsAGrid() {
        XCTAssertNil(guessProjection(points: [gridPoint(1, 0, 0), gridPoint(2, 1, 0)]))
    }

    // MARK: Ticks

    func testJoinsTicksOnTheFrame() {
        let w = 1400, h = 1000
        var data = [UInt8](repeating: 0, count: w * h)
        let xs = stride(from: 250.0, through: 1150.0, by: 150.0).map { $0 }
        let ys = stride(from: 240.0, through: 760.0, by: 130.0).map { $0 }
        data.withUnsafeMutableBytes { buf in
            let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            ctx.setFillColor(gray: 0.92, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setStrokeColor(gray: 0.1, alpha: 1)
            ctx.setLineWidth(3)
            ctx.stroke(CGRect(x: 100, y: 100, width: 1200, height: 800))
            ctx.setLineWidth(2)
            for x in xs {
                for (y0, y1) in [(100.0, 116.0), (900.0, 884.0)] {
                    ctx.move(to: CGPoint(x: x, y: y0))
                    ctx.addLine(to: CGPoint(x: x, y: y1))
                    ctx.strokePath()
                }
            }
            for y in ys {
                for (x0, x1) in [(100.0, 116.0), (1300.0, 1284.0)] {
                    ctx.move(to: CGPoint(x: x0, y: y))
                    ctx.addLine(to: CGPoint(x: x1, y: y))
                    ctx.strokePath()
                }
            }
        }
        var params = DetectionParams()
        params.style = .ticks
        let result = detectGraticule(gray: GrayImage(width: w, height: h, data: data), params: params)
        XCTAssertEqual(result.points.count, xs.count * ys.count)
        for p in result.points {
            guard p.col >= 0, p.col < xs.count, p.row >= 0, p.row < ys.count else {
                XCTFail("cell \(p.col),\(p.row)")
                continue
            }
            XCTAssertLessThan(Vec2(p.x, p.y).distance(to: Vec2(xs[p.col], ys[p.row])), 1.5, "cell \(p.col),\(p.row)")
        }
        XCTAssertEqual(result.lines.count, xs.count + ys.count)
    }
}
