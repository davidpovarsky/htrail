import SwiftUI
import Foundation

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

    public init(items: Binding<[KeyValueItem]>, keyPlaceholder: String = "key", valuePlaceholder: String = "value") {
        self._items = items
        self.keyPlaceholder = keyPlaceholder
        self.valuePlaceholder = valuePlaceholder
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
                        .foregroundStyle(item.enabled ? Theme.color.textBright : Theme.color.textFaint)

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
                HStack(spacing: 6) {
                    Text("＋").font(.system(size: 13))
                    Text("add \(keyPlaceholder == "key" ? "row" : keyPlaceholder)")
                    Spacer()
                }
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color(hex: "#60A5FA"))
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
        .background(Theme.color.codeBG)
    }

    private var plainBody: some View {
        ScrollView([.vertical, .horizontal]) {
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
        return ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
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
        HStack(alignment: .top, spacing: 10) {
            Text(glyph).foregroundStyle(color)
                .font(.system(size: 13))
                .frame(width: 16)
            Text(message.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.color.textSoft)
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
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
        case .incoming: return Theme.color.green
        case .outgoing: return Theme.color.blue
        case .system: return Theme.color.textDim
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
                            HStack(alignment: .top, spacing: 12) {
                                Text(header.name)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Theme.color.codeKey)
                                    .textSelection(.enabled)
                                    .frame(width: 220, alignment: .leading)
                                Text(header.value)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Theme.color.textSoft)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 8).padding(.horizontal, 16)
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button("Copy value") { Clipboard.copy(header.value) }
                                Button("Copy name") { Clipboard.copy(header.name) }
                                Button("Copy “name: value”") {
                                    Clipboard.copy("\(header.name): \(header.value)")
                                }
                            }
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

// MARK: - Toolbar button

/// A compact text+icon button for the copy/export toolbars. When `flash` is set,
/// it briefly shows a "Copied" checkmark after tapping.
struct BarButton: View {
    let title: String
    let systemImage: String
    var flash: Bool = true
    let action: () -> Void
    @SwiftUI.State private var flashed = false

    var body: some View {
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
