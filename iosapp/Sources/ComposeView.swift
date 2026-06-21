import SwiftUI
import UniformTypeIdentifiers
import HTTrailCore

private let httpMethods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

/// Full on-device API client (Hoppscotch): request composer with params,
/// headers, auth, body, GraphQL, scripts and code generation, plus collections,
/// environments and history.
struct ComposeView: View {
    @EnvironmentObject var model: AppModel
    @State private var showLibrary = false
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
            .navigationTitle("Compose")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showLibrary = true } label: { Image(systemName: "folder") }
                }
                ToolbarItem(placement: .topBarTrailing) { EnvironmentMenu() }
                ToolbarItem(placement: .topBarTrailing) {
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
    private let tabs = ["Params", "Headers", "Auth", "Body", "GraphQL", "Scripts", "Code"]

    var body: some View {
        let request = $model.requests[index]
        VStack(spacing: 10) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(httpMethods, id: \.self) { m in
                            Button(m) { model.requests[index].method = m }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(model.requests[index].method)
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(Theme.methodColor(model.requests[index].method))
                            Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(Theme.color.textFaint)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(Theme.methodColor(model.requests[index].method).opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: Theme.radius.md))
                    }
                    TextField("https://api.example.com  (or paste a cURL command)", text: request.url, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, design: .monospaced))
                        .padding(.horizontal, 11).padding(.vertical, 9)
                        .htField()
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        // Paste a full `curl …` command into the URL field and it
                        // is parsed into the whole request automatically.
                        .onChange(of: model.requests[index].url) { _, newValue in
                            model.applyCurlIfDetected(newValue, at: index)
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

            Picker("", selection: $tab) {
                ForEach(tabs, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            tabContent(request: request)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let response = model.responsesByRequest[model.requests[index].id] {
                Divider().overlay(Theme.color.hairline)
                ResponseView(response: response,
                             scriptOutput: model.scriptOutputs[model.requests[index].id])
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
            ScrollView { KeyValueEditor(items: request.headers).padding() }
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
            ScrollView { KeyValueEditor(items: request.queryParams).padding() }
        }
    }
}

struct BodyEditor: View {
    @Binding var request: APIRequest
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Body", selection: $request.bodyMode) {
                ForEach(RequestBodyMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            if request.bodyMode == .none {
                ContentUnavailableView("No body", systemImage: "doc")
            } else {
                TextEditor(text: $request.rawBody)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .border(Color.hairline)
            }
        }
        .padding(.horizontal)
    }
}

struct GraphQLEditor: View {
    @Binding var request: APIRequest
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("Query").font(.caption.bold())
                TextEditor(text: $request.graphqlQuery)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 120).border(Color.hairline)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                Text("Variables (JSON)").font(.caption.bold())
                TextEditor(text: $request.graphqlVariables)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 80).border(Color.hairline)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                Button("Use GraphQL body mode") { request.bodyMode = .graphql }.font(.caption)
            }
            .padding()
        }
    }
}

struct ScriptsEditor: View {
    @Binding var request: APIRequest
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pre-request Script (JavaScript)").font(.caption.bold())
                Text("e.g. pm.environment.set(\"token\", \"…\")")
                    .font(.caption2).foregroundStyle(.secondary)
                TextEditor(text: $request.preRequestScript)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 90).border(Color.hairline)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                Text("Test Script").font(.caption.bold())
                Text("e.g. pm.test(\"ok\", () => pm.expect(pm.response.code).to.equal(200))")
                    .font(.caption2).foregroundStyle(.secondary)
                TextEditor(text: $request.testScript)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 90).border(Color.hairline)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
            }
            .padding()
        }
    }
}

struct CodePanel: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Target", selection: $model.codeTarget) {
                ForEach(CodeGenerator.Target.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu).padding(.horizontal)
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
                Text("No authorization").foregroundStyle(.secondary)
            case .bearer:
                TextField("Token", text: $auth.token).autocorrectionDisabled().textInputAutocapitalization(.never)
            case .basic:
                TextField("Username", text: $auth.username).autocorrectionDisabled().textInputAutocapitalization(.never)
                SecureField("Password", text: $auth.password)
            case .apiKey:
                TextField("Key", text: $auth.key).autocorrectionDisabled().textInputAutocapitalization(.never)
                TextField("Value", text: $auth.value).autocorrectionDisabled().textInputAutocapitalization(.never)
                Toggle("Add to header (off = query param)", isOn: $auth.addToHeader)
            }
        }
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
        var base = ["Body", "Headers", "Preview"]
        if let s = scriptOutput, !s.tests.isEmpty || !s.logs.isEmpty { base.append("Tests") }
        return base
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if response.error == nil {
                    Text("\(response.statusCode)")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(UIFormat.statusColor(response.statusCode))
                } else {
                    StatusIndicator(state: .error)
                }
                Text("\(response.durationMS) ms").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.color.textDim)
                Text(UIFormat.byteSize(response.body.count)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.color.textDim)
                if let count = scriptOutput?.tests.count, count > 0 {
                    let passed = scriptOutput?.tests.filter { $0.passed }.count ?? 0
                    Label("\(passed)/\(count)", systemImage: passed == count ? "checkmark.seal" : "xmark.seal")
                        .font(.system(size: 12)).foregroundStyle(passed == count ? Theme.color.green : Theme.color.amber)
                }
                Spacer()
                Label("decrypted", systemImage: "lock.fill")
                    .font(.system(size: 11)).foregroundStyle(Theme.color.green)
            }
            .padding(.horizontal).padding(.vertical, 8)
            if let err = response.error {
                Text(err).font(.caption).foregroundStyle(Theme.color.red).padding(.horizontal)
            }
            Picker("", selection: $section) {
                ForEach(sections, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented).padding(.horizontal).padding(.bottom, 6)

            switch section {
            case "Headers":
                HeaderTable(headers: response.headers)
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
                            Text(test.name).font(.system(size: 13))
                            if let message = test.message, !test.passed {
                                Text(message).font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                }
                if !output.logs.isEmpty {
                    Divider().padding(.vertical, 4)
                    Text("Console").font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(Array(output.logs.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 11, design: .monospaced))
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
    var body: some View {
        NavigationStack {
            List {
                Section("Open Requests") {
                    ForEach(model.requests) { request in
                        Button {
                            model.selectedRequestID = request.id; dismiss()
                        } label: {
                            HStack(spacing: 8) {
                                MethodBadge(method: request.method)
                                Text(request.name.isEmpty ? request.url : request.name).lineLimit(1)
                            }
                        }
                    }
                }
                if !model.collections.isEmpty {
                    Section("Collections") {
                        ForEach(model.collections) { collection in
                            CollectionOutline(collection: collection) { dismiss() }
                        }
                    }
                }
                if !model.history.isEmpty {
                    Section("History") {
                        ForEach(model.history.prefix(30)) { entry in
                            Button {
                                model.loadRequest(entry.request); dismiss()
                            } label: {
                                HStack(spacing: 8) {
                                    MethodBadge(method: entry.request.method)
                                    Text(entry.request.url).lineLimit(1).font(.caption)
                                    Spacer()
                                    Text("\(entry.statusCode)").font(.caption2)
                                        .foregroundStyle(UIFormat.statusColor(entry.statusCode))
                                }
                            }
                        }
                    }
                }
            }
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
                        Text(request.name.isEmpty ? request.url : request.name).lineLimit(1)
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
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $model.importCurlText)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .border(Color.hairline)
            }
            .padding()
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
