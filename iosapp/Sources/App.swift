import SwiftUI
import UIKit
import HTTrailCore

@main
struct HTTrailiOSApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var vpn = VPNController()

    init() { Self.configureAppearance() }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(model)
                .environmentObject(vpn)
                .preferredColorScheme(.dark)
                .tint(Theme.color.accent)
                // Always-visible floating "hide keyboard" button, app-wide.
                .modifier(FloatingKeyboardDismiss())
                // Breakpoints can fire from any tab — present globally.
                .sheet(item: $model.pendingBreakpoint) { _ in BreakpointSheet().environmentObject(model) }
                // Tail flows captured by the background Packet Tunnel extension.
                .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
                    model.refreshSharedFlows()
                    model.refreshPinnedHosts()
                    model.refreshCaptureStatus()
                }
        }
    }

    /// Match the HTTrail design: translucent dark nav + tab bars over the deep
    /// indigo app background.
    static func configureAppearance() {
        let appBG = UIColor(Theme.color.app)

        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor(Theme.color.base).withAlphaComponent(0.92)
        nav.shadowColor = UIColor.white.withAlphaComponent(0.06)
        nav.titleTextAttributes = [.foregroundColor: UIColor(Theme.color.text)]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor(Theme.color.text)]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav

        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = appBG.withAlphaComponent(0.96)
        tab.shadowColor = UIColor.white.withAlphaComponent(0.07)
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }
}

/// Mobile-idiomatic layout that exposes the **same feature set** as the macOS
/// app: Capture, Compose, Rules, Realtime, Setup.
struct RootTabView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        TabView(selection: $model.selectedTab) {
            CaptureView()
                .tabItem { Label("Capture", systemImage: "dot.radiowaves.left.and.right") }.tag(0)
            ComposeView()
                .tabItem { Label("Compose", systemImage: "paperplane") }.tag(1)
            RulesView()
                .tabItem { Label("Rules", systemImage: "slider.horizontal.3") }.tag(2)
            RealtimeView()
                .tabItem { Label("Realtime", systemImage: "bolt.horizontal") }.tag(3)
            SetupView()
                .tabItem { Label("Setup", systemImage: "shield.lefthalf.filled") }.tag(4)
        }
    }
}

/// Adds a "dismiss keyboard" button to the keyboard accessory bar. Apply to any
/// `NavigationStack` containing editable fields so the software keyboard can
/// always be hidden.
/// Tracks software-keyboard visibility/height via UIKit notifications so SwiftUI
/// can react to it (SwiftUI has no native "is the keyboard up?" signal).
final class KeyboardObserver: ObservableObject {
    @Published var height: CGFloat = 0
    private var tokens: [NSObjectProtocol] = []

    init() {
        let nc = NotificationCenter.default
        tokens.append(nc.addObserver(forName: UIResponder.keyboardWillShowNotification,
                                     object: nil, queue: .main) { [weak self] note in
            if let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                self?.height = frame.height
            }
        })
        tokens.append(nc.addObserver(forName: UIResponder.keyboardWillHideNotification,
                                     object: nil, queue: .main) { [weak self] _ in
            self?.height = 0
        })
    }

    deinit { tokens.forEach { NotificationCenter.default.removeObserver($0) } }

    var isVisible: Bool { height > 0 }
}

/// A floating circular "hide keyboard" button that appears just above the
/// software keyboard whenever it's up — works on every screen regardless of
/// whether the keyboard's input-accessory toolbar renders. Always discoverable.
struct FloatingKeyboardDismiss: ViewModifier {
    @StateObject private var keyboard = KeyboardObserver()

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomTrailing) {
            if keyboard.isVisible {
                Button {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(Circle().fill(Theme.color.accent))
                        .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
                }
                .padding(.trailing, 16)
                .padding(.bottom, 10)
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Hide keyboard")
            }
        }
        .animation(.easeOut(duration: 0.18), value: keyboard.isVisible)
    }
}

struct KeyboardDismissButton: ViewModifier {
    func body(content: Content) -> some View {
        content
            // Drag any scrollable content (Forms, Lists, editors) down to dismiss…
            .scrollDismissesKeyboard(.interactively)
            // …or tap the explicit Done button in the keyboard accessory bar
            // (the only option for number-pad fields, which have no return key).
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    } label: {
                        // Explicit "Done" text (not just an icon) so it's an
                        // obvious way to dismiss the keyboard, incl. number pads.
                        Label("Done", systemImage: "keyboard.chevron.compact.down")
                            .labelStyle(.titleAndIcon)
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
    }
}

extension View {
    func keyboardDismissButton() -> some View { modifier(KeyboardDismissButton()) }
}
