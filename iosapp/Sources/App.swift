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
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor(Theme.color.base).withAlphaComponent(0.92)
        nav.shadowColor = UIColor.white.withAlphaComponent(0.06)
        nav.titleTextAttributes = [.foregroundColor: UIColor(Theme.color.text)]
        // Design header: 28px / weight 800 / letter-spacing -.02em.
        nav.largeTitleTextAttributes = [
            .foregroundColor: UIColor(Theme.color.text),
            .font: UIFont.systemFont(ofSize: 28, weight: .heavy),
            .kern: -0.5,
        ]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav

        // Translucent, blurred tab bar over the deep indigo background to match the
        // design's `rgba(11,9,26,.85)` + `backdrop-filter:blur(20px)` chrome.
        let tab = UITabBarAppearance()
        tab.configureWithDefaultBackground()
        tab.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        tab.backgroundColor = UIColor(Theme.color.base).withAlphaComponent(0.85)
        tab.shadowColor = UIColor.white.withAlphaComponent(0.08)

        // Active tab tinted with the accent, inactive in the faint tertiary tier,
        // labels at the design's ~9.5px / semibold.
        let normalColor = UIColor(Theme.color.textFaint)
        let selectedColor = UIColor(Theme.color.accent)
        let labelFont = UIFont.systemFont(ofSize: 10, weight: .semibold)
        let item = UITabBarItemAppearance()
        item.normal.iconColor = normalColor
        item.normal.titleTextAttributes = [.foregroundColor: normalColor, .font: labelFont]
        item.selected.iconColor = selectedColor
        item.selected.titleTextAttributes = [.foregroundColor: selectedColor, .font: labelFont]
        tab.stackedLayoutAppearance = item
        tab.inlineLayoutAppearance = item
        tab.compactInlineLayoutAppearance = item

        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }
}

/// The design's green "Live" status pill shown in the screen header — a glowing
/// dot + label in a translucent green capsule. Mirrors the on-device capture
/// indicator from the iOS design chrome.
struct LiveStatusPill: View {
    let active: Bool
    var body: some View {
        HStack(spacing: 7) {
            ConnectionDot(status: active ? .live : .off)
                .scaleEffect(7.0 / 8.0)  // design dot is 7px; ConnectionDot is 8px
            Text(active ? "Live" : "Idle")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(active ? Color(hex: "#6EE7B7") : Theme.color.textMuted)
        }
        .padding(.horizontal, 11).padding(.vertical, 5)
        .background(
            (active ? Theme.color.green : Theme.color.textFaint).opacity(0.14),
            in: Capsule())
        .overlay(Capsule().strokeBorder(
            (active ? Theme.color.green : Theme.color.textFaint).opacity(0.30), lineWidth: 1))
    }
}

/// The HTTrail brand mark — a compact rounded-square glyph carrying the logo's
/// signature request-trail gradient (violet → blue → cyan → green). Drawn in
/// SwiftUI so it stays crisp at nav-bar sizes without shipping a raster asset.
struct BrandMark: View {
    var size: CGFloat = 26
    private let trail = LinearGradient(
        colors: [Color(hex: "#8B5CF6"), Color(hex: "#3B82F6"),
                 Color(hex: "#06B6D4"), Color(hex: "#10B981")],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(trail)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.white))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1))
            .shadow(color: Color(hex: "#3B82F6").opacity(0.35), radius: 4, y: 1)
            .accessibilityHidden(true)
    }
}

/// The consistent header bar shown at the very top of every root tab: the brand
/// mark + screen title on the left, a status/action cluster on the right. Drawn
/// as our own bar (not the system navigation bar) so we fully control sizing and
/// spacing and avoid the platform's circular toolbar-item glass backgrounds,
/// which clashed with the square logo and crowded the trailing buttons.
struct ScreenHeader<Trailing: View>: View {
    let title: String
    let trailing: Trailing
    var body: some View {
        HStack(spacing: 11) {
            BrandMark(size: 30)
            Text(title)
                .font(.system(size: 24, weight: .heavy))
                .kerning(-0.5)
                .foregroundStyle(Theme.color.text)
            Spacer(minLength: 8)
            trailing
                .font(.system(size: 17, weight: .semibold))
                .tint(Theme.color.accent)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(alignment: .bottom) {
            Rectangle().fill(Theme.color.hairline).frame(height: 1)
        }
        .background(Theme.color.base.opacity(0.92))
    }
}

/// Installs the shared header above a root tab and hides the system nav bar so
/// only one top bar is ever shown. Pushed destinations keep their own nav bar.
private struct ScreenChrome<Trailing: View>: ViewModifier {
    let title: String
    let trailing: Trailing
    func body(content: Content) -> some View {
        content
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                ScreenHeader(title: title, trailing: trailing)
            }
    }
}

extension View {
    /// Apply the shared screen chrome with a trailing status/action cluster.
    func htScreenChrome<Trailing: View>(_ title: String,
                                        @ViewBuilder trailing: () -> Trailing) -> some View {
        modifier(ScreenChrome(title: title, trailing: trailing()))
    }
    /// Apply the shared screen chrome with no trailing content.
    func htScreenChrome(_ title: String) -> some View {
        modifier(ScreenChrome(title: title, trailing: EmptyView()))
    }
}

/// Mobile-idiomatic layout that exposes the **same feature set** as the macOS
/// app: Capture, Compose, Rules, Realtime, Setup.
struct RootTabView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        TabView(selection: $model.selectedTab) {
            // Per-tab icons mirror the design's tab glyphs: signal wave, braces,
            // funnel, lightning bolt, gear.
            CaptureView()
                .tabItem { Label("Capture", systemImage: "waveform.path.ecg") }.tag(0)
            ComposeView()
                .tabItem { Label("Compose", systemImage: "curlybraces") }.tag(1)
            RulesView()
                .tabItem { Label("Rules", systemImage: "line.3.horizontal.decrease") }.tag(2)
            RealtimeView()
                .tabItem { Label("Realtime", systemImage: "bolt.fill") }.tag(3)
            SetupView()
                .tabItem { Label("Setup", systemImage: "gearshape") }.tag(4)
        }
        // QA seam: `-htInitialTab N` launch arg (auto-mapped into UserDefaults by
        // iOS) selects a starting tab for screenshots. No-op in normal use.
        .onAppear {
            #if DEBUG
            // `-htDemo 1` seeds rich sample data for App Store screenshots.
            if UserDefaults.standard.bool(forKey: "htDemo") { model.seedDemoData() }
            #endif
            let t = UserDefaults.standard.integer(forKey: "htInitialTab")
            if t > 0 { model.selectedTab = t }
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
            // Drag any scrollable content (Forms, Lists, editors) down to dismiss.
            // The single, always-available dismiss control is the floating button
            // applied app-wide (see `FloatingKeyboardDismiss`); we intentionally do
            // NOT add a second "Done" button in the keyboard accessory bar — having
            // both made the dismiss affordance inconsistent (one icon vs. two, and
            // the accessory bar never rendered for number-pad fields).
            .scrollDismissesKeyboard(.interactively)
    }
}

extension View {
    func keyboardDismissButton() -> some View { modifier(KeyboardDismissButton()) }
}
