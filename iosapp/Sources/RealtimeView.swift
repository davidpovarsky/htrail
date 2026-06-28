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
            .htScreenChrome("Realtime") { LiveStatusPill(active: model.wsConnected) }
            .keyboardDismissButton()
        }
    }

    private var connectionForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            protocolPicker

            switch model.rtProtocol {
            case .webSocket, .socketIO, .sse:
                fieldCard("Endpoint") {
                    TextField(urlPlaceholder, text: $model.wsURL)
                        .textFieldStyle(.plain)
                        .font(Theme.mono(13))
                        .foregroundStyle(Theme.color.textBright)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                }
                if model.rtProtocol == .socketIO {
                    fieldCard("Event") {
                        TextField("Event name", text: $model.sioEvent)
                            .textFieldStyle(.plain)
                            .font(Theme.mono(13))
                            .foregroundStyle(Theme.color.textBright)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                }
            case .mqtt:
                HStack(alignment: .top, spacing: 10) {
                    fieldCard("Broker host") {
                        TextField("Broker host", text: $model.mqttHost)
                            .textFieldStyle(.plain)
                            .font(Theme.mono(13))
                            .foregroundStyle(Theme.color.textBright)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                    fieldCard("Port") {
                        TextField("Port", value: $model.mqttPort, format: .number)
                            .textFieldStyle(.plain)
                            .font(Theme.mono(13))
                            .foregroundStyle(Theme.color.textBright)
                    }
                    .frame(width: 96)
                }
                fieldCard("Topic") {
                    TextField("Topic", text: $model.mqttTopic)
                        .textFieldStyle(.plain)
                        .font(Theme.mono(13))
                        .foregroundStyle(Theme.color.textBright)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                }
            }

            if model.wsConnected {
                Button(role: .destructive) { model.disconnectRealtime() } label: {
                    connectLabel("Disconnect", dot: .live)
                }
                .buttonStyle(.plain)
                .background(Theme.color.red.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Theme.color.red.opacity(0.40), lineWidth: 1))
                .foregroundStyle(Color(hex: "#FCA5A5"))
            } else {
                Button { model.connectRealtime() } label: {
                    connectLabel("Connect", dot: .off)
                }
                .buttonStyle(.plain)
                .background(Theme.color.green.opacity(0.16),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Theme.color.green.opacity(0.42), lineWidth: 1))
                .foregroundStyle(Color(hex: "#6EE7B7"))
            }

            Toggle(isOn: Binding(get: { model.testServerRunning },
                                 set: { _ in model.toggleTestServer() })) {
                Label("Local test server", systemImage: "ladybug")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.color.textDim)
            }
            .tint(Theme.color.accent)
            .disabled(model.testServerBusy)
            if model.testServerRunning {
                Text(model.testServerHint)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.color.textFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
    }

    /// Custom protocol segmented control matching the v2 design: a `panelBG`
    /// track with a solid-blue active pill (white label) and dim inactive labels.
    private var protocolPicker: some View {
        HStack(spacing: 5) {
            ForEach(AppModel.RealtimeProtocol.allCases) { proto in
                let on = model.rtProtocol == proto
                Button { model.rtProtocol = proto } label: {
                    Text(proto.rawValue)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(on ? .white : Theme.color.textDim)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(on ? Theme.color.accent : .clear,
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Theme.color.panelBG, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .disabled(model.wsConnected)
    }

    /// Shared Connect / Disconnect button content: a status dot + bold label,
    /// full-width with the design's 13px vertical padding.
    private func connectLabel(_ title: String, dot: ConnectionDot.Status) -> some View {
        HStack(spacing: 8) {
            ConnectionDot(status: dot)
            Text(title).font(.system(size: 14, weight: .bold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    /// A labeled mono input card: an `HTEyebrow` above a `.htField()` surface.
    private func fieldCard<Content: View>(_ label: String,
                                          @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HTEyebrow(label)
            content()
                .padding(.horizontal, 12).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .htField()
        }
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
            TextField(composerPlaceholder, text: $model.wsOutgoing)
                .textFieldStyle(.plain)
                .font(Theme.mono(13))
                .foregroundStyle(Theme.color.textBright)
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

    /// Composer placeholder matching the design: SSE is receive-only, MQTT
    /// publishes to a topic, everything else sends a message.
    private var composerPlaceholder: String {
        switch model.rtProtocol {
        case .sse: return "Receive-only stream"
        case .mqtt: return "Publish payload to topic…"
        default: return "Send a message…"
        }
    }

    private var urlPlaceholder: String {
        switch model.rtProtocol {
        case .socketIO: return "https://… (Socket.IO)"
        case .sse: return "https://… (SSE stream)"
        default: return "wss://…"
        }
    }
}
