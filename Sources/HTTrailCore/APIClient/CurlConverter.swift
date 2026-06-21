import Foundation

/// Imports a `curl` command into an ``APIRequest`` and exports the reverse —
/// the Hoppscotch "Import cURL" / "Generate code" feature.
public struct CurlConverter: Sendable {
    public init() {}

    // MARK: Import

    public func importCommand(_ command: String) -> APIRequest? {
        let tokens = tokenize(command)
        guard let curlIdx = tokens.firstIndex(where: { $0 == "curl" }) ?? (tokens.isEmpty ? nil : tokens.startIndex) else {
            return nil
        }
        var request = APIRequest(name: "Imported")
        var explicitMethod: String?
        var headers: [KeyValueItem] = []
        var dataParts: [String] = []
        var url: String?

        var i = tokens.index(after: curlIdx)
        while i < tokens.endIndex {
            let token = tokens[i]
            switch token {
            case "-X", "--request":
                i = tokens.index(after: i)
                if i < tokens.endIndex { explicitMethod = tokens[i].uppercased() }
            case "-H", "--header":
                i = tokens.index(after: i)
                if i < tokens.endIndex, let pair = splitHeader(tokens[i]) {
                    headers.append(KeyValueItem(name: pair.0, value: pair.1))
                }
            case "-d", "--data", "--data-raw", "--data-binary", "--data-ascii":
                i = tokens.index(after: i)
                if i < tokens.endIndex { dataParts.append(tokens[i]) }
            case "-u", "--user":
                i = tokens.index(after: i)
                if i < tokens.endIndex {
                    let creds = tokens[i].split(separator: ":", maxSplits: 1)
                    var auth = AuthConfig(); auth.type = .basic
                    auth.username = String(creds.first ?? "")
                    auth.password = creds.count > 1 ? String(creds[1]) : ""
                    request.auth = auth
                }
            case "--compressed", "-L", "--location", "-k", "--insecure", "-s", "--silent", "-i", "-v":
                break // ignored flags
            default:
                if token.hasPrefix("-") {
                    // Unknown flag — skip a following value if it isn't a URL.
                } else if url == nil {
                    url = token
                }
            }
            i = tokens.index(after: i)
        }

        guard let finalURL = url else { return nil }
        request.url = finalURL
        request.headers = headers
        if !dataParts.isEmpty {
            request.rawBody = dataParts.joined(separator: "&")
            request.bodyMode = looksLikeJSON(request.rawBody) ? .json : .raw
        }
        request.method = explicitMethod ?? (dataParts.isEmpty ? "GET" : "POST")
        return request
    }

    // MARK: Export

    public func exportCommand(_ request: APIRequest, environment: [String: String] = [:]) -> String {
        var parts = ["curl"]
        if request.method != "GET" { parts.append("-X \(request.method)") }

        var urlString = request.url
        let activeQuery = request.queryParams.filter { $0.enabled && !$0.name.isEmpty }
        if !activeQuery.isEmpty, var comps = URLComponents(string: urlString) {
            var items = comps.queryItems ?? []
            items.append(contentsOf: activeQuery.map { URLQueryItem(name: $0.name, value: $0.value) })
            comps.queryItems = items
            urlString = comps.url?.absoluteString ?? urlString
        }
        parts.append("'\(urlString)'")

        for header in request.headers where header.enabled && !header.name.isEmpty {
            parts.append("-H '\(header.name): \(header.value)'")
        }
        switch request.auth.type {
        case .bearer: parts.append("-H 'Authorization: Bearer \(request.auth.token)'")
        case .basic: parts.append("-u '\(request.auth.username):\(request.auth.password)'")
        case .apiKey where request.auth.addToHeader:
            parts.append("-H '\(request.auth.key): \(request.auth.value)'")
        default: break
        }
        if request.bodyMode != .none, !request.rawBody.isEmpty {
            let escaped = request.rawBody.replacingOccurrences(of: "'", with: "'\\''")
            parts.append("--data '\(escaped)'")
        }
        return parts.joined(separator: " \\\n  ")
    }

    // MARK: Helpers

    private func splitHeader(_ raw: String) -> (String, String)? {
        guard let colon = raw.firstIndex(of: ":") else { return nil }
        let name = raw[..<colon].trimmingCharacters(in: .whitespaces)
        let value = raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return (name, value)
    }

    private func looksLikeJSON(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
    }

    /// Shell-like tokenizer that respects single/double quotes and `\` line
    /// continuations.
    private func tokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var iterator = command.makeIterator()
        var pending: Character?

        func nextChar() -> Character? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }

        while let ch = nextChar() {
            if let q = quote {
                if ch == q { quote = nil }
                else { current.append(ch) }
            } else {
                switch ch {
                case "'", "\"":
                    quote = ch
                case "\\":
                    // Line continuation or escaped char.
                    if let next = nextChar(), next != "\n" { current.append(next) }
                case " ", "\t", "\n", "\r":
                    if !current.isEmpty { tokens.append(current); current = "" }
                default:
                    current.append(ch)
                }
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
