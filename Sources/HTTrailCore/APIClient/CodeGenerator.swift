import Foundation

/// Generates client code snippets for a request (Hoppscotch "Generate code").
public struct CodeGenerator: Sendable {
    public enum Target: String, CaseIterable, Identifiable, Sendable {
        case curl = "cURL"
        case swift = "Swift (URLSession)"
        case javascript = "JavaScript (fetch)"
        case python = "Python (requests)"
        public var id: String { rawValue }
    }

    public init() {}

    public func generate(_ request: APIRequest, target: Target,
                         environment: [String: String] = [:]) -> String {
        switch target {
        case .curl: return CurlConverter().exportCommand(request, environment: environment)
        case .swift: return swift(request)
        case .javascript: return javascript(request)
        case .python: return python(request)
        }
    }

    /// The request body as a single string for the script targets. Form bodies
    /// are serialized the same way the runner sends them; multipart (which can
    /// carry binary files) returns nil and is represented per-target instead.
    private func bodyString(_ request: APIRequest) -> String? {
        switch request.bodyMode {
        case .none:
            return nil
        case .formURLEncoded:
            if BodyEncoder.hasFields(request.bodyForm) { return BodyEncoder.urlEncoded(request.bodyForm) }
            return request.rawBody.isEmpty ? nil : request.rawBody
        case .multipart:
            return nil
        case .json, .raw, .graphql:
            return request.rawBody.isEmpty ? nil : request.rawBody
        }
    }

    private func headerLines(_ request: APIRequest) -> [(String, String)] {
        var result = request.headers.filter { $0.enabled && !$0.name.isEmpty }.map { ($0.name, $0.value) }
        switch request.auth.type {
        case .bearer: result.append(("Authorization", "Bearer \(request.auth.token)"))
        case .apiKey where request.auth.addToHeader: result.append((request.auth.key, request.auth.value))
        default: break
        }
        return result
    }

    private func swift(_ request: APIRequest) -> String {
        var lines = [
            "var request = URLRequest(url: URL(string: \"\(request.url)\")!)",
            "request.httpMethod = \"\(request.method)\""
        ]
        for (name, value) in headerLines(request) {
            lines.append("request.setValue(\"\(value)\", forHTTPHeaderField: \"\(name)\")")
        }
        if let body = bodyString(request) {
            lines.append("request.httpBody = #\"\(body)\"#.data(using: .utf8)")
        }
        lines.append("let (data, response) = try await URLSession.shared.data(for: request)")
        return lines.joined(separator: "\n")
    }

    private func javascript(_ request: APIRequest) -> String {
        let headers = headerLines(request)
            .map { "    \"\($0.0)\": \"\($0.1)\"" }.joined(separator: ",\n")
        var options = ["  method: \"\(request.method)\""]
        if !headers.isEmpty { options.append("  headers: {\n\(headers)\n  }") }
        if let body = bodyString(request) {
            options.append("  body: `\(body)`")
        }
        return "fetch(\"\(request.url)\", {\n\(options.joined(separator: ",\n"))\n})\n  .then(r => r.json())\n  .then(console.log)"
    }

    private func python(_ request: APIRequest) -> String {
        let headers = headerLines(request)
            .map { "    \"\($0.0)\": \"\($0.1)\"" }.joined(separator: ",\n")
        var lines = ["import requests", ""]
        if !headers.isEmpty { lines.append("headers = {\n\(headers)\n}") }
        let body = bodyString(request)
        if let body { lines.append("data = r'''\(body)'''") }
        var call = "response = requests.request(\"\(request.method)\", \"\(request.url)\""
        if !headers.isEmpty { call += ", headers=headers" }
        if body != nil { call += ", data=data" }
        call += ")"
        lines.append(call)
        lines.append("print(response.text)")
        return lines.joined(separator: "\n")
    }
}
