import SwiftUI

/// Settings that are remembered between launches. The Preferences window edits
/// them with `@AppStorage`; the rest of the app reads them here.
enum Prefs {
    enum Key {
        static let loupeEnabled = "loupeEnabled"
        static let loupeSize = "loupeSize"
        static let loupeZoom = "loupeZoom"
        static let snapOnDrop = "snapOnDrop"
        static let snapRadius = "snapRadius"
        static let zoomOnNavigate = "zoomOnNavigate"
        static let focusZoom = "focusZoom"
        static let reviewThreshold = "reviewThreshold"
        static let readLabelsAfterDetect = "readLabelsAfterDetect"
        static let writeProjectionOnSave = "writeProjectionOnSave"
    }

    static let defaults: [String: Any] = [
        Key.loupeEnabled: true,
        Key.loupeSize: 160.0,
        Key.loupeZoom: 4.0,
        Key.snapOnDrop: true,
        Key.snapRadius: 12.0,
        Key.zoomOnNavigate: false,
        Key.focusZoom: 2.0,
        Key.reviewThreshold: 0.5,
        Key.readLabelsAfterDetect: false,
        Key.writeProjectionOnSave: false,
    ]

    static func register() { UserDefaults.standard.register(defaults: defaults) }

    private static var store: UserDefaults { UserDefaults.standard }
    static var loupeEnabled: Bool { store.bool(forKey: Key.loupeEnabled) }
    static var loupeSize: Double { store.double(forKey: Key.loupeSize) }
    static var loupeZoom: Double { store.double(forKey: Key.loupeZoom) }
    static var snapOnDrop: Bool { store.bool(forKey: Key.snapOnDrop) }
    static var snapRadius: Double { store.double(forKey: Key.snapRadius) }
    static var zoomOnNavigate: Bool { store.bool(forKey: Key.zoomOnNavigate) }
    static var focusZoom: Double { store.double(forKey: Key.focusZoom) }
    static var reviewThreshold: Double { store.double(forKey: Key.reviewThreshold) }
    static var readLabelsAfterDetect: Bool { store.bool(forKey: Key.readLabelsAfterDetect) }
    static var writeProjectionOnSave: Bool { store.bool(forKey: Key.writeProjectionOnSave) }
}

/// The Preferences window (⌘,).
struct PreferencesView: View {
    var body: some View {
        TabView {
            EditingPreferences().tabItem { Label("Editing", systemImage: "hand.point.up.left") }
            ReviewPreferences().tabItem { Label("Review", systemImage: "checklist") }
            AutomationPreferences().tabItem { Label("Automation", systemImage: "wand.and.stars") }
        }
        .frame(width: 480)
    }
}

private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

private struct EditingPreferences: View {
    @AppStorage(Prefs.Key.loupeEnabled) private var loupeEnabled = true
    @AppStorage(Prefs.Key.loupeSize) private var loupeSize = 160.0
    @AppStorage(Prefs.Key.loupeZoom) private var loupeZoom = 4.0
    @AppStorage(Prefs.Key.snapOnDrop) private var snapOnDrop = true
    @AppStorage(Prefs.Key.snapRadius) private var snapRadius = 12.0
    @AppStorage(Prefs.Key.zoomOnNavigate) private var zoomOnNavigate = false
    @AppStorage(Prefs.Key.focusZoom) private var focusZoom = 2.0

    var body: some View {
        Form {
            Section("Magnifier") {
                Toggle("Show a magnifier while dragging a point", isOn: $loupeEnabled)
                Slider(value: $loupeSize, in: 100...280) { Text("Size: \(Int(loupeSize)) pt") }
                    .disabled(!loupeEnabled)
                Slider(value: $loupeZoom, in: 2...12) { Text("Zoom: at least \(Int(loupeZoom))×") }
                    .disabled(!loupeEnabled)
                Note("The magnifier shows the map under the point enlarged, so the point can be set on a crossing "
                    + "without zooming the whole map.")
            }
            Section("Snapping") {
                Toggle("Snap a dropped point to the nearest crossing", isOn: $snapOnDrop)
                Slider(value: $snapRadius, in: 4...40) { Text("Within \(Int(snapRadius)) px") }
                    .disabled(!snapOnDrop)
                Note("When a dragged point is let go near a crossing of two lines, it moves onto the crossing. "
                    + "Hold Control while letting go to leave the point exactly where it is. Arrow-key nudges never snap.")
            }
            Section("Moving between points") {
                Toggle("Zoom in when moving to a neighbouring point", isOn: $zoomOnNavigate)
                Slider(value: $focusZoom, in: 0.5...8) {
                    Text(String(format: "Zoom to Selection: %.1f×", focusZoom))
                }
                Note("⌘ with an arrow key selects the next intersection along the same parallel or meridian. "
                    + "Zoom to Selection (⌘E) and Review use the zoom set here: 1× shows one image pixel per screen point.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct ReviewPreferences: View {
    @AppStorage(Prefs.Key.reviewThreshold) private var reviewThreshold = 0.5

    var body: some View {
        Form {
            Section("What to review") {
                Slider(value: $reviewThreshold, in: 0...1) {
                    Text("Confidence below \(Int((reviewThreshold * 100).rounded()))%")
                }
                Note("Review steps through the inferred (red) intersections, then the detected ones whose "
                    + "confidence is below this, least confident first. Confidence is the weakest of a crossing's "
                    + "four arms: 100% means the lines show clearly on every side.")
            }
            Section("Keys during review") {
                Note("Return accepts the point and moves on. Delete removes it. Arrow keys nudge it "
                    + "(⇧ ×10, ⌥ ×0.1). Tab or Space skips it. Esc ends the review.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AutomationPreferences: View {
    @AppStorage(Prefs.Key.readLabelsAfterDetect) private var readLabelsAfterDetect = false
    @AppStorage(Prefs.Key.writeProjectionOnSave) private var writeProjectionOnSave = false

    var body: some View {
        Form {
            Section("Margin labels") {
                Toggle("Read the margin labels after every detection", isOn: $readLabelsAfterDetect)
                Note("Reads the degree numbers printed along the frame (Apple Vision) and proposes the grid's "
                    + "longitudes and latitudes for you to confirm. Off: use Points ▸ Read Margin Labels when wanted. "
                    + "Reading takes a few seconds on a large scan.")
            }
            Section("Projection") {
                Toggle("Save a projection guess with the points", isOn: $writeProjectionOnSave)
                Note("Writes “<points file>.projection.txt” beside the points file each time they are saved. "
                    + "Off: it is written only after you have used Points ▸ Guess Projection for the map.")
            }
        }
        .formStyle(.grouped)
    }
}
