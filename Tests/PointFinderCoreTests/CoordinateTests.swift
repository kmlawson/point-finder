import XCTest

@testable import PointFinderCore

final class CoordinateTests: XCTestCase {
    func testDecimalDegrees() throws {
        XCTAssertEqual(try parseCoordinate("35.5", axis: .latitude), 35.5)
        XCTAssertEqual(try parseCoordinate(" -110 ", axis: .longitude), -110)
        XCTAssertEqual(try parseCoordinate("35,5", axis: .latitude), 35.5)
    }

    func testHemisphereLetters() throws {
        XCTAssertEqual(try parseCoordinate("35N", axis: .latitude), 35)
        XCTAssertEqual(try parseCoordinate("35 s", axis: .latitude), -35)
        XCTAssertEqual(try parseCoordinate("E110", axis: .longitude), 110)
        XCTAssertEqual(try parseCoordinate("110°W", axis: .longitude), -110)
    }

    func testDegreesMinutesSeconds() throws {
        XCTAssertEqual(try parseCoordinate("35°30'N", axis: .latitude), 35.5)
        XCTAssertEqual(try parseCoordinate("35 30 36 S", axis: .latitude), -35.51, accuracy: 1e-9)
        XCTAssertEqual(try parseCoordinate("-0°30'", axis: .longitude), -0.5)
    }

    func testLongitudeWrapsPast180() throws {
        XCTAssertEqual(try parseCoordinate("190", axis: .longitude), -170)
        XCTAssertEqual(try parseCoordinate("180", axis: .longitude), 180)
    }

    func testRejectsBadInput() {
        XCTAssertThrowsError(try parseCoordinate("", axis: .latitude))
        XCTAssertThrowsError(try parseCoordinate("abc", axis: .latitude))
        XCTAssertThrowsError(try parseCoordinate("35E", axis: .latitude))
        XCTAssertThrowsError(try parseCoordinate("35N", axis: .longitude))
        XCTAssertThrowsError(try parseCoordinate("95", axis: .latitude))
        XCTAssertThrowsError(try parseCoordinate("35 75", axis: .latitude))
        XCTAssertThrowsError(try parseCoordinate("-35S", axis: .latitude))
    }

    func testFormatting() {
        XCTAssertEqual(formatCoordinate(35, axis: .latitude), "35°N")
        XCTAssertEqual(formatCoordinate(-35.5, axis: .latitude), "35.5°S")
        XCTAssertEqual(formatCoordinate(-110, axis: .longitude), "110°W")
        XCTAssertEqual(formatCoordinate(0, axis: .longitude), "0°")
    }
}
