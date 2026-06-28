import SwiftUI
import HTTrailCore

/// Charles-style interception rules: block, map local/remote, rewrite, throttle,
/// breakpoint — plus the SSL proxying allowlist.
struct RulesView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($model.rules) { $rule in
                        NavigationLink {
                            RuleEditor(rule: $rule)
                        } label: {
                            RuleRow(rule: rule) {
                                rule.enabled.toggle()
                                model.pushRulesToEngine()
                            }
                        }
                        .listRowBackground(Color.clear)
                    }
                    .onDelete { idx in
                        model.rules.remove(atOffsets: idx); model.pushRulesToEngine()
                    }
                    if model.rules.isEmpty {
                        Text("No rules. Rules run inside the proxy: block, map, rewrite, throttle, breakpoint.")
                            .font(.caption).foregroundStyle(Theme.color.textMuted)
                            .listRowBackground(Color.clear)
                    }
                } header: {
                    HTEyebrow("INTERCEPTION RULES")
                }

                Section {
                    HStack(spacing: 8) {
                        TextField("Add host glob (e.g. *.example.com)", text: $model.newAllowlistEntry)
                            .font(Theme.mono(13))
                            .foregroundStyle(Theme.color.text)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                            .htField()
                            .onSubmit { model.addAllowlistEntry() }
                        Button { model.addAllowlistEntry() } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(canAddAllowlist ? Theme.color.accent : Theme.color.textFaint)
                                .frame(width: 30, height: 30)
                                .background(Theme.color.fill, in: RoundedRectangle(cornerRadius: Theme.radius.sm, style: .continuous))
                        }
                        .buttonStyle(.borderless)
                        .disabled(!canAddAllowlist)
                    }
                    .listRowBackground(Color.clear)

                    if model.sslAllowlist.isEmpty {
                        Text("Empty list = decrypt everything.")
                            .font(.caption2).italic().foregroundStyle(Theme.color.textFaint)
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(model.sslAllowlist, id: \.self) { host in
                            AllowlistRow(host: host) { model.removeAllowlistEntry(host) }
                                .listRowBackground(Color.clear)
                        }
                        .onDelete { model.removeAllowlist(at: $0) }
                    }
                } header: {
                    HTEyebrow("SSL PROXYING ALLOWLIST")
                } footer: {
                    Text("Hosts to decrypt (glob). Empty = decrypt everything. Swipe a row to remove.")
                        .font(.caption2).foregroundStyle(Theme.color.textMuted)
                }

                Section {
                    HStack(spacing: 10) {
                        Image(systemName: model.pinningDetectionEnabled ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(model.pinningDetectionEnabled ? Theme.color.green : Theme.color.textFaint)
                        Text("Auto-detect Cert Pinning")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.color.textBright)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { model.pinningDetectionEnabled },
                            set: { model.setPinningDetection($0) }
                        ))
                        .labelsHidden()
                        .tint(Theme.color.green)
                    }
                    .listRowBackground(Color.clear)

                    if model.detectedPinnedHosts.isEmpty {
                        Text("None detected yet.")
                            .font(.caption2).italic().foregroundStyle(Theme.color.textFaint)
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(model.detectedPinnedHosts) { info in
                            PinnedHostCard(info: info) { model.forceDecryptHost(info.host) }
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        }
                    }
                } header: {
                    HTEyebrow("CERTIFICATE PINNING")
                } footer: {
                    Text("Hosts that reject the proxy certificate are tunneled automatically so pinned apps keep working. Tap Decrypt to retry interception there.")
                        .font(.caption2).foregroundStyle(Theme.color.textMuted)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.appBackground)
            .htScreenChrome("Rules") {
                Button { model.addRule() } label: { Image(systemName: "plus") }
            }
            .keyboardDismissButton()
        }
    }

    private var canAddAllowlist: Bool {
        !model.newAllowlistEntry.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// A single interception-rule row: a rounded green checkbox toggles `enabled`,
/// with the rule name (semibold) + action label (dim) alongside it.
private struct RuleRow: View {
    let rule: InterceptRule
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            CheckBox(on: rule.enabled, action: toggle)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(rule.enabled ? Theme.color.textBright : Theme.color.textMuted)
                    .lineLimit(1)
                Text(rule.kind.label)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.color.textMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

/// Rounded checkbox: filled green w/ white check when on, hollow faint border when off.
private struct CheckBox: View {
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(on ? Theme.color.green : Color.clear)
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(on ? Color.clear : Theme.color.textFaint, lineWidth: 1.5)
                if on {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
    }
}

/// A single allowlisted host: lock-open glyph, green mono host, red × remove.
private struct AllowlistRow: View {
    let host: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.open")
                .font(.caption2)
                .foregroundStyle(Theme.color.textMuted)
            Text(host)
                .font(Theme.mono(13))
                .foregroundStyle(Theme.color.codeString)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.color.textFaint)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 1)
    }
}

/// A detected pinned host shown as a small card with a tinted "Decrypt" pill.
private struct PinnedHostCard: View {
    let info: PinnedHostInfo
    let decrypt: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(Theme.color.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.host)
                    .font(Theme.mono(13))
                    .foregroundStyle(Theme.color.textBright)
                    .lineLimit(1)
                Text("Tunneled — certificate pinning")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.color.amber)
            }
            Spacer(minLength: 0)
            Button(action: decrypt) {
                Text("Decrypt")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.color.blue)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Theme.color.accent.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: Theme.radius.sm, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radius.sm, style: .continuous)
                            .strokeBorder(Theme.color.accent.opacity(0.4), lineWidth: 1)
                    )
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(Theme.color.surface.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                .strokeBorder(Theme.color.border, lineWidth: 1)
        )
    }
}

struct RuleEditor: View {
    @EnvironmentObject var model: AppModel
    @Binding var rule: InterceptRule

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $rule.name)
                Toggle("Enabled", isOn: $rule.enabled)
                    .tint(Theme.color.green)
                Picker("Action", selection: $rule.kind) {
                    ForEach(RuleKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            } header: {
                HTEyebrow("Match")
            }
            Section {
                TextField("*api.example.com*", text: $rule.urlPattern)
                    .font(Theme.mono(12.5))
                    .foregroundStyle(Theme.color.codeKey)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
            } header: {
                HTEyebrow("URL Pattern")
            }
            ruleParams
        }
        .scrollContentBackground(.hidden)
        .background(Theme.appBackground)
        .navigationTitle(rule.name)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: rule) { _, _ in model.pushRulesToEngine() }
    }

    @ViewBuilder
    private var ruleParams: some View {
        switch rule.kind {
        case .block:
            Section {
                Stepper("Status: \(rule.blockStatus)", value: $rule.blockStatus, in: 100...599)
            } header: { HTEyebrow("Parameters") }
        case .mapLocal:
            Section {
                TextField("Local file path", text: $rule.localFilePath)
                    .font(Theme.mono(12.5))
                    .foregroundStyle(Theme.color.codeString)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                TextField("Content-Type", text: $rule.localContentType)
                    .font(Theme.mono(12.5))
                    .foregroundStyle(Theme.color.codeString)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
            } header: { HTEyebrow("Parameters") }
        case .mapRemote:
            Section {
                TextField("Host", text: $rule.remoteHost)
                    .font(Theme.mono(12.5))
                    .foregroundStyle(Theme.color.codeString)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                Stepper("Port: \(rule.remotePort)", value: $rule.remotePort, in: 1...65535)
                Toggle("TLS", isOn: $rule.remoteTLS)
                    .tint(Theme.color.green)
            } header: { HTEyebrow("Parameters") }
        case .rewriteRequest, .rewriteResponse:
            Section {
                KeyValueEditor(items: $rule.setHeaders, keyPlaceholder: "Set header", valuePlaceholder: "Value")
            } header: { HTEyebrow("Set Headers") }
            Section {
                TextField("Find", text: $rule.findText)
                    .font(Theme.mono(12.5))
                    .foregroundStyle(Theme.color.codeString)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                TextField("Replace", text: $rule.replaceText)
                    .font(Theme.mono(12.5))
                    .foregroundStyle(Theme.color.codeString)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                if rule.kind == .rewriteResponse {
                    Stepper("Override status: \(rule.setStatus) (0 = keep)", value: $rule.setStatus, in: 0...599)
                }
            } header: { HTEyebrow("Body Find / Replace") }
        case .throttle:
            Section {
                Stepper("Delay: \(rule.throttleMS) ms", value: $rule.throttleMS, in: 0...60000, step: 250)
            } header: { HTEyebrow("Parameters") }
        case .breakpoint:
            Section {
                Toggle("Pause on request", isOn: $rule.breakRequest)
                    .tint(Theme.color.amber)
                Toggle("Pause on response", isOn: $rule.breakResponse)
                    .tint(Theme.color.amber)
            } header: { HTEyebrow("Breakpoint") }
        }
    }
}

/// Modal that pauses a request/response for manual editing (Charles breakpoints).
struct BreakpointSheet: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                if let event = model.pendingBreakpoint {
                    Text(event.request.url)
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.color.codeString).lineLimit(2)
                    Text("Edit the body, then continue or drop the change.")
                        .font(.caption).foregroundStyle(Theme.color.textMuted)
                    TextEditor(text: $model.breakpointBody)
                        .font(Theme.mono(13))
                        .foregroundStyle(Theme.color.text)
                        .scrollContentBackground(.hidden)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .padding(6)
                        .background(Theme.color.panelBG, in: RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                                .strokeBorder(Theme.color.borderStrong, lineWidth: 1)
                        )
                    HStack {
                        Button("Continue Unchanged") { model.resolveBreakpoint(apply: false) }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Theme.color.textSoft)
                        Spacer()
                        Button("Apply & Continue") { model.resolveBreakpoint(apply: true) }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.color.accent)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.appBackground)
            .navigationTitle(model.pendingBreakpoint?.phase == .response ? "Breakpoint — Response" : "Breakpoint — Request")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDismissButton()
        }
        .interactiveDismissDisabled()
    }
}
