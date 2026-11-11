import XCTest

@testable import PointFinderCore

final class SolverTests: XCTestCase {
    func testTwoDiagonalAnchorsFixTheGrid() throws {
        let s = try solveGrid(anchors: [
            GridAnchor(col: 1, row: 1, lon: 80, lat: 45),
            GridAnchor(col: 3, row: 4, lon: 90, lat: 30),
        ])
        XCTAssertTrue(s.columnsAreMeridians)
        let v = s.coordinate(col: 8, row: 0)
        XCTAssertEqual(v.lon, 115, accuracy: 1e-9)
        XCTAssertEqual(v.lat, 50, accuracy: 1e-9)
    }

    func testAnchorsOnOneLineAreRejected() {
        XCTAssertThrowsError(try solveGrid(anchors: [
            GridAnchor(col: 1, row: 1, lon: 80, lat: 45),
            GridAnchor(col: 1, row: 4, lon: 80, lat: 30),
        ]))
        XCTAssertThrowsError(try solveGrid(anchors: [GridAnchor(col: 1, row: 1, lon: 80, lat: 45)])) {
            XCTAssertEqual($0 as? SolveError, .tooFewAnchors)
        }
    }

    func testRotatedMapWhereRowsAreMeridians() throws {
        // Longitude changes down the rows; latitude across the columns.
        let s = try solveGrid(anchors: [
            GridAnchor(col: 0, row: 0, lon: 10, lat: 40),
            GridAnchor(col: 0, row: 2, lon: 20, lat: 40),
            GridAnchor(col: 3, row: 0, lon: 10, lat: 55),
        ])
        XCTAssertFalse(s.columnsAreMeridians)
        let v = s.coordinate(col: 1, row: 1)
        XCTAssertEqual(v.lon, 15, accuracy: 1e-9)
        XCTAssertEqual(v.lat, 45, accuracy: 1e-9)
    }

    func testInconsistentAnchorsAreReported() {
        XCTAssertThrowsError(try solveGrid(anchors: [
            GridAnchor(col: 0, row: 0, lon: 70, lat: 50),
            GridAnchor(col: 1, row: 1, lon: 75, lat: 45),
            GridAnchor(col: 2, row: 2, lon: 83, lat: 40),
        ])) { error in
            guard case SolveError.inconsistent = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    func testGridAcrossTheDateLine() throws {
        let s = try solveGrid(anchors: [
            GridAnchor(col: 0, row: 0, lon: 170, lat: 10),
            GridAnchor(col: 2, row: 1, lon: -170, lat: 0),
        ])
        XCTAssertEqual(s.coordinate(col: 1, row: 0).lon, 180, accuracy: 1e-9)
        XCTAssertEqual(s.coordinate(col: 3, row: 0).lon, -160, accuracy: 1e-9)
    }

    func testCalculateFillsGridPointsAndKeepsUserValues() throws {
        var points: [MapPoint] = []
        var id = 0
        for row in 0..<3 {
            for col in 0..<4 {
                points.append(MapPoint(id: id, x: Double(100 + col * 200), y: Double(100 + row * 150), col: col, row: row))
                id += 1
            }
        }
        points[0].lon = 100
        points[0].lat = 40
        points[0].source = .user
        points[5].lon = 105
        points[5].lat = 35
        points[5].source = .user
        // An added point half-way between grid lines.
        points.append(MapPoint(id: id, x: 400, y: 175))
        let summary = try calculateCoordinates(&points)
        XCTAssertEqual(summary.gridPointsFilled, 10)
        XCTAssertEqual(summary.addedPointsEstimated, 1)
        XCTAssertEqual(points[11].lon!, 115, accuracy: 1e-9)
        XCTAssertEqual(points[11].lat!, 30, accuracy: 1e-9)
        XCTAssertEqual(points[11].source, .calculated)
        XCTAssertEqual(points[0].source, .user)
        let added = points[12]
        XCTAssertEqual(added.source, .estimated)
        XCTAssertEqual(added.lon!, 107.5, accuracy: 1e-6)
        XCTAssertEqual(added.lat!, 37.5, accuracy: 1e-6)
        let snapped = summary.solution.snapped(lon: 107.4, lat: 37.6)
        XCTAssertEqual(snapped.lon, 105, accuracy: 1e-9)
        XCTAssertEqual(snapped.lat, 40, accuracy: 1e-9)
    }

    func testGCPFileUsesNegativeYAndSkipsPointsWithoutCoordinates() {
        var a = MapPoint(id: 0, x: 574.25, y: 435.5, col: 0, row: 0)
        a.lon = 75
        a.lat = 45
        a.source = .user
        var b = MapPoint(id: 1, x: 10, y: 20)
        b.lon = -0.5
        b.lat = -12.25
        b.enabled = false
        let c = MapPoint(id: 2, x: 1, y: 1, col: 1, row: 1)
        let lines = GCPFile.contents(for: [a, b, c]).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[0].hasPrefix("#CRS: GEOGCRS[\"WGS 84\""))
        XCTAssertEqual(lines[1], "mapX,mapY,sourceX,sourceY,enable,dX,dY,residual")
        XCTAssertEqual(lines[2], "75,45,574.25,-435.5,1,0,0,0")
        XCTAssertEqual(lines[3], "-0.5,-12.25,10,-20,0,0,0,0")
    }

    func testGCPFileRoundTrip() {
        var a = MapPoint(id: 0, x: 574.25, y: 435.5, col: 0, row: 0)
        a.lon = 75
        a.lat = 45
        var b = MapPoint(id: 1, x: 10, y: 20)
        b.lon = -0.5
        b.lat = -12.25
        b.enabled = false
        let read = GCPFile.parse(GCPFile.contents(for: [a, b]), firstID: 7)
        XCTAssertEqual(read.count, 2)
        XCTAssertEqual(read[0].id, 7)
        XCTAssertEqual(read[0].x, 574.25)
        XCTAssertEqual(read[0].y, 435.5)
        XCTAssertEqual(read[0].lon, 75)
        XCTAssertEqual(read[0].lat, 45)
        XCTAssertEqual(read[0].source, .user)
        XCTAssertFalse(read[0].isGridPoint)
        XCTAssertTrue(read[0].enabled)
        XCTAssertFalse(read[1].enabled)
    }

    func testParsesOlderTabSeparatedFilesAndSkipsJunk() {
        let text = "mapX\tmapY\tpixelX\tpixelY\n100\t40\t12.5\t-30\nnot a point\n"
        let read = GCPFile.parse(text)
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read[0].y, 30)
        XCTAssertEqual(read[0].lon, 100)
    }

    func testFindsThePointsFileBesideAnImage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("map.jpg")
        XCTAssertNil(GCPFile.existingFile(for: image))
        XCTAssertEqual(GCPFile.defaultFile(for: image).lastPathComponent, "map.jpg.points")
        try "x".write(to: dir.appendingPathComponent("map.points"), atomically: true, encoding: .utf8)
        XCTAssertEqual(GCPFile.existingFile(for: image)?.lastPathComponent, "map.points")
        try "x".write(to: dir.appendingPathComponent("map.jpg.points"), atomically: true, encoding: .utf8)
        XCTAssertEqual(GCPFile.existingFile(for: image)?.lastPathComponent, "map.jpg.points")
    }

    func testDetectionKeepsLoadedPointsAndAdoptsTheirCoordinates() {
        var onCrossing = MapPoint(id: 3, x: 100.5, y: 200.5)
        onCrossing.lon = 80
        onCrossing.lat = 45
        onCrossing.source = .user
        var elsewhere = MapPoint(id: 4, x: 900, y: 900)
        elsewhere.lon = 91
        elsewhere.lat = 33
        elsewhere.source = .user
        let staleGrid = MapPoint(id: 5, x: 50, y: 50, col: 9, row: 9)
        let detected = [
            GridPoint(x: 101, y: 201, col: 1, row: 1, quality: 1),
            GridPoint(x: 300, y: 201, col: 2, row: 1, quality: 1),
        ]
        let merged = mergeDetection(existing: [onCrossing, elsewhere, staleGrid], detected: detected, nextID: 10)
        XCTAssertEqual(merged.count, 3)
        let adopted = merged.first { $0.col == 1 }!
        XCTAssertEqual(adopted.id, 3)
        XCTAssertEqual(adopted.lon, 80)
        XCTAssertEqual(adopted.source, .user)
        XCTAssertEqual(adopted.x, 101)
        XCTAssertNil(merged.first { $0.col == 2 }!.lon)
        XCTAssertTrue(merged.contains { $0.id == 4 && !$0.isGridPoint && $0.lon == 91 })
        XCTAssertFalse(merged.contains { $0.id == 5 })
    }
}
