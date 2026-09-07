import SwiftUI

/// Minimal host used only by the iOS Simulator runtime tests. Keeping this host
/// independent of HTTrailCore avoids pulling the proxy's SwiftPM dependency graph
/// into the model-runtime XCTest bundle while still making the exact production
/// model resources available through Bundle.main.
@main
struct ImageFilterRuntimeHostApp: App {
    var body: some Scene {
        WindowGroup {
            Color.clear
                .ignoresSafeArea()
                .accessibilityHidden(true)
        }
    }
}
