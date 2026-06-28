import SwiftUI
import HTTrailCore

// MARK: - Rules sidebar (rule list + SSL allowlist + cert-pinning auto-detect)

struct RulesListView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            // Header: title + ＋ add
            HStack {
                Text("Interception Rules")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.color.textBright)
                Spacer()
                Button { model.addRule() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(Theme.color.textDim)
                        .frame(width: 26, height: 26)
                        .background(Color.white.opacity(0.04),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Theme.color.borderStrong, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add rule")
            }
            .padding(.horizontal, 14)
            .padding(.top, 13)
            .padding(.bottom, 9)

            // Single scroll body: rules → allowlist → pinning
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.rules) { rule in
                        RuleRow(rule: rule,
                                selected: model.selectedRuleID == rule.id,
                                select: { model.selectedRuleID = rule.id },
                                toggle: {
                                    if let i = model.rules.firstIndex(where: { $0.id == rule.id }) {
                                        model.rules[i].enabled.toggle()
                                        model.pushRulesToEngine()
                                    }
                                })
                    }
                    AllowlistSection()
                    PinnedHostsSection()
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 14)
            }
        }
    }
}

/// A single interception-rule row: a rounded checkbox toggles `enabled`, the rule
/// name + action label sit alongside. Selecting the row opens it in the editor.
private struct RuleRow: View {
    let rule: InterceptRule
    let selected: Bool
    let select: () -> Void
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                CheckBox(on: rule.enabled, action: toggle)
                VStack(alignment: .leading, spacing: 1) {
                    Text(rule.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(rule.enabled ? Theme.color.textBright : Theme.color.textMuted)
                        .lineLimit(1)
                    Text(rule.kind.label)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.color.textMuted)
                }
                Spacer(minLength: 0)
            }
            .padding(9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.06)
                          : (hovering ? Color.white.opacity(0.04) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.bottom, 2)
    }
}

/// Rounded 15px checkbox: filled accent w/ white check when on, hollow faint border when off.
private struct CheckBox: View {
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(on ? Theme.color.accent : Color.clear)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(on ? Theme.color.accent : Theme.color.textFaint, lineWidth: 1.5)
                if on {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 15, height: 15)
        }
        .buttonStyle(.plain)
    }
}

/// Managed SSL-proxying allowlist: add hosts with the field, remove inline.
struct AllowlistSection: View {
    @EnvironmentObject var model: AppModel

    private var canAdd: Bool {
        !model.newAllowlistEntry.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HTEyebrow("SSL PROXYING ALLOWLIST")
                .padding(.horizontal, 8)
                .padding(.top, 16)
                .padding(.bottom, 7)

            HStack(spacing: 7) {
                TextField("host glob, e.g. *.acme.dev", text: $model.newAllowlistEntry)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.color.textSoft)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Theme.color.panelBG, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Theme.color.borderStrong, lineWidth: 1))
                    .onSubmit { model.addAllowlistEntry() }
                Button { model.addAllowlistEntry() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(canAdd ? Theme.color.textDim : Theme.color.textFaint)
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.04),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Theme.color.borderStrong, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(!canAdd)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)

            if model.sslAllowlist.isEmpty {
                Text("Empty list = decrypt everything.")
                    .font(.system(size: 10))
                    .italic()
                    .foregroundStyle(Theme.color.textFaint)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
            } else {
                ForEach(model.sslAllowlist, id: \.self) { host in
                    AllowlistRow(host: host) { model.removeAllowlistEntry(host) }
                }
            }
        }
    }
}

/// A single allowlisted host: green mono host, hover-red ×.
private struct AllowlistRow: View {
    let host: String
    let remove: () -> Void
    @State private var rowHover = false
    @State private var xHover = false

    var body: some View {
        HStack(spacing: 6) {
            Text(host)
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.color.codeString)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(xHover ? Theme.color.red : Theme.color.textFaint)
            }
            .buttonStyle(.plain)
            .onHover { xHover = $0 }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(rowHover ? Color.white.opacity(0.03) : Color.clear))
        .padding(.horizontal, 8)
        .onHover { rowHover = $0 }
    }
}

/// Lists hosts that auto-detection has put into tunnel mode because they reject
/// the proxy's certificate (certificate pinning), with a per-host override.
struct PinnedHostsSection: View {
    @EnvironmentObject var model: AppModel
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HTEyebrow("AUTO-DETECT CERT PINNING")
                .padding(.horizontal, 8)
                .padding(.top, 18)
                .padding(.bottom, 7)

            HStack(spacing: 8) {
                CheckBox(on: model.pinningDetectionEnabled) {
                    model.setPinningDetection(!model.pinningDetectionEnabled)
                }
                Text("Tunnel hosts that reject the proxy cert")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.color.textSoft)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)

            if model.detectedPinnedHosts.isEmpty {
                Text("None detected.")
                    .font(.system(size: 10))
                    .italic()
                    .foregroundStyle(Theme.color.textFaint)
                    .padding(.horizontal, 10)
            } else {
                ForEach(model.detectedPinnedHosts) { info in
                    PinnedHostCard(info: info) { model.forceDecryptHost(info.host) }
                }
            }
        }
        .onReceive(tick) { _ in model.refreshPinnedHosts() }
    }
}

/// A detected pinned host shown as a small card with a tinted "Decrypt" pill.
private struct PinnedHostCard: View {
    let info: PinnedHostInfo
    let decrypt: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(info.host)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.color.textBright)
                    .lineLimit(1)
                Text("Tunneled — certificate pinning")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.color.amber)
            }
            Spacer(minLength: 0)
            Button(action: decrypt) {
                Text("Decrypt")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(Color(hex: "#BFD4FF"))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Theme.color.accent.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Theme.color.accent.opacity(0.4), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.02),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }
}

// MARK: - Rule editor (detail)

struct RuleEditorView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if let index = model.selectedRuleIndex {
                editor(index: index)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Editor scroll body

    @ViewBuilder
    private func editor(index: Int) -> some View {
        let rule = model.rules[index]
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HTEyebrow("MATCH").padding(.bottom, 12)

                // Name + Enabled
                HStack(alignment: .bottom, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        fieldLabel("Name")
                        TextField("Name", text: binding(index).name)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.color.textBright)
                            .ruleFieldChrome()
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        fieldLabel("Enabled")
                        PillToggle(on: binding(index).enabled)
                    }
                }
                .padding(.bottom, 14)

                // URL pattern
                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel("URL pattern")
                    TextField("*api.example.com*", text: binding(index).urlPattern)
                        .textFieldStyle(.plain)
                        .font(Theme.mono(12.5))
                        .foregroundStyle(Theme.color.codeKey)
                        .ruleFieldChrome()
                }
                .padding(.bottom, 14)

                // Action picker (chips)
                VStack(alignment: .leading, spacing: 7) {
                    fieldLabel("Action")
                    FlowLayout(spacing: 6) {
                        ForEach(RuleKind.allCases, id: \.self) { kind in
                            actionChip(kind: kind, selected: rule.kind == kind) {
                                binding(index).kind.wrappedValue = kind
                            }
                        }
                    }
                }

                Rectangle()
                    .fill(Color.white.opacity(0.07))
                    .frame(height: 1)
                    .padding(.vertical, 22)

                HTEyebrow("PARAMETERS").padding(.bottom, 14)
                ruleParams(index: index)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: model.rules) { _, _ in model.pushRulesToEngine() }
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) { model.deleteSelectedRule() } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    // MARK: Action-specific parameters

    @ViewBuilder
    private func ruleParams(index: Int) -> some View {
        let rule = model.rules[index]
        switch rule.kind {
        case .block:
            HStack(spacing: 14) {
                paramLabel("Respond with status")
                StepperBox(value: binding(index).blockStatus, range: 100...599,
                           valueColor: Theme.color.codeNumber, width: 50)
            }
        case .mapLocal:
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel("Local file")
                    TextField("~/mocks/response.json", text: binding(index).localFilePath)
                        .textFieldStyle(.plain)
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.color.textSoft)
                        .ruleFieldChrome()
                }
                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel("Content-Type")
                    TextField("application/json", text: binding(index).localContentType)
                        .textFieldStyle(.plain)
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.color.textSoft)
                        .ruleFieldChrome()
                        .frame(maxWidth: 280, alignment: .leading)
                }
            }
        case .mapRemote:
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .bottom, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        fieldLabel("Target host")
                        TextField("staging.acme.dev", text: binding(index).remoteHost)
                            .textFieldStyle(.plain)
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.color.textSoft)
                            .ruleFieldChrome()
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        fieldLabel("Port")
                        StepperBox(value: binding(index).remotePort, range: 1...65535,
                                   valueColor: Theme.color.textSoft, width: 60)
                    }
                }
                HStack(spacing: 10) {
                    PillToggle(on: binding(index).remoteTLS)
                    paramLabel("Use TLS")
                }
            }
        case .rewriteRequest, .rewriteResponse:
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    fieldLabel("Set headers")
                    KeyValueEditor(items: binding(index).setHeaders,
                                   keyPlaceholder: "Header", valuePlaceholder: "Value", addNoun: "header")
                }
                HStack(alignment: .bottom, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        fieldLabel("Body · find")
                        TextField("find…", text: binding(index).findText)
                            .textFieldStyle(.plain)
                            .font(Theme.mono(12))
                            .foregroundStyle(Color(hex: "#FCA5A5"))
                            .ruleFieldChrome()
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        fieldLabel("Body · replace")
                        TextField("replace…", text: binding(index).replaceText)
                            .textFieldStyle(.plain)
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.color.codeString)
                            .ruleFieldChrome()
                    }
                }
                if rule.kind == .rewriteResponse {
                    HStack(spacing: 14) {
                        paramLabel("Override status (0 = keep)")
                        StepperBox(value: binding(index).setStatus, range: 0...599,
                                   valueColor: Color(hex: "#FCA5A5"), width: 50)
                    }
                }
            }
        case .throttle:
            HStack(spacing: 14) {
                paramLabel("Delay each response by")
                StepperBox(value: binding(index).throttleMS, range: 0...60000, step: 250,
                           valueColor: Theme.color.textBright, width: 70)
                paramLabel("ms")
            }
        case .breakpoint:
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    PillToggle(on: binding(index).breakRequest)
                    paramLabel("Pause on request")
                }
                HStack(spacing: 12) {
                    PillToggle(on: binding(index).breakResponse)
                    paramLabel("Pause on response")
                }
            }
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 15) {
            ZStack {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.color.violet.opacity(0.18),
                                                  Theme.color.blue.opacity(0.12)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 64, height: 64)
                    .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .strokeBorder(Color(hex: "#6366F1").opacity(0.26), lineWidth: 1))
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Color(hex: "#A78BFA"))
            }
            VStack(spacing: 6) {
                Text("Select or add a rule")
                    .font(.system(size: 14.5, weight: .bold))
                    .foregroundStyle(Theme.color.textSoft)
                Text("Rules run inside the proxy — block, map local/remote, rewrite, throttle, or set a breakpoint on matching traffic.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.color.textFaint)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 340)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Helpers

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.color.textDim)
    }

    private func paramLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.color.textSoft)
    }

    @ViewBuilder
    private func actionChip(kind: RuleKind, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(kind.label)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(selected ? .white : Theme.color.textDim)
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(selected ? Theme.color.accent.opacity(0.18) : Color.white.opacity(0.03),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Theme.color.accent.opacity(0.5) : Theme.color.borderStrong,
                                  lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func binding(_ index: Int) -> Binding<InterceptRule> {
        $model.rules[index]
    }
}

// MARK: - Editor building blocks

/// Pill switch (42×24) matching the design's toggle: accent track on, faint off,
/// 20px white knob sliding between the two edges.
private struct PillToggle: View {
    @Binding var on: Bool

    var body: some View {
        Button { on.toggle() } label: {
            ZStack(alignment: on ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(on ? Theme.color.accent : Color.white.opacity(0.14))
                Circle()
                    .fill(.white)
                    .frame(width: 20, height: 20)
                    .padding(.horizontal, 2)
            }
            .frame(width: 42, height: 24)
            .animation(.easeOut(duration: 0.16), value: on)
        }
        .buttonStyle(.plain)
    }
}

/// Inline − / value / + stepper inside a panel-background field.
private struct StepperBox: View {
    @Binding var value: Int
    var range: ClosedRange<Int>
    var step: Int = 1
    var valueColor: Color = Theme.color.textBright
    var width: CGFloat = 50

    var body: some View {
        HStack(spacing: 0) {
            Button { value = max(range.lowerBound, value - step) } label: {
                Text("−")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.color.textDim)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("\(value)")
                .font(Theme.mono(13, .bold))
                .foregroundStyle(valueColor)
                .frame(width: width)
                .multilineTextAlignment(.center)

            Button { value = min(range.upperBound, value + step) } label: {
                Text("+")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.color.textDim)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(Theme.color.panelBG)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Theme.color.borderStrong, lineWidth: 1))
    }
}

/// Simple wrapping row layout (used for the action chips).
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                totalHeight += rowHeight + spacing
                maxRowWidth = max(maxRowWidth, x - spacing)
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        maxRowWidth = max(maxRowWidth, x - spacing)
        let width = maxWidth == .infinity ? maxRowWidth : maxWidth
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            v.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Field chrome helper

extension View {
    /// Panel-background field surface (radius 8, strong hairline) used by editor inputs.
    fileprivate func ruleFieldChrome() -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Theme.color.panelBG, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.color.borderStrong, lineWidth: 1))
    }
}
