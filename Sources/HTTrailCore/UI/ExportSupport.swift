import SwiftUI
import Foundation
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Cross-platform clipboard helper so the shared components (header table, body
/// viewer) can offer copy actions on both macOS and iOS without each app wiring
/// up its own pasteboard.
public enum Clipboard {
    public static func copy(_ string: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = string
        #endif
    }
}

/// A minimal `FileDocument` wrapping raw `Data`, used with SwiftUI's
/// `.fileExporter` to save a request/response body or a header dump to disk on
/// both platforms. We export the *exact* bytes; the file's extension comes from
/// the supplied default filename.
public struct ExportableData: FileDocument {
    // `.data` is generic (no forced extension), so the chosen filename's
    // extension is honoured; `.plainText` is included for header dumps.
    public static var readableContentTypes: [UTType] { [.data, .plainText] }
    public var data: Data
    public init(_ data: Data) { self.data = data }
    public init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Helpers for deriving export filenames and serialising headers to text.
public enum ExportSupport {
    /// A sensible file extension for a body of the given Content-Type.
    public static func fileExtension(forContentType ct: String?) -> String {
        let t = (ct ?? "").lowercased()
        if t.contains("json") { return "json" }
        if t.contains("html") { return "html" }
        if t.contains("xml") { return "xml" }
        if t.contains("css") { return "css" }
        if t.contains("javascript") || t.contains("ecmascript") { return "js" }
        if t.contains("csv") { return "csv" }
        if t.contains("image/png") { return "png" }
        if t.contains("image/jpeg") || t.contains("image/jpg") { return "jpg" }
        if t.contains("image/gif") { return "gif" }
        if t.contains("image/webp") { return "webp" }
        if t.contains("image/svg") { return "svg" }
        if t.contains("pdf") { return "pdf" }
        if t.contains("zip") { return "zip" }
        if t.contains("gzip") { return "gz" }
        if t.contains("text/") { return "txt" }
        return "bin"
    }

    /// Default save name for a body of the given Content-Type.
    public static func bodyFilename(contentType: String?) -> String {
        "body.\(fileExtension(forContentType: contentType))"
    }

    /// Render a header list as a plain `Name: value` block (one per line).
    public static func headersText(_ headers: [HeaderPair]) -> String {
        headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
    }
}
