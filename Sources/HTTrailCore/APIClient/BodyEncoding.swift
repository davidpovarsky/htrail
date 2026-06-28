import Foundation

/// One field of a structured request body (form-urlencoded or multipart).
/// Text fields use `name`/`value`; multipart file fields set `isFile` and carry
/// the picked file's `fileName` + `fileData`.
public struct BodyField: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var value: String
    public var enabled: Bool
    public var isFile: Bool
    public var fileName: String
    public var fileData: Data?

    public init(id: UUID = UUID(), name: String = "", value: String = "",
                enabled: Bool = true, isFile: Bool = false,
                fileName: String = "", fileData: Data? = nil) {
        self.id = id; self.name = name; self.value = value; self.enabled = enabled
        self.isFile = isFile; self.fileName = fileName; self.fileData = fileData
    }
}

/// Serializes structured body fields into the two wire formats, shared by the
/// request runner and the code generator so "what is sent" and "generated code"
/// agree. A constant multipart boundary keeps codegen deterministic.
public enum BodyEncoder {
    public static let multipartBoundary = "----HTTrailFormBoundaryKZpVq7Jb2x9Lm0"

    public static var multipartContentType: String {
        "multipart/form-data; boundary=\(multipartBoundary)"
    }

    public static func hasFields(_ fields: [BodyField]) -> Bool {
        fields.contains { $0.enabled && !$0.name.isEmpty }
    }

    /// `application/x-www-form-urlencoded` string from enabled text fields.
    public static func urlEncoded(_ fields: [BodyField]) -> String {
        fields.filter { $0.enabled && !$0.name.isEmpty && !$0.isFile }
            .map { "\(formEscape($0.name))=\(formEscape($0.value))" }
            .joined(separator: "&")
    }

    /// `multipart/form-data` body (use ``multipartContentType`` for the header).
    public static func multipart(_ fields: [BodyField]) -> Data {
        var data = Data()
        for field in fields where field.enabled && !field.name.isEmpty {
            data.appendString("--\(multipartBoundary)\r\n")
            if field.isFile {
                let filename = field.fileName.isEmpty ? "file" : field.fileName
                data.appendString("Content-Disposition: form-data; name=\"\(field.name)\"; filename=\"\(filename)\"\r\n")
                data.appendString("Content-Type: application/octet-stream\r\n\r\n")
                data.append(field.fileData ?? Data())
                data.appendString("\r\n")
            } else {
                data.appendString("Content-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n")
                data.appendString("\(field.value)\r\n")
            }
        }
        data.appendString("--\(multipartBoundary)--\r\n")
        return data
    }

    private static func formEscape(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._")
        let encoded = s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
        return encoded.replacingOccurrences(of: "%20", with: "+")
    }
}

private extension Data {
    mutating func appendString(_ string: String) { append(Data(string.utf8)) }
}

/// Validates request-body JSON (used by the JSON body editor and GraphQL
/// variables). Pure + synchronous so it can be unit-tested and called from view
/// bodies cheaply.
public enum JSONValidation {
    public enum Result: Equatable {
        case empty
        case valid
        case invalid(String)
    }

    public static func check(_ text: String) -> Result {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        guard let data = trimmed.data(using: .utf8) else { return .invalid("Not valid UTF-8 text") }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return .valid
        } catch {
            return .invalid(message(from: error))
        }
    }

    /// Pretty-prints object/array JSON; returns nil for fragments or invalid input.
    public static func prettyPrinted(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let pretty = try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.prettyPrinted, .withoutEscapingSlashes]),
              let string = String(data: pretty, encoding: .utf8) else { return nil }
        return string
    }

    private static func message(from error: Error) -> String {
        let ns = error as NSError
        if let debug = ns.userInfo[NSDebugDescriptionErrorKey] as? String {
            // Trim the trailing "around line N, column M." noise varies; keep concise.
            return debug
        }
        return ns.localizedDescription
    }
}
