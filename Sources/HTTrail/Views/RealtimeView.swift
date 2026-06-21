import SwiftUI
import HTTrailCore

struct RealtimeSidebar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Protocol", selection: $model.rtProtocol) {
                ForEach(AppModel.RealtimeProtocol.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(model.wsConnected)

            switch model.rtProtocol {
            case .webSocket, .socketIO, .sse:
                TextField(urlPlaceholder, text: $model.wsURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                if model.rtProtocol == .socketIO {
                    TextField("Event name", text: $model.sioEvent).textFieldStyle(.roundedBorder)
                }
            case .mqtt:
                TextField("Broker host", text: $model.mqttHost).textFieldStyle(.roundedBorder)
                HStack {
                    Text("Port").font(.caption)
                    TextField("Port", value: $model.mqttPort, format: .number).textFieldStyle(.roundedBorder)
                }
                TextField("Topic", text: $model.mqttTopic).textFieldStyle(.roundedBorder)
            }

            HStack {
                if model.wsConnected {
                    Button(role: .destructive) { model.disconnectRealtime() } label: {
                        Label("Disconnect", systemImage: "bolt.slash")
                    }
                } else {
                    Button { model.connectRealtime() } label: {
                        Label("Connect", systemImage: "bolt.horizontal")
                    }
                }
                Spacer()
                Circle().fill(model.wsConnected ? .green : .secondary).frame(width: 8, height: 8)
            }

            Divider().overlay(Theme.color.hairline)
            Toggle(isOn: Binding(get: { model.testServerRunning },
                                 set: { _ in model.toggleTestServer() })) {
                Label("Local test server", systemImage: "ladybug")
                    .font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .tint(Theme.color.accent)
            if model.testServerRunning {
                Text(model.testServerHint)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.color.textFaint).lineLimit(2)
                Text("Connect to echo your messages, or send “datetime”.")
                    .font(.system(size: 10)).foregroundStyle(Theme.color.textFaint)
            }

            Spacer()
        }
        .padding(12)
    }

    private var urlPlaceholder: String {
        switch model.rtProtocol {
        case .socketIO: return "https://… (Socket.IO)"
        case .sse: return "https://… (SSE stream)"
        default: return "wss://…"
        }
    }
}

struct RealtimeView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ConnectionDot(status: model.wsConnected ? .live : .off)
                Text(model.wsConnected ? "\(model.wsURL) · connected" : "disconnected")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.color.textDim).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(Theme.color.surface.opacity(0.5))
            .overlay(Theme.color.hairline.frame(height: 1), alignment: .bottom)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.wsMessages) { message in
                            RealtimeRow(message: message).id(message.id)
                            Divider().overlay(Theme.color.hairline.opacity(0.6))
                        }
                    }
                }
                .background(Theme.color.responseBG)
                .onChange(of: model.wsMessages.count) { _, _ in
                    if let last = model.wsMessages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            HStack(spacing: 8) {
                TextField(model.rtProtocol.canSend ? "Send a message…" : "Receive-only stream", text: $model.wsOutgoing)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .htField()
                    .onSubmit { model.sendRealtimeMessage() }
                    .disabled(!model.wsConnected || !model.rtProtocol.canSend)
                Button { model.sendRealtimeMessage() } label: { Text("Send") }
                    .buttonStyle(.htPrimary)
                    .disabled(!model.wsConnected || model.wsOutgoing.isEmpty || !model.rtProtocol.canSend)
            }
            .padding(10)
            .background(Theme.color.base.opacity(0.6))
        }
    }
}

// RealtimeRow now lives in HTTrailCore (shared by both apps).

struct ImportCurlSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Import cURL").font(.headline)
            Text("Paste a cURL command to turn it into a request.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $model.importCurlText)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 160)
                .border(Color(nsColor: .separatorColor))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Import") { model.importCurl() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.importCurlText.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 560)
    }
}

struct BreakpointSheet: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let event = model.pendingBreakpoint {
                Label(event.phase == .request ? "Breakpoint — Request" : "Breakpoint — Response",
                      systemImage: "pause.circle.fill")
                    .font(.headline)
                Text(event.request.url).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                Text("Edit the body, then continue or drop the change.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $model.breakpointBody)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 220)
                    .border(Color(nsColor: .separatorColor))
                HStack {
                    Spacer()
                    Button("Continue Unchanged") { model.resolveBreakpoint(apply: false) }
                    Button("Apply & Continue") { model.resolveBreakpoint(apply: true) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .frame(width: 620)
    }
}
