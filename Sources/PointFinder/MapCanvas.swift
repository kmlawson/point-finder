import AppKit
import PointFinderCore
import SwiftUI

/// Keeps a document smaller than the viewport centred instead of pinned to a corner.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposed)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if rect.height > doc.frame.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}

/// The map image and its points. The image sits in a magnifying scroll view; the
/// points are drawn by a transparent view on top so they keep the same size on
/// screen at any zoom.
final class MapCanvasView: NSView {
    let scrollView = NSScrollView()
    private let imageView = NSView()
    private let overlay = OverlayView()
    private var image: CGImage?
    private var lastFit = -1
    private var lastReveal = -1
    weak var model: AppModel?

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollView.contentView = CenteringClipView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(calibratedWhite: 0.22, alpha: 1)
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.02
        scrollView.maxMagnification = 48
        scrollView.autoresizingMask = [.width, .height]
        scrollView.frame = bounds
        imageView.wantsLayer = true
        scrollView.documentView = imageView
        addSubview(scrollView)

        overlay.canvas = self
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(viewChanged), name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func viewChanged() { overlay.needsDisplay = true }

    override func layout() {
        super.layout()
        if lastFit < 0, image != nil, let model {
            lastFit = model.fitRequest
            zoomToFit()
        }
        overlay.needsDisplay = true
    }

    func sync(with model: AppModel) {
        self.model = model
        if model.image !== image {
            image = model.image
            if let cg = image {
                imageView.frame = NSRect(x: 0, y: 0, width: cg.width, height: cg.height)
                imageView.layer?.contents = cg
                imageView.layer?.magnificationFilter = .nearest
                imageView.layer?.minificationFilter = .trilinear
            } else {
                imageView.frame = .zero
                imageView.layer?.contents = nil
            }
            lastFit = -1
        }
        if model.fitRequest != lastFit, image != nil, bounds.width > 0 {
            lastFit = model.fitRequest
            zoomToFit()
        }
        if model.revealRequest != lastReveal {
            lastReveal = model.revealRequest
            if let p = model.selectedPoint { reveal(Vec2(p.x, p.y)) }
        }
        overlay.window?.invalidateCursorRects(for: overlay)
        overlay.needsDisplay = true
    }

    func zoomToFit() {
        guard let cg = image, bounds.width > 0, bounds.height > 0 else { return }
        let fit = min(bounds.width / CGFloat(cg.width), bounds.height / CGFloat(cg.height)) * 0.97
        scrollView.minMagnification = min(0.02, fit / 2)
        scrollView.magnification = fit
        overlay.needsDisplay = true
    }

    /// Scrolls so that an image position is on screen, zooming in if the view is far out.
    func reveal(_ p: Vec2) {
        let docPoint = docPoint(for: p)
        let visible = scrollView.contentView.bounds.insetBy(
            dx: scrollView.contentView.bounds.width * 0.1, dy: scrollView.contentView.bounds.height * 0.1)
        if visible.contains(docPoint) { return }
        let size = scrollView.contentView.bounds.size
        scrollView.contentView.scroll(to: NSPoint(x: docPoint.x - size.width / 2, y: docPoint.y - size.height / 2))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        overlay.needsDisplay = true
    }

    // Image coordinates have y down from the top-left; the document view has y up.
    func docPoint(for p: Vec2) -> NSPoint {
        NSPoint(x: p.x, y: Double(image?.height ?? 0) - p.y)
    }

    func viewPoint(for p: Vec2) -> NSPoint { imageView.convert(docPoint(for: p), to: overlay) }

    func imagePoint(forView q: NSPoint) -> Vec2 {
        let d = overlay.convert(q, to: imageView)
        return Vec2(d.x, Double(image?.height ?? 0) - d.y)
    }
}

/// Draws the points and handles the mouse and keyboard.
private final class OverlayView: NSView {
    weak var canvas: MapCanvasView?
    private var dragPoint: Int?
    private var dragOffset = NSPoint.zero
    private var mouseDownAt = NSPoint.zero
    private var moved = false
    private var panning = false
    private var panOrigin = NSPoint.zero

    private var model: AppModel? { canvas?.model }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        if model?.addMode == true { addCursorRect(bounds, cursor: .crosshair) }
    }

    // MARK: Drawing

    private func color(for p: MapPoint) -> NSColor {
        if !p.enabled { return NSColor(calibratedWhite: 0.55, alpha: 1) }
        switch p.source {
        case .user: return NSColor(calibratedRed: 0.0, green: 0.42, blue: 1.0, alpha: 1)
        case .calculated: return NSColor(calibratedRed: 0.0, green: 0.62, blue: 0.25, alpha: 1)
        case .estimated: return NSColor(calibratedRed: 0.62, green: 0.25, blue: 0.85, alpha: 1)
        case nil: return NSColor(calibratedRed: 1.0, green: 0.5, blue: 0.0, alpha: 1)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let canvas, let model, model.image != nil else { return }
        let visible = bounds.insetBy(dx: -40, dy: -40)

        if model.showLines {
            for line in model.lines {
                let path = NSBezierPath()
                for (i, v) in line.polyline.enumerated() {
                    let q = canvas.viewPoint(for: v)
                    if i == 0 { path.move(to: q) } else { path.line(to: q) }
                }
                (line.family == .column
                    ? NSColor(calibratedRed: 0.9, green: 0.1, blue: 0.3, alpha: 0.45)
                    : NSColor(calibratedRed: 0.1, green: 0.3, blue: 0.95, alpha: 0.45)).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }

        var onScreen: [(point: MapPoint, at: NSPoint)] = []
        for p in model.points {
            let q = canvas.viewPoint(for: Vec2(p.x, p.y))
            if visible.contains(q) { onScreen.append((p, q)) }
        }
        for (p, q) in onScreen {
            let selected = p.id == model.selection
            let r: CGFloat = selected ? 9 : 6.5
            let fill = color(for: p)
            // Cross-hair arms that stop short of the centre, so the exact spot stays visible.
            let arms = NSBezierPath()
            for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
                arms.move(to: NSPoint(x: q.x + dx * 2.5, y: q.y + dy * 2.5))
                arms.line(to: NSPoint(x: q.x + dx * (r + 5), y: q.y + dy * (r + 5)))
            }
            let rect = NSRect(x: q.x - r, y: q.y - r, width: 2 * r, height: 2 * r)
            // Detected intersections are circles; points added by hand are squares.
            let ring = p.isGridPoint ? NSBezierPath(ovalIn: rect) : NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            NSColor.white.setStroke()
            arms.lineWidth = 3.5
            arms.stroke()
            ring.lineWidth = selected ? 5.5 : 4.5
            ring.stroke()
            fill.setStroke()
            arms.lineWidth = 1.5
            arms.stroke()
            ring.lineWidth = selected ? 3.5 : 2.5
            ring.stroke()
            if selected {
                NSColor.black.setStroke()
                let outer = p.isGridPoint
                    ? NSBezierPath(ovalIn: rect.insetBy(dx: -3.5, dy: -3.5))
                    : NSBezierPath(rect: rect.insetBy(dx: -3, dy: -3))
                outer.lineWidth = 1.5
                outer.stroke()
            }
        }

        if model.showLabels && onScreen.count <= 220 {
            let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            for (p, q) in onScreen {
                guard let lon = p.lon, let lat = p.lat else { continue }
                let text = "\(formatCoordinate(lon, axis: .longitude)) \(formatCoordinate(lat, axis: .latitude))"
                    + (p.source == .estimated ? " ≈" : "")
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
                let size = (text as NSString).size(withAttributes: attributes)
                let box = NSRect(x: q.x + 11, y: q.y + 7, width: size.width + 8, height: size.height + 2)
                color(for: p).withAlphaComponent(0.92).setFill()
                NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
                (text as NSString).draw(at: NSPoint(x: box.minX + 4, y: box.minY + 1), withAttributes: attributes)
            }
        }
    }

    // MARK: Mouse

    private func hitPoint(_ q: NSPoint) -> MapPoint? {
        guard let canvas, let model else { return nil }
        var best: (MapPoint, CGFloat)?
        for p in model.points {
            let v = canvas.viewPoint(for: Vec2(p.x, p.y))
            let d = hypot(v.x - q.x, v.y - q.y)
            if d <= 11, d < (best?.1 ?? .infinity) { best = (p, d) }
        }
        return best?.0
    }

    override func mouseDown(with event: NSEvent) {
        guard let canvas, let model, model.image != nil else { return }
        window?.makeFirstResponder(self)
        let q = convert(event.locationInWindow, from: nil)
        mouseDownAt = q
        moved = false
        dragPoint = nil
        panning = false
        if let hit = hitPoint(q) {
            model.selection = hit.id
            dragPoint = hit.id
            let v = canvas.viewPoint(for: Vec2(hit.x, hit.y))
            dragOffset = NSPoint(x: v.x - q.x, y: v.y - q.y)
            if event.clickCount == 2 { model.editRequest += 1 }
        } else if model.addMode || event.modifierFlags.contains(.option) {
            model.addPoint(at: canvas.imagePoint(forView: q))
        } else {
            panning = true
            panOrigin = canvas.scrollView.contentView.bounds.origin
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let canvas, let model else { return }
        let q = convert(event.locationInWindow, from: nil)
        if !moved && hypot(q.x - mouseDownAt.x, q.y - mouseDownAt.y) < 3 { return }
        moved = true
        if let id = dragPoint {
            model.move(id: id, to: canvas.imagePoint(forView: NSPoint(x: q.x + dragOffset.x, y: q.y + dragOffset.y)))
        } else if panning {
            let scale = canvas.scrollView.magnification
            let clip = canvas.scrollView.contentView
            let target = NSPoint(
                x: panOrigin.x - (q.x - mouseDownAt.x) / scale, y: panOrigin.y - (q.y - mouseDownAt.y) / scale)
            clip.setBoundsOrigin(clip.constrainBoundsRect(NSRect(origin: target, size: clip.bounds.size)).origin)
            canvas.scrollView.reflectScrolledClipView(clip)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let model else { return }
        if let id = dragPoint, moved { model.finishedMoving(id: id) }
        if panning && !moved { model.selection = nil }
        dragPoint = nil
        panning = false
    }

    override func scrollWheel(with event: NSEvent) {
        guard let canvas else { return }
        let trackpad = event.hasPreciseScrollingDeltas || event.phase != [] || event.momentumPhase != []
        if trackpad && !event.modifierFlags.contains(.command) {
            canvas.scrollView.scrollWheel(with: event)
        } else {
            // A mouse wheel zooms about the pointer.
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.12
            let factor = exp(max(-0.5, min(0.5, delta)))
            let target = min(
                canvas.scrollView.maxMagnification,
                max(canvas.scrollView.minMagnification, canvas.scrollView.magnification * factor))
            let centre = canvas.scrollView.contentView.convert(event.locationInWindow, from: nil)
            canvas.scrollView.setMagnification(target, centeredAt: centre)
        }
    }

    override func magnify(with event: NSEvent) { canvas?.scrollView.magnify(with: event) }
    override func smartMagnify(with event: NSEvent) { canvas?.scrollView.smartMagnify(with: event) }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let model else { return super.keyDown(with: event) }
        let step = event.modifierFlags.contains(.shift) ? 10.0 : (event.modifierFlags.contains(.option) ? 0.1 : 1.0)
        func nudge(_ dx: Double, _ dy: Double) {
            guard let p = model.selectedPoint else { return }
            model.move(id: p.id, to: Vec2(p.x + dx * step, p.y + dy * step))
            model.finishedMoving(id: p.id)
        }
        switch event.keyCode {
        case 51, 117: model.deleteSelected()  // delete, forward delete
        case 123: nudge(-1, 0)
        case 124: nudge(1, 0)
        case 125: nudge(0, 1)
        case 126: nudge(0, -1)
        case 36, 76: if model.selection != nil { model.editRequest += 1 }  // return, enter
        case 53:  // escape
            if model.addMode { model.addMode = false } else { model.selection = nil }
        default: super.keyDown(with: event)
        }
    }
}

struct MapCanvas: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeNSView(context: Context) -> MapCanvasView {
        let view = MapCanvasView(frame: .zero)
        view.sync(with: model)
        return view
    }

    func updateNSView(_ view: MapCanvasView, context: Context) {
        view.sync(with: model)
    }
}
