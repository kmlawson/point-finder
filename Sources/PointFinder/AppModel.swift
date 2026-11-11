import AppKit
import PointFinderCore
import SwiftUI
import UniformTypeIdentifiers

/// Everything the window shows: the image, its control points, and the actions on them.
@MainActor
final class AppModel: ObservableObject {
    @Published var imageURL: URL?
    @Published var image: CGImage?
    @Published var points: [MapPoint] = []
    @Published var lines: [GridLine] = []
    @Published var selection: Int?
    @Published var addMode = false
    @Published var showLines = true
    @Published var showLabels = true
    @Published var status = "Open a map image to begin."
    @Published var busy: String?
    @Published var progress = 0.0
    @Published var solution: GridSolution?
    @Published var params = DetectionParams()
    @Published var hasUnsavedChanges = false
    /// Bumped to ask the canvas to fit the image, or to bring a point into view.
    @Published var fitRequest = 0
    @Published var revealRequest = 0
    /// Bumped to move keyboard focus to the longitude field.
    @Published var editRequest = 0

    private(set) var pointsFileURL: URL?
    private var nextID = 1

    var selectedPoint: MapPoint? { points.first { $0.id == selection } }
    var referenceCount: Int { points.filter { $0.isGridPoint && $0.source == .user }.count }
    var savableCount: Int { points.filter { $0.hasCoordinate }.count }
    var hasGrid: Bool { points.contains { $0.isGridPoint } }

    // MARK: Opening

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a map image"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        if hasUnsavedChanges {
            let alert = NSAlert()
            alert.messageText = "Discard unsaved points?"
            alert.informativeText = "The points on the current map have changes that are not saved."
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return }
        }
        do {
            let cg = try loadCGImage(url: url)
            imageURL = url
            image = cg
            points = []
            lines = []
            selection = nil
            solution = nil
            nextID = 1
            hasUnsavedChanges = false
            pointsFileURL = nil
            fitRequest += 1
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            if let file = GCPFile.existingFile(for: url),
               let text = try? String(contentsOf: file, encoding: .utf8) {
                let loaded = GCPFile.parse(text, firstID: nextID)
                points = loaded
                nextID += loaded.count
                pointsFileURL = file
                status = "Loaded \(loaded.count) point\(loaded.count == 1 ? "" : "s") from \(file.lastPathComponent). "
                    + "Press Detect to look for graticule intersections as well."
            } else {
                detect()
            }
        } catch {
            status = error.localizedDescription
        }
    }

    // MARK: Detection

    func detect() {
        guard let cg = image, busy == nil else { return }
        busy = "Looking for graticule lines"
        progress = 0
        let params = self.params
        Task.detached(priority: .userInitiated) {
            let outcome: Result<DetectionResult, Error>
            do {
                let gray = try grayImage(from: cg, ink: params.ink)
                outcome = .success(detectGraticule(gray: gray, params: params) { stage, fraction in
                    Task { @MainActor in
                        self.busy = stage
                        self.progress = fraction
                    }
                })
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run { self.finishDetection(outcome, for: cg) }
        }
    }

    private func finishDetection(_ outcome: Result<DetectionResult, Error>, for cg: CGImage) {
        busy = nil
        guard cg === image else { return }
        switch outcome {
        case .failure(let error):
            status = error.localizedDescription
        case .success(let result):
            let merged = mergeDetection(existing: points, detected: result.points, nextID: nextID)
            nextID = (merged.map { $0.id }.max() ?? nextID) + 1
            points = merged
            lines = result.lines
            if let s = selection, !points.contains(where: { $0.id == s }) { selection = nil }
            if result.points.isEmpty {
                status = "No graticule intersections found. Try the detection settings, or add points by hand."
            } else {
                status = "Found \(result.points.count) intersections. Select two that are diagonal from each "
                    + "other, give each a longitude and latitude, then press Calculate."
                hasUnsavedChanges = true
            }
            recalculateQuietly()
        }
    }

    // MARK: Editing points

    private func index(of id: Int) -> Int? { points.firstIndex { $0.id == id } }

    /// Sets a point's coordinate from typed text. Returns a message when the text cannot be used.
    func setCoordinate(id: Int, lonText: String, latText: String) -> String? {
        guard let i = index(of: id) else { return nil }
        do {
            let lon = try parseCoordinate(lonText, axis: .longitude)
            let lat = try parseCoordinate(latText, axis: .latitude)
            points[i].lon = lon
            points[i].lat = lat
            points[i].source = .user
            hasUnsavedChanges = true
            let refs = referenceCount
            if points[i].isGridPoint && solution == nil {
                status = refs < 2
                    ? "Reference point set. Give one more intersection, diagonal from this one, its coordinates."
                    : "\(refs) reference points set. Press Calculate to fill in the rest."
            }
            recalculateQuietly()
            return nil
        } catch let error as CoordinateParseError {
            switch error {
            case .empty: return "Enter both a longitude and a latitude."
            default: return error.localizedDescription
            }
        } catch {
            return error.localizedDescription
        }
    }

    func clearCoordinate(id: Int) {
        guard let i = index(of: id) else { return }
        points[i].lon = nil
        points[i].lat = nil
        points[i].source = nil
        hasUnsavedChanges = true
    }

    func delete(id: Int) {
        guard let i = index(of: id) else { return }
        points.remove(at: i)
        if selection == id { selection = nil }
        hasUnsavedChanges = true
    }

    func deleteSelected() {
        if let s = selection { delete(id: s) }
    }

    func setEnabled(id: Int, _ enabled: Bool) {
        guard let i = index(of: id) else { return }
        points[i].enabled = enabled
        hasUnsavedChanges = true
    }

    func addPoint(at p: Vec2) {
        guard let image, p.x >= 0, p.y >= 0, p.x <= Double(image.width), p.y <= Double(image.height) else { return }
        let point = MapPoint(id: nextID, x: p.x, y: p.y)
        nextID += 1
        points.append(point)
        selection = point.id
        hasUnsavedChanges = true
        status = "Point added. Type its coordinates, or press Calculate to estimate them from the grid."
        recalculateQuietly()
    }

    func move(id: Int, to p: Vec2) {
        guard let i = index(of: id), let image else { return }
        points[i].x = min(max(p.x, 0), Double(image.width))
        points[i].y = min(max(p.y, 0), Double(image.height))
        hasUnsavedChanges = true
    }

    /// Called when a drag or nudge ends: an estimated coordinate depends on position.
    func finishedMoving(id: Int) {
        guard let i = index(of: id) else { return }
        if points[i].source == .estimated { recalculateQuietly() }
    }

    func snapSelectedToGraticule() {
        guard let s = selection, let i = index(of: s), let solution,
              let lon = points[i].lon, let lat = points[i].lat else { return }
        let v = solution.snapped(lon: lon, lat: lat)
        points[i].lon = v.lon
        points[i].lat = v.lat
        points[i].source = .user
        hasUnsavedChanges = true
    }

    // MARK: Calculating

    func calculate() {
        do {
            let summary = try calculateCoordinates(&points)
            solution = summary.solution
            hasUnsavedChanges = true
            var text = "Calculated \(summary.gridPointsFilled) intersections from \(referenceCount) reference points"
            text += String(
                format: " (grid step %@ × %@).",
                trimmed(abs(summary.solution.lonStep)), trimmed(abs(summary.solution.latStep)))
            if summary.addedPointsEstimated > 0 {
                text += " Estimated \(summary.addedPointsEstimated) added point\(summary.addedPointsEstimated == 1 ? "" : "s")."
            }
            status = text + " Check a few labels against the map, then save."
        } catch {
            status = error.localizedDescription
            NSSound.beep()
        }
    }

    /// Keeps calculated values up to date after an edit, once a grid solution exists.
    private func recalculateQuietly() {
        guard solution != nil else { return }
        if let summary = try? calculateCoordinates(&points) { solution = summary.solution }
    }

    private func trimmed(_ v: Double) -> String {
        var s = String(format: "%.4f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s + "°"
    }

    // MARK: Saving

    func save(askForLocation: Bool = false) {
        guard let imageURL else { return }
        guard savableCount > 0 else {
            status = "Nothing to save yet: no point has a longitude and latitude."
            NSSound.beep()
            return
        }
        var target = pointsFileURL
        if target == nil || askForLocation {
            let suggested = pointsFileURL ?? GCPFile.defaultFile(for: imageURL)
            let panel = NSSavePanel()
            panel.directoryURL = suggested.deletingLastPathComponent()
            panel.nameFieldStringValue = suggested.lastPathComponent
            panel.message = "QGIS loads a .points file automatically when it has the image's full name."
            if let type = UTType(filenameExtension: "points") { panel.allowedContentTypes = [type] }
            panel.allowsOtherFileTypes = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            target = url
        }
        guard let target else { return }
        do {
            try GCPFile.write(points, to: target)
            pointsFileURL = target
            hasUnsavedChanges = false
            let skipped = points.count - savableCount
            status = "Saved \(savableCount) points to \(target.lastPathComponent)."
                + (skipped > 0 ? " \(skipped) without coordinates were left out." : "")
        } catch {
            status = "Could not save: \(error.localizedDescription)"
        }
    }
}
