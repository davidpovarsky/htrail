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
                Text("Sessions").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.color.textMuted)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
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
                            SessionRow(session: session)
                        }
                        .buttonStyle(.plain)
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
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var flowList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { model.viewSession(nil) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                }.buttonStyle(.plain)
                Text(model.sessions.first { $0.id == model.viewingSessionID }?.name ?? "Session")
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer()
                if !model.selectedFlowIDs.isEmpty {
                    Button(role: .destructive) { model.deleteSelectedFlows() } label: {
                        Image(systemName: "trash")
                    }.buttonStyle(.plain).help("Delete selected requests")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)

            ResourceFilterBar(selection: $model.resourceTypeFilter)
                .padding(.bottom, 6)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.color.textFaint)
                TextField("Filter host, path or method", text: $model.filterText)
                    .textFieldStyle(.plain).font(.system(size: 12))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .htField()
            .padding(.horizontal, 10).padding(.bottom, 8)

            List(selection: $model.selectedFlowIDs) {
                ForEach(model.filteredFlows) { flow in
                    FlowRow(flow: flow).tag(flow.id)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
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
            MethodBadge(method: flow.request.method)
            VStack(alignment: .leading, spacing: 1) {
                Text(flow.request.host)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.color.textBright)
                    .lineLimit(1)
                Text(flow.request.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.color.textMuted)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                StatusIndicator(state: statusState)
                if let ms = flow.durationMS {
                    Text("\(ms) ms").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.color.textFaint)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var statusState: StatusIndicator.State {
        switch flow.state {
        case .pending: return .pending
        case .failed: return .error
        case .completed: return flow.statusCode.map { .code($0) } ?? .none
        }
    }
}

/// Detail inspector for a selected flow: request & response with header/body/preview.
struct FlowInspector: View {
    @EnvironmentObject var model: AppModel
    let flow: Flow
    @State private var tab: Tab = .response

    enum Tab: String, CaseIterable, Identifiable {
        case request = "Request"
        case response = "Response"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    MethodBadge(method: flow.request.method)
                    Text(flow.request.url)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                    Spacer()
                    Menu {
                        Button("Edit & Resend (Compose)") { model.composeFromFlow(flow) }
                        Button("Copy as cURL") {
                            let req = APIRequest(method: flow.request.method, url: flow.request.url,
                                                 headers: flow.request.headers.map { KeyValueItem(name: $0.name, value: $0.value) })
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(CurlConverter().exportCommand(req), forType: .string)
                        }
                    } label: { Image(systemName: "square.and.pencil") }
                    .frame(width: 44)
                }
                HStack(spacing: 12) {
                    Label(flow.secure ? "HTTPS (decrypted)" : "HTTP",
                          systemImage: flow.secure ? "lock.fill" : "lock.open")
                        .font(.caption).foregroundStyle(.secondary)
                    if let code = flow.statusCode {
                        Text("Status \(code)")
                            .font(.caption.bold())
                            .foregroundStyle(UIFormat.statusColor(code))
                    }
                    if let ms = flow.durationMS {
                        Text("\(ms) ms").font(.caption).foregroundStyle(.secondary)
                    }
                    if let err = flow.error {
                        Text(err).font(.caption).foregroundStyle(.red).lineLimit(1)
                    }
                }
            }
            .padding(12)
            Divider()

            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            switch tab {
            case .request:
                MessageView(headers: flow.request.headers, bodyData: flow.request.body,
                            contentType: flow.request.header("Content-Type"),
                            baseURL: URL(string: flow.request.url))
            case .response:
                if let response = flow.response {
                    MessageView(headers: response.headers, bodyData: response.body,
                                contentType: response.contentType,
                                baseURL: URL(string: flow.request.url))
                } else {
                    ContentUnavailableView("No response", systemImage: "tray",
                                           description: Text(flow.error ?? "Request still in flight"))
                }
            }
        }
    }
}

/// Tabbed headers/body/preview viewer shared by request & response.
struct MessageView: View {
    let headers: [HeaderPair]
    let bodyData: Data
    let contentType: String?
    var baseURL: URL?
    @State private var section: Section = .body

    enum Section: String, CaseIterable, Identifiable {
        case headers = "Headers"
        case body = "Body"
        case preview = "Preview"
        var id: String { rawValue }
    }

    private var isHTML: Bool { (contentType ?? "").lowercased().contains("html") }
    private var isImage: Bool { (contentType ?? "").lowercased().hasPrefix("image/") }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8).padding(.bottom, 6)

            switch section {
            case .headers:
                HeaderTable(headers: headers)
            case .body:
                BodyViewer(data: bodyData, contentType: contentType)
            case .preview:
                Group {
                    if isHTML, let html = String(data: bodyData, encoding: .utf8) {
                        HTMLPreview(html: html, baseURL: baseURL)
                    } else if isImage {
                        ImagePreview(data: bodyData)
                    } else {
                        ContentUnavailableView("No preview", systemImage: "eye.slash",
                                               description: Text("Preview supports HTML and images. Content-Type: \(contentType ?? "unknown")"))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }
}

// HeaderTable now lives in HTTrailCore (shared by both apps).
