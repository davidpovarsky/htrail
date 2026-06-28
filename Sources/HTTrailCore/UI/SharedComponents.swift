import SwiftUI
import Foundation
import UniformTypeIdentifiers

/// Cross-platform formatting + small reusable SwiftUI components shared by the
/// macOS and iOS apps so both render identically. Styling follows the HTTrail
/// design system (see Theme.swift).
public enum UIFormat {
    /// HTTP method color (delegates to the design palette).
    public static func methodColor(_ method: String) -> Color { Theme.methodColor(method) }

    /// HTTP status-class color (delegates to the design palette).
    public static func statusColor(_ code: Int?) -> Color { Theme.statusColor(code) }

    public static func prettyBody(_ data: Data, contentType: String?) -> String {
        if let ct = contentType?.lowercased(), ct.contains("json"),
           let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: object,
                                                    options: [.prettyPrinted, .sortedKeys]),
           let string = String(data: pretty, encoding: .utf8) {
            return string
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        return "<\(data.count) bytes of binary data>"
    }

    public static func byteSize(_ count: Int) -> String {
        if count < 1024 { return "\(count) B" }
        if count < 1024 * 1024 { return String(format: "%.1f KB", Double(count) / 1024) }
        return String(format: "%.1f MB", Double(count) / (1024 * 1024))
    }
}

extension Color {
    /// Background for monospaced code/text viewers — the design's code surface.
    public static var codeBackground: Color { Theme.color.codeBG }
    /// Hairline separator colour.
    public static var hairline: Color { Theme.color.hairline }
}

// MARK: - Syntax highlighting

/// Lightweight JSON / XML syntax highlighter producing an `AttributedString`
/// with the design's code colors (cyan keys, green strings, amber numbers,
/// violet bool/null). Mirrors the design canvas' `hlJson` / `hlXml`.
public enum SyntaxHighlighter {
    public static func highlight(_ text: String, contentType: String?) -> AttributedString {
        let ct = (contentType ?? "").lowercased()
        if ct.contains("json") || looksLikeJSON(text) { return json(text) }
        if ct.contains("xml") || ct.contains("html") || looksLikeXML(text) { return xml(text) }
        var plain = AttributedString(text)
        plain.foregroundColor = Theme.color.codeText
        return plain
    }

    private static func looksLikeJSON(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("{") || t.hasPrefix("[")
    }
    private static func looksLikeXML(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<")
    }

    public static func json(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        out.foregroundColor = Theme.color.codeText
        // strings (optionally a key when followed by a colon), bool/null, numbers
        let pattern = #""(?:\\.|[^"\\])*"(?:\s*:)?|\b(?:true|false|null)\b|-?\d+(?:\.\d+)?(?:[eE][+\-]?\d+)?"#
        apply(regex: pattern, to: &out, in: text) { match in
            if match.hasPrefix("\"") {
                return match.hasSuffix(":") || match.reversed().drop(while: { $0 == " " }).first == ":"
                    ? Theme.color.codeKey : Theme.color.codeString
            }
            if match == "true" || match == "false" || match == "null" { return Theme.color.codeBool }
            return Theme.color.codeNumber
        }
        return out
    }

    public static func xml(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        out.foregroundColor = Theme.color.codeText
        apply(regex: #"</?([\w:.-]+)"#, to: &out, in: text) { _ in Theme.color.codeKey }
        apply(regex: #"="(?:[^"]*)""#, to: &out, in: text) { _ in Theme.color.codeString }
        return out
    }

    private static func apply(regex pattern: String,
                              to attr: inout AttributedString,
                              in source: String,
                              color: (String) -> Color) {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return }
        let ns = source as NSString
        for m in re.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            let token = ns.substring(with: m.range)
            guard let lo = AttributedString.Index(String.Index(utf16Offset: m.range.location, in: source), within: attr),
                  let hi = AttributedString.Index(String.Index(utf16Offset: m.range.location + m.range.length, in: source), within: attr)
            else { continue }
            attr[lo..<hi].foregroundColor = color(token)
        }
    }
}

// MARK: - Method badge

/// Small coloured pill used for HTTP methods.
public struct MethodBadge: View {
    let method: String
    public init(method: String) { self.method = method }
    public var body: some View {
        Text(method.uppercased())
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .tracking(-0.2)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Theme.methodColor(method).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: Theme.radius.sm))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius.sm)
                .strokeBorder(Theme.methodColor(method).opacity(0.32), lineWidth: 1))
            .foregroundStyle(Theme.methodColor(method))
    }
}

// MARK: - Key/Value editor

/// Editable list of enabled key/value rows (query params, headers), styled with
/// the design's checkbox toggles + monospaced fields.
public struct KeyValueEditor: View {
    @Binding var items: [KeyValueItem]
    var keyPlaceholder: String
    var valuePlaceholder: String
    var addNoun: String

    public init(items: Binding<[KeyValueItem]>, keyPlaceholder: String = "key",
                valuePlaceholder: String = "value", addNoun: String = "row") {
        self._items = items
        self.keyPlaceholder = keyPlaceholder
        self.valuePlaceholder = valuePlaceholder
        self.addNoun = addNoun
    }

    public var body: some View {
        VStack(spacing: 0) {
            ForEach($items) { $item in
                HStack(spacing: 9) {
                    Button {
                        item.enabled.toggle()
                    } label: {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(item.enabled ? Theme.color.accent : .clear)
                            .frame(width: 16, height: 16)
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(item.enabled ? Theme.color.accent : Theme.color.textMuted, lineWidth: 1.5))
                            .overlay(Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .opacity(item.enabled ? 1 : 0))
                    }
                    .buttonStyle(.plain)

                    TextField(keyPlaceholder, text: $item.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(item.enabled ? Theme.color.codeKey : Theme.color.textFaint)

                    TextField(valuePlaceholder, text: $item.value)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(item.enabled ? Theme.color.textSoft : Theme.color.textFaint)

                    Button {
                        items.removeAll { $0.id == item.id }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.color.textFaint)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Theme.color.rowBG)
                Divider().overlay(Theme.color.hairline)
            }
            Button {
                items.append(KeyValueItem())
            } label: {
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color(hex: "#4A4C70"),
                                      style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                        .frame(width: 15, height: 15)
                    Text("Add \(addNoun)…")
                    Spacer()
                }
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.color.textFaint)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Theme.color.rowBG)
            }
            .buttonStyle(.plain)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
            .strokeBorder(Theme.color.border, lineWidth: 1))
    }
}

// MARK: - Form body editor

/// Key/value editor for structured request bodies, shared by macOS + iOS so both
/// render identically. `allowFiles` (multipart) adds a per-row Text/File toggle
/// and a file picker; without it (form-urlencoded) rows are plain key/value.
public struct FormFieldEditor: View {
    @Binding var fields: [BodyField]
    var allowFiles: Bool
    @SwiftUI.State private var importingFieldID: UUID?

    public init(fields: Binding<[BodyField]>, allowFiles: Bool = false) {
        self._fields = fields
        self.allowFiles = allowFiles
    }

    public var body: some View {
        VStack(spacing: 0) {
            ForEach($fields) { $field in
                row($field)
                Divider().overlay(Theme.color.hairline)
            }
            addButton
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
            .strokeBorder(Theme.color.border, lineWidth: 1))
        .fileImporter(isPresented: Binding(get: { importingFieldID != nil },
                                           set: { if !$0 { importingFieldID = nil } }),
                      allowedContentTypes: [.data]) { result in
            defer { importingFieldID = nil }
            guard case .success(let url) = result, let id = importingFieldID,
                  let idx = fields.firstIndex(where: { $0.id == id }) else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            fields[idx].fileData = data
            fields[idx].fileName = url.lastPathComponent
            if fields[idx].name.isEmpty { fields[idx].name = "file" }
        }
    }

    @ViewBuilder
    private func row(_ field: Binding<BodyField>) -> some View {
        let f = field.wrappedValue
        HStack(spacing: 9) {
            checkbox(field)
            TextField("field name", text: field.name)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(f.enabled ? Theme.color.codeKey : Theme.color.textFaint)

            if allowFiles && f.isFile {
                fileButton(field)
            } else {
                TextField("value", text: field.value)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(f.enabled ? Theme.color.textSoft : Theme.color.textFaint)
            }

            if allowFiles { typeToggle(field) }

            Button {
                fields.removeAll { $0.id == f.id }
            } label: {
                Image(systemName: "xmark").font(.system(size: 11)).foregroundStyle(Theme.color.textFaint)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.color.rowBG)
    }

    private func checkbox(_ field: Binding<BodyField>) -> some View {
        Button { field.wrappedValue.enabled.toggle() } label: {
            let on = field.wrappedValue.enabled
            RoundedRectangle(cornerRadius: 4)
                .fill(on ? Theme.color.accent : .clear)
                .frame(width: 16, height: 16)
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(on ? Theme.color.accent : Theme.color.textMuted, lineWidth: 1.5))
                .overlay(Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .opacity(on ? 1 : 0))
        }
        .buttonStyle(.plain)
    }

    private func typeToggle(_ field: Binding<BodyField>) -> some View {
        Button {
            field.wrappedValue.isFile.toggle()
            if !field.wrappedValue.isFile {
                field.wrappedValue.fileData = nil
                field.wrappedValue.fileName = ""
            }
        } label: {
            Image(systemName: field.wrappedValue.isFile ? "doc.fill" : "textformat")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(field.wrappedValue.isFile ? Theme.color.accent : Theme.color.textMuted)
                .frame(width: 22, height: 22)
                .background(Theme.color.fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(field.wrappedValue.isFile ? "File field — tap to switch to text" : "Text field — tap to attach a file")
    }

    private func fileButton(_ field: Binding<BodyField>) -> some View {
        let f = field.wrappedValue
        return Button { importingFieldID = f.id } label: {
            HStack(spacing: 6) {
                Image(systemName: "paperclip").font(.system(size: 10))
                Text(f.fileName.isEmpty ? "Choose File…" : f.fileName)
                    .lineLimit(1).truncationMode(.middle)
                if let data = f.fileData {
                    Text(UIFormat.byteSize(data.count)).foregroundStyle(Theme.color.textFaint)
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(f.fileName.isEmpty ? Theme.color.accent : Theme.color.textSoft)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private var addButton: some View {
        Button {
            fields.append(BodyField())
        } label: {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color(hex: "#4A4C70"), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                    .frame(width: 15, height: 15)
                Text(allowFiles ? "Add field…" : "Add parameter…")
                Spacer()
            }
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Theme.color.textFaint)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Theme.color.rowBG)
        }
        .buttonStyle(.plain)
    }
}

/// Inline validity indicator for a JSON text field (body or GraphQL variables):
/// green when valid, red with the parser message when not, nothing when empty.
public struct JSONStatusBar: View {
    let text: String
    public init(text: String) { self.text = text }
    public var body: some View {
        switch JSONValidation.check(text) {
        case .empty:
            EmptyView()
        case .valid:
            Label("Valid JSON", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.color.green)
        case .invalid(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.color.red)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Code viewer

/// Read-only monospaced text viewer with horizontal + vertical scrolling,
/// JSON/XML syntax highlighting and a line-number gutter.
public struct CodeViewer: View {
    let text: String
    let contentType: String?
    let showLineNumbers: Bool
    public init(text: String, contentType: String? = nil, showLineNumbers: Bool = true) {
        self.text = text
        self.contentType = contentType
        self.showLineNumbers = showLineNumbers
    }

    /// Above this size we skip the per-line gutter layout and render a single
    /// Text, so very large bodies don't build thousands of SwiftUI rows.
    private static let gutterLineLimit = 2000

    public var body: some View {
        let lines = text.isEmpty ? ["—"] : text.components(separatedBy: "\n")
        Group {
            if showLineNumbers && lines.count <= Self.gutterLineLimit {
                numberedBody(lines)
            } else {
                plainBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.color.codeBG)
    }

    private var plainBody: some View {
        // Vertical-only so the text fills the panel width and wraps long lines,
        // instead of sizing to its intrinsic width and sitting in a narrow column.
        ScrollView(.vertical) {
            Text(text.isEmpty ? AttributedString("—") : SyntaxHighlighter.highlight(text, contentType: contentType))
                .font(.system(size: 12, design: .monospaced))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
    }

    private func numberedBody(_ lines: [String]) -> some View {
        let digits = max(2, String(lines.count).count)
        let gutterWidth = CGFloat(digits) * 8.0 + 4
        // Vertical-only scroll: the code column fills the panel width and wraps,
        // rather than a 2-axis scroll that shrinks content to a centered column.
        return ScrollView(.vertical) {
            // Lazy so only on-screen lines are built + syntax-highlighted; an eager
            // VStack here rebuilds all (up to gutterLineLimit) rows on every body
            // pass, which made switching requests in Compose janky.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(idx + 1)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.color.textFaint)
                            .frame(width: gutterWidth, alignment: .trailing)
                        Text(line.isEmpty ? AttributedString(" ")
                                          : SyntaxHighlighter.highlight(line, contentType: contentType))
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .lineSpacing(3)
                }
            }
            .padding(.vertical, 12).padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Realtime row

/// One row in the realtime message log, with the design's direction glyphs.
public struct RealtimeRow: View {
    let message: RealtimeMessage
    public init(message: RealtimeMessage) { self.message = message }
    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(glyph).foregroundStyle(color)
                .font(.system(size: 13, weight: .heavy))
                .frame(width: 14, alignment: .center)
            Text(message.timestamp.formatted(.dateTime.hour().minute().second()))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.color.textFaint)
                .frame(width: 54, alignment: .leading)
                .padding(.top, 2)
            Text(message.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(message.direction == .system ? Theme.color.textMuted : Theme.color.textSoft)
                .lineSpacing(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18).padding(.vertical, 6)
    }
    private var glyph: String {
        switch message.direction {
        case .incoming: return "↙"
        case .outgoing: return "↗"
        case .system: return "ⓘ"
        }
    }
    private var color: Color {
        switch message.direction {
        case .incoming: return Color(hex: "#34D399")
        case .outgoing: return Color(hex: "#60A5FA")
        case .system: return Theme.color.textMuted
        }
    }
}

// MARK: - Header table

/// Read-only response/request header list (design: cyan keys, soft values).
/// A toolbar offers Copy-all / Export, and each row has a context menu to copy
/// the value, the name, or the `name: value` pair.
public struct HeaderTable: View {
    let headers: [HeaderPair]
    @SwiftUI.State private var exporting = false
    /// `true` = name stacked above its value (full-width, easy to read on a narrow
    /// panel); `false` = name/value side-by-side columns. Persisted + shared.
    @AppStorage("responseHeadersStacked") private var stacked = true
    public init(headers: [HeaderPair]) { self.headers = headers }
    public var body: some View {
        if headers.isEmpty {
            ContentUnavailableView("No headers", systemImage: "list.bullet")
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("\(headers.count) header\(headers.count == 1 ? "" : "s")")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.color.textFaint)
                    // Layout toggle: Half = name-over-value, Side = two columns.
                    HStack(spacing: 3) {
                        layoutButton("Half", stackedValue: true, system: "rectangle.split.1x2")
                        layoutButton("Side", stackedValue: false, system: "rectangle.split.2x1")
                    }
                    Spacer()
                    BarButton(title: "Copy all", systemImage: "doc.on.doc") {
                        Clipboard.copy(ExportSupport.headersText(headers))
                    }
                    BarButton(title: "Export", systemImage: "square.and.arrow.down", flash: false) {
                        exporting = true
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                Divider().overlay(Theme.color.hairline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(headers) { header in
                            HeaderRow(header: header, stacked: stacked)
                            Divider().overlay(Theme.color.hairline)
                        }
                    }
                }
            }
            .fileExporter(isPresented: $exporting,
                          document: ExportableData(Data(ExportSupport.headersText(headers).utf8)),
                          contentType: .plainText,
                          defaultFilename: "headers.txt") { _ in }
        }
    }

    private func layoutButton(_ title: String, stackedValue: Bool, system: String) -> some View {
        let active = stacked == stackedValue
        return Button { stacked = stackedValue } label: {
            Label(title, systemImage: system)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(active ? Theme.color.accent : Theme.color.textDim)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(active ? Theme.color.accent.opacity(0.14) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(stackedValue ? "Stack name above value" : "Name and value side by side")
    }
}

/// One header row: monospaced `name` / `value` columns plus a copy control that
/// grabs the value, the name, or the `name: value` pair. The copy menu is
/// reachable two ways — a trailing button (revealed on hover on macOS, always
/// visible on iOS) and a right-click / long-press context menu — and the text
/// stays selectable either way.
private struct HeaderRow: View {
    let header: HeaderPair
    let stacked: Bool
    @SwiftUI.State private var hovering = false

    private var nameText: some View {
        Text(header.name)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(Theme.color.codeKey)
            .textSelection(.enabled)
    }

    private var valueText: some View {
        Text(header.value)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Theme.color.textSoft)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        Group {
            if stacked {
                // Name on its own line, value full-width beneath it.
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        nameText
                        Spacer(minLength: 8)
                        copyMenu
                    }
                    valueText
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    nameText.frame(width: 220, alignment: .leading)
                    valueText
                    copyMenu
                        #if os(macOS)
                        .opacity(hovering ? 1 : 0)
                        .animation(.easeInOut(duration: 0.12), value: hovering)
                        #endif
                }
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 16)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { copyButtons }
    }

    private var copyMenu: some View {
        Menu {
            copyButtons
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
                .labelStyle(.iconOnly)
                .font(.system(size: 11))
                .foregroundStyle(Theme.color.textFaint)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Copy this header")
    }

    /// The three copy actions, shared by the trailing menu and the context menu.
    @ViewBuilder private var copyButtons: some View {
        Button("Copy value") { Clipboard.copy(header.value) }
        Button("Copy name") { Clipboard.copy(header.name) }
        Button("Copy “name: value”") {
            Clipboard.copy("\(header.name): \(header.value)")
        }
    }
}

// MARK: - Body viewer (text / hex, copy, export)

/// Read-only body viewer with a toolbar to copy or export the body, and a
/// Text / Hex toggle. Binary bodies (not valid UTF-8) default to the hex view;
/// Export always saves the *raw* bytes.
public struct BodyViewer: View {
    let data: Data
    let contentType: String?
    @SwiftUI.State private var mode: Mode
    @SwiftUI.State private var exporting = false

    enum Mode { case text, hex }

    public init(data: Data, contentType: String?) {
        self.data = data
        self.contentType = contentType
        let textual = data.isEmpty || String(data: data, encoding: .utf8) != nil
        _mode = SwiftUI.State(initialValue: textual ? .text : .hex)
    }

    private var isTextDecodable: Bool { data.isEmpty || String(data: data, encoding: .utf8) != nil }
    private var prettyText: String { UIFormat.prettyBody(data, contentType: contentType) }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    modeButton("Text", .text, enabled: isTextDecodable)
                    modeButton("Hex", .hex, enabled: true)
                }
                Text(UIFormat.byteSize(data.count))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.color.textFaint)
                Spacer()
                BarButton(title: "Copy", systemImage: "doc.on.doc") {
                    Clipboard.copy(mode == .hex || !isTextDecodable ? HexDump.make(data) : prettyText)
                }
                .disabled(data.isEmpty)
                BarButton(title: "Export", systemImage: "square.and.arrow.down", flash: false) {
                    exporting = true
                }
                .disabled(data.isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider().overlay(Theme.color.hairline)
            if mode == .text && isTextDecodable {
                CodeViewer(text: prettyText, contentType: contentType)
            } else {
                HexViewer(data: data)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .fileExporter(isPresented: $exporting,
                      document: ExportableData(data),
                      contentType: .data,
                      defaultFilename: ExportSupport.bodyFilename(contentType: contentType)) { _ in }
    }

    private func modeButton(_ title: String, _ value: Mode, enabled: Bool) -> some View {
        Button { mode = value } label: {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(mode == value ? Theme.color.accent : Theme.color.textDim)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(mode == value ? Theme.color.accent.opacity(0.14) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

public struct RawRequestViewer: View {
    let text: String

    public init(text: String) {
        self.text = text
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                BarButton(title: "Copy", systemImage: "doc.on.doc") {
                    Clipboard.copy(text)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider().overlay(Theme.color.hairline)
            CodeViewer(text: text, contentType: "text/plain", showLineNumbers: false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Toolbar button

/// A compact text+icon button for the copy/export toolbars. When `flash` is set,
/// it briefly shows a "Copied" checkmark after tapping.
public struct BarButton: View {
    let title: String
    let systemImage: String
    var flash: Bool = true
    let action: () -> Void
    @SwiftUI.State private var flashed = false

    public init(title: String, systemImage: String, flash: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.flash = flash
        self.action = action
    }

    public var body: some View {
        Button {
            action()
            if flash {
                flashed = true
                Task { try? await Task.sleep(nanoseconds: 1_000_000_000); flashed = false }
            }
        } label: {
            Label(flashed ? "Copied" : title, systemImage: flashed ? "checkmark" : systemImage)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(flashed ? Theme.color.green : Theme.color.textDim)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - WebSocket message log (Chrome DevTools style)

/// A Chrome DevTools-style frame log for an upgraded WebSocket flow: a scrollable
/// list of frames (↑ sent / ↓ received) with size + time, and a detail pane that
/// renders the selected frame's payload — text as text, binary as hex (via
/// ``BodyViewer``).
public struct WebSocketMessagesView: View {
    let messages: [WebSocketMessage]
    @SwiftUI.State private var selectedID: WebSocketMessage.ID?

    public init(messages: [WebSocketMessage]) { self.messages = messages }

    private var selected: WebSocketMessage? { messages.first { $0.id == selectedID } }

    public var body: some View {
        VStack(spacing: 0) {
            if messages.isEmpty {
                ContentUnavailableView("No frames yet", systemImage: "dot.radiowaves.up.forward",
                    description: Text("Frames appear here as they are sent and received."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(messages) { msg in
                            WebSocketMessageRow(message: msg, selected: msg.id == selectedID)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedID = (selectedID == msg.id) ? nil : msg.id }
                            Divider().overlay(Theme.color.hairline)
                        }
                    }
                }
                .frame(maxHeight: selected == nil ? .infinity : 200)
                if let selected {
                    Divider().overlay(Theme.color.hairline)
                    if selected.truncated {
                        Text("Frame truncated for display — \(UIFormat.byteSize(selected.data.count)) kept")
                            .font(.system(size: 10)).foregroundStyle(Theme.color.textFaint)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.top, 4)
                    }
                    BodyViewer(data: selected.data,
                               contentType: selected.kind == .text ? "text/plain; charset=utf-8" : nil)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

/// One row in ``WebSocketMessagesView``: a direction glyph, a one-line preview,
/// and the frame's size + timestamp.
struct WebSocketMessageRow: View {
    let message: WebSocketMessage
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: glyph)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(preview)
                .font(Theme.mono(12))
                .foregroundStyle(isControl ? Theme.color.textMuted : Theme.color.textBright)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(UIFormat.byteSize(message.data.count))
                .font(Theme.mono(10)).foregroundStyle(Theme.color.textFaint)
            Text(Self.time(message.timestamp))
                .font(Theme.mono(10)).foregroundStyle(Theme.color.textFaint)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
    }

    private var isControl: Bool {
        message.kind == .ping || message.kind == .pong || message.kind == .close
    }

    private var glyph: String {
        switch message.kind {
        case .ping, .pong: return "arrow.left.arrow.right.circle.fill"
        case .close: return "xmark.circle.fill"
        case .text, .binary:
            return message.direction == .sent ? "arrow.up.circle.fill" : "arrow.down.circle.fill"
        }
    }

    private var tint: Color {
        if isControl { return Theme.color.textMuted }
        return message.direction == .sent ? Color(hex: "#34D399") : Color(hex: "#60A5FA")
    }

    private var rowBackground: Color {
        if selected { return Theme.color.accent.opacity(0.14) }
        guard !isControl else { return .clear }
        return message.direction == .sent ? Color(hex: "#34D399").opacity(0.05) : .clear
    }

    private var preview: String {
        switch message.kind {
        case .text:
            return message.text ?? "(non-UTF-8 text frame)"
        case .binary:
            let hex = message.data.prefix(24).map { String(format: "%02x", $0) }.joined(separator: " ")
            return "⬡ \(hex)\(message.data.count > 24 ? " …" : "")"
        case .ping: return "● Ping"
        case .pong: return "● Pong"
        case .close: return "● Close"
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    static func time(_ date: Date) -> String { formatter.string(from: date) }
}
