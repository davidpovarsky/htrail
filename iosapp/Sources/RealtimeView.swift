import SwiftUI
import HTTrailCore

/// WebSocket / Socket.IO / MQTT client with a live message log.
struct RealtimeView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        NavigationStack {
            ZStack {
                Theme.appBackground
                VStack(spacing: 0) {
                    connectionForm
                    Divider().overlay(Theme.color.hairline)
                    messageLog
                    Divider().overlay(Theme.color.hairline)
                    composer
                }
            }
            .navigationTitle("Realtime")
            .keyboardDismissButton()
        }
    }

    private var connectionForm: some View {
        VStack(spacing: 8) {
            Picker("Protocol", selection: $model.rtProtocol) {
                ForEach(AppModel.RealtimeProtocol.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).disabled(model.wsConnected)

            switch model.rtProtocol {
            case .webSocket, .socketIO, .sse:
                TextField(urlPlaceholder, text: $model.wsURL)
                    .textFieldStyle(.roundedBorder).font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                if model.rtProtocol == .socketIO {
                    TextField("Event name", text: $model.sioEvent).textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                }
            case .mqtt:
                TextField("Broker host", text: $model.mqttHost).textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                HStack {
                    Text("Port").font(.caption)
                    TextField("Port", value: $model.mqttPort, format: .number).textFieldStyle(.roundedBorder)
                }
                TextField("Topic", text: $model.mqttTopic).textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
            }

            HStack {
                if model.wsConnected {
                    Button(role: .destructive) { model.disconnectRealtime() } label: {
                        Label("Disconnect", systemImage: "bolt.slash")
                    }
                    .buttonStyle(.htGhost)
                } else {
                    Button { model.connectRealtime() } label: {
                        Label("Connect", systemImage: "bolt.horizontal")
                    }
                    .buttonStyle(.htPrimary)
                }
                Spacer()
                ConnectionDot(status: model.wsConnected ? .live : .off)
            }

            Toggle(isOn: Binding(get: { model.testServerRunning },
                                 set: { _ in model.toggleTestServer() })) {
                Label("Local test server", systemImage: "ladybug").font(.system(size: 12))
            }
            .tint(Theme.color.accent)
            if model.testServerRunning {
                Text(model.testServerHint)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.color.textFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
    }

    private var messageLog: some View {
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
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField(model.rtProtocol.canSend ? "Send a message…" : "Receive-only stream", text: $model.wsOutgoing)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 12).padding(.vertical, 9)
                .htField()
                .onSubmit { model.sendRealtimeMessage() }
                .disabled(!model.wsConnected || !model.rtProtocol.canSend)
            Button { model.sendRealtimeMessage() } label: { Text("Send") }
                .buttonStyle(.htPrimary)
                .disabled(!model.wsConnected || model.wsOutgoing.isEmpty || !model.rtProtocol.canSend)
        }
        .padding(10)
    }

    private var urlPlaceholder: String {
        switch model.rtProtocol {
        case .socketIO: return "https://… (Socket.IO)"
        case .sse: return "https://… (SSE stream)"
        default: return "wss://…"
        }
    }
}
