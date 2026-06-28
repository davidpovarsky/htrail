import SwiftUI
import AppKit
import HTTrailCore

@main
struct HTTrailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("HTTrail") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 1040, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Request") { model.mode = .compose; model.newRequest() }
                    .keyboardShortcut("n")
            }
            CommandGroup(after: .toolbar) {
                Button("Command Palette") { model.showCommandPalette.toggle() }
                    .keyboardShortcut("k")
            }
            CommandMenu("Proxy") {
                Button(model.isProxyRunning ? "Stop Proxy" : "Start Proxy") { model.toggleProxy() }
                    .keyboardShortcut("p")
                Button("Toggle System Proxy") { model.toggleSystemProxy() }
                Divider()
                Button("Reveal Root CA…") { model.revealCACertificate() }
                Button("Export iOS Profile…") { model.exportiOSProfile() }
                Divider()
                Button("Clear Captured Flows") { model.clearFlows() }
            }
        }
    }
}

/// SPM executables launch as accessory apps by default; promote to a regular
/// foreground app so the window and menu bar behave normally.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
