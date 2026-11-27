import SwiftUI

@main
struct PurelineWireGuardValidationApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                #if DEBUG
                if UserDefaults.standard.bool(forKey: "purelineLab") {
                    PurelineFilteringLabView()
                } else {
                    PurelineWireGuardView()
                }
                #else
                PurelineWireGuardView()
                #endif
            }
        }
    }
}
