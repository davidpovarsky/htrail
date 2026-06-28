import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// How the request body is encoded — mirrors Hoppscotch's body modes.
public enum RequestBodyMode: String, Codable, Sendable, CaseIterable {
    case none
    case json
    case raw
    case formURLEncoded
    case multipart
    case graphql
}

public struct KeyValueItem: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var value: String
    public var enabled: Bool
    public init(id: UUID = UUID(), name: String = "", value: String = "", enabled: Bool = true) {
        self.id = id; self.name = name; self.value = value; self.enabled = enabled
    }
}

public enum AuthType: String, Codable, Sendable, CaseIterable {
    case none, bearer, basic, apiKey
}

/// Authorization helper applied at send time (Hoppscotch "Authorization" tab).
public struct AuthConfig: Codable, Sendable, Hashable {
    public var type: AuthType = .none
    public var token: String = ""        // bearer
    public var username: String = ""     // basic
    public var password: String = ""     // basic
    public var key: String = ""          // apiKey name
    public var value: String = ""        // apiKey value
    public var addToHeader: Bool = true  // apiKey: header vs query
    public init() {}
}

/// A composable API request — the Hoppscotch "request builder" document.
/// Tolerant decoding lets saved collections survive new fields being added.
public struct APIRequest: Codable, Sendable, Identifiable {
    public static let defaultURL = "https://1.1.1.1/cdn-cgi/trace"

    public var id: UUID
    public var name: String
    public var method: String
    public var url: String
    public var queryParams: [KeyValueItem]
    public var headers: [KeyValueItem]
    public var bodyMode: RequestBodyMode
    public var rawBody: String
    /// Structured fields for form-urlencoded + multipart bodies (key/value, plus
    /// file attachments in multipart). `rawBody` stays the source for json/raw.
    public var bodyForm: [BodyField]
    public var contentType: String
    public var auth: AuthConfig
    public var graphqlQuery: String
    public var graphqlVariables: String
    public var preRequestScript: String
    public var testScript: String

    public init(id: UUID = UUID(), name: String = "New Request", method: String = "GET",
                url: String = Self.defaultURL, queryParams: [KeyValueItem] = [],
                headers: [KeyValueItem] = [], bodyMode: RequestBodyMode = .none,
                rawBody: String = "", bodyForm: [BodyField] = [],
                contentType: String = "application/json",
                auth: AuthConfig = AuthConfig(), graphqlQuery: String = "",
                graphqlVariables: String = "", preRequestScript: String = "", testScript: String = "") {
        self.id = id; self.name = name; self.method = method; self.url = url
        self.queryParams = queryParams; self.headers = headers; self.bodyMode = bodyMode
        self.rawBody = rawBody; self.bodyForm = bodyForm; self.contentType = contentType; self.auth = auth
        self.graphqlQuery = graphqlQuery; self.graphqlVariables = graphqlVariables
        self.preRequestScript = preRequestScript; self.testScript = testScript
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "New Request"
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? "GET"
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? Self.defaultURL
        queryParams = try c.decodeIfPresent([KeyValueItem].self, forKey: .queryParams) ?? []
        headers = try c.decodeIfPresent([KeyValueItem].self, forKey: .headers) ?? []
        bodyMode = try c.decodeIfPresent(RequestBodyMode.self, forKey: .bodyMode) ?? .none
        rawBody = try c.decodeIfPresent(String.self, forKey: .rawBody) ?? ""
        bodyForm = try c.decodeIfPresent([BodyField].self, forKey: .bodyForm) ?? []
        contentType = try c.decodeIfPresent(String.self, forKey: .contentType) ?? "application/json"
        auth = try c.decodeIfPresent(AuthConfig.self, forKey: .auth) ?? AuthConfig()
        graphqlQuery = try c.decodeIfPresent(String.self, forKey: .graphqlQuery) ?? ""
        graphqlVariables = try c.decodeIfPresent(String.self, forKey: .graphqlVariables) ?? ""
        preRequestScript = try c.decodeIfPresent(String.self, forKey: .preRequestScript) ?? ""
        testScript = try c.decodeIfPresent(String.self, forKey: .testScript) ?? ""
    }
}

public struct APIResponse: Sendable, Codable {
    public var statusCode: Int
    public var headers: [HeaderPair]
    public var body: Data
    public var durationMS: Int
    public var error: String?
    public var rawRequestHeader: String?

    public var bodyString: String { String(data: body, encoding: .utf8) ?? "" }

    public init(statusCode: Int, headers: [HeaderPair], body: Data, durationMS: Int,
                error: String? = nil, rawRequestHeader: String? = nil) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.durationMS = durationMS
        self.error = error
        self.rawRequestHeader = rawRequestHeader
    }
}

/// Executes an ``APIRequest`` directly (Hoppscotch-style), independent of the
/// capturing proxy. Substitutes `{{var}}` environment placeholders before send.
public struct RequestRunner: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: APIRequest, environment: [String: String] = [:]) async -> APIResponse {
        let start = Date()
        guard let urlRequest = makeURLRequest(request, environment: environment) else {
            return APIResponse(statusCode: 0, headers: [], body: Data(), durationMS: 0,
                               error: "Invalid URL")
        }
        let rawRequestHeader = Self.rawRequestHeader(for: urlRequest)
        do {
            let (data, response) = try await session.data(for: urlRequest)
            let duration = Int(Date().timeIntervalSince(start) * 1000)
            let http = response as? HTTPURLResponse
            let headers: [HeaderPair] = (http?.allHeaderFields ?? [:]).compactMap { key, value in
                guard let name = key as? String else { return nil }
                return HeaderPair(name: name, value: "\(value)")
            }
            return APIResponse(statusCode: http?.statusCode ?? 0, headers: headers,
                               body: data, durationMS: duration, error: nil,
                               rawRequestHeader: rawRequestHeader)
        } catch {
            let duration = Int(Date().timeIntervalSince(start) * 1000)
            return APIResponse(statusCode: 0, headers: [], body: Data(),
                               durationMS: duration, error: error.localizedDescription,
                               rawRequestHeader: rawRequestHeader)
        }
    }

    public static func rawRequestHeader(for request: URLRequest) -> String {
        let method = request.httpMethod?.isEmpty == false ? request.httpMethod! : "GET"
        let target = requestTarget(for: request.url)
        var lines = ["\(method) \(target) HTTP/1.1"]
        let headers = request.allHTTPHeaderFields ?? [:]
        if !headers.keys.contains(where: { $0.caseInsensitiveCompare("Host") == .orderedSame }),
           let host = hostHeaderValue(for: request.url) {
            lines.append("Host: \(host)")
        }
        if let body = request.httpBody, !body.isEmpty,
           !headers.keys.contains(where: { $0.caseInsensitiveCompare("Content-Length") == .orderedSame }) {
            lines.append("Content-Length: \(body.count)")
        }
        for key in headers.keys.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
            guard let value = headers[key] else { continue }
            lines.append("\(key): \(value)")
        }
        var raw = lines.joined(separator: "\r\n") + "\r\n\r\n"
        if let body = request.httpBody, !body.isEmpty {
            if let text = String(data: body, encoding: .utf8) {
                raw += text
            } else {
                raw += "[binary body: \(body.count) bytes]"
            }
        }
        return raw
    }

    private static func requestTarget(for url: URL?) -> String {
        guard let url else { return "/" }
        var target = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty {
            target += "?\(query)"
        }
        return target
    }

    private static func hostHeaderValue(for url: URL?) -> String? {
        guard let url, var host = url.host, !host.isEmpty else { return nil }
        if host.contains(":"), !host.hasPrefix("[") {
            host = "[\(host)]"
        }
        if let port = url.port, port != defaultPort(for: url.scheme) {
            return "\(host):\(port)"
        }
        return host
    }

    private static func defaultPort(for scheme: String?) -> Int? {
        switch scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    func makeURLRequest(_ request: APIRequest, environment: [String: String]) -> URLRequest? {
        let resolvedURL = substitute(request.url, environment)
        guard var components = URLComponents(string: resolvedURL) else { return nil }

        let activeQuery = request.queryParams.filter { $0.enabled && !$0.name.isEmpty }
        if !activeQuery.isEmpty {
            var items = components.queryItems ?? []
            items.append(contentsOf: activeQuery.map {
                URLQueryItem(name: substitute($0.name, environment), value: substitute($0.value, environment))
            })
            components.queryItems = items
        }
        guard let url = components.url else { return nil }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        for header in request.headers where header.enabled && !header.name.isEmpty {
            urlRequest.setValue(substitute(header.value, environment),
                                forHTTPHeaderField: substitute(header.name, environment))
        }

        applyAuth(request.auth, to: &urlRequest, components: &components, environment: environment)

        switch request.bodyMode {
        case .none:
            break
        case .json, .raw:
            let body = substitute(request.rawBody, environment)
            urlRequest.httpBody = body.data(using: .utf8)
            if urlRequest.value(forHTTPHeaderField: "Content-Type") == nil {
                let ct = request.bodyMode == .json ? "application/json" : request.contentType
                urlRequest.setValue(ct, forHTTPHeaderField: "Content-Type")
            }
        case .formURLEncoded:
            if BodyEncoder.hasFields(request.bodyForm) {
                let fields = substitutedFields(request.bodyForm, environment)
                urlRequest.httpBody = BodyEncoder.urlEncoded(fields).data(using: .utf8)
            } else {
                urlRequest.httpBody = substitute(request.rawBody, environment).data(using: .utf8)
            }
            if urlRequest.value(forHTTPHeaderField: "Content-Type") == nil {
                urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
        case .multipart:
            if BodyEncoder.hasFields(request.bodyForm) {
                let fields = substitutedFields(request.bodyForm, environment)
                urlRequest.httpBody = BodyEncoder.multipart(fields)
                if urlRequest.value(forHTTPHeaderField: "Content-Type") == nil {
                    urlRequest.setValue(BodyEncoder.multipartContentType, forHTTPHeaderField: "Content-Type")
                }
            } else {
                urlRequest.httpBody = substitute(request.rawBody, environment).data(using: .utf8)
            }
        case .graphql:
            let payload = graphqlPayload(request, environment: environment)
            urlRequest.httpBody = payload
            if urlRequest.value(forHTTPHeaderField: "Content-Type") == nil {
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            if urlRequest.httpMethod == "GET" { urlRequest.httpMethod = "POST" }
        }
        return urlRequest
    }

    /// Encodes `{ query, variables }` for a GraphQL POST.
    func graphqlPayload(_ request: APIRequest, environment: [String: String]) -> Data? {
        let query = substitute(request.graphqlQuery, environment)
        var payload: [String: Any] = ["query": query]
        let vars = substitute(request.graphqlVariables, environment)
        if !vars.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let data = vars.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            payload["variables"] = object
        }
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    private func applyAuth(_ auth: AuthConfig, to urlRequest: inout URLRequest,
                           components: inout URLComponents, environment: [String: String]) {
        switch auth.type {
        case .none:
            break
        case .bearer:
            let token = substitute(auth.token, environment)
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .basic:
            let raw = "\(substitute(auth.username, environment)):\(substitute(auth.password, environment))"
            let encoded = Data(raw.utf8).base64EncodedString()
            urlRequest.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        case .apiKey:
            let key = substitute(auth.key, environment)
            let value = substitute(auth.value, environment)
            guard !key.isEmpty else { return }
            if auth.addToHeader {
                urlRequest.setValue(value, forHTTPHeaderField: key)
            } else {
                var items = components.queryItems ?? []
                items.append(URLQueryItem(name: key, value: value))
                components.queryItems = items
                if let url = components.url { urlRequest.url = url }
            }
        }
    }

    /// Applies `{{var}}` substitution to each field's name (and text value); file
    /// data is left untouched.
    private func substitutedFields(_ fields: [BodyField], _ environment: [String: String]) -> [BodyField] {
        fields.map { field in
            var copy = field
            copy.name = substitute(field.name, environment)
            if !field.isFile { copy.value = substitute(field.value, environment) }
            return copy
        }
    }

    private func substitute(_ string: String, _ environment: [String: String]) -> String {
        guard !environment.isEmpty, string.contains("{{") else { return string }
        var result = string
        for (key, value) in environment {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return result
    }
}
