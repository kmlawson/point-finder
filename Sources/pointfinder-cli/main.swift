import CoreGraphics
import Foundation
import ImageIO
import PointFinderCore
import UniformTypeIdentifiers

// Command-line front end for the graticule detector, mainly for checking what
// the detector finds on an image without opening the app.

let usage = """
    pointfinder-cli — find graticule intersections on a map image.

    Usage: pointfinder-cli <image> [options]

    Options:
      --overlay <file.png>   Write a reduced copy of the image with the found lines and points drawn on it.
      --overlay-mode <mode>  "lines" (default) or "segments" (the raw straight runs before joining).
      --contrast <n>         How much darker than its surroundings a line must be, 0-255 (default 28).
      --min-line <fraction>  Shortest line kept, as a fraction of the image's shorter side (default 0.25).
      --mask <file.png>      Write the thin-dark-line mask the search runs on.
      --black-only           Ignore coloured ink; only black or grey lines count.
      --help                 Show this text.

    Prints one line per intersection: column, row, pixel x, pixel y, quality.
    """

var args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || args.contains("--help") || args.contains("-h") {
    print(usage)
    exit(args.isEmpty ? 1 : 0)
}
var imagePath: String?
var overlayPath: String?
var overlayMode = "lines"
var maskPath: String?
var params = DetectionParams()
while !args.isEmpty {
    let a = args.removeFirst()
    func value() -> String {
        guard !args.isEmpty else {
            FileHandle.standardError.write("Missing value for \(a)\n".data(using: .utf8)!)
            exit(1)
        }
        return args.removeFirst()
    }
    switch a {
    case "--overlay": overlayPath = value()
    case "--overlay-mode": overlayMode = value()
    case "--mask": maskPath = value()
    case "--contrast": params.contrast = Int(value()) ?? params.contrast
    case "--min-line": params.minLineFraction = Double(value()) ?? params.minLineFraction
    case "--black-only": params.ink = .blackOnly
    default: imagePath = a
    }
}
guard let imagePath else {
    print(usage)
    exit(1)
}

do {
    let start = Date()
    let cg = try loadCGImage(url: URL(fileURLWithPath: imagePath))
    let gray = try grayImage(from: cg, ink: params.ink)
    params.keepDebugMask = maskPath != nil
    let result = detectGraticule(gray: gray, params: params) { stage, fraction in
        FileHandle.standardError.write("\r\(stage) \(Int(fraction * 100))%          ".data(using: .utf8)!)
    }
    FileHandle.standardError.write("\n".data(using: .utf8)!)
    let cols = result.lines.filter { $0.family == .column }.count
    let rows = result.lines.filter { $0.family == .row }.count
    FileHandle.standardError.write(
        String(
            format: "%d segments, %d candidate lines, %d columns, %d rows, %d points, %.1fs\n",
            result.segmentCount, result.candidateLines.count, cols, rows, result.points.count,
            Date().timeIntervalSince(start)
        ).data(using: .utf8)!)
    print("col\trow\tx\ty\tquality")
    for p in result.points {
        print(String(format: "%d\t%d\t%.2f\t%.2f\t%.2f", p.col, p.row, p.x, p.y, p.quality))
    }

    if let maskPath, let m = result.debugMask,
       let provider = CGDataProvider(data: Data(m.data) as CFData),
       let image = CGImage(
           width: m.width, height: m.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: m.width,
           space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
           decode: nil, shouldInterpolate: false, intent: .defaultIntent),
       let dest = CGImageDestinationCreateWithURL(
           URL(fileURLWithPath: maskPath) as CFURL, UTType.png.identifier as CFString, 1, nil)
    {
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    if let overlayPath {
        let scale = min(1, 2400 / Double(max(cg.width, cg.height)))
        let w = Int(Double(cg.width) * scale), h = Int(Double(cg.height) * scale)
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { exit(2) }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Wash the map out so the overlay reads clearly.
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.45))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        func pt(_ v: Vec2) -> CGPoint { CGPoint(x: v.x * scale, y: Double(h) - v.y * scale) }
        func stroke(_ line: [Vec2], _ color: CGColor, _ width: CGFloat) {
            guard let first = line.first else { return }
            ctx.setStrokeColor(color)
            ctx.setLineWidth(width)
            ctx.move(to: pt(first))
            for v in line.dropFirst() { ctx.addLine(to: pt(v)) }
            ctx.strokePath()
        }
        if overlayMode == "segments" {
            for line in result.debugSegments { stroke(line, CGColor(red: 0.8, green: 0, blue: 0.8, alpha: 1), 1.5) }
        } else {
            for line in result.candidateLines { stroke(line, CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1), 3) }
            for line in result.debugConflictLines { stroke(line, CGColor(red: 1, green: 0.6, blue: 0, alpha: 1), 3) }
        }
        for p in result.debugRejectedCrossings {
            let c = pt(p)
            ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10))
        }
        for line in result.lines {
            let color = line.family == .column
                ? CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1) : CGColor(red: 0.1, green: 0.2, blue: 0.9, alpha: 1)
            stroke(line.polyline, color, 1.5)
        }
        for p in result.points {
            let c = pt(Vec2(p.x, p.y))
            ctx.setFillColor(CGColor(red: 0, green: 0.7, blue: 0.1, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10))
        }
        if let image = ctx.makeImage(),
           let dest = CGImageDestinationCreateWithURL(
               URL(fileURLWithPath: overlayPath) as CFURL, UTType.png.identifier as CFString, 1, nil)
        {
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
        }
    }
} catch {
    FileHandle.standardError.write("Error: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(2)
}
