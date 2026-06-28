import SwiftUI
import HTTrailCore

/// Sidebar list of saved API requests (the Hoppscotch collection pane).
struct RequestListView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Requests").font(.headline)
                Spacer()
                Button { model.newRequest() } label: {
                    Label("New", systemImage: "plus").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
            }
            .padding(8)
            Divider()
            List(selection: $model.selectedRequestID) {
                ForEach(model.requests) { request in
                    HStack(spacing: 8) {
                        MethodBadge(method: request.method)
                        Text(AppModel.composeRequestTitle(for: request))
                            .lineLimit(1)
                    }
                    .tag(request.id)
                }
            }
            .listStyle(.inset)
        }
    }
}

/// The Hoppscotch-style request composer + response viewer.
struct RequestEditorView: View {
    @EnvironmentObject var model: AppModel
    /// Whether the response panel sits beside the request (draggable HSplit) or
    /// below it (draggable VSplit). Persisted across launches.
    @AppStorage("composeResponseBeside") private var responseBeside = true

    private static let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

    var body: some View {
        if let index = model.selectedRequestIndex {
            editor(index: index)
        } else {
            ContentUnavailableView("No request selected", systemImage: "paperplane")
        }
    }

    @ViewBuilder
    private func editor(index: Int) -> some View {
        let request = model.requests[index]
        // Both layouts use a SwiftUI split view, so the divider between the
        // request form and the response is always draggable for more area.
        if responseBeside {
            HSplitView {
                requestPane(index: index).frame(minWidth: 380)
                responsePane(request: request).frame(minWidth: 360)
            }
        } else {
            VSplitView {
                requestPane(index: index).frame(minHeight: 170)
                responsePane(request: request).frame(minHeight: 220)
            }
        }
    }

    @ViewBuilder
    private func requestPane(index: Int) -> some View {
        let requestBinding = $model.requests[index]
        let request = model.requests[index]
        VStack(spacing: 0) {
            // ===== URL bar =====
            HStack(spacing: 9) {
                // Method well — tinted by the current method.
                Menu {
                    ForEach(Self.methods, id: \.self) { m in
                        Button(m) { model.requests[index].method = m }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(request.method)
                            .font(Theme.mono(12.5, .bold))
                            .foregroundStyle(Theme.methodColor(request.method))
                        Text("\u{25BE}")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.color.textFaint)
                    }
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(Theme.methodColor(request.method).opacity(0.14),
                                in: RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                        .strokeBorder(Theme.methodColor(request.method).opacity(0.40), lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()

                // URL field. Pasting a full `curl …` command here is detected and
                // parsed into the whole request automatically.
                TextField("https://api.example.com/endpoint  (or paste a cURL command)", text: requestBinding.url)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(12.5))
                    .foregroundStyle(Theme.color.textBright)
                    .padding(.vertical, 10).padding(.horizontal, 12)
                    .frame(maxWidth: .infinity)
                    .background(Theme.color.panelBG,
                                in: RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                    .onTapGesture {
                        model.prepareComposeURLFieldForEditing(at: index)
                    }
                    .onChange(of: model.requests[index].url) { _, newValue in
                        if !model.applyCurlIfDetected(newValue, at: index) {
                            model.normalizeComposeURLIfNeeded(newValue, at: index)
                        }
                    }

                // Gradient Send button.
                Button {
                    model.sendSelectedRequest()
                } label: {
                    HStack(spacing: 8) {
                        if model.isSending {
                            ProgressView().controlSize(.small).tint(.white)
                        }
                        Text(model.isSending ? "Sending…" : "Send")
                    }
                }
                .buttonStyle(.htPrimary)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.isSending)

                // Layout toggle — icon + text well. Shows the action it performs
                // (move the response Below when beside, Beside when below).
                Button {
                    responseBeside.toggle()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: responseBeside ? "rectangle.split.1x2" : "rectangle.split.2x1")
                        Text(responseBeside ? "Below" : "Beside")
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.color.textDim)
                        .padding(.horizontal, 11)
                        .frame(minWidth: 76, minHeight: 38)
                        .background(Theme.color.fill, in: RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help(responseBeside ? "Move response below" : "Move response beside")

                // More menu — 38×38 ghost well.
                Menu {
                    Button("Save to Collection") { model.saveRequestToCollection() }
                    Button("Duplicate") { model.loadRequest(model.requests[index]) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Theme.color.textDim)
                        .frame(width: 38, height: 38)
                        .background(Theme.color.fill, in: RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .fixedSize()
                .help("More")
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.color.hairline).frame(height: 1)
            }

            RequestConfigTabs(request: requestBinding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func responsePane(request: APIRequest) -> some View {
        ResponseView(response: model.responsesByRequest[request.id],
                     scriptOutput: model.scriptOutputs[request.id])
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.color.responseBG)
    }
}

/// A 38×38 ghost icon well (layout toggle / More) used in the Compose URL bar.
struct IconWellButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 38, height: 38)
            .foregroundStyle(Theme.color.textDim)
            .background(Theme.color.fill, in: RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

/// v2 underlined tab bar: active tab gets a 2px accent underline, inactive tabs
/// are muted with a clear underline. A hairline divider sits under the whole row.
struct UnderlinedTabBar: View {
    let tabs: [String]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { t in
                let active = selection == t
                Button { selection = t } label: {
                    Text(t)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(active ? Theme.color.text : Theme.color.textMuted)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.vertical, 10).padding(.horizontal, 11)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(active ? Theme.color.accent : Color.clear)
                                .frame(height: 2)
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.color.hairline).frame(height: 1)
        }
    }
}

/// v2 mono TextEditor: sits on the code surface with a rounded 1px border.
struct CodeEditorField: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(Theme.mono(12))
            .foregroundStyle(Theme.color.text)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(Theme.color.codeBG)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                .strokeBorder(Theme.color.border, lineWidth: 1))
    }
}

struct RequestConfigTabs: View {
    @EnvironmentObject var model: AppModel
    @Binding var request: APIRequest
    @State private var tab = "Params"
    private let tabs = ["Params", "Headers", "Auth", "Body", "GraphQL", "Scripts", "Code"]

    /// Active-row count shown as a small accent badge next to a tab.
    private func badge(for t: String) -> Int? {
        switch t {
        case "Params":
            let n = request.queryParams.filter { $0.enabled && !$0.name.isEmpty }.count
            return n > 0 ? n : nil
        case "Headers":
            let n = request.headers.filter { $0.enabled && !$0.name.isEmpty }.count
            return n > 0 ? n : nil
        default:
            return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // ===== Config tab bar (gap 1px, padding 0 14px, hairline base). =====
            HStack(spacing: 1) {
                ForEach(tabs, id: \.self) { t in
                    let active = tab == t
                    Button { tab = t } label: {
                        HStack(spacing: 6) {
                            Text(t)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(active ? Theme.color.textBright : Theme.color.textMuted)
                            if let n = badge(for: t) {
                                Text("\(n)")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Theme.color.accent)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Theme.color.blue.opacity(0.16),
                                                in: RoundedRectangle(cornerRadius: 5))
                            }
                        }
                        .padding(.horizontal, 11).padding(.vertical, 10)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(active ? Theme.color.accent : Color.clear)
                                .frame(height: 2)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.color.hairline).frame(height: 1)
            }

            // ===== Tab body (padding 14×16). =====
            ScrollView {
                Group {
                    switch tab {
                    case "Params":
                        KeyValueEditor(items: $request.queryParams, addNoun: "parameter")
                    case "Headers":
                        KeyValueEditor(items: $request.headers, addNoun: "header")
                    case "Auth":
                        AuthEditor(auth: $request.auth)
                    case "GraphQL":
                        graphqlEditor
                    case "Scripts":
                        scriptsEditor
                    case "Code":
                        codePanel
                    default:
                        bodyEditor
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 14)
            }
        }
    }

    private var bodyEditor: some View {
        VStack(alignment: .leading, spacing: 11) {
            // Mode pills.
            HStack(spacing: 6) {
                ForEach(RequestBodyMode.allCases, id: \.self) { mode in
                    let active = request.bodyMode == mode
                    Button { request.bodyMode = mode } label: {
                        Text(mode.rawValue)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(active ? Theme.color.accent : Theme.color.textMuted)
                            .padding(.horizontal, 11).padding(.vertical, 5)
                            .background(active ? Theme.color.blue.opacity(0.16) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(active ? Theme.color.blue.opacity(0.45) : Theme.color.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }

            bodyContent
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
        switch request.bodyMode {
        case .none:
            ContentUnavailableView("No body", systemImage: "doc")
        case .formURLEncoded:
            FormFieldEditor(fields: $request.bodyForm, allowFiles: false)
        case .multipart:
            FormFieldEditor(fields: $request.bodyForm, allowFiles: true)
        case .json:
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    JSONStatusBar(text: request.rawBody)
                    Spacer()
                    Button("Format") {
                        if let pretty = JSONValidation.prettyPrinted(request.rawBody) { request.rawBody = pretty }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.color.accent)
                }
                CodeEditorField(text: $request.rawBody).frame(minHeight: 160)
            }
        case .graphql:
            VStack(alignment: .leading, spacing: 6) {
                Text("GraphQL body — edit the query and variables in the GraphQL tab.")
                    .font(.caption).foregroundStyle(Theme.color.textDim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .raw:
            CodeEditorField(text: $request.rawBody).frame(minHeight: 160)
        }
    }

    private var graphqlEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HTEyebrow("QUERY")
            CodeEditorField(text: $request.graphqlQuery).frame(minHeight: 120)
            HStack(spacing: 8) {
                HTEyebrow("VARIABLES (JSON)")
                Spacer()
                JSONStatusBar(text: request.graphqlVariables)
                Button("Format") {
                    if let pretty = JSONValidation.prettyPrinted(request.graphqlVariables) { request.graphqlVariables = pretty }
                }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(Theme.color.accent)
            }
            CodeEditorField(text: $request.graphqlVariables).frame(minHeight: 60)
            Button("Use GraphQL body mode") { request.bodyMode = .graphql }
                .font(.caption)
        }
    }

    private var scriptsEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Scripts run in JavaScript with a Postman-style `pm` API. The pre-request script runs before the request is sent; the test script runs after the response arrives (results appear under Response ▸ Tests).")
                .font(.caption2).foregroundStyle(Theme.color.textDim)
                .fixedSize(horizontal: false, vertical: true)
            HTEyebrow("PRE-REQUEST SCRIPT")
            Text("e.g. pm.environment.set(\"token\", \"abc123\")")
                .font(Theme.mono(11)).foregroundStyle(Theme.color.textFaint)
            CodeEditorField(text: $request.preRequestScript).frame(minHeight: 90)
            HTEyebrow("TEST SCRIPT")
            Text("e.g. pm.test(\"ok\", () => pm.expect(pm.response.code).to.equal(200))")
                .font(Theme.mono(11)).foregroundStyle(Theme.color.textFaint)
            CodeEditorField(text: $request.testScript).frame(minHeight: 90)
        }
    }

    private var codePanel: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Picker("Target", selection: $model.codeTarget) {
                    ForEach(CodeGenerator.Target.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 220)
                Spacer()
                // Visible icon+text Copy button that flashes "✓ Copied".
                BarButton(title: "Copy", systemImage: "doc.on.doc") {
                    Clipboard.copy(model.generatedCode())
                }
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Theme.color.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.color.border, lineWidth: 1))
            }
            CodeViewer(text: model.generatedCode())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Theme.color.codeBG)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                    .strokeBorder(Theme.color.border, lineWidth: 1))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct TestResultsView: View {
    let output: ScriptOutput
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(output.tests.enumerated()), id: \.offset) { _, test in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: test.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(test.passed ? .green : .red)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(test.name).font(.system(size: 12))
                            if let message = test.message, !test.passed {
                                Text(message).font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                }
                if !output.logs.isEmpty {
                    Divider().padding(.vertical, 4).overlay(Theme.color.hairline)
                    HTEyebrow("CONSOLE")
                    ForEach(Array(output.logs.enumerated()), id: \.offset) { _, line in
                        Text(line).font(Theme.mono(11)).foregroundStyle(Theme.color.textDim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(10)
        }
    }
}

struct AuthEditor: View {
    @Binding var auth: AuthConfig

    private func label(_ t: AuthType) -> String {
        switch t {
        case .apiKey: return "API key"
        default: return t.rawValue.capitalized
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            // ===== TYPE list =====
            VStack(alignment: .leading, spacing: 5) {
                HTEyebrow("TYPE")
                ForEach(AuthType.allCases, id: \.self) { t in
                    let active = auth.type == t
                    Button { auth.type = t } label: {
                        HStack(spacing: 9) {
                            Circle()
                                .fill(active ? Theme.color.accent : Color.clear)
                                .frame(width: 7, height: 7)
                                .overlay(Circle()
                                    .strokeBorder(active ? Theme.color.accent : Theme.color.textMuted, lineWidth: 1.5))
                            Text(label(t))
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(active ? Theme.color.text : Theme.color.textMuted)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 11).padding(.vertical, 8)
                        .background(active ? Theme.color.fill : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 170)

            // ===== Fields =====
            VStack(alignment: .leading, spacing: 12) {
                switch auth.type {
                case .none:
                    Text("No authorization sent with this request.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.color.textMuted)
                case .bearer:
                    authField("TOKEN") { TextField("token", text: $auth.token) }
                case .basic:
                    authField("USERNAME") { TextField("username", text: $auth.username) }
                    authField("PASSWORD") { SecureField("password", text: $auth.password) }
                case .apiKey:
                    authField("KEY") { TextField("key", text: $auth.key) }
                    authField("VALUE") { TextField("value", text: $auth.value) }
                    Toggle("Add to header (off = query param)", isOn: $auth.addToHeader)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.color.textDim)
                        .toggleStyle(.switch)
                        .tint(Theme.color.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func authField<F: View>(_ title: String, @ViewBuilder _ field: () -> F) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HTEyebrow(title)
            field()
                .textFieldStyle(.plain)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.color.textBright)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .htField()
        }
    }
}

struct ResponseView: View {
    let response: APIResponse?
    var scriptOutput: ScriptOutput?
    @State private var section = "Body"

    private var sections: [String] {
        var base = ["Body", "Headers"]
        if let raw = response?.rawRequestHeader, !raw.isEmpty { base.append("Request") }
        base.append("Preview")
        if let scriptOutput, !scriptOutput.tests.isEmpty || !scriptOutput.logs.isEmpty { base.append("Tests") }
        return base
    }

    var body: some View {
        if let response {
            let contentType = response.headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
            VStack(alignment: .leading, spacing: 0) {
                // ===== Status bar =====
                HStack(spacing: 12) {
                    if response.error == nil {
                        Text("\(response.statusCode)")
                            .font(Theme.mono(14, .bold))
                            .foregroundStyle(UIFormat.statusColor(response.statusCode))
                    } else {
                        StatusIndicator(state: .error)
                    }
                    Text("\(response.durationMS) ms").foregroundStyle(Theme.color.textDim)
                        .font(Theme.mono(12))
                    Text(UIFormat.byteSize(response.body.count)).foregroundStyle(Theme.color.textDim)
                        .font(Theme.mono(12))
                    if let ct = contentType?.split(separator: ";").first.map(String.init) {
                        Text(ct)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.color.textSoft)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Theme.color.fill, in: RoundedRectangle(cornerRadius: 6))
                    }
                    if let count = scriptOutput?.tests.count, count > 0 {
                        let passed = scriptOutput?.tests.filter { $0.passed }.count ?? 0
                        let allPass = passed == count
                        HStack(spacing: 4) {
                            Image(systemName: allPass ? "checkmark" : "xmark")
                            Text("\(passed)/\(count)")
                        }
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(allPass ? Color(hex: "#6EE7B7") : Theme.color.amber)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background((allPass ? Theme.color.green : Theme.color.amber).opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder((allPass ? Theme.color.green : Theme.color.amber).opacity(0.3), lineWidth: 1))
                    }
                    if let err = response.error {
                        Text(err).foregroundStyle(Theme.color.red).font(.system(size: 12)).lineLimit(1)
                    }
                    Label("decrypted", systemImage: "lock.fill")
                        .font(.system(size: 11)).foregroundStyle(Theme.color.codeKey)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 11)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.color.hairline).frame(height: 1)
                }

                // ===== Subtabs + copy body =====
                HStack(spacing: 0) {
                    UnderlinedTabBar(tabs: sections, selection: $section)
                    BarButton(title: "Copy", systemImage: "doc.on.doc") {
                        Clipboard.copy(copyText(for: response))
                    }
                    .padding(.trailing, 12)
                }
                .padding(.leading, 12)

                if section == "Tests" {
                    TestResultsView(output: scriptOutput ?? ScriptOutput())
                } else {
                    content(response)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            // ===== Empty state =====
            VStack(spacing: 15) {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.color.violet.opacity(0.20), Theme.color.blue.opacity(0.14)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 62, height: 62)
                    .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .strokeBorder(Color(hex: "#6366F1").opacity(0.28), lineWidth: 1))
                    .overlay(Image(systemName: "arrow.right")
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(Color(hex: "#8FB3FF")))
                VStack(spacing: 6) {
                    Text("Send a request to see the response")
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundStyle(Theme.color.textSoft)
                    HStack(spacing: 4) {
                        Text("Press")
                        Text("⌘↩")
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.color.textDim)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Theme.color.fill, in: RoundedRectangle(cornerRadius: 5))
                        Text("or the Send button.")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.color.textFaint)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func content(_ response: APIResponse) -> some View {
        let contentType = response.headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
        switch section {
        case "Headers":
            HeaderTable(headers: response.headers)
        case "Request":
            RawRequestViewer(text: response.rawRequestHeader ?? "")
        case "Preview":
            Group {
                if (contentType ?? "").lowercased().contains("html"),
                   let html = String(data: response.body, encoding: .utf8) {
                    HTMLPreview(html: html, baseURL: nil)
                } else if ImageSniffer.isImage(data: response.body, contentType: contentType) {
                    ImagePreview(data: response.body, contentType: contentType)
                } else {
                    ContentUnavailableView("No preview", systemImage: "eye.slash",
                                           description: Text("Preview supports HTML and images."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        default:
            BodyViewer(data: response.body, contentType: contentType)
        }
    }

    private func copyText(for response: APIResponse) -> String {
        switch section {
        case "Headers":
            return response.headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
        case "Request":
            return response.rawRequestHeader ?? ""
        default:
            return String(data: response.body, encoding: .utf8) ?? ""
        }
    }
}
