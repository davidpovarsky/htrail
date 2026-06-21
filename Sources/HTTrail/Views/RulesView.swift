import SwiftUI
import HTTrailCore

struct RulesListView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Interception Rules").font(.headline)
                Spacer()
                Button { model.addRule() } label: { Image(systemName: "plus") }.buttonStyle(.borderless)
            }
            .padding(8)
            Divider()
            List(selection: $model.selectedRuleID) {
                ForEach(model.rules) { rule in
                    HStack(spacing: 9) {
                        Image(systemName: rule.enabled ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(rule.enabled ? Theme.color.green : Theme.color.textFaint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(rule.name).lineLimit(1).foregroundStyle(Theme.color.textBright)
                            Text(rule.kind.label).font(.system(size: 11)).foregroundStyle(Theme.color.textMuted)
                        }
                    }
                    .tag(rule.id)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            Divider()
            AllowlistSection()
            Divider()
            PinnedHostsSection()
        }
    }
}

/// Managed SSL-proxying allowlist: add hosts with the field, remove inline.
struct AllowlistSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SSL Proxying Allowlist").font(.caption.bold())
            Text("Hosts to decrypt (glob, e.g. *.example.com). Empty = decrypt everything.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("Add host glob…", text: $model.newAllowlistEntry)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .onSubmit { model.addAllowlistEntry() }
                Button { model.addAllowlistEntry() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .disabled(model.newAllowlistEntry.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if model.sslAllowlist.isEmpty {
                Text("No hosts — all HTTPS is decrypted.")
                    .font(.caption2).foregroundStyle(Theme.color.textFaint)
            } else {
                ForEach(model.sslAllowlist, id: \.self) { host in
                    HStack(spacing: 6) {
                        Image(systemName: "lock.open").font(.caption2).foregroundStyle(Theme.color.textMuted)
                        Text(host).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                        Spacer()
                        Button { model.removeAllowlistEntry(host) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).font(.caption2).foregroundStyle(Theme.color.textMuted)
                    }
                }
            }
        }
        .padding(8)
    }
}

/// Lists hosts that auto-detection has put into tunnel mode because they reject
/// the proxy's certificate (certificate pinning), with a per-host override.
struct PinnedHostsSection: View {
    @EnvironmentObject var model: AppModel
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { model.pinningDetectionEnabled },
                set: { model.setPinningDetection($0) }
            )) {
                Text("Auto-detect Cert Pinning").font(.caption.bold())
            }
            .toggleStyle(.checkbox)
            Text("Hosts that reject the proxy cert are tunneled so pinned apps keep working.")
                .font(.caption2).foregroundStyle(.secondary)

            if model.detectedPinnedHosts.isEmpty {
                Text("None detected.").font(.caption2).foregroundStyle(Theme.color.textFaint)
            } else {
                ForEach(model.detectedPinnedHosts) { info in
                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield").foregroundStyle(Theme.color.green)
                        Text(info.host).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                        Spacer()
                        Button("Decrypt") { model.forceDecryptHost(info.host) }
                            .buttonStyle(.borderless).font(.caption2)
                    }
                }
            }
        }
        .padding(8)
        .onReceive(tick) { _ in model.refreshPinnedHosts() }
    }
}

struct RuleEditorView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let index = model.selectedRuleIndex {
            Form {
                Section {
                    TextField("Name", text: binding(index).name)
                    Toggle("Enabled", isOn: binding(index).enabled)
                    Picker("Action", selection: binding(index).kind) {
                        ForEach(RuleKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    TextField("URL pattern (e.g. *api.example.com*)", text: binding(index).urlPattern)
                        .font(.system(.body, design: .monospaced))
                } header: { Text("Match") }

                ruleParams(index: index)
            }
            .formStyle(.grouped)
            .onChange(of: model.rules) { _, _ in model.pushRulesToEngine() }
            .toolbar {
                ToolbarItem(placement: .destructiveAction) {
                    Button(role: .destructive) { model.deleteSelectedRule() } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } else {
            ContentUnavailableView("Select or add a rule", systemImage: "slider.horizontal.3",
                                   description: Text("Rules run inside the proxy: block, map, rewrite, throttle, breakpoint."))
        }
    }

    @ViewBuilder
    private func ruleParams(index: Int) -> some View {
        let rule = model.rules[index]
        switch rule.kind {
        case .block:
            Section("Block") {
                Stepper("Status: \(rule.blockStatus)", value: binding(index).blockStatus, in: 100...599)
            }
        case .mapLocal:
            Section("Map Local") {
                TextField("Local file path", text: binding(index).localFilePath)
                TextField("Content-Type", text: binding(index).localContentType)
            }
        case .mapRemote:
            Section("Map Remote") {
                TextField("Host", text: binding(index).remoteHost)
                Stepper("Port: \(rule.remotePort)", value: binding(index).remotePort, in: 1...65535)
                Toggle("TLS", isOn: binding(index).remoteTLS)
            }
        case .rewriteRequest, .rewriteResponse:
            Section("Headers") {
                KeyValueEditor(items: binding(index).setHeaders, keyPlaceholder: "Set header", valuePlaceholder: "Value")
            }
            Section("Body find / replace") {
                TextField("Find", text: binding(index).findText)
                TextField("Replace", text: binding(index).replaceText)
                if rule.kind == .rewriteResponse {
                    Stepper("Override status: \(rule.setStatus) (0 = keep)", value: binding(index).setStatus, in: 0...599)
                }
            }
        case .throttle:
            Section("Throttle") {
                Stepper("Delay: \(rule.throttleMS) ms", value: binding(index).throttleMS, in: 0...60000, step: 250)
            }
        case .breakpoint:
            Section("Breakpoint") {
                Toggle("Pause on request", isOn: binding(index).breakRequest)
                Toggle("Pause on response", isOn: binding(index).breakResponse)
            }
        }
    }

    private func binding(_ index: Int) -> Binding<InterceptRule> {
        $model.rules[index]
    }
}
