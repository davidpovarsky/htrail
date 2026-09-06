import SwiftUI
import UIKit

/// Embeds the complete UI/lifecycle of the pinned AI-Image-Classifier app inside
/// HTTrail. The vendor app's original `@main` file is deliberately excluded from
/// this framework target; everything it did around `ContentView` is reproduced
/// here so the server, diagnostics and original UI keep their existing behavior.
public struct EmbeddedImageFilterRootView: View {
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some View {
        ContentView()
            .task { try? await DiagnosticLogService.shared.startSession() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                Task {
                    try? await DiagnosticLogService.shared.log(
                        level: "warning",
                        category: "system",
                        event: "memoryWarningReceived"
                    )
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
                Task {
                    try? await DiagnosticLogService.shared.log(
                        level: "info",
                        category: "system",
                        event: "thermalStateChanged",
                        details: ["state": String(ProcessInfo.processInfo.thermalState.rawValue)]
                    )
                }
            }
            .onChange(of: scenePhase) { _, phase in
                Task {
                    try? await DiagnosticLogService.shared.log(
                        level: "info",
                        category: "lifecycle",
                        event: "scenePhaseChanged",
                        details: ["phase": String(describing: phase)]
                    )
                }
            }
    }
}
