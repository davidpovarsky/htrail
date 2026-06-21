import SwiftUI

// MARK: - HTTrail Design System
//
// Swift implementation of the "HTTrail App" / "HTTrail Design System" design
// canvas. The product is intentionally **dark-first**: a deep indigo app
// background with a left-to-right signal gradient (violet → blue → cyan →
// green) borrowed from the logo, used sparingly for brand / active / realtime
// moments. Proportional system font for chrome, monospaced for every URL,
// header, payload and code surface.
//
// Everything here is cross-platform (macOS + iOS 17) and shared by both apps.

// MARK: Hex color

extension Color {
    /// Build a Color from a `#RRGGBB` / `RRGGBB` / `#RRGGBBAA` hex string.
    public init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let r, g, b, a: Double
        switch s.count {
        case 8: // RRGGBBAA
            r = Double((value & 0xFF00_0000) >> 24) / 255
            g = Double((value & 0x00FF_0000) >> 16) / 255
            b = Double((value & 0x0000_FF00) >> 8) / 255
            a = Double(value & 0x0000_00FF) / 255
        default: // RRGGBB
            r = Double((value & 0xFF0000) >> 16) / 255
            g = Double((value & 0x00FF00) >> 8) / 255
            b = Double(value & 0x0000FF) / 255
            a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

// MARK: Design tokens

/// Namespace for the HTTrail design tokens (`Theme.color.surface`, …).
public enum Theme {

    // MARK: Colors
    public enum color {
        // Surfaces (dark, primary)
        public static let app      = Color(hex: "#08071A") // bg / app
        public static let base     = Color(hex: "#0B091A") // bg / base
        public static let surface  = Color(hex: "#131734") // cards / panels
        public static let raised   = Color(hex: "#1B1F46") // raised chips
        public static let codeBG   = Color(hex: "#0C0B22") // code surface
        public static let panelBG  = Color(hex: "#0E1228") // inputs / url bar
        public static let rowBG    = Color(hex: "#10142E") // table rows
        public static let responseBG = Color(hex: "#0B0E22") // response area

        // Text tiers
        public static let text      = Color(hex: "#EAEAF6") // primary
        public static let textBright = Color(hex: "#E3E3F2")
        public static let textSoft  = Color(hex: "#C7C8E0")
        public static let textDim   = Color(hex: "#9A9CC0") // secondary
        public static let textMuted = Color(hex: "#7D7FA3")
        public static let textFaint = Color(hex: "#62648A") // tertiary

        // Brand / signal gradient stops
        public static let violet = Color(hex: "#8B5CF6")
        public static let blue   = Color(hex: "#3B82F6")
        public static let cyan   = Color(hex: "#06B6D4")
        public static let green  = Color(hex: "#10B981")
        public static let amber  = Color(hex: "#F59E0B")
        public static let red    = Color(hex: "#EF4444")

        /// Primary accent (solid).
        public static let accent = blue

        // Code syntax highlighting
        public static let codeKey    = Color(hex: "#7DD3FC") // object keys
        public static let codeString = Color(hex: "#A5E8C0") // strings
        public static let codeNumber = Color(hex: "#FBBF24") // numbers
        public static let codeBool   = Color(hex: "#C084FC") // bool / null
        public static let codeText   = Color(hex: "#C7C8E0") // plain code

        // Hairlines / borders (white overlays on dark)
        public static let border    = Color.white.opacity(0.08)
        public static let borderStrong = Color.white.opacity(0.12)
        public static let hairline  = Color.white.opacity(0.06)
        public static let fill      = Color.white.opacity(0.05)
        public static let fillHover = Color.white.opacity(0.09)
    }

    // MARK: Radii
    public enum radius {
        public static let sm: CGFloat = 6
        public static let md: CGFloat = 9
        public static let lg: CGFloat = 12
        public static let xl: CGFloat = 16
        public static let pill: CGFloat = 999
    }

    // MARK: Spacing
    public enum space {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
    }

    // MARK: Gradients
    /// The brand "signal" gradient (violet → blue → cyan → green).
    public static let signal = LinearGradient(
        colors: [color.violet, color.blue, color.cyan, color.green],
        startPoint: .leading, endPoint: .trailing)

    /// Primary action gradient (violet → blue, 135°).
    public static let primary = LinearGradient(
        colors: [color.violet, color.blue],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    /// The deep radial app background.
    public static var appBackground: some View {
        ZStack {
            color.app
            RadialGradient(
                colors: [Color(hex: "#15173A"), Color(hex: "#0A0820"), color.app],
                center: UnitPoint(x: 0.12, y: -0.10),
                startRadius: 0, endRadius: 1100)
        }
        .ignoresSafeArea()
    }

    // MARK: Semantic helpers

    /// Color for an HTTP method, matching the design palette.
    public static func methodColor(_ method: String) -> Color {
        switch method.uppercased() {
        case "GET": return color.blue
        case "POST": return color.green
        case "PUT": return color.amber
        case "PATCH": return color.violet
        case "DELETE": return color.red
        case "OPTIONS": return color.cyan
        case "QUERY": return Color(hex: "#E535AB")
        case "HEAD", "CONNECT": return Color(hex: "#6B7280")
        default: return color.textDim
        }
    }

    /// Color for an HTTP status code class.
    public static func statusColor(_ code: Int?) -> Color {
        guard let code else { return color.textDim }
        switch code {
        case 200..<300: return color.green
        case 300..<400: return color.blue
        case 400..<500: return color.amber
        case 500...: return color.red
        default: return color.textDim
        }
    }
}

// MARK: - View modifiers

extension View {
    /// Fill behind a scene with the HTTrail radial app background, force dark.
    public func htAppBackground() -> some View {
        self
            .background(Theme.appBackground)
            .preferredColorScheme(.dark)
            .tint(Theme.color.accent)
    }

    /// A surface card: surface fill, hairline border, rounded corners.
    public func htCard(_ radius: CGFloat = Theme.radius.lg,
                       fill: Color = Theme.color.surface.opacity(0.55)) -> some View {
        self
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.color.border, lineWidth: 1))
    }

    /// A bordered input/field surface (panel background, hairline).
    public func htField(_ radius: CGFloat = Theme.radius.md) -> some View {
        self
            .background(Theme.color.panelBG, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.color.borderStrong, lineWidth: 1))
    }
}

// MARK: - Button styles

/// The primary gradient action button (Send, Import, Connect …).
public struct HTPrimaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 20).padding(.vertical, 9)
            .background(Theme.primary, in: RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous))
            .shadow(color: Theme.color.blue.opacity(0.5), radius: 9, y: 5)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A subtle bordered/ghost button used for icon and secondary actions.
public struct HTGhostButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.color.textDim)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.color.fill, in: RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                    .strokeBorder(Theme.color.border, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension ButtonStyle where Self == HTPrimaryButtonStyle {
    public static var htPrimary: HTPrimaryButtonStyle { .init() }
}
extension ButtonStyle where Self == HTGhostButtonStyle {
    public static var htGhost: HTGhostButtonStyle { .init() }
}

// MARK: - Section label (mono, tracked, uppercase)

/// Small monospaced uppercase eyebrow used above panels.
public struct HTEyebrow: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(1.4)
            .foregroundStyle(Theme.color.textFaint)
    }
}

// MARK: - Status indicator (tri-state: code / pending / ERR)

/// Renders a response status the way the design does: colored code, blinking
/// `···` while pending, red `ERR` pill on failure.
public struct StatusIndicator: View {
    public enum State { case code(Int), pending, error, none }
    let state: State
    public init(state: State) { self.state = state }

    public var body: some View {
        switch state {
        case .code(let c):
            Text("\(c)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.statusColor(c))
        case .pending:
            Text("···")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(Theme.color.textDim)
                .modifier(BlinkModifier())
        case .error:
            Text("ERR")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Theme.color.red, in: RoundedRectangle(cornerRadius: 5))
        case .none:
            Text("—")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.color.textDim)
        }
    }
}

/// A pulsing connection dot (live = green glow, off = grey, error = red).
public struct ConnectionDot: View {
    public enum Status { case live, off, error }
    let status: Status
    @SwiftUI.State private var pulse = false
    public init(status: Status) { self.status = status }
    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: status == .live ? color : .clear, radius: 4)
            .opacity(status == .live && pulse ? 0.45 : 1)
            .animation(status == .live
                       ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                       : .default, value: pulse)
            .onAppear { if status == .live { pulse = true } }
    }
    private var color: Color {
        switch status {
        case .live: return Theme.color.green
        case .off: return Theme.color.textFaint
        case .error: return Theme.color.red
        }
    }
}

/// Subtle opacity blink used for pending status text.
struct BlinkModifier: ViewModifier {
    @SwiftUI.State private var on = false
    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0.3)
            .animation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}
