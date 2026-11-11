import AppKit
import PointFinderCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
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
                .onAppear { SelfCheck.runIfRequested(model: model) }
        }
        .handlesExternalEvents(matching: ["*"])
        .commands {
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
                Divider()
                Toggle("Add Points", isOn: $model.addMode).keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Delete Selected Point") { model.deleteSelected() }.disabled(model.selection == nil)
                Divider()
                Toggle("Show Detected Lines", isOn: $model.showLines)
                Toggle("Show Labels", isOn: $model.showLabels)
                Button("Zoom to Fit") { model.fitRequest += 1 }.keyboardShortcut("0")
            }
        }
    }
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
            }
            if let out = ProcessInfo.processInfo.environment["PF_SNAPSHOT_SAVE"] {
                try? GCPFile.write(model.points, to: URL(fileURLWithPath: out))
            }
            NSApp.terminate(nil)
        }
    }
}
