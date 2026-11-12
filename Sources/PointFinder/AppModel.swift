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
    /// Long lines the last detection ruled out (frame, routes), for the second opinion to avoid.
    private var rejectedLines: [[Vec2]] = []
    @Published var selection: Int?
    @Published var addMode = false {
        didSet { if addMode && regionMode { regionMode = false } }
    }
    /// While on, dragging on the map marks out an area to search again.
    @Published var regionMode = false {
        didSet {
            if regionMode && addMode { addMode = false }
            if regionMode { status = "Drag a rectangle over the area to search again. Esc cancels." }
        }
    }
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
    /// Bumped to zoom in on the selected point.
    @Published var focusRequest = 0
    /// Points being stepped through in review, and how far the review has got.
    @Published var reviewIDs: [Int] = []
    @Published var reviewPosition = 0
    @Published var reviewing = false
    /// The last projection guess asked for; saved beside the points.
    @Published var projection: ProjectionGuess?
    /// Earlier states of the points, newest last, each with the name of the change that followed it.
    @Published private var undoStack: [(snapshot: Snapshot, name: String)] = []
    @Published private var redoStack: [(snapshot: Snapshot, name: String)] = []
    /// The grey image the last detection ran on, kept for snapping and second opinions.
    private var grayCache: (image: CGImage, ink: InkMode, gray: GrayImage)?

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
            rejectedLines = []
            projection = nil
            reviewing = false
            reviewIDs = []
            grayCache = nil
            undoStack = []
            redoStack = []
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
            let outcome: Result<(DetectionResult, GrayImage), Error>
            do {
                let gray = try grayImage(from: cg, ink: params.ink)
                let result = detectGraticule(gray: gray, params: params) { stage, fraction in
                    Task { @MainActor in
                        self.busy = stage
                        self.progress = fraction
                    }
                }
                outcome = .success((result, gray))
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run { self.finishDetection(outcome, for: cg, ink: params.ink) }
        }
    }

    private func finishDetection(_ outcome: Result<(DetectionResult, GrayImage), Error>, for cg: CGImage, ink: InkMode) {
        busy = nil
        guard cg === image else { return }
        switch outcome {
        case .failure(let error):
            status = error.localizedDescription
        case .success(let (result, gray)):
            grayCache = (cg, ink, gray)
            if !result.points.isEmpty { checkpoint("Detect Intersections") }
            reviewing = false
            let merged = mergeDetection(existing: points, detected: result.points, nextID: nextID)
            nextID = (merged.map { $0.id }.max() ?? nextID) + 1
            points = merged
            lines = result.lines
            rejectedLines = result.rejectedLines
            if let s = selection, !points.contains(where: { $0.id == s }) { selection = nil }
            if result.points.isEmpty {
                status = "No graticule intersections found. Try the detection settings, or add points by hand."
            } else {
                let inferred = result.points.filter { $0.inferred }.count
                status = "Found \(result.points.count) intersections"
                    + (inferred > 0 ? " (\(inferred) inferred from the lines, shown in red — check them)" : "")
                    + ". Select two that are diagonal from each "
                    + "other, give each a longitude and latitude, then press Calculate."
                hasUnsavedChanges = true
            }
            recalculateQuietly()
            if Prefs.readLabelsAfterDetect && !result.points.isEmpty && referenceCount == 0 { readMarginLabels() }
        }
    }

    /// The grey image for the current map, computed once per ink setting.
    private func currentGray() -> GrayImage? {
        guard let cg = image else { return nil }
        if let cache = grayCache, cache.image === cg, cache.ink == params.ink { return cache.gray }
        guard let gray = try? grayImage(from: cg, ink: params.ink) else { return nil }
        grayCache = (cg, params.ink, gray)
        return gray
    }

    // MARK: Undo

    private struct Snapshot {
        var points: [MapPoint]
        var lines: [GridLine]
        var solution: GridSolution?
        var selection: Int?
        var nextID: Int
    }

    private var present: Snapshot {
        Snapshot(points: points, lines: lines, solution: solution, selection: selection, nextID: nextID)
    }

    /// Call before changing the points: makes the change undoable.
    private func checkpoint(_ name: String) {
        undoStack.append((present, name))
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack = []
    }

    var undoTitle: String { undoStack.last.map { "Undo \($0.name)" } ?? "Undo" }
    var redoTitle: String { redoStack.last.map { "Redo \($0.name)" } ?? "Redo" }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// While a text field is being edited, Undo and Redo belong to the typing in it.
    private func textUndoManager() -> UndoManager? {
        (NSApp.keyWindow?.firstResponder as? NSText)?.undoManager
    }

    func undo() {
        if let text = textUndoManager(), text.canUndo { return text.undo() }
        guard busy == nil, let last = undoStack.popLast() else { return NSSound.beep() }
        redoStack.append((present, last.name))
        restore(last.snapshot)
        status = "Undid: \(last.name)."
    }

    func redo() {
        if let text = textUndoManager(), text.canRedo { return text.redo() }
        guard busy == nil, let next = redoStack.popLast() else { return NSSound.beep() }
        undoStack.append((present, next.name))
        restore(next.snapshot)
        status = "Redid: \(next.name)."
    }

    private func restore(_ snapshot: Snapshot) {
        points = snapshot.points
        lines = snapshot.lines
        solution = snapshot.solution
        nextID = max(nextID, snapshot.nextID)
        selection = snapshot.selection.flatMap { id in points.contains { $0.id == id } ? id : nil }
        hasUnsavedChanges = true
        if reviewing { reviewIDs = reviewIDs.filter { id in points.contains { $0.id == id } } }
    }

    // MARK: Review

    /// Starts stepping through the doubtful points: inferred ones, then low-confidence ones.
    func startReview() {
        let queue = reviewQueue(points, threshold: Prefs.reviewThreshold)
        guard !queue.isEmpty else {
            status = "Nothing to review: no inferred points, and none below "
                + "\(Int((Prefs.reviewThreshold * 100).rounded()))% confidence."
            return
        }
        regionMode = false
        addMode = false
        reviewIDs = queue
        reviewPosition = 0
        reviewing = true
        showReviewPoint()
    }

    func endReview(finished: Bool = false) {
        guard reviewing else { return }
        reviewing = false
        reviewIDs = []
        status = finished ? "Review finished." : "Review stopped."
    }

    private func showReviewPoint() {
        // Skip anything deleted since the review began.
        while reviewPosition < reviewIDs.count, index(of: reviewIDs[reviewPosition]) == nil { reviewPosition += 1 }
        guard reviewPosition < reviewIDs.count else {
            endReview(finished: true)
            return
        }
        selection = reviewIDs[reviewPosition]
        focusRequest += 1
    }

    func reviewStep(_ by: Int) {
        guard reviewing else { return }
        let target = reviewPosition + by
        if target < 0 { return }
        reviewPosition = target
        showReviewPoint()
    }

    /// Marks the point under review as checked and moves on.
    func reviewAccept() {
        guard reviewing, reviewPosition < reviewIDs.count, let i = index(of: reviewIDs[reviewPosition]) else { return }
        checkpoint("Accept Point")
        points[i].reviewed = true
        points[i].inferred = false
        hasUnsavedChanges = true
        reviewStep(1)
    }

    func reviewDelete() {
        guard reviewing, reviewPosition < reviewIDs.count else { return }
        delete(id: reviewIDs[reviewPosition])
        reviewStep(1)
    }

    // MARK: Moving between points

    func selectNeighbour(_ step: GridStep) {
        guard let s = selection, let next = neighbour(of: s, in: points, step: step) else {
            NSSound.beep()
            return
        }
        selection = next
        if Prefs.zoomOnNavigate { focusRequest += 1 } else { revealRequest += 1 }
    }

    func zoomToSelection() {
        if selection != nil { focusRequest += 1 }
    }

    // MARK: Margin labels

    /// Reads the degree labels in the map's margins and offers the grid they give.
    func readMarginLabels() {
        guard let cg = image, busy == nil else { return }
        guard hasGrid, !lines.isEmpty else {
            status = "Reading margin labels needs the grid lines from Detect first."
            NSSound.beep()
            return
        }
        let lines = self.lines
        busy = "Reading margin labels"
        progress = 0.5
        Task.detached(priority: .userInitiated) {
            let labels = recognizeText(in: cg)
            let proposal = proposeGrid(lines: lines, labels: labels, imageSize: Double(max(cg.width, cg.height)))
            await MainActor.run { self.finishReadingLabels(proposal, for: cg) }
        }
    }

    private func finishReadingLabels(_ proposal: LabelProposal?, for cg: CGImage) {
        busy = nil
        guard cg === image else { return }
        guard let proposal else {
            status = "The margin labels did not give a consistent reading. Enter two reference points by hand."
            return
        }
        guard let pair = referencePair(in: points), let a = index(of: pair.0), let b = index(of: pair.1) else {
            status = "The labels were read, but there are no two intersections diagonal from each other to carry them."
            return
        }
        let grid = points.filter { $0.isGridPoint }
        let cols = grid.map { $0.col! }, rows = grid.map { $0.row! }
        let first = proposal.coordinate(col: cols.min()!, row: rows.min()!)
        let last = proposal.coordinate(col: cols.max()!, row: rows.max()!)
        let alert = NSAlert()
        alert.messageText = "Use the grid read from the margin labels?"
        alert.informativeText =
            "Meridians: \(formatCoordinate(first.lon, axis: .longitude)) to \(formatCoordinate(last.lon, axis: .longitude)), "
            + "every \(trimmed(proposal.lonStep)) (\(proposal.lonSupport) labels agree).\n"
            + "Parallels: \(formatCoordinate(first.lat, axis: .latitude)) to \(formatCoordinate(last.lat, axis: .latitude)), "
            + "every \(trimmed(abs(proposal.latStep))) (\(proposal.latSupport) labels agree).\n\n"
            + "East/west and north/south are judged from the direction the numbers run, assuming north is up. "
            + "Two reference points will be set from this and the rest calculated. Check a few against the map."
        alert.addButton(withTitle: "Use These")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            status = "Margin labels not used."
            return
        }
        checkpoint("Read Margin Labels")
        for i in [a, b] {
            let v = proposal.coordinate(col: points[i].col!, row: points[i].row!)
            points[i].lon = v.lon
            points[i].lat = v.lat
            points[i].source = .user
        }
        hasUnsavedChanges = true
        calculate(undoable: false)
    }

    // MARK: Projection

    /// Works out the likely projection from the grid and shows the reasoning.
    func guessProjectionNow() {
        guard let guess = guessProjection(points: points) else {
            status = "Guessing the projection needs a grid: at least two meridians and two parallels with three intersections each."
            NSSound.beep()
            return
        }
        projection = guess
        let alert = NSAlert()
        alert.messageText = guess.name
        alert.informativeText = guess.report
            + (solution == nil ? "\nCalculate the coordinates first for an estimate of the projection's parameters." : "")
            + "\nThis will be saved beside the points file."
        alert.addButton(withTitle: "OK")
        alert.runModal()
        status = "Projection guess: \(guess.name). It is saved beside the points file."
        hasUnsavedChanges = true
    }

    // MARK: Second opinion

    /// Searches one area of the map again, more leniently, for intersections the
    /// grid of known points predicts there.
    func secondOpinion(in region: PixelRect) {
        guard let cg = image, busy == nil else { return }
        let known = points.compactMap { p -> GridPoint? in
            guard let c = p.col, let r = p.row else { return nil }
            return GridPoint(x: p.x, y: p.y, col: c, row: r, quality: 1, inferred: p.inferred)
        }
        guard known.count >= 3 else {
            status = "A second opinion needs the grid from Detect first: it works from the intersections already found."
            NSSound.beep()
            return
        }
        let completion = CompletionParams.secondOpinion(
            region: region, detection: params, avoidLines: rejectedLines)
        let ink = params.ink
        busy = "Looking again at the selected area"
        progress = 0.5
        let cached = grayCache.flatMap { $0.image === cg && $0.ink == ink ? $0.gray : nil }
        Task.detached(priority: .userInitiated) {
            let outcome: Result<[GridPoint], Error>
            do {
                let gray = try cached ?? grayImage(from: cg, ink: ink)
                outcome = .success(completeGrid(gray: gray, known: known, params: completion))
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run { self.finishSecondOpinion(outcome, for: cg) }
        }
    }

    private func finishSecondOpinion(_ outcome: Result<[GridPoint], Error>, for cg: CGImage) {
        busy = nil
        guard cg === image else { return }
        switch outcome {
        case .failure(let error):
            status = error.localizedDescription
        case .success(let found):
            // Leave alone any spot that already has a point (one added by hand, say).
            let fresh = found.filter { g in
                !points.contains { Vec2($0.x, $0.y).distance(to: Vec2(g.x, g.y)) < 6 }
                    && !points.contains { $0.col == g.col && $0.row == g.row }
            }
            guard !fresh.isEmpty else {
                status = "Second opinion: nothing new in that area."
                return
            }
            checkpoint("Second Opinion")
            for g in fresh {
                var p = MapPoint(id: nextID, x: g.x, y: g.y, col: g.col, row: g.row)
                p.inferred = g.inferred
                p.quality = g.quality
                nextID += 1
                points.append(p)
            }
            lines.append(contentsOf: linesThrough(fresh.filter { !$0.inferred }))
            hasUnsavedChanges = true
            let inferred = fresh.filter { $0.inferred }.count, seen = fresh.count - inferred
            var parts: [String] = []
            if seen > 0 { parts.append("found \(seen) more intersection\(seen == 1 ? "" : "s")") }
            if inferred > 0 { parts.append("placed \(inferred) inferred (red) where the image shows no clear crossing") }
            status = "Second opinion: " + parts.joined(separator: " and ") + ". Check them against the map."
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
            checkpoint("Set Coordinates")
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
        checkpoint("Clear Coordinates")
        points[i].lon = nil
        points[i].lat = nil
        points[i].source = nil
        hasUnsavedChanges = true
    }

    func delete(id: Int) {
        guard let i = index(of: id) else { return }
        checkpoint("Delete Point")
        points.remove(at: i)
        if selection == id { selection = nil }
        hasUnsavedChanges = true
    }

    func deleteSelected() {
        if let s = selection { delete(id: s) }
    }

    func setEnabled(id: Int, _ enabled: Bool) {
        guard let i = index(of: id) else { return }
        checkpoint(enabled ? "Use Point" : "Leave Out Point")
        points[i].enabled = enabled
        hasUnsavedChanges = true
    }

    func addPoint(at p: Vec2) {
        guard let image, p.x >= 0, p.y >= 0, p.x <= Double(image.width), p.y <= Double(image.height) else { return }
        checkpoint("Add Point")
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
        // Once placed by hand it is no longer a guess.
        points[i].inferred = false
        hasUnsavedChanges = true
    }

    /// Call once before a drag or a nudge moves a point, so the move can be undone.
    func willMove() { checkpoint("Move Point") }

    /// Called when a drag or nudge ends. A point dropped by the mouse near a
    /// crossing of two lines moves onto it (if that preference is on).
    func finishedMoving(id: Int, dropped: Bool = false) {
        guard let i = index(of: id) else { return }
        if dropped && Prefs.snapOnDrop, let gray = currentGray() {
            let here = Vec2(points[i].x, points[i].y)
            let hint = nearestLineDirections(at: here, lines: lines).map { [($0.row, $0.column)] } ?? []
            let unit = max(1, Double(max(gray.width, gray.height)) / 5000)
            if let snapped = snapToCrossing(
                gray: gray, near: here, directions: hint, radius: Prefs.snapRadius * unit,
                contrast: params.contrast, minArm: params.minArm)
            {
                points[i].x = snapped.x
                points[i].y = snapped.y
                status = "Snapped to the crossing. Hold Control while letting go to place a point freely."
            }
        }
        if points[i].source == .estimated { recalculateQuietly() }
    }

    func snapSelectedToGraticule() {
        guard let s = selection, let i = index(of: s), let solution,
              let lon = points[i].lon, let lat = points[i].lat else { return }
        checkpoint("Snap to Graticule")
        let v = solution.snapped(lon: lon, lat: lat)
        points[i].lon = v.lon
        points[i].lat = v.lat
        points[i].source = .user
        hasUnsavedChanges = true
    }

    // MARK: Calculating

    func calculate(undoable: Bool = true) {
        do {
            var updated = points
            let summary = try calculateCoordinates(&updated)
            if undoable { checkpoint("Calculate Coordinates") }
            points = updated
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
            var projectionNote = ""
            if projection != nil || Prefs.writeProjectionOnSave, let guess = guessProjection(points: points) {
                projection = guess
                let file = target.deletingPathExtension().appendingPathExtension("projection.txt")
                try guess.report.write(to: file, atomically: true, encoding: .utf8)
                projectionNote = " Projection guess in \(file.lastPathComponent)."
            }
            let skipped = points.count - savableCount
            status = "Saved \(savableCount) points to \(target.lastPathComponent)."
                + (skipped > 0 ? " \(skipped) without coordinates were left out." : "") + projectionNote
        } catch {
            status = "Could not save: \(error.localizedDescription)"
        }
    }
}
