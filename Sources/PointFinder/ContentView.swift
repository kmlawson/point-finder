import PointFinderCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                ZStack {
                    MapCanvas(model: model)
                    if model.image == nil { emptyState }
                }
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                Sidebar()
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 460, maxHeight: .infinity)
            }
            Divider()
            statusBar
        }
        .toolbar { toolbar }
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

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.openPanel() } label: { Label("Open", systemImage: "folder") }
                .help("Open a map image (⌘O)")
        }
        ToolbarItemGroup(placement: .principal) {
            Button { model.detect() } label: { Label("Detect", systemImage: "viewfinder") }
                .help("Find graticule intersections (⌘D)")
                .disabled(model.image == nil || model.busy != nil)
            Button { showSettings.toggle() } label: { Label("Detection Settings", systemImage: "slider.horizontal.3") }
                .help("Adjust how lines are detected")
                .disabled(model.image == nil)
                .popover(isPresented: $showSettings, arrowEdge: .bottom) { DetectionSettings() }
            Toggle(isOn: $model.regionMode) { Label("Second Opinion", systemImage: "rectangle.dashed") }
                .help("Drag a rectangle on the map to search that area again for missed intersections")
                .disabled(model.image == nil || model.busy != nil || !model.hasGrid)
            Toggle(isOn: $model.addMode) { Label("Add Points", systemImage: "plus.viewfinder") }
                .help("Click the map to add a point (or Option-click at any time)")
                .disabled(model.image == nil)
            Button { model.calculate() } label: { Label("Calculate", systemImage: "function") }
                .help("Work out every other point from your reference points (⌘K)")
                .disabled(model.referenceCount < 2)
            Button { model.save() } label: { Label("Save", systemImage: "square.and.arrow.down") }
                .help("Save a .points file for the QGIS Georeferencer (⌘S)")
                .disabled(model.savableCount == 0)
        }
        ToolbarItemGroup(placement: .automatic) {
            Menu {
                Toggle("Detected Lines", isOn: $model.showLines)
                Toggle("Coordinate Labels", isOn: $model.showLabels)
                Divider()
                Button("Zoom to Fit") { model.fitRequest += 1 }
            } label: {
                Label("View", systemImage: "eye")
            }
        }
    }
}

private struct DetectionSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var showSearchSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                    + (p.isGridPoint ? "  ·  column \(p.col! + 1), row \(p.row! + 1)" : ""))
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

private struct PointTable: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Table(model.points, selection: Binding(get: { model.selection }, set: { newValue in
            model.selection = newValue
            if newValue != nil { model.revealRequest += 1 }
        })) {
            TableColumn("Use") { p in
                Toggle("", isOn: Binding(get: { p.enabled }, set: { model.setEnabled(id: p.id, $0) }))
                    .labelsHidden()
            }
            .width(30)
            TableColumn("Longitude") { p in
                Text(p.lon.map { formatCoordinate($0, axis: .longitude) } ?? "—").monospacedDigit()
            }
            TableColumn("Latitude") { p in
                Text(p.lat.map { formatCoordinate($0, axis: .latitude) } ?? "—").monospacedDigit()
            }
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
