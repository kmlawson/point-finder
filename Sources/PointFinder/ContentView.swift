import PointFinderCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false
    @AppStorage(Prefs.Key.loupeEnabled) private var loupeEnabled = true
    @AppStorage(Prefs.Key.snapOnDrop) private var snapOnDrop = true

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VStack(spacing: 0) {
                    ZStack {
                        MapCanvas(model: model)
                        if model.image == nil { emptyState }
                    }
                    if model.reviewing {
                        Divider()
                        ReviewBar()
                    }
                }
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                Sidebar()
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 460, maxHeight: .infinity)
            }
            Divider()
            statusBar
        }
        .toolbar(id: "main") {
            fileItems
            workflowItems
            pointItems
            viewItems
            switchItems
        }
        .navigationTitle(model.imageURL?.lastPathComponent ?? "Point Finder")
        .navigationSubtitle(model.hasUnsavedChanges ? "Edited" : "")
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in model.open(url) } }
            }
            return true
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "map").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Open a map image").font(.title2)
            Text("Drop a scan here or choose a file. Graticule intersections are found automatically.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Open Image…") { model.openPanel() }.controlSize(.large)
        }
        .padding(32)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if let busy = model.busy {
                ProgressView(value: model.progress).frame(width: 120)
                Text(busy)
            } else {
                Text(model.status)
            }
            Spacer()
            if model.image != nil {
                Text("\(model.points.count) points · \(model.savableCount) with coordinates")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .lineLimit(2)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 30)
    }

    // The toolbar is customisable: right-click it, or View ▸ Customize Toolbar…,
    // to add, remove and rearrange these. Items marked `shown: false` start in
    // the customisation sheet, not in the toolbar.

    private func item<V: View>(_ id: String, shown: Bool = true, @ViewBuilder _ content: () -> V)
        -> ToolbarItem<String, V>
    {
        ToolbarItem(id: id, placement: .automatic, showsByDefault: shown, content: content)
    }

    private var canSearch: Bool { model.image != nil && model.busy == nil && model.hasGrid }
    private var canSnapSelection: Bool {
        guard let p = model.selectedPoint else { return false }
        return !p.isGridPoint && model.solution != nil && p.hasCoordinate
    }

    @ToolbarContentBuilder
    private var fileItems: some CustomizableToolbarContent {
        item("open") {
            Button { model.openPanel() } label: { Label("Open", systemImage: "folder") }
                .help("Open a map image (⌘O)")
        }
        item("save") {
            Button { model.save() } label: { Label("Save", systemImage: "square.and.arrow.down") }
                .help("Save a .points file for the QGIS Georeferencer (⌘S)")
                .disabled(model.savableCount == 0)
        }
        item("saveAs", shown: false) {
            Button { model.save(askForLocation: true) } label: {
                Label("Save As", systemImage: "square.and.arrow.down.on.square")
            }
            .help("Save the points under another name or in another place (⇧⌘S)")
            .disabled(model.savableCount == 0)
        }
        item("undo") {
            Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .help("\(model.undoTitle) (⌘Z)")
                .disabled(!model.canUndo)
        }
        item("redo") {
            Button { model.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .help("\(model.redoTitle) (⇧⌘Z)")
                .disabled(!model.canRedo)
        }
    }

    @ToolbarContentBuilder
    private var workflowItems: some CustomizableToolbarContent {
        item("detect") {
            Button { model.detect() } label: { Label("Detect", systemImage: "viewfinder") }
                .help("Find graticule intersections (⌘D)")
                .disabled(model.image == nil || model.busy != nil)
        }
        item("detectionSettings") {
            Button { showSettings.toggle() } label: { Label("Detection Settings", systemImage: "slider.horizontal.3") }
                .help("Adjust how lines are detected")
                .disabled(model.image == nil)
                .popover(isPresented: $showSettings, arrowEdge: .bottom) { DetectionSettings() }
        }
        item("secondOpinion") {
            Toggle(isOn: $model.regionMode) { Label("Second Opinion", systemImage: "rectangle.dashed") }
                .help("Drag a rectangle on the map to search that area again for missed intersections (⌘R)")
                .disabled(!canSearch)
        }
        item("readLabels") {
            Button { model.readMarginLabels() } label: { Label("Read Labels", systemImage: "text.viewfinder") }
                .help("Read the degree numbers in the margins and propose the grid's coordinates (⌘L)")
                .disabled(!canSearch)
        }
        item("calculate") {
            Button { model.calculate() } label: { Label("Calculate", systemImage: "function") }
                .help("Work out every other point from your reference points (⌘K)")
                .disabled(model.referenceCount < 2)
        }
        item("review") {
            // A fixed name, so the item reads the same in the customisation sheet.
            Toggle(isOn: Binding(
                get: { model.reviewing },
                set: { if $0 { model.startReview() } else { model.endReview() } })
            ) {
                Label("Review", systemImage: "checklist")
            }
            .help("Step through the inferred and low-confidence points one at a time (⇧⌘R)")
            .disabled(model.image == nil || !model.hasGrid)
        }
        item("projection", shown: false) {
            Button { model.guessProjectionNow() } label: { Label("Guess Projection", systemImage: "globe") }
                .help("Judge the map's projection from the shape of its grid")
                .disabled(!model.hasGrid)
        }
    }

    @ToolbarContentBuilder
    private var pointItems: some CustomizableToolbarContent {
        item("addPoints") {
            Toggle(isOn: $model.addMode) { Label("Add Points", systemImage: "plus.viewfinder") }
                .help("Click the map to add a point (or Option-click at any time) (⇧⌘A)")
                .disabled(model.image == nil)
        }
        item("deletePoint", shown: false) {
            Button { model.deleteSelected() } label: { Label("Delete Point", systemImage: "trash") }
                .help("Remove the selected point (Delete)")
                .disabled(model.selection == nil)
        }
        item("typeCoordinates", shown: false) {
            Button { model.editRequest += 1 } label: { Label("Coordinates", systemImage: "character.cursor.ibeam") }
                .help("Type the selected point's longitude and latitude (Return)")
                .disabled(model.selection == nil)
        }
        item("snapToGraticule", shown: false) {
            Button { model.snapSelectedToGraticule() } label: { Label("Snap to Graticule", systemImage: "grid") }
                .help("Round the selected added point to the nearest crossing of the map's grid lines")
                .disabled(!canSnapSelection)
        }
        item("previousColumn", shown: false) {
            Button { model.selectNeighbour(.left) } label: { Label("West", systemImage: "arrow.left") }
                .help("Select the next intersection to the left (⌘←)")
                .disabled(model.selection == nil)
        }
        item("nextColumn", shown: false) {
            Button { model.selectNeighbour(.right) } label: { Label("East", systemImage: "arrow.right") }
                .help("Select the next intersection to the right (⌘→)")
                .disabled(model.selection == nil)
        }
        item("previousRow", shown: false) {
            Button { model.selectNeighbour(.up) } label: { Label("North", systemImage: "arrow.up") }
                .help("Select the next intersection above (⌘↑)")
                .disabled(model.selection == nil)
        }
        item("nextRow", shown: false) {
            Button { model.selectNeighbour(.down) } label: { Label("South", systemImage: "arrow.down") }
                .help("Select the next intersection below (⌘↓)")
                .disabled(model.selection == nil)
        }
    }

    @ToolbarContentBuilder
    private var viewItems: some CustomizableToolbarContent {
        item("zoomOut", shown: false) {
            Button { model.zoom(by: 1 / 1.5) } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                .help("Zoom out (⌘−)")
                .disabled(model.image == nil)
        }
        item("zoomIn", shown: false) {
            Button { model.zoom(by: 1.5) } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
                .help("Zoom in (⌘+)")
                .disabled(model.image == nil)
        }
        item("actualSize", shown: false) {
            Button { model.zoom(by: 0) } label: { Label("Actual Size", systemImage: "1.magnifyingglass") }
                .help("Show one image pixel per screen point (⌘1)")
                .disabled(model.image == nil)
        }
        item("zoomToFit") {
            Button { model.fitRequest += 1 } label: {
                Label("Zoom to Fit", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .help("Show the whole map (⌘0)")
            .disabled(model.image == nil)
        }
        item("zoomToSelection", shown: false) {
            Button { model.zoomToSelection() } label: { Label("Zoom to Selection", systemImage: "scope") }
                .help("Centre and zoom in on the selected point (⌘E)")
                .disabled(model.selection == nil)
        }
        item("showLines", shown: false) {
            Toggle(isOn: $model.showLines) { Label("Lines", systemImage: "squareshape.split.3x3") }
                .help("Show or hide the detected grid lines")
        }
        item("showLabels", shown: false) {
            Toggle(isOn: $model.showLabels) { Label("Labels", systemImage: "tag") }
                .help("Show or hide the coordinate labels beside the points")
        }
        item("viewMenu") {
            Menu {
                Toggle("Detected Lines", isOn: $model.showLines)
                Toggle("Coordinate Labels", isOn: $model.showLabels)
                Divider()
                Button("Zoom In") { model.zoom(by: 1.5) }
                Button("Zoom Out") { model.zoom(by: 1 / 1.5) }
                Button("Actual Size") { model.zoom(by: 0) }
                Button("Zoom to Fit") { model.fitRequest += 1 }
                Button("Zoom to Selection") { model.zoomToSelection() }.disabled(model.selection == nil)
                Divider()
                Button("Guess Projection…") { model.guessProjectionNow() }.disabled(!model.hasGrid)
            } label: {
                Label("View", systemImage: "eye")
            }
            .help("What is drawn on the map, and zooming")
        }
    }

    @ToolbarContentBuilder
    private var switchItems: some CustomizableToolbarContent {
        item("magnifier", shown: false) {
            Toggle(isOn: $loupeEnabled) { Label("Magnifier", systemImage: "magnifyingglass.circle") }
                .help("Show a magnifier while a point is dragged")
        }
        item("snapOnDrop", shown: false) {
            Toggle(isOn: $snapOnDrop) { Label("Snap", systemImage: "dot.scope") }
                .help("Snap a dropped point onto the nearest crossing (hold Control to place it freely)")
        }
        item("preferences", shown: false) {
            Group {
                if #available(macOS 14, *) {
                    SettingsLink { Label("Preferences", systemImage: "gearshape") }
                } else {
                    Button {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    } label: {
                        Label("Preferences", systemImage: "gearshape")
                    }
                }
            }
            .help("Magnifier, snapping, review and automation settings (⌘,)")
        }
    }
}

private struct DetectionSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var showSearchSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Picker("Graticule", selection: $model.params.style) {
                    Text("Lines across the map").tag(GraticuleStyle.lines)
                    Text("Ticks on the frame only").tag(GraticuleStyle.ticks)
                }
                if model.params.style == .ticks {
                    Text("Joins each tick to the one opposite with a straight line and marks where the lines "
                        + "cross. Right for maps with straight meridians and parallels; approximate otherwise.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Line contrast: \(model.params.contrast)")
                Slider(
                    value: Binding(
                        get: { Double(model.params.contrast) }, set: { model.params.contrast = Int($0) }),
                    in: 10...90)
                Text("Lower finds fainter lines; higher ignores more clutter.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Shortest line: \(Int(model.params.minLineFraction * 100))% of the image's shorter side")
                Slider(value: $model.params.minLineFraction, in: 0.08...0.6)
                Text("Lower picks up short lines, such as those of an inset map.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle(
                "Black ink only (ignore coloured lines)",
                isOn: Binding(
                    get: { model.params.ink == .blackOnly }, set: { model.params.ink = $0 ? .blackOnly : .anyDark }))
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Infer hidden intersections from the lines", isOn: $model.params.inferMissing)
                Text("Adds a red point where two found lines cross under lettering, where one runs "
                    + "through a gap in the other, or (second opinion) in a gap between known "
                    + "points. Check these against the map.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            DisclosureGroup("Guided search and second opinion", isExpanded: $showSearchSettings) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Search where the grid predicts a crossing", isOn: $model.params.searchMissing)
                        Text("After the lines are numbered, looks for crossings they imply but the line "
                            + "search missed: a line found on one page only, or a short or broken line.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Search distance: \(Int((model.params.searchFraction * 100).rounded()))% of the grid spacing")
                        Slider(value: $model.params.searchFraction, in: 0.04...0.3)
                        Text("How far from the predicted spot a crossing may be. Raise it for pages that "
                            + "have slipped a long way at the gutter; lower it if wrong lines are picked up.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Line must show along: \(Int((model.params.searchMinLine * 100).rounded()))% of its length")
                        Slider(value: $model.params.searchMinLine, in: 0.25...0.9)
                        Text("Lower accepts lines broken by lettering; higher rejects more look-alikes.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Second opinion leniency: \(Int((model.params.secondOpinionLeniency * 100).rounded()))%")
                        Slider(value: $model.params.secondOpinionLeniency, in: 0...1)
                        Text("How much fainter, more broken and further from the predicted spot a crossing "
                            + "may be when you ask for a second opinion on an area.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Toggle("Second opinion may add a line beyond the grid", isOn: $model.params.secondOpinionNewLines)
                    }
                }
                .padding(.top, 8)
            }
            HStack {
                Button("Defaults") { model.params = DetectionParams() }
                Spacer()
                Button("Detect Again") { model.detect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.busy != nil)
            }
            Text("Points you added, and points you gave coordinates to, are kept.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 340)
    }
}

private struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Inspector()
            Divider()
            PointTable()
        }
    }
}

private func sourceName(_ p: MapPoint) -> String {
    switch p.source {
    case .user: return p.isGridPoint ? "Reference" : "Entered"
    case .calculated: return "Calculated"
    case .estimated: return "Estimated"
    case nil: return "—"
    }
}

private func sourceColor(_ p: MapPoint) -> Color {
    if !p.enabled { return .gray }
    if p.inferred && p.source != .user { return Color(red: 0.85, green: 0.1, blue: 0.15) }
    switch p.source {
    case .user: return Color(red: 0, green: 0.42, blue: 1)
    case .calculated: return Color(red: 0, green: 0.62, blue: 0.25)
    case .estimated: return Color(red: 0.62, green: 0.25, blue: 0.85)
    case nil: return .orange
    }
}

/// Shows the selected point and takes its longitude and latitude.
private struct Inspector: View {
    @EnvironmentObject var model: AppModel
    @State private var lonText = ""
    @State private var latText = ""
    @State private var message: String?
    @FocusState private var focus: Field?

    private enum Field { case lon, lat }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let p = model.selectedPoint {
                HStack {
                    Image(systemName: p.isGridPoint ? "circle" : "square")
                        .foregroundStyle(sourceColor(p))
                        .fontWeight(.bold)
                    Text(p.isGridPoint ? (p.inferred ? "Inferred intersection" : "Detected intersection") : "Added point")
                        .font(.headline)
                    Spacer()
                    Button(role: .destructive) { model.delete(id: p.id) } label: { Image(systemName: "trash") }
                        .help("Delete this point (Delete key)")
                }
                Text(String(format: "Pixel %.1f, %.1f", p.x, p.y)
                    + (p.isGridPoint ? "  ·  column \(p.col! + 1), row \(p.row! + 1)" : "")
                    + (p.isGridPoint ? (p.inferred ? "  ·  inferred" : "  ·  confidence \(confidenceText(p))") : ""))
                    .font(.callout).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text("Longitude")
                        TextField("e.g. 110E or -110.5", text: $lonText)
                            .focused($focus, equals: .lon)
                            .onSubmit { focus = .lat }
                    }
                    GridRow {
                        Text("Latitude")
                        TextField("e.g. 35N or 35°30'S", text: $latText)
                            .focused($focus, equals: .lat)
                            .onSubmit { apply(p) }
                    }
                }
                .textFieldStyle(.roundedBorder)
                if let message {
                    Text(message).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Set") { apply(p) }.keyboardShortcut(.defaultAction)
                    Button("Clear") {
                        model.clearCoordinate(id: p.id)
                        load()
                    }
                    .disabled(!p.hasCoordinate)
                    if !p.isGridPoint && model.solution != nil && p.hasCoordinate {
                        Button("Snap to Graticule") {
                            model.snapSelectedToGraticule()
                            load()
                        }
                        .help("Round to the nearest crossing of the map's grid lines")
                    }
                    Spacer()
                    Toggle("Use", isOn: Binding(get: { p.enabled }, set: { model.setEnabled(id: p.id, $0) }))
                        .help("Unchecked points are saved switched off")
                }
                Text(hint(for: p)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No point selected").font(.headline)
                Text(generalHint).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: model.selection) { _ in load() }
        .onChange(of: model.selectedPoint?.lon) { _ in if focus == nil { load() } }
        .onChange(of: model.selectedPoint?.lat) { _ in if focus == nil { load() } }
        .onChange(of: model.editRequest) { _ in focus = .lon }
        .onAppear { load() }
    }

    private var generalHint: String {
        if model.image == nil { return "Open a map image to begin." }
        if !model.hasGrid {
            return "Click a point to select it. Option-click the map to add a point. "
                + "Press Detect to find graticule intersections."
        }
        if model.solution == nil {
            return "Click an orange intersection and type its longitude and latitude. Do this for two "
                + "intersections that are diagonal from each other, then press Calculate."
        }
        return "Drag a point to adjust it, or use the arrow keys. Option-click the map to add a point."
    }

    private func hint(for p: MapPoint) -> String {
        switch p.source {
        case .user where p.isGridPoint: return "Reference point: the grid is calculated from these."
        case .user: return "Coordinates entered by hand."
        case .calculated: return "Calculated from the grid. Type a value to override it."
        case .estimated: return "Estimated from the surrounding grid. Type the true value, or snap it to the graticule."
        case nil:
            return "Drag to move, arrow keys to nudge (⇧ ×10, ⌥ ×0.1). Press Return on the map to type coordinates."
        }
    }

    private func load() {
        message = nil
        guard let p = model.selectedPoint else {
            lonText = ""
            latText = ""
            return
        }
        lonText = p.lon.map { formatCoordinate($0, axis: .longitude) } ?? ""
        latText = p.lat.map { formatCoordinate($0, axis: .latitude) } ?? ""
    }

    private func apply(_ p: MapPoint) {
        message = model.setCoordinate(id: p.id, lonText: lonText, latText: latText)
        if message == nil {
            focus = nil
            load()
        }
    }
}

/// How sure the detector was of a point, for display.
private func confidenceText(_ p: MapPoint) -> String {
    if p.inferred { return "inferred" }
    guard let q = p.quality else { return "—" }
    return "\(Int((q * 100).rounded()))%" + (p.reviewed ? " ✓" : "")
}

/// Values the points table sorts by. Missing values sort first.
extension MapPoint {
    var sortLongitude: Double { lon ?? -.infinity }
    var sortLatitude: Double { lat ?? -.infinity }
    /// Inferred points sort below everything the detector saw; points without a score sort last.
    var sortConfidence: Double { inferred ? -1 : (quality ?? 2) }
}

/// The strip under the map while stepping through doubtful points.
private struct ReviewBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Text("Review \(min(model.reviewPosition + 1, model.reviewIDs.count)) of \(model.reviewIDs.count)")
                .font(.headline).monospacedDigit()
            if let p = model.selectedPoint {
                Text(p.inferred ? "Inferred: not seen in the image" : "Confidence \(confidenceText(p))")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Previous") { model.reviewStep(-1) }.disabled(model.reviewPosition == 0)
            Button("Skip") { model.reviewStep(1) }.help("Leave it as it is and go on (Tab or Space)")
            Button("Delete") { model.reviewDelete() }.help("Remove this point (Delete)")
            Button("Accept") { model.reviewAccept() }
                .help("It is in the right place (Return). Nudge it with the arrow keys first if not.")
                .buttonStyle(.borderedProminent)
            Button("Done") { model.endReview() }.help("Stop reviewing (Esc)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct PointTable: View {
    @EnvironmentObject var model: AppModel
    @State private var sortOrder: [KeyPathComparator<MapPoint>] = []

    private var rows: [MapPoint] { sortOrder.isEmpty ? model.points : model.points.sorted(using: sortOrder) }

    var body: some View {
        Table(rows, selection: Binding(get: { model.selection }, set: { newValue in
            model.selection = newValue
            if newValue != nil { model.revealRequest += 1 }
        }), sortOrder: $sortOrder) {
            TableColumn("Use") { p in
                Toggle("", isOn: Binding(get: { p.enabled }, set: { model.setEnabled(id: p.id, $0) }))
                    .labelsHidden()
            }
            .width(30)
            TableColumn("Longitude", value: \.sortLongitude) { p in
                Text(p.lon.map { formatCoordinate($0, axis: .longitude) } ?? "—").monospacedDigit()
            }
            TableColumn("Latitude", value: \.sortLatitude) { p in
                Text(p.lat.map { formatCoordinate($0, axis: .latitude) } ?? "—").monospacedDigit()
            }
            TableColumn("Conf.", value: \.sortConfidence) { p in
                Text(confidenceText(p)).monospacedDigit()
                    .foregroundStyle(p.inferred ? Color(red: 0.85, green: 0.1, blue: 0.15) : .primary)
            }
            .width(min: 44, ideal: 58)
            TableColumn("Source") { p in
                HStack(spacing: 5) {
                    Image(systemName: p.isGridPoint ? "circle.fill" : "square.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(sourceColor(p))
                    Text(sourceName(p))
                }
            }
        }
        .onDeleteCommand { model.deleteSelected() }
    }
}
