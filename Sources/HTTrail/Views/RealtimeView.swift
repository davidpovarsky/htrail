import SwiftUI
import HTTrailCore

struct RealtimeSidebar: View {
    @EnvironmentObject var model: AppModel

    // rgba(255,255,255,.1) — the design's segmented/field border.
    private let fieldBorder = Color.white.opacity(0.1)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — padding 13/14/11, 13px 700
            Text("Realtime")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.color.textBright)
                .padding(.horizontal, 14).padding(.top, 13).padding(.bottom, 11)

            // PROTOCOL segmented control — bg #0e1228, border white .1, radius 9, padding 3
            HStack(spacing: 3) {
                ForEach(AppModel.RealtimeProtocol.allCases) { proto in
                    Button {
                        if !model.wsConnected { model.rtProtocol = proto }
                    } label: {
                        Text(proto.rawValue)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(model.rtProtocol == proto ? Theme.color.accent : Theme.color.textMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7).padding(.horizontal, 4)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.radius.sm, style: .continuous)
                                    .fill(model.rtProtocol == proto ? Theme.color.accent.opacity(0.16) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                    .fill(Theme.color.panelBG)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                            .stroke(fieldBorder, lineWidth: 1)
                    )
            )
            .disabled(model.wsConnected)
            .padding(.horizontal, 12).padding(.bottom, 14)

            // Fields + Connect — content padding 0 12
            VStack(alignment: .leading, spacing: 12) {
                switch model.rtProtocol {
                case .webSocket, .socketIO, .sse:
                    fieldCard(label: "URL") {
                        TextField(urlPlaceholder, text: $model.wsURL)
                            .textFieldStyle(.plain)
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.color.codeKey)
                    }
                    if model.rtProtocol == .socketIO {
                        fieldCard(label: "EVENT") {
                            TextField("Event name", text: $model.sioEvent)
                                .textFieldStyle(.plain)
                                .font(Theme.mono(12))
                                .foregroundStyle(Theme.color.textSoft)
                        }
                    }
                case .mqtt:
                    fieldCard(label: "BROKER HOST") {
                        TextField("Broker host", text: $model.mqttHost)
                            .textFieldStyle(.plain)
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.color.textSoft)
                    }
                    fieldCard(label: "PORT") {
                        TextField("Port", value: $model.mqttPort, format: .number)
                            .textFieldStyle(.plain)
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.color.textSoft)
                    }
                    fieldCard(label: "TOPIC") {
                        TextField("Topic", text: $model.mqttTopic)
                            .textFieldStyle(.plain)
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.color.textSoft)
                    }
                }

                // CONNECT / Disconnect — full-width, centered, dot 8px, 13px 700, radius 9
                connectButton
            }
            .padding(.horizontal, 12)

            Spacer(minLength: 0)

            // Bottom — Local test server, border-top hairline
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Local test server")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.color.textSoft)
                    Spacer()
                    testServerToggle
                }
                hintText
                if model.testServerRunning {
                    Text(model.testServerHint)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.color.textFaint)
                        .lineLimit(2)
                }
            }
            .padding(12)
            .overlay(Theme.color.hairline.frame(height: 1), alignment: .top)
        }
    }

    // CONNECT / Disconnect button.
    private var connectButton: some View {
        let connected = model.wsConnected
        let tint = connected ? Theme.color.red : Theme.color.accent
        return Button {
            if connected { model.disconnectRealtime() } else { model.connectRealtime() }
        } label: {
            HStack(spacing: 9) {
                ConnectionDot(status: connected ? .live : .off)
                Text(connected ? "Disconnect" : "Connect")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(tint)
            }
            .frame(maxWidth: .infinity)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                    .fill(tint.opacity(connected ? 0.12 : 0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                            .stroke(tint.opacity(0.4), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(model.testServerBusy)
        .opacity(model.testServerBusy ? 0.6 : 1)
    }

    // Custom 42x24 pill toggle (knob 20px, inset 2) matching the design.
    private var testServerToggle: some View {
        Button { model.toggleTestServer() } label: {
            ZStack(alignment: model.testServerRunning ? .trailing : .leading) {
                Capsule()
                    .fill(model.testServerRunning ? Theme.color.green : Color.white.opacity(0.12))
                    .frame(width: 42, height: 24)
                Circle()
                    .fill(.white)
                    .frame(width: 20, height: 20)
                    .padding(2)
            }
            .animation(.easeInOut(duration: 0.16), value: model.testServerRunning)
        }
        .buttonStyle(.plain)
        .disabled(model.testServerBusy)
        .opacity(model.testServerBusy ? 0.6 : 1)
    }

    // "Spins up an echo server on :9091 …" — 10.5px, :9091 mono.
    private var hintText: some View {
        (Text("Spins up an echo server on ")
            + Text(":9091").font(Theme.mono(10.5)).foregroundColor(Theme.color.textMuted)
            + Text(" so you can test send/receive without a backend."))
            .font(.system(size: 10.5))
            .foregroundColor(Theme.color.textFaint)
            .lineSpacing(4)
    }

    @ViewBuilder
    private func fieldCard<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HTEyebrow(label)
            content()
                .padding(.horizontal, 12).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.color.panelBG)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(fieldBorder, lineWidth: 1)
                        )
                )
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

struct RealtimeView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            // Connection header — pulsing dot + "wss://… · connected" mono 12.5/600
            HStack(spacing: 10) {
                ConnectionDot(status: model.wsConnected ? .live : .off)
                Text(model.wsConnected ? "\(model.wsURL) · connected" : "disconnected")
                    .font(Theme.mono(12.5, .semibold))
                    .foregroundStyle(model.wsConnected ? Theme.color.textSoft : Theme.color.textMuted)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 18).padding(.vertical, 13)
            .overlay(Theme.color.hairline.frame(height: 1), alignment: .bottom)

            // Message log — direction glyphs, mono; padding 8px 0
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.wsMessages) { message in
                            RealtimeRow(message: message).id(message.id)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: model.wsMessages.count) { _, _ in
                    if let last = model.wsMessages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            // Composer — mono field + gradient Send; padding 12/16, border-top hairline
            HStack(spacing: 10) {
                TextField(model.rtProtocol.canSend ? "Send a message…" : "Receive-only stream", text: $model.wsOutgoing)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(12.5))
                    .foregroundStyle(Theme.color.textBright)
                    .padding(.horizontal, 12).padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                            .fill(Theme.color.panelBG)
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
                            )
                    )
                    .onSubmit { model.sendRealtimeMessage() }
                    .disabled(!model.wsConnected || !model.rtProtocol.canSend)
                Button { model.sendRealtimeMessage() } label: { Text("Send") }
                    .buttonStyle(.htPrimary)
                    .disabled(!model.wsConnected || model.wsOutgoing.isEmpty || !model.rtProtocol.canSend)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .overlay(Theme.color.hairline.frame(height: 1), alignment: .top)
        }
        .background(Theme.color.responseBG)
    }
}

// RealtimeRow now lives in HTTrailCore (shared by both apps).

struct ImportCurlSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Import cURL")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.color.textBright)
            Text("Paste a cURL command to turn it into a request.")
                .font(.caption).foregroundStyle(Theme.color.textMuted)
            TextEditor(text: $model.importCurlText)
                .font(Theme.mono(12))
                .frame(minHeight: 160)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                        .fill(Theme.color.panelBG)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                                .stroke(Theme.color.border, lineWidth: 1)
                        )
                )
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
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.color.textBright)
                Text(event.request.url).font(Theme.mono(11)).foregroundStyle(Theme.color.textDim).lineLimit(2)
                Text("Edit the body, then continue or drop the change.")
                    .font(.caption).foregroundStyle(Theme.color.textMuted)
                TextEditor(text: $model.breakpointBody)
                    .font(Theme.mono(12))
                    .frame(minHeight: 220)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                            .fill(Theme.color.panelBG)
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                                    .stroke(Theme.color.border, lineWidth: 1)
                            )
                    )
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
