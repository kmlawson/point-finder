import Foundation

public enum CoordinateAxis: Sendable {
    case longitude, latitude
}

public enum CoordinateParseError: Error, LocalizedError, Equatable {
    case empty
    case unreadable(String)
    case wrongHemisphere(String)
    case outOfRange(String)

    public var errorDescription: String? {
        switch self {
        case .empty: return "Enter a value."
        case .unreadable(let s): return "Could not read \u{201C}\(s)\u{201D} as degrees. Try 35.5, 35N, or 35°30'N."
        case .wrongHemisphere(let s): return s
        case .outOfRange(let s): return s
        }
    }
}

/// Reads a latitude or longitude typed by a person: decimal degrees ("-35.5"),
/// a hemisphere letter ("35N", "E 110"), or degrees, minutes and seconds
/// ("35°30'15\"S", "35 30 15 S"). South and west are negative.
public func parseCoordinate(_ text: String, axis: CoordinateAxis) throws -> Double {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { throw CoordinateParseError.empty }
    var hemisphere: Character? = nil
    var numbers: [Double] = []
    var negative = false
    var current = ""
    var sawNumber = false
    func flush() throws {
        if current.isEmpty { return }
        guard let v = Double(current) else { throw CoordinateParseError.unreadable(trimmed) }
        numbers.append(v)
        current = ""
    }
    for ch in trimmed {
        if ch.isNumber || ch == "." {
            current.append(ch)
            sawNumber = true
        } else if ch == "," && !current.isEmpty && !current.contains(".") {
            // Decimal comma.
            current.append(".")
        } else if ch == "-" || ch == "\u{2212}" {
            if sawNumber || negative { throw CoordinateParseError.unreadable(trimmed) }
            negative = true
        } else if ch == "+" {
            if sawNumber { throw CoordinateParseError.unreadable(trimmed) }
        } else if "NSEWnsew".contains(ch) {
            try flush()
            if hemisphere != nil { throw CoordinateParseError.unreadable(trimmed) }
            hemisphere = Character(ch.uppercased())
        } else if ch.isWhitespace || "°'\"\u{2032}\u{2033}\u{2019}\u{201D}dms:".contains(ch) {
            try flush()
        } else {
            throw CoordinateParseError.unreadable(trimmed)
        }
    }
    try flush()
    guard !numbers.isEmpty, numbers.count <= 3 else { throw CoordinateParseError.unreadable(trimmed) }
    if numbers.count > 1 && numbers.dropFirst().contains(where: { $0 >= 60 }) {
        throw CoordinateParseError.unreadable(trimmed)
    }
    var value = numbers[0]
    if numbers.count > 1 { value += numbers[1] / 60 }
    if numbers.count > 2 { value += numbers[2] / 3600 }
    if negative { value = -value }
    if let h = hemisphere {
        switch (axis, h) {
        case (.latitude, "E"), (.latitude, "W"):
            throw CoordinateParseError.wrongHemisphere("\(h) is a longitude direction; latitude takes N or S.")
        case (.longitude, "N"), (.longitude, "S"):
            throw CoordinateParseError.wrongHemisphere("\(h) is a latitude direction; longitude takes E or W.")
        default: break
        }
        if negative { throw CoordinateParseError.unreadable(trimmed) }
        if h == "S" || h == "W" { value = -value }
    }
    switch axis {
    case .latitude:
        if abs(value) > 90 { throw CoordinateParseError.outOfRange("Latitude must be between 90°S and 90°N.") }
    case .longitude:
        if abs(value) > 360 { throw CoordinateParseError.outOfRange("Longitude must be between 180°W and 180°E.") }
        value = wrapLongitude(value)
    }
    return value
}

/// Brings a longitude into the range (-180, 180].
public func wrapLongitude(_ lon: Double) -> Double {
    var v = lon.truncatingRemainder(dividingBy: 360)
    if v > 180 { v -= 360 }
    if v <= -180 { v += 360 }
    return v
}

/// "35°N", "110.5°E": degrees with a hemisphere letter and no needless decimals.
public func formatCoordinate(_ value: Double, axis: CoordinateAxis) -> String {
    let magnitude = abs(value)
    var digits = String(format: "%.5f", magnitude)
    while digits.hasSuffix("0") { digits.removeLast() }
    if digits.hasSuffix(".") { digits.removeLast() }
    if magnitude < 0.000005 { return "0°" }
    let letter: String
    switch axis {
    case .latitude: letter = value >= 0 ? "N" : "S"
    case .longitude: letter = value >= 0 ? "E" : "W"
    }
    return "\(digits)°\(letter)"
}
