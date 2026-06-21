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
                Button { model.newRequest() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
            }
            .padding(8)
            Divider()
            List(selection: $model.selectedRequestID) {
                ForEach(model.requests) { request in
                    HStack(spacing: 8) {
                        MethodBadge(method: request.method)
                        Text(request.name.isEmpty ? request.url : request.name)
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
        let requestBinding = $model.requests[index]
        let request = model.requests[index]

        VSplitView {
            VStack(spacing: 10) {
                HStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Menu {
                            ForEach(Self.methods, id: \.self) { m in
                                Button(m) { model.requests[index].method = m }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Text(request.method)
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Theme.methodColor(request.method))
                                Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(Theme.color.textFaint)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(Theme.methodColor(request.method).opacity(0.12))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()

                        Rectangle().fill(Theme.color.border).frame(width: 1, height: 22)

                        TextField("https://api.example.com/endpoint", text: requestBinding.url)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(Theme.color.text)
                            .padding(.horizontal, 12)
                    }
                    .background(Theme.color.panelBG)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                        .strokeBorder(Theme.color.borderStrong, lineWidth: 1))

                    Button {
                        model.sendSelectedRequest()
                    } label: {
                        HStack(spacing: 7) {
                            if model.isSending {
                                ProgressView().controlSize(.small).tint(.white)
                            }
                            Text(model.isSending ? "Sending…" : "Send")
                        }
                    }
                    .buttonStyle(.htPrimary)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.isSending)
                    .padding(.leading, 6)

                    Menu {
                        Button("Save to Collection") { model.saveRequestToCollection() }
                        Button("Duplicate") { model.loadRequest(model.requests[index]) }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .frame(width: 40)
                }
                RequestConfigTabs(request: requestBinding)
            }
            .padding(12)
            .frame(minHeight: 170)

            ResponseView(response: model.responsesByRequest[request.id],
                         scriptOutput: model.scriptOutputs[request.id])
                .frame(minHeight: 220)
        }
    }
}

struct RequestConfigTabs: View {
    @EnvironmentObject var model: AppModel
    @Binding var request: APIRequest
    @State private var tab = "Params"
    private let tabs = ["Params", "Headers", "Auth", "Body", "GraphQL", "Scripts", "Code"]

    var body: some View {
        VStack(spacing: 6) {
            Picker("", selection: $tab) {
                ForEach(tabs, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch tab {
            case "Params":
                ScrollView { KeyValueEditor(items: $request.queryParams).padding(4) }
            case "Headers":
                ScrollView { KeyValueEditor(items: $request.headers).padding(4) }
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
    }

    private var bodyEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Body", selection: $request.bodyMode) {
                ForEach(RequestBodyMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .frame(width: 220)

            if request.bodyMode == .none {
                ContentUnavailableView("No body", systemImage: "doc")
            } else {
                TextEditor(text: $request.rawBody)
                    .font(.system(size: 12, design: .monospaced))
                    .border(Color(nsColor: .separatorColor))
            }
        }
    }

    private var graphqlEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Query").font(.caption.bold())
            TextEditor(text: $request.graphqlQuery)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 120)
                .border(Color(nsColor: .separatorColor))
            Text("Variables (JSON)").font(.caption.bold())
            TextEditor(text: $request.graphqlVariables)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 60)
                .border(Color(nsColor: .separatorColor))
            Button("Use GraphQL body mode") { request.bodyMode = .graphql }
                .font(.caption)
        }
    }

    private var scriptsEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Pre-request Script (JavaScript)").font(.caption.bold())
            Text("e.g. pm.environment.set(\"token\", \"…\")")
                .font(.caption2).foregroundStyle(.secondary)
            TextEditor(text: $request.preRequestScript)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 90).border(Color(nsColor: .separatorColor))
            Text("Test Script").font(.caption.bold())
            Text("e.g. pm.test(\"ok\", () => pm.expect(pm.response.code).to.equal(200))")
                .font(.caption2).foregroundStyle(.secondary)
            TextEditor(text: $request.testScript)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 90).border(Color(nsColor: .separatorColor))
        }
    }

    private var codePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Target", selection: $model.codeTarget) {
                ForEach(CodeGenerator.Target.allCases) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 260)
            CodeViewer(text: model.generatedCode())
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
                            Text(test.name).font(.system(size: 12))
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
            .padding(10)
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
                TextField("Token", text: $auth.token)
            case .basic:
                TextField("Username", text: $auth.username)
                SecureField("Password", text: $auth.password)
            case .apiKey:
                TextField("Key", text: $auth.key)
                TextField("Value", text: $auth.value)
                Toggle("Add to header (off = query param)", isOn: $auth.addToHeader)
            }
        }
        .formStyle(.grouped)
    }
}

struct ResponseView: View {
    let response: APIResponse?
    var scriptOutput: ScriptOutput?
    @State private var section = "Body"

    private var sections: [String] {
        var base = ["Body", "Headers", "Preview"]
        if let scriptOutput, !scriptOutput.tests.isEmpty || !scriptOutput.logs.isEmpty { base.append("Tests") }
        return base
    }

    var body: some View {
        if let response {
            let contentType = response.headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    if response.error == nil {
                        Text("\(response.statusCode)")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(UIFormat.statusColor(response.statusCode))
                    } else {
                        StatusIndicator(state: .error)
                    }
                    Text("\(response.durationMS) ms").foregroundStyle(Theme.color.textDim)
                        .font(.system(size: 12, design: .monospaced))
                    Text(UIFormat.byteSize(response.body.count)).foregroundStyle(Theme.color.textDim)
                        .font(.system(size: 12, design: .monospaced))
                    if let ct = contentType?.split(separator: ";").first.map(String.init) {
                        Text(ct)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.color.codeKey)
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background(Theme.color.codeKey.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    }
                    if let count = scriptOutput?.tests.count, count > 0 {
                        let passed = scriptOutput?.tests.filter { $0.passed }.count ?? 0
                        Label("\(passed)/\(count)", systemImage: passed == count ? "checkmark.seal" : "xmark.seal")
                            .font(.system(size: 12)).foregroundStyle(passed == count ? Theme.color.green : Theme.color.amber)
                    }
                    if let err = response.error {
                        Text(err).foregroundStyle(Theme.color.red).font(.system(size: 12)).lineLimit(1)
                    }
                    Spacer()
                    Label("decrypted", systemImage: "lock.fill")
                        .font(.system(size: 12)).foregroundStyle(Theme.color.green)
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                Picker("", selection: $section) {
                    ForEach(sections, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 12).padding(.bottom, 8)
                Divider().overlay(Theme.color.hairline)
                if section == "Tests" {
                    TestResultsView(output: scriptOutput ?? ScriptOutput())
                } else {
                    content(response)
                }
            }
        } else {
            ContentUnavailableView("Send a request to see the response", systemImage: "tray.and.arrow.down")
        }
    }

    @ViewBuilder
    private func content(_ response: APIResponse) -> some View {
        let contentType = response.headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
        switch section {
        case "Headers":
            HeaderTable(headers: response.headers)
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
}
