import AppKit
import PointFinderCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Offers to save control points that have not been written to a file.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.hasUnsavedChanges, model.savableCount > 0,
              ProcessInfo.processInfo.environment["PF_SNAPSHOT_DIR"] == nil else { return .terminateNow }
        // After the window has been closed there is nothing to go back to, so no Cancel.
        let canCancel = sender.windows.contains { $0.isVisible && $0.canBecomeMain }
        let alert = NSAlert()
        alert.messageText = "Save the control points before quitting?"
        alert.informativeText = "\(model.savableCount) point\(model.savableCount == 1 ? " has" : "s have") "
            + "coordinates that are not saved. They will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        if canCancel { alert.addButton(withTitle: "Cancel") }
        let discard = alert.addButton(withTitle: "Don't Save")
        discard.hasDestructiveAction = true
        while true {
            let answer = alert.runModal()
            if answer == .alertFirstButtonReturn {
                model.save()
                // Still unsaved: the save panel was cancelled or the write failed.
                if !model.hasUnsavedChanges { return .terminateNow }
                if canCancel { return .terminateCancel }
                continue
            }
            return canCancel && answer == .alertSecondButtonReturn ? .terminateCancel : .terminateNow
        }
    }
}

@main
struct PointFinderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Point Finder", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 560)
                // Files dropped on the app icon, or chosen with Open With, arrive here.
                .onOpenURL { model.open($0) }
                .onAppear {
                    delegate.model = model
                    SelfCheck.runIfRequested(model: model)
                }
        }
        .handlesExternalEvents(matching: ["*"])
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button(model.undoTitle) { model.undo() }.keyboardShortcut("z")
                Button(model.redoTitle) { model.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Button("Zoom to Selection") { model.zoomToSelection() }
                    .keyboardShortcut("e")
                    .disabled(model.selection == nil)
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Image…") { model.openPanel() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Points") { model.save() }
                    .keyboardShortcut("s")
                    .disabled(model.image == nil)
                Button("Save Points As…") { model.save(askForLocation: true) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(model.image == nil)
            }
            CommandMenu("Points") {
                Button("Detect Intersections") { model.detect() }
                    .keyboardShortcut("d")
                    .disabled(model.image == nil || model.busy != nil)
                Button("Calculate Coordinates") { model.calculate() }
                    .keyboardShortcut("k")
                    .disabled(model.referenceCount < 2)
                Button("Read Margin Labels") { model.readMarginLabels() }
                    .keyboardShortcut("l")
                    .disabled(model.image == nil || model.busy != nil || !model.hasGrid)
                Button("Guess Projection…") { model.guessProjectionNow() }
                    .disabled(!model.hasGrid)
                Divider()
                Button(model.reviewing ? "Stop Review" : "Review Doubtful Points") {
                    if model.reviewing { model.endReview() } else { model.startReview() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!model.hasGrid)
                Divider()
                Toggle("Second Opinion on an Area", isOn: $model.regionMode)
                    .keyboardShortcut("r")
                    .disabled(model.image == nil || model.busy != nil || !model.hasGrid)
                Toggle("Add Points", isOn: $model.addMode).keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Delete Selected Point") { model.deleteSelected() }.disabled(model.selection == nil)
                Divider()
                Toggle("Show Detected Lines", isOn: $model.showLines)
                Toggle("Show Labels", isOn: $model.showLabels)
                Button("Zoom to Fit") { model.fitRequest += 1 }.keyboardShortcut("0")
            }
        }
        Settings { PreferencesView() }
    }

    init() { Prefs.register() }
}

/// Development aid: when PF_SNAPSHOT_DIR is set, drives the app through its main
/// steps and writes pictures of the window there, then quits. Lets the interface
/// be checked without screen-recording permission.
@MainActor
enum SelfCheck {
    static func runIfRequested(model: AppModel) {
        guard let dir = ProcessInfo.processInfo.environment["PF_SNAPSHOT_DIR"] else { return }
        Task { @MainActor in
            @MainActor func snap(_ name: String) {
                FileHandle.standardError.write("snap \(name) windows=\(NSApp.windows.count) busy=\(model.busy ?? "-") points=\(model.points.count)\n".data(using: .utf8)!)
                guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView?.superview,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
            }
            func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
            FileHandle.standardError.write("selfcheck start\n".data(using: .utf8)!)
            await pause(1.5)
            if let path = ProcessInfo.processInfo.environment["PF_SNAPSHOT_IMAGE"] {
                model.open(URL(fileURLWithPath: path))
                await pause(0.5)
                if model.busy == nil && !model.hasGrid { model.detect() }
            }
            while model.busy != nil { await pause(0.2) }
            await pause(1)
            snap("1-detected.png")
            let grid = model.points.filter { $0.isGridPoint }
            if let a = grid.first(where: { $0.col == 1 && $0.row == 1 }),
               let b = grid.first(where: { $0.col == 8 && $0.row == 4 }) {
                _ = model.setCoordinate(id: a.id, lonText: "80E", latText: "45N")
                _ = model.setCoordinate(id: b.id, lonText: "115", latText: "30")
                model.selection = b.id
                await pause(0.6)
                snap("2-references.png")
                model.calculate()
                await pause(0.6)
                snap("3-calculated.png")
                model.addPoint(at: Vec2(2400, 1500))
                await pause(0.6)
                snap("4-added.png")
                // Undo and redo through the window's undo manager.
                let before = model.points.count
                model.undo()
                await pause(0.3)
                let undone = model.points.count
                model.redo()
                await pause(0.3)
                FileHandle.standardError.write(
                    "undo: \(before) -> \(undone) -> \(model.points.count)\n".data(using: .utf8)!)
                model.startReview()
                await pause(0.8)
                FileHandle.standardError.write(
                    "review: \(model.reviewIDs.count) points, reviewing \(model.reviewing)\n".data(using: .utf8)!)
                snap("5-review.png")
                model.reviewAccept()
                await pause(0.6)
                snap("6-review-next.png")
                model.endReview()
                if let guess = guessProjection(points: model.points) {
                    FileHandle.standardError.write("projection: \(guess.name)\n".data(using: .utf8)!)
                }
            }
            if let out = ProcessInfo.processInfo.environment["PF_SNAPSHOT_SAVE"] {
                try? GCPFile.write(model.points, to: URL(fileURLWithPath: out))
            }
            NSApp.terminate(nil)
        }
    }
}
