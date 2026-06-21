import SwiftUI
import HTTrailCore

/// Charles-style interception rules: block, map local/remote, rewrite, throttle,
/// breakpoint — plus the SSL proxying allowlist.
struct RulesView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        NavigationStack {
            List {
                Section("Interception Rules") {
                    ForEach($model.rules) { $rule in
                        NavigationLink {
                            RuleEditor(rule: $rule)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: rule.enabled ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(rule.enabled ? Theme.color.green : Theme.color.textFaint)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(rule.name).lineLimit(1).foregroundStyle(Theme.color.textBright)
                                    Text(rule.kind.label).font(.caption).foregroundStyle(Theme.color.textMuted)
                                }
                            }
                        }
                    }
                    .onDelete { idx in
                        model.rules.remove(atOffsets: idx); model.pushRulesToEngine()
                    }
                    if model.rules.isEmpty {
                        Text("No rules. Rules run inside the proxy: block, map, rewrite, throttle, breakpoint.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    ForEach(model.sslAllowlist, id: \.self) { host in
                        HStack(spacing: 8) {
                            Image(systemName: "lock.open").font(.caption).foregroundStyle(Theme.color.textMuted)
                            Text(host).font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(Theme.color.textBright)
                        }
                    }
                    .onDelete { model.removeAllowlist(at: $0) }
                    HStack(spacing: 8) {
                        TextField("Add host glob (e.g. *.example.com)", text: $model.newAllowlistEntry)
                            .font(.system(.footnote, design: .monospaced))
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                            .onSubmit { model.addAllowlistEntry() }
                        Button { model.addAllowlistEntry() } label: { Image(systemName: "plus.circle.fill") }
                            .buttonStyle(.borderless)
                            .disabled(model.newAllowlistEntry.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("SSL Proxying Allowlist")
                } footer: {
                    Text("Hosts to decrypt (glob). Empty = decrypt everything. Swipe a row to remove.")
                }

                Section {
                    Toggle("Auto-detect Cert Pinning", isOn: Binding(
                        get: { model.pinningDetectionEnabled },
                        set: { model.setPinningDetection($0) }
                    ))
                    if model.detectedPinnedHosts.isEmpty {
                        Text("None detected yet.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(model.detectedPinnedHosts) { info in
                            HStack(spacing: 8) {
                                Image(systemName: "lock.shield").foregroundStyle(Theme.color.green)
                                Text(info.host)
                                    .font(.system(.footnote, design: .monospaced)).lineLimit(1)
                                    .foregroundStyle(Theme.color.textBright)
                                Spacer()
                                Button("Decrypt") { model.forceDecryptHost(info.host) }
                                    .buttonStyle(.borderless).font(.caption)
                            }
                        }
                    }
                } header: {
                    Text("Certificate Pinning")
                } footer: {
                    Text("Hosts that reject the proxy certificate are tunneled automatically so pinned apps keep working. Tap Decrypt to retry interception there.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.appBackground)
            .navigationTitle("Rules")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.addRule() } label: { Image(systemName: "plus") }
                }
            }
            .keyboardDismissButton()
        }
    }
}

struct RuleEditor: View {
    @EnvironmentObject var model: AppModel
    @Binding var rule: InterceptRule

    var body: some View {
        Form {
            Section("Match") {
                TextField("Name", text: $rule.name)
                Toggle("Enabled", isOn: $rule.enabled)
                Picker("Action", selection: $rule.kind) {
                    ForEach(RuleKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                TextField("URL pattern (e.g. *api.example.com*)", text: $rule.urlPattern)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
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
            Section("Block") {
                Stepper("Status: \(rule.blockStatus)", value: $rule.blockStatus, in: 100...599)
            }
        case .mapLocal:
            Section("Map Local") {
                TextField("Local file path", text: $rule.localFilePath)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                TextField("Content-Type", text: $rule.localContentType)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
            }
        case .mapRemote:
            Section("Map Remote") {
                TextField("Host", text: $rule.remoteHost)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                Stepper("Port: \(rule.remotePort)", value: $rule.remotePort, in: 1...65535)
                Toggle("TLS", isOn: $rule.remoteTLS)
            }
        case .rewriteRequest, .rewriteResponse:
            Section("Set Headers") {
                KeyValueEditor(items: $rule.setHeaders, keyPlaceholder: "Set header", valuePlaceholder: "Value")
            }
            Section("Body find / replace") {
                TextField("Find", text: $rule.findText)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                TextField("Replace", text: $rule.replaceText)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                if rule.kind == .rewriteResponse {
                    Stepper("Override status: \(rule.setStatus) (0 = keep)", value: $rule.setStatus, in: 0...599)
                }
            }
        case .throttle:
            Section("Throttle") {
                Stepper("Delay: \(rule.throttleMS) ms", value: $rule.throttleMS, in: 0...60000, step: 250)
            }
        case .breakpoint:
            Section("Breakpoint") {
                Toggle("Pause on request", isOn: $rule.breakRequest)
                Toggle("Pause on response", isOn: $rule.breakResponse)
            }
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
                    Text(event.request.url).font(.caption.monospaced())
                        .foregroundStyle(.secondary).lineLimit(2)
                    Text("Edit the body, then continue or drop the change.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $model.breakpointBody)
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .border(Color.hairline)
                    HStack {
                        Button("Continue Unchanged") { model.resolveBreakpoint(apply: false) }
                        Spacer()
                        Button("Apply & Continue") { model.resolveBreakpoint(apply: true) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding()
            .navigationTitle(model.pendingBreakpoint?.phase == .response ? "Breakpoint — Response" : "Breakpoint — Request")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDismissButton()
        }
        .interactiveDismissDisabled()
    }
}
