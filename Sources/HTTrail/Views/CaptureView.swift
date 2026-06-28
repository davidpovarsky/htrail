import SwiftUI
import HTTrailCore

/// Capture sidebar: the Sessions list, or a selected session's flow list.
struct FlowListView: View {
    @EnvironmentObject var model: AppModel
    @State private var renaming: CaptureSession?
    @State private var renameText = ""
    @State private var editingNotes: CaptureSession?
    @State private var notesText = ""

    var body: some View {
        Group {
            if model.viewingSessionID == nil {
                sessionsList
            } else {
                flowList
            }
        }
        .sheet(item: $renaming) { session in
            EditTextSheet(title: "Rename Session", text: $renameText) {
                model.renameSession(session.id, to: renameText)
            }
        }
        .sheet(item: $editingNotes) { session in
            EditTextSheet(title: "Session Notes", text: $notesText, multiline: true) {
                model.setSessionNotes(session.id, notesText)
            }
        }
    }

    private var sessionsList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sessions").font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.color.text)
                Spacer()
                Text("\(model.sessions.count)")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.color.textFaint)
            }
            .padding(.horizontal, 14).padding(.top, 13).padding(.bottom, 10)
            if model.sessions.isEmpty {
                Spacer()
                Text("No sessions yet — press Start to record.")
                    .font(.system(size: 11)).foregroundStyle(Theme.color.textFaint)
                    .multilineTextAlignment(.center).padding()
                Spacer()
            } else {
                List {
                    ForEach(model.sessions) { session in
                        Button { model.viewSession(session.id) } label: {
                            SessionCard(session: session)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .contextMenu {
                            Button("Open") { model.viewSession(session.id) }
                            Button("Resume Capture") { model.startProxy(resuming: session.id) }
                                .disabled(model.isProxyRunning)
                            Button("Rename…") { renameText = session.name; renaming = session }
                            Button("Edit Notes…") { notesText = session.notes; editingNotes = session }
                            Button("Export HAR…") { model.exportHAR(sessionID: session.id) }
                            Divider()
                            Button("Delete", role: .destructive) { model.deleteSession(session.id) }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var flowList: some View {
        VStack(spacing: 0) {
            let viewingSession = model.sessions.first { $0.id == model.viewingSessionID }
            HStack(spacing: 8) {
                Button { model.viewSession(nil) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.color.textSoft)
                        .frame(width: 26, height: 26)
                        .background(Color.white.opacity(0.04),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1))
                }.buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 1) {
                    Text(viewingSession?.name ?? "Session")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(Theme.color.text)
                        .lineLimit(1)
                    Text("\(viewingSession?.recordCount ?? model.filteredFlows.count) flows")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.color.textFaint)
                }
                Spacer()
                if !model.selectedFlowIDs.isEmpty {
                    Button(role: .destructive) { model.deleteSelectedFlows() } label: {
                        Label("Delete", systemImage: "trash").labelStyle(.titleAndIcon)
                    }.buttonStyle(.plain).help("Delete selected requests")
                }
            }
            .padding(.horizontal, 12).padding(.top, 11).padding(.bottom, 9)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.color.textFaint)
                TextField("Filter host, path or method", text: $model.filterText)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .foregroundStyle(Theme.color.textBright)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Theme.color.app.opacity(0.5),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Theme.color.border, lineWidth: 1))
            .padding(.horizontal, 12).padding(.vertical, 9)

            ResourceFilterBar(selection: $model.resourceTypeFilter)
                .padding(.bottom, 9)

            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)

            List(selection: $model.selectedFlowIDs) {
                ForEach(model.filteredFlows) { flow in
                    FlowRow(flow: flow).tag(flow.id)
                        .listRowSeparatorTint(Color.white.opacity(0.04))
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }
}

/// A session rendered as a v2 card: name + time, flow count, optional note.
struct SessionCard: View {
    let session: CaptureSession
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if session.isRecording {
                    Image(systemName: "record.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.color.red)
                }
                Text(session.name)
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(Theme.color.textBright)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.color.textFaint)
                    .lineLimit(1)
                    .fixedSize()
            }
            HStack(spacing: 8) {
                Text("\(session.recordCount) flow\(session.recordCount == 1 ? "" : "s")")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.color.textMuted)
                if session.isRecording {
                    Text("REC")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.color.red)
                }
                if !session.notes.isEmpty {
                    Text("· \(session.notes)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.color.textDim)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.05 : 0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(hovering ? Theme.color.borderStrong : Theme.color.hairline, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering = $0 }
    }
}

/// Small reusable sheet for renaming / editing notes.
struct EditTextSheet: View {
    let title: String
    @Binding var text: String
    var multiline = false
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            if multiline {
                TextEditor(text: $text).frame(height: 120).font(.system(size: 12))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.color.hairline))
            } else {
                TextField("", text: $text).textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { onSave(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18).frame(width: 360)
    }
}

struct FlowRow: View {
    let flow: Flow
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: flow.secure ? "lock.fill" : "lock.open")
                .font(.system(size: 10))
                .foregroundStyle(flow.secure ? Theme.color.green : Theme.color.textFaint)
            Text(flow.isWebSocket ? "WS" : flow.request.method.uppercased())
                .font(Theme.mono(9, .bold))
                .foregroundStyle(flow.isWebSocket ? Theme.color.cyan : Theme.methodColor(flow.request.method))
                .frame(width: 46, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(flow.request.host)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.color.textBright)
                    .lineLimit(1)
                Text(flow.request.path)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.color.textMuted)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                StatusIndicator(state: statusState)
                if flow.isWebSocket {
                    Text("\(flow.webSocketMessages?.count ?? 0) msg")
                        .font(Theme.mono(9.5)).foregroundStyle(Theme.color.textFaint)
                } else if let ms = flow.durationMS {
                    Text("\(ms) ms").font(Theme.mono(9.5)).foregroundStyle(Theme.color.textFaint)
                }
            }
        }
        .padding(.vertical, 5)
    }

    private var statusState: StatusIndicator.State {
        switch flow.state {
        case .pending: return .pending
        case .failed: return .error
        case .completed: return flow.statusCode.map { .code($0) } ?? .none
        }
    }
}

/// Detail inspector for a selected flow: a header block, a combined
/// Request/Response segmented control + Headers/Body/Preview sub-toggle on one
/// toolbar row, then the matching content.
struct FlowInspector: View {
    @EnvironmentObject var model: AppModel
    let flow: Flow
    @State private var tab: Tab
    @State private var section: Section = .body

    init(flow: Flow) {
        self.flow = flow
        _tab = State(initialValue: flow.isWebSocket ? .messages : .response)
    }

    enum Tab: String, CaseIterable, Identifiable {
        case request = "Request"
        case response = "Response"
        case messages = "Messages"
        var id: String { rawValue }
    }
    enum Section: String, CaseIterable, Identifiable {
        case headers = "Headers"
        case body = "Body"
        case preview = "Preview"
        var id: String { rawValue }
    }

    /// Re-read the live flow from the model so a streaming WebSocket's frames keep
    /// updating while the inspector is open.
    private var current: Flow { model.displayedFlows.first { $0.id == flow.id } ?? flow }
    private var tabs: [Tab] { flow.isWebSocket ? [.request, .messages] : [.request, .response] }

    // The currently-selected message (request or response).
    private var activeHeaders: [HeaderPair] {
        tab == .request ? flow.request.headers : (flow.response?.headers ?? [])
    }
    private var activeBody: Data {
        tab == .request ? flow.request.body : (flow.response?.body ?? Data())
    }
    private var activeContentType: String? {
        tab == .request ? flow.request.header("Content-Type") : flow.response?.contentType
    }
    private var isHTML: Bool { (activeContentType ?? "").lowercased().contains("html") }
    private var isImage: Bool { ImageSniffer.isImage(data: activeBody, contentType: activeContentType) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.06))
            toolbar
            Divider().overlay(Color.white.opacity(0.05))
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Theme.color.responseBG)
        }
    }

    // MARK: header block

    private var header: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 11) {
                Text(flow.request.method.uppercased())
                    .font(Theme.mono(11, .bold))
                    .foregroundStyle(Theme.methodColor(flow.request.method))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.white.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Theme.methodColor(flow.request.method).opacity(0.2), lineWidth: 1))
                Text(flow.request.url)
                    .font(Theme.mono(12.5))
                    .foregroundStyle(Theme.color.textBright)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                editMenu
            }
            metaRow
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private var editMenu: some View {
        Menu {
            Button("Edit & Resend (Compose)") { model.composeFromFlow(flow) }
            Button("Copy as cURL") {
                let req = APIRequest(method: flow.request.method, url: flow.request.url,
                                     headers: flow.request.headers.map { KeyValueItem(name: $0.name, value: $0.value) })
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(CurlConverter().exportCommand(req), forType: .string)
            }
        } label: {
            HStack(spacing: 6) {
                Text("Edit").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.color.textSoft)
                Image(systemName: "chevron.down").font(.system(size: 9))
                    .foregroundStyle(Theme.color.textFaint)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Theme.color.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Theme.color.borderStrong, lineWidth: 1))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    private var metaSep: some View {
        Text("·").font(.system(size: 11.5)).foregroundStyle(Color(hex: "#3A3C5E"))
    }

    private var metaRow: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: flow.secure ? "lock.fill" : "lock.open").font(.system(size: 12))
                Text(flow.secure ? "HTTPS (decrypted)" : "HTTP")
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(flow.secure ? Theme.color.green : Theme.color.textMuted)
            if let code = flow.statusCode {
                metaSep
                Text("\(code)")
                    .font(Theme.mono(11.5, .bold))
                    .foregroundStyle(UIFormat.statusColor(code))
            }
            if let ms = flow.durationMS {
                metaSep
                Text("\(ms) ms").font(Theme.mono(11.5)).foregroundStyle(Theme.color.textDim)
            }
            if let err = flow.error {
                metaSep
                Text(err)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(hex: "#FCA5A5"))
                    .lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Theme.color.red.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Theme.color.red.opacity(0.3), lineWidth: 1))
            }
        }
    }

    // MARK: toolbar (segmented + sub-toggle)

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                ForEach(tabs) { t in
                    segButton(t.rawValue, active: tab == t) { tab = t }
                }
            }
            .padding(3)
            .background(Theme.color.panelBG, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Theme.color.borderStrong, lineWidth: 1))

            Spacer()

            // The Headers/Body/Preview sub-toggle doesn't apply to the WebSocket
            // frame log.
            if tab != .messages {
                HStack(spacing: 4) {
                    ForEach(Section.allCases) { s in
                        subButton(s.rawValue, active: section == s) { section = s }
                    }
                }
                .padding(3)
                .background(Theme.color.app.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Theme.color.border, lineWidth: 1))
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
    }

    private func segButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(active ? .white : Theme.color.textMuted)
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(active ? Theme.color.accent : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func subButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(active ? Theme.color.textBright : Theme.color.textMuted)
                .padding(.horizontal, 13).padding(.vertical, 6)
                .background(active ? Theme.color.fillHover : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: content

    @ViewBuilder private var content: some View {
        if tab == .messages {
            WebSocketMessagesView(messages: current.webSocketMessages ?? [])
        } else if tab == .response && flow.response == nil {
            ContentUnavailableView("No response", systemImage: "tray",
                                   description: Text(flow.error ?? "Request still in flight"))
        } else {
            switch section {
            case .headers:
                HeaderTable(headers: activeHeaders)
            case .body:
                BodyViewer(data: activeBody, contentType: activeContentType).id(tab)
            case .preview:
                preview
            }
        }
    }

    @ViewBuilder private var preview: some View {
        if isHTML, let html = String(data: activeBody, encoding: .utf8) {
            HTMLPreview(html: html, baseURL: URL(string: flow.request.url))
        } else if isImage {
            ImagePreview(data: activeBody, contentType: activeContentType)
        } else {
            ContentUnavailableView("No preview", systemImage: "photo.on.rectangle",
                                   description: Text("This content type can't be rendered visually. Content-Type: \(activeContentType ?? "unknown")"))
        }
    }
}

/// v2 underlined tab bar: active tab gets `.text` with a 2px accent underline,
/// inactive tabs are `.textMuted`; a 1px hairline divider sits beneath the row.
struct UnderlineTabBar: View {
    let tabs: [String]
    let selection: String
    let onSelect: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                ForEach(tabs, id: \.self) { tab in
                    let active = tab == selection
                    Button { onSelect(tab) } label: {
                        VStack(spacing: 6) {
                            Text(tab)
                                .font(.system(size: 12, weight: active ? .semibold : .regular))
                                .foregroundStyle(active ? Theme.color.text : Theme.color.textMuted)
                            Rectangle()
                                .fill(active ? Theme.color.accent : Color.clear)
                                .frame(height: 2)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            Rectangle()
                .fill(Theme.color.hairline)
                .frame(height: 1)
        }
    }
}

// HeaderTable now lives in HTTrailCore (shared by both apps).
