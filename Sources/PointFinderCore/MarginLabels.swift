import CoreGraphics
import Foundation

#if canImport(Vision)
import Vision
#endif

/// A piece of text found on the map image. Coordinates are image pixels, y down.
public struct TextLabel: Sendable, Equatable {
    public var text: String
    public var center: Vec2
    public var height: Double

    public init(text: String, center: Vec2, height: Double) {
        self.text = text
        self.center = center
        self.height = height
    }
}

/// The number on a graticule label ("75", "105°", "35° N"), or nil for any other text.
public func parseDegreeLabel(_ text: String) -> Double? {
    var s = text.trimmingCharacters(in: .whitespaces)
    // Hemisphere letters and the degree sign may follow the number.
    while let last = s.last, "°ºNSEWnsew. ".contains(last) { s.removeLast() }
    guard !s.isEmpty, s.count <= 3, s.allSatisfy({ $0.isASCII && $0.isNumber }), let v = Double(s) else { return nil }
    return v <= 180 ? v : nil
}

/// A straight-line reading of labels along one family of lines: line `index`
/// carries the value `origin + step * index`.
public struct LabelFit: Sendable, Equatable {
    public var origin: Double
    public var step: Double
    /// How many different lines had a label that agrees.
    public var support: Int
}

/// Finds the evenly stepped sequence that most labels agree on. Labels that
/// belong to something else (an inset's own graticule, an atlas grid number)
/// are outvoted. Needs agreement from at least three different lines.
public func fitLabelSequence(_ candidates: [(index: Int, value: Double)]) -> LabelFit? {
    var best: LabelFit? = nil
    func niceness(_ step: Double) -> Int {
        [1, 2, 5, 10, 15, 20, 30, 0.5, 0.25, 4, 3].firstIndex(of: abs(step)).map { 20 - $0 } ?? 0
    }
    for a in candidates {
        for b in candidates where b.index > a.index {
            let step = (b.value - a.value) / Double(b.index - a.index)
            if step == 0 || abs(step) > 45 { continue }
            let origin = a.value - step * Double(a.index)
            let support = Set(candidates.filter { abs($0.value - origin - step * Double($0.index)) < 0.01 }
                .map { $0.index }).count
            let fit = LabelFit(origin: origin, step: step, support: support)
            if let current = best {
                if (support, niceness(step)) > (current.support, niceness(current.step)) { best = fit }
            } else {
                best = fit
            }
        }
    }
    guard let fit = best, fit.support >= 3 else { return nil }
    return fit
}

/// Pairs degree labels with the grid lines they sit at the end of. A label
/// belongs to a line when it lies close to the line carried straight on past
/// one of its ends.
public func labelCandidates(lines: [GridLine], labels: [TextLabel], imageSize: Double)
    -> (columns: [(index: Int, value: Double)], rows: [(index: Int, value: Double)])
{
    var columns: [(index: Int, value: Double)] = [], rows: [(index: Int, value: Double)] = []
    for label in labels {
        guard let value = parseDegreeLabel(label.text) else { continue }
        var best: (line: GridLine, miss: Double)? = nil
        for line in lines where line.polyline.count >= 2 {
            let n = line.polyline.count
            for (end, before) in [(line.polyline[0], line.polyline[1]), (line.polyline[n - 1], line.polyline[n - 2])] {
                let out = (end - before).normalized
                let r = label.center - end
                let along = r.dot(out), across = abs(r.dot(out.perp))
                if along < -2 * label.height || along > 0.15 * imageSize { continue }
                let allowed = max(2.5 * label.height, 0.008 * imageSize) + 0.03 * max(0, along)
                if across > allowed { continue }
                let miss = across + 0.1 * max(0, along)
                if miss < (best?.miss ?? .infinity) { best = (line, miss) }
            }
        }
        guard let hit = best else { continue }
        if hit.line.family == .column {
            columns.append((hit.line.index, value))
        } else {
            rows.append((hit.line.index, value))
        }
    }
    return (columns, rows)
}

/// What the margin labels say about the grid: longitude by column and latitude
/// by row, signed (west and south negative).
public struct LabelProposal: Sendable, Equatable {
    public var lonOrigin: Double
    public var lonStep: Double
    public var latOrigin: Double
    public var latStep: Double
    public var lonSupport: Int
    public var latSupport: Int

    public func coordinate(col: Int, row: Int) -> (lon: Double, lat: Double) {
        (wrapLongitude(lonOrigin + lonStep * Double(col)), latOrigin + latStep * Double(row))
    }
}

/// Reads the grid's longitudes and latitudes off the margin labels. Assumes a
/// north-up map with meridians as columns. Labels carry no sign, so the
/// hemisphere is taken from the direction the numbers run: longitudes that
/// fall from left to right are west, latitudes that rise downwards are south.
public func proposeGrid(lines: [GridLine], labels: [TextLabel], imageSize: Double) -> LabelProposal? {
    let candidates = labelCandidates(lines: lines, labels: labels, imageSize: imageSize)
    guard let lon = fitLabelSequence(candidates.columns), let lat = fitLabelSequence(candidates.rows) else { return nil }
    let west = lon.step < 0, south = lat.step > 0
    return LabelProposal(
        lonOrigin: west ? -lon.origin : lon.origin, lonStep: abs(lon.step),
        latOrigin: south ? -lat.origin : lat.origin, latStep: -abs(lat.step),
        lonSupport: lon.support, latSupport: lat.support)
}

/// Two grid points to carry the reference coordinates: as far apart as
/// possible on both columns and rows, and seen in the image rather than inferred.
public func referencePair(in points: [MapPoint]) -> (Int, Int)? {
    let usable = points.filter { $0.isGridPoint && $0.enabled && !$0.inferred }
    var best: (a: Int, b: Int, score: Int)? = nil
    for (i, a) in usable.enumerated() {
        for b in usable.dropFirst(i + 1) {
            let dc = abs(a.col! - b.col!), dr = abs(a.row! - b.row!)
            if dc == 0 || dr == 0 { continue }
            let score = min(dc, dr) * 1000 + dc + dr
            if score > (best?.score ?? 0) { best = (a.id, b.id, score) }
        }
    }
    return best.map { ($0.a, $0.b) }
}

#if canImport(Vision)
/// Reads all text on an image with Apple's Vision framework. The image is read
/// in overlapping tiles so that small print on a large scan is not lost.
public func recognizeText(in image: CGImage, tileSize: Int = 1600, overlap: Int = 240) -> [TextLabel] {
    var origins: [(x: Int, y: Int)] = []
    let stride = max(1, tileSize - overlap)
    var y = 0
    while true {
        var x = 0
        while true {
            origins.append((x, y))
            if x + tileSize >= image.width { break }
            x += stride
        }
        if y + tileSize >= image.height { break }
        y += stride
    }
    var found: [TextLabel] = []
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: origins.count) { i in
        let o = origins[i]
        let rect = CGRect(
            x: o.x, y: o.y, width: min(tileSize, image.width - o.x), height: min(tileSize, image.height - o.y))
        guard let tile = image.cropping(to: rect) else { return }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.004
        do {
            try VNImageRequestHandler(cgImage: tile, options: [:]).perform([request])
        } catch {
            return
        }
        var labels: [TextLabel] = []
        for observation in request.results ?? [] {
            guard let top = observation.topCandidates(1).first else { continue }
            // Vision boxes are fractions of the tile with the origin at the bottom-left.
            let box = observation.boundingBox
            let cx = rect.minX + box.midX * rect.width
            let cy = rect.minY + (1 - box.midY) * rect.height
            labels.append(TextLabel(text: top.string, center: Vec2(cx, cy), height: box.height * rect.height))
        }
        lock.lock()
        found.append(contentsOf: labels)
        lock.unlock()
    }
    // The same text read in two overlapping tiles counts once.
    var unique: [TextLabel] = []
    for label in found.sorted(by: { ($0.center.y, $0.center.x) < ($1.center.y, $1.center.x) }) {
        if unique.contains(where: {
            $0.text == label.text && $0.center.distance(to: label.center) < max($0.height, label.height)
        }) { continue }
        unique.append(label)
    }
    return unique
}
#endif
