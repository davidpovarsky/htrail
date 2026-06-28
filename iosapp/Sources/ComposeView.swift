import SwiftUI
import UniformTypeIdentifiers
import HTTrailCore

private let httpMethods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

/// v2 segmented pill tab bar: a panel-coloured track holding pills; the active
/// pill is filled with the accent + white text, inactive pills are transparent
/// with dim text. `fill: true` spreads the pills to equal widths (design's
/// `flex:1`); `fill: false` sizes pills to content and scrolls horizontally so a
/// long tab set (Params…Code) still fits a phone width.
struct SegmentedPillTabs: View {
    let tabs: [String]
    @Binding var selection: String
    var fill: Bool = true

    var body: some View {
        Group {
            if fill {
                HStack(spacing: 3) { pills }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) { pills }
                }
            }
        }
        .padding(3)
        .background(Theme.color.panelBG,
                    in: RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
            .strokeBorder(Theme.color.borderStrong, lineWidth: 1))
    }

    @ViewBuilder private var pills: some View {
        ForEach(tabs, id: \.self) { t in
            let active = selection == t
            Button { selection = t } label: {
                Text(t)
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(active ? .white : Theme.color.textDim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                    .fixedSize(horizontal: !fill, vertical: false)
                    .padding(.vertical, 7).padding(.horizontal, 12)
                    .frame(maxWidth: fill ? .infinity : nil)
                    .background(active ? Theme.color.accent : Color.clear,
                                in: RoundedRectangle(cornerRadius: Theme.radius.sm, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// v2 mono TextEditor: sits on the code surface with a rounded 1px border.
struct CodeEditorField: View {
    @Binding var text: String
    var minHeight: CGFloat? = nil

    var body: some View {
        TextEditor(text: $text)
            .font(Theme.mono(12))
            .foregroundStyle(Theme.color.text)
            .scrollContentBackground(.hidden)
            .autocorrectionDisabled().textInputAutocapitalization(.never)
            .padding(7)
            .frame(minHeight: minHeight)
            .background(Theme.color.codeBG)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                .strokeBorder(Theme.color.border, lineWidth: 1))
    }
}

/// Full on-device API client (Hoppscotch): request composer with params,
/// headers, auth, body, GraphQL, scripts and code generation, plus collections,
/// environments and history.
struct ComposeView: View {
    @EnvironmentObject var model: AppModel
    @State private var showLibrary = false
    @State private var showHistory = false
    @State private var showImportCurl = false
    @State private var showFileImporter = false

    var body: some View {
        NavigationStack {
            Group {
                if let index = model.selectedRequestIndex {
                    RequestEditor(index: index)
                } else {
                    ContentUnavailableView("No request", systemImage: "paperplane",
                                           description: Text("Create a request to get started."))
                }
            }
            .htScreenChrome("Compose") {
                HStack(spacing: 16) {
                    Button { showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                    Button { showLibrary = true } label: { Image(systemName: "folder") }
                    EnvironmentMenu()
                    Menu {
                        Button { model.newRequest() } label: { Label("New Request", systemImage: "plus") }
                        Button { model.saveRequestToCollection() } label: { Label("Save to Collection", systemImage: "tray.and.arrow.down") }
                        Divider()
                        Button { showImportCurl = true } label: { Label("Import cURL…", systemImage: "curlybraces") }
                        Button { showFileImporter = true } label: { Label("Import OpenAPI / Postman…", systemImage: "square.and.arrow.down") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $showLibrary) { LibrarySheet() }
            .sheet(isPresented: $showHistory) { HistorySheet() }
            .sheet(isPresented: $showImportCurl) { ImportCurlSheet() }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.json]) { result in
                if case .success(let url) = result { model.importCollection(from: url) }
            }
            .keyboardDismissButton()
        }
    }
}

struct EnvironmentMenu: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Menu {
            Button("No Environment") { model.activeEnvironmentID = nil; model.persistEnvironments() }
            Divider()
            ForEach(model.environments) { env in
                Button {
                    model.activeEnvironmentID = env.id; model.persistEnvironments()
                } label: {
                    if env.id == model.activeEnvironmentID { Label(env.name, systemImage: "checkmark") }
                    else { Text(env.name) }
                }
            }
            Divider()
            Button { model.addEnvironment() } label: { Label("Add Environment", systemImage: "plus") }
        } label: {
            Image(systemName: "list.bullet.rectangle")
        }
    }
}

struct RequestEditor: View {
    @EnvironmentObject var model: AppModel
    let index: Int
    @State private var tab = "Params"
    /// Height of the response pane in the draggable split. Persisted so the
    /// user's preferred request/response ratio survives navigation + launches.
    @AppStorage("iosComposeResponseHeight") private var responseHeight: Double = 320
    private let tabs = ["Params", "Headers", "Auth", "Body", "GraphQL", "Scripts", "Code"]

    var body: some View {
        let request = $model.requests[index]
        VStack(spacing: 10) {
            VStack(spacing: 9) {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(httpMethods, id: \.self) { m in
                            Button(m) { model.requests[index].method = m }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(model.requests[index].method)
                                .font(Theme.mono(12.5, .bold))
                                .foregroundStyle(Theme.methodColor(model.requests[index].method))
                            Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(Theme.color.textFaint)
                        }
                        .padding(.horizontal, 13).padding(.vertical, 10)
                        .background(Theme.methodColor(model.requests[index].method).opacity(0.13),
                                    in: RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                            .strokeBorder(Theme.methodColor(model.requests[index].method).opacity(0.30), lineWidth: 1))
                    }
                    TextField("https://api.example.com  (or paste a cURL command)", text: request.url, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(Theme.mono(11.5))
                        .foregroundStyle(Theme.color.textBright)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .htField()
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .onTapGesture {
                            model.prepareComposeURLFieldForEditing(at: index)
                        }
                        // Paste a full `curl …` command into the URL field and it
                        // is parsed into the whole request automatically.
                        .onChange(of: model.requests[index].url) { _, newValue in
                            if !model.applyCurlIfDetected(newValue, at: index) {
                                model.normalizeComposeURLIfNeeded(newValue, at: index)
                            }
                        }
                }
                Button { model.sendSelectedRequest() } label: {
                    HStack(spacing: 7) {
                        if model.isSending { ProgressView().controlSize(.small).tint(.white) }
                        Text(model.isSending ? "Sending…" : "Send").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.htPrimary)
                .disabled(model.isSending)
            }
            .padding(.horizontal)

            SegmentedPillTabs(tabs: tabs, selection: $tab, fill: false)
                .padding(.horizontal)

            if let response = model.responsesByRequest[model.requests[index].id] {
                // Request fields on top, response below, with a draggable divider
                // so either pane can be resized. Each pane scrolls independently.
                GeometryReader { geo in
                    let minPane: CGFloat = 96
                    let total = geo.size.height
                    let respH = min(max(CGFloat(responseHeight), minPane), max(minPane, total - minPane))
                    VStack(spacing: 0) {
                        tabContent(request: request)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        ResponseSplitHandle(height: $responseHeight, total: total, minPane: minPane)
                        ResponseView(response: response,
                                     scriptOutput: model.scriptOutputs[model.requests[index].id])
                            .frame(maxWidth: .infinity)
                            .frame(height: respH)
                    }
                }
            } else {
                tabContent(request: request)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.vertical, 8)
        .background(Theme.appBackground)
    }

    @ViewBuilder
    private func tabContent(request: Binding<APIRequest>) -> some View {
        switch tab {
        case "Headers":
            ScrollView { KeyValueEditor(items: request.headers, addNoun: "header").padding() }
        case "Auth":
            AuthEditor(auth: request.auth)
        case "Body":
            BodyEditor(request: request)
        case "GraphQL":
            GraphQLEditor(request: request)
        case "Scripts":
            ScriptsEditor(request: request)
        case "Code":
            CodePanel()
        default:
            ScrollView { KeyValueEditor(items: request.queryParams, addNoun: "parameter").padding() }
        }
    }
}

/// Draggable grab-bar between the request fields and the response pane. Drag up
/// to grow the response, down to shrink it; the height is clamped so neither
/// pane collapses below `minPane`.
private struct ResponseSplitHandle: View {
    @Binding var height: Double
    let total: CGFloat
    let minPane: CGFloat
    @State private var dragBase: Double?

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.color.panelBG)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Theme.color.borderStrong)
                .frame(width: 38, height: 4)
        }
        .frame(maxWidth: .infinity).frame(height: 22)
        .overlay(alignment: .top) { Rectangle().fill(Theme.color.hairline).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.color.hairline).frame(height: 1) }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let base = dragBase ?? height
                    if dragBase == nil { dragBase = height }
                    let maxH = Double(max(minPane, total - minPane))
                    height = min(max(base - Double(value.translation.height), Double(minPane)), maxH)
                }
                .onEnded { _ in dragBase = nil }
        )
    }
}

struct BodyEditor: View {
    @Binding var request: APIRequest
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Body", selection: $request.bodyMode) {
                    ForEach(RequestBodyMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .tint(Theme.color.accent)
                bodyContent
            }
            .padding(.horizontal)
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
            HStack(spacing: 8) {
                JSONStatusBar(text: request.rawBody)
                Spacer()
                Button("Format") {
                    if let pretty = JSONValidation.prettyPrinted(request.rawBody) { request.rawBody = pretty }
                }
                .font(.system(size: 12, weight: .medium))
                .tint(Theme.color.accent)
            }
            CodeEditorField(text: $request.rawBody, minHeight: 160)
        case .graphql:
            Text("GraphQL body — edit the query and variables in the GraphQL tab.")
                .font(.caption).foregroundStyle(Theme.color.textDim)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .raw:
            CodeEditorField(text: $request.rawBody, minHeight: 160)
        }
    }
}

struct GraphQLEditor: View {
    @Binding var request: APIRequest
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                HTEyebrow("QUERY")
                CodeEditorField(text: $request.graphqlQuery, minHeight: 120)
                HStack(spacing: 8) {
                    HTEyebrow("VARIABLES (JSON)")
                    Spacer()
                    JSONStatusBar(text: request.graphqlVariables)
                    Button("Format") {
                        if let pretty = JSONValidation.prettyPrinted(request.graphqlVariables) { request.graphqlVariables = pretty }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .tint(Theme.color.accent)
                }
                CodeEditorField(text: $request.graphqlVariables, minHeight: 80)
                Button("Use GraphQL body mode") { request.bodyMode = .graphql }
                    .font(.caption)
                    .tint(Theme.color.accent)
            }
            .padding()
        }
    }
}

struct ScriptsEditor: View {
    @Binding var request: APIRequest
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                HTEyebrow("PRE-REQUEST SCRIPT (JAVASCRIPT)")
                Text("e.g. pm.environment.set(\"token\", \"…\")")
                    .font(.caption2).foregroundStyle(Theme.color.textMuted)
                CodeEditorField(text: $request.preRequestScript, minHeight: 90)
                HTEyebrow("TEST SCRIPT")
                Text("e.g. pm.test(\"ok\", () => pm.expect(pm.response.code).to.equal(200))")
                    .font(.caption2).foregroundStyle(Theme.color.textMuted)
                CodeEditorField(text: $request.testScript, minHeight: 90)
            }
            .padding()
        }
    }
}

struct CodePanel: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Target", selection: $model.codeTarget) {
                ForEach(CodeGenerator.Target.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .tint(Theme.color.accent)
            .padding(.horizontal)
            CodeViewer(text: model.generatedCode())
        }
    }
}

struct AuthEditor: View {
    @Binding var auth: AuthConfig
    var body: some View {
        Form {
            Picker("Type", selection: $auth.type) {
                ForEach(AuthType.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            switch auth.type {
            case .none:
                Text("No authorization").foregroundStyle(Theme.color.textMuted)
            case .bearer:
                TextField("Token", text: $auth.token)
                    .font(Theme.mono(12.5))
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
            case .basic:
                TextField("Username", text: $auth.username)
                    .font(Theme.mono(12.5))
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                SecureField("Password", text: $auth.password)
                    .font(Theme.mono(12.5))
            case .apiKey:
                TextField("Key", text: $auth.key)
                    .font(Theme.mono(12.5))
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                TextField("Value", text: $auth.value)
                    .font(Theme.mono(12.5))
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                Toggle("Add to header (off = query param)", isOn: $auth.addToHeader)
                    .tint(Theme.color.accent)
            }
        }
        .scrollContentBackground(.hidden)
    }
}

struct ResponseView: View {
    let response: APIResponse
    var scriptOutput: ScriptOutput?
    @State private var section = "Body"

    private var contentType: String? {
        response.headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
    }
    private var sections: [String] {
        var base = ["Body", "Headers"]
        if let raw = response.rawRequestHeader, !raw.isEmpty { base.append("Request") }
        base.append("Preview")
        if let s = scriptOutput, !s.tests.isEmpty || !s.logs.isEmpty { base.append("Tests") }
        return base
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if response.error == nil {
                    Text("\(response.statusCode)")
                        .font(Theme.mono(16, .bold))
                        .foregroundStyle(UIFormat.statusColor(response.statusCode))
                } else {
                    StatusIndicator(state: .error)
                }
                Text("\(response.durationMS) ms").font(Theme.mono(12)).foregroundStyle(Theme.color.textDim)
                Text(UIFormat.byteSize(response.body.count)).font(Theme.mono(12)).foregroundStyle(Theme.color.textDim)
                if let ct = contentType, !ct.isEmpty {
                    Text(ct.split(separator: ";").first.map(String.init) ?? ct)
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.color.textSoft)
                        .lineLimit(1)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Theme.color.fill, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.color.border, lineWidth: 1))
                }
                if let count = scriptOutput?.tests.count, count > 0 {
                    let passed = scriptOutput?.tests.filter { $0.passed }.count ?? 0
                    Label("\(passed)/\(count)", systemImage: passed == count ? "checkmark.seal" : "xmark.seal")
                        .font(.system(size: 12)).foregroundStyle(passed == count ? Theme.color.green : Theme.color.amber)
                }
                Spacer()
                Label("decrypted", systemImage: "lock.fill")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.color.codeKey)
            }
            .padding(.horizontal).padding(.vertical, 9)
            if let err = response.error {
                Text(err).font(.caption).foregroundStyle(Theme.color.red).padding(.horizontal).padding(.bottom, 4)
            }
            SegmentedPillTabs(tabs: sections, selection: $section, fill: false)
                .padding(.horizontal).padding(.bottom, 6)

            switch section {
            case "Headers":
                HeaderTable(headers: response.headers)
            case "Request":
                RawRequestViewer(text: response.rawRequestHeader ?? "")
            case "Preview":
                Group {
                    if (contentType ?? "").lowercased().contains("html"),
                       let html = String(data: response.body, encoding: .utf8) {
                        WebPreview(html: html)
                    } else if ImageSniffer.isImage(data: response.body, contentType: contentType) {
                        ImagePreview(data: response.body, contentType: contentType)
                    } else {
                        ContentUnavailableView("No preview", systemImage: "eye.slash")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            case "Tests":
                TestResultsView(output: scriptOutput ?? ScriptOutput())
            default:
                BodyViewer(data: response.body, contentType: contentType)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.color.responseBG)
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
                            .foregroundStyle(test.passed ? Theme.color.green : Theme.color.red)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(test.name).font(.system(size: 13)).foregroundStyle(Theme.color.text)
                            if let message = test.message, !test.passed {
                                Text(message).font(.caption).foregroundStyle(Theme.color.red)
                            }
                        }
                    }
                }
                if !output.logs.isEmpty {
                    Rectangle().fill(Theme.color.hairline).frame(height: 1).padding(.vertical, 4)
                    HTEyebrow("CONSOLE")
                    ForEach(Array(output.logs.enumerated()), id: \.offset) { _, line in
                        Text(line).font(Theme.mono(11)).foregroundStyle(Theme.color.textSoft)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding()
        }
    }
}

/// Requests + Collections + History browser, presented as a sheet on iOS.
struct LibrarySheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("composeOpenExpanded") private var openExpanded = true
    @AppStorage("composeCollectionsExpanded") private var collectionsExpanded = true
    @AppStorage("composeHistoryExpanded") private var historyExpanded = true

    var body: some View {
        NavigationStack {
            List {
                Section("Open Requests", isExpanded: $openExpanded) {
                    ForEach(model.requests) { request in
                        Button {
                            model.selectedRequestID = request.id; dismiss()
                        } label: {
                            HStack(spacing: 8) {
                                MethodBadge(method: request.method)
                                Text(AppModel.composeRequestTitle(for: request)).lineLimit(1)
                            }
                        }
                    }
                }
                if !model.collections.isEmpty {
                    Section("Collections", isExpanded: $collectionsExpanded) {
                        ForEach(model.collections) { collection in
                            CollectionOutline(collection: collection) { dismiss() }
                        }
                    }
                }
                if !model.history.isEmpty {
                    Section("History", isExpanded: $historyExpanded) {
                        ForEach(model.history.prefix(30)) { entry in
                            Button {
                                model.loadHistory(entry); dismiss()
                            } label: {
                                HStack(spacing: 8) {
                                    MethodBadge(method: entry.request.method)
                                    Text(AppModel.composeHistoryTitle(for: entry)).lineLimit(1).font(Theme.mono(11))
                                    Spacer()
                                    Text("\(entry.statusCode)").font(Theme.mono(10.5))
                                        .foregroundStyle(UIFormat.statusColor(entry.statusCode))
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { model.newRequest(); dismiss() } label: { Label("New", systemImage: "plus") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear History") { model.clearHistory() }.disabled(model.history.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// Dedicated history screen: every past send, each row reopenable (View) or
/// repeatable (Send again).
struct HistorySheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.history.isEmpty {
                    ContentUnavailableView("No history", systemImage: "clock.arrow.circlepath",
                                           description: Text("Requests you send appear here."))
                } else {
                    List {
                        ForEach(model.history.prefix(50)) { entry in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    MethodBadge(method: entry.request.method)
                                    Text(AppModel.composeHistoryTitle(for: entry))
                                        .font(Theme.mono(11.5)).foregroundStyle(Theme.color.text)
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 6)
                                    Text("\(entry.statusCode)")
                                        .font(Theme.mono(11, .bold))
                                        .foregroundStyle(UIFormat.statusColor(entry.statusCode))
                                }
                                HStack(spacing: 8) {
                                    Text(entry.timestamp, format: .relative(presentation: .named))
                                        .font(.caption2).foregroundStyle(Theme.color.textMuted)
                                    Spacer()
                                    Button { model.loadHistory(entry); dismiss() } label: {
                                        Label("View", systemImage: "eye")
                                    }
                                    .buttonStyle(.bordered).controlSize(.small).tint(Theme.color.accent)
                                    Button {
                                        model.loadHistory(entry); model.sendSelectedRequest(); dismiss()
                                    } label: {
                                        Label("Send again", systemImage: "arrow.clockwise")
                                    }
                                    .buttonStyle(.borderedProminent).controlSize(.small).tint(Theme.color.accent)
                                }
                            }
                            .padding(.vertical, 4)
                            .listRowBackground(Theme.color.panelBG)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.appBackground)
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") { model.clearHistory() }.disabled(model.history.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

struct CollectionOutline: View {
    @EnvironmentObject var model: AppModel
    let collection: RequestCollection
    var onPick: () -> Void
    var body: some View {
        DisclosureGroup {
            ForEach(collection.folders) { folder in
                CollectionOutline(collection: folder, onPick: onPick)
            }
            ForEach(collection.requests) { request in
                Button {
                    model.loadRequest(request); onPick()
                } label: {
                    HStack(spacing: 8) {
                        MethodBadge(method: request.method)
                        Text(AppModel.composeRequestTitle(for: request)).lineLimit(1)
                    }
                }
            }
        } label: {
            Label(collection.name, systemImage: "folder").font(.system(size: 13, weight: .medium))
        }
    }
}

struct ImportCurlSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("Paste a cURL command to turn it into a request.")
                    .font(.caption).foregroundStyle(Theme.color.textMuted)
                CodeEditorField(text: $model.importCurlText)
            }
            .padding()
            .background(Theme.appBackground)
            .navigationTitle("Import cURL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { model.importCurl(); dismiss() }
                        .disabled(model.importCurlText.isEmpty)
                }
            }
            .keyboardDismissButton()
        }
    }
}
