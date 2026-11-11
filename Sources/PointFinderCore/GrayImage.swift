import CoreGraphics
import Foundation
import ImageIO

public enum InkMode: String, Sendable, CaseIterable {
    /// Any dark line counts, whatever its colour.
    case anyDark
    /// Only black or grey ink counts; coloured lines (rivers, roads) are ignored.
    case blackOnly
}

public struct GrayImage: Sendable {
    public let width: Int
    public let height: Int
    public var data: [UInt8]

    public init(width: Int, height: Int, data: [UInt8]) {
        self.width = width
        self.height = height
        self.data = data
    }

    /// Bilinear sample at pixel-index coordinates (integer = pixel centre).
    @inline(__always)
    func sample(_ x: Double, _ y: Double) -> Double {
        let cx = min(max(x, 0), Double(width - 1))
        let cy = min(max(y, 0), Double(height - 1))
        let x0 = Int(cx), y0 = Int(cy)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let fx = cx - Double(x0), fy = cy - Double(y0)
        return data.withUnsafeBufferPointer { p in
            let a = Double(p[y0 * width + x0]), b = Double(p[y0 * width + x1])
            let c = Double(p[y1 * width + x0]), d = Double(p[y1 * width + x1])
            return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
        }
    }

    /// Area-averaged copy scaled by `scale` (0 < scale <= 1).
    func downscaled(by scale: Double) -> GrayImage {
        if scale >= 0.999 { return self }
        let w = max(1, Int(Double(width) * scale)), h = max(1, Int(Double(height) * scale))
        var out = [UInt8](repeating: 0, count: w * h)
        let inv = 1 / scale
        data.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    let sy0 = min(height - 1, Int(Double(y) * inv))
                    let sy1 = min(height, max(sy0 + 1, Int(Double(y + 1) * inv)))
                    for x in 0..<w {
                        let sx0 = min(width - 1, Int(Double(x) * inv))
                        let sx1 = min(width, max(sx0 + 1, Int(Double(x + 1) * inv)))
                        var sum = 0
                        for sy in sy0..<sy1 {
                            let row = sy * width
                            for sx in sx0..<sx1 { sum += Int(src[row + sx]) }
                        }
                        dst[y * w + x] = UInt8(sum / ((sy1 - sy0) * (sx1 - sx0)))
                    }
                }
            }
        }
        return GrayImage(width: w, height: h, data: out)
    }
}

public enum ImageLoadError: Error, LocalizedError {
    case cannotOpen(URL)
    case cannotRender

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let url): return "Could not open \(url.lastPathComponent) as an image."
        case .cannotRender: return "Could not decode the image."
        }
    }
}

public func loadCGImage(url: URL) throws -> CGImage {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else { throw ImageLoadError.cannotOpen(url) }
    return image
}

/// Converts an image to 8-bit grey in stored pixel order (no EXIF rotation), the
/// same pixel grid a GIS reads.
public func grayImage(from image: CGImage, ink: InkMode) throws -> GrayImage {
    let w = image.width, h = image.height
    var rgba = [UInt8](repeating: 0, count: w * h * 4)
    let ok: Bool = rgba.withUnsafeMutableBytes { buf in
        guard let ctx = CGContext(
            data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return false }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard ok else { throw ImageLoadError.cannotRender }
    var gray = [UInt8](repeating: 0, count: w * h)
    rgba.withUnsafeBufferPointer { src in
        gray.withUnsafeMutableBufferPointer { dst in
            DispatchQueue.concurrentPerform(iterations: h) { y in
                var i = y * w * 4
                for x in 0..<w {
                    let r = Int(src[i]), g = Int(src[i + 1]), b = Int(src[i + 2])
                    switch ink {
                    case .anyDark: dst[y * w + x] = UInt8((r * 77 + g * 150 + b * 29) >> 8)
                    case .blackOnly: dst[y * w + x] = UInt8(max(r, max(g, b)))
                    }
                    i += 4
                }
            }
        }
    }
    return GrayImage(width: w, height: h, data: gray)
}

/// Marks thin dark strokes: pixels much darker than their surroundings once every
/// dark feature narrower than `kernel` has been filled in (a black top-hat).
func thinDarkMask(_ image: GrayImage, kernel: Int, threshold: Int) -> [Bool] {
    let w = image.width, h = image.height
    let r = kernel / 2
    func pass(_ src: [UInt8], horizontal: Bool, takeMax: Bool) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h)
        src.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { d in
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for x in 0..<w {
                        var best = s[y * w + x]
                        if horizontal {
                            let lo = max(0, x - r), hi = min(w - 1, x + r)
                            var i = y * w + lo
                            for _ in lo...hi {
                                let v = s[i]
                                if takeMax ? v > best : v < best { best = v }
                                i += 1
                            }
                        } else {
                            let lo = max(0, y - r), hi = min(h - 1, y + r)
                            var i = lo * w + x
                            for _ in lo...hi {
                                let v = s[i]
                                if takeMax ? v > best : v < best { best = v }
                                i += w
                            }
                        }
                        d[y * w + x] = best
                    }
                }
            }
        }
        return out
    }
    var closed = pass(image.data, horizontal: true, takeMax: true)
    closed = pass(closed, horizontal: false, takeMax: true)
    closed = pass(closed, horizontal: true, takeMax: false)
    closed = pass(closed, horizontal: false, takeMax: false)
    var mask = [Bool](repeating: false, count: w * h)
    for i in 0..<(w * h) {
        mask[i] = Int(closed[i]) - Int(image.data[i]) >= threshold
    }
    return mask
}

/// Clears connected groups of mask pixels whose bounding box is smaller than
/// `minExtent` in both directions: lettering, symbols and specks. Lines survive
/// because everything they touch joins them into one large group.
func removeSmallComponents(_ mask: inout [Bool], width: Int, height: Int, minExtent: Int) {
    var label = [Int32](repeating: 0, count: width * height)
    var stack: [Int32] = []
    var members: [Int32] = []
    var next: Int32 = 0
    for start in 0..<(width * height) where mask[start] && label[start] == 0 {
        next += 1
        label[start] = next
        stack.removeAll(keepingCapacity: true)
        members.removeAll(keepingCapacity: true)
        stack.append(Int32(start))
        var minX = width, maxX = 0, minY = height, maxY = 0
        while let top = stack.popLast() {
            let i = Int(top)
            members.append(top)
            let x = i % width, y = i / width
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
            for dy in -1...1 {
                let yy = y + dy
                if yy < 0 || yy >= height { continue }
                for dx in -1...1 {
                    let xx = x + dx
                    if xx < 0 || xx >= width { continue }
                    let j = yy * width + xx
                    if mask[j] && label[j] == 0 {
                        label[j] = next
                        stack.append(Int32(j))
                    }
                }
            }
        }
        if max(maxX - minX, maxY - minY) + 1 < minExtent {
            for m in members { mask[Int(m)] = false }
        }
    }
}
