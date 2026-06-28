import Foundation

/// Imports an OpenAPI 3 document (JSON) into a collection of requests.
public struct OpenAPIImporter: Sendable {
    public init() {}

    public func importDocument(_ data: Data) -> RequestCollection? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let info = root["info"] as? [String: Any]
        let title = (info?["title"] as? String) ?? "OpenAPI"

        var baseURL = ""
        if let servers = root["servers"] as? [[String: Any]], let first = servers.first {
            baseURL = (first["url"] as? String) ?? ""
        }

        var requests: [APIRequest] = []
        let methods = ["get", "post", "put", "patch", "delete", "head", "options"]
        if let paths = root["paths"] as? [String: Any] {
            for (path, value) in paths.sorted(by: { $0.key < $1.key }) {
                guard let operations = value as? [String: Any] else { continue }
                for method in methods {
                    guard let op = operations[method] as? [String: Any] else { continue }
                    let summary = (op["summary"] as? String) ?? (op["operationId"] as? String)
                    var request = APIRequest(
                        name: summary ?? "\(method.uppercased()) \(path)",
                        method: method.uppercased(),
                        url: baseURL + path
                    )
                    // Surface path/query parameters as disabled query items.
                    if let params = op["parameters"] as? [[String: Any]] {
                        request.queryParams = params.compactMap { param in
                            guard (param["in"] as? String) == "query",
                                  let name = param["name"] as? String else { return nil }
                            return KeyValueItem(name: name, value: "", enabled: false)
                        }
                    }
                    requests.append(request)
                }
            }
        }
        guard !requests.isEmpty else { return nil }
        return RequestCollection(name: title, requests: requests)
    }
}

/// Imports a Postman Collection v2.1 (JSON) into a collection.
public struct PostmanImporter: Sendable {
    public init() {}

    public func importDocument(_ data: Data) -> RequestCollection? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let info = root["info"] as? [String: Any]
        let name = (info?["name"] as? String) ?? "Postman Import"
        let items = root["item"] as? [[String: Any]] ?? []
        let parsed = parseItems(items)
        guard !parsed.requests.isEmpty || !parsed.folders.isEmpty else { return nil }
        return RequestCollection(name: name, requests: parsed.requests, folders: parsed.folders)
    }

    private func parseItems(_ items: [[String: Any]]) -> (requests: [APIRequest], folders: [RequestCollection]) {
        var requests: [APIRequest] = []
        var folders: [RequestCollection] = []
        for item in items {
            if let subItems = item["item"] as? [[String: Any]] {
                let nested = parseItems(subItems)
                folders.append(RequestCollection(name: (item["name"] as? String) ?? "Folder",
                                                 requests: nested.requests, folders: nested.folders))
            } else if let req = item["request"] {
                if let request = parseRequest(req, name: item["name"] as? String) {
                    requests.append(request)
                }
            }
        }
        return (requests, folders)
    }

    private func parseRequest(_ value: Any, name: String?) -> APIRequest? {
        // Postman request can be a string (just URL) or an object.
        if let urlString = value as? String {
            return APIRequest(name: name ?? urlString, url: urlString)
        }
        guard let dict = value as? [String: Any] else { return nil }
        let method = (dict["method"] as? String) ?? "GET"
        let urlString = urlString(from: dict["url"])
        var request = APIRequest(name: name ?? urlString, method: method, url: urlString)

        if let headers = dict["header"] as? [[String: Any]] {
            request.headers = headers.compactMap { h in
                guard let key = h["key"] as? String else { return nil }
                return KeyValueItem(name: key, value: (h["value"] as? String) ?? "",
                                    enabled: !((h["disabled"] as? Bool) ?? false))
            }
        }
        if let body = dict["body"] as? [String: Any], let raw = body["raw"] as? String {
            request.rawBody = raw
            request.bodyMode = raw.trimmingCharacters(in: .whitespaces).hasPrefix("{") ? .json : .raw
        }
        return request
    }

    private func urlString(from value: Any?) -> String {
        if let string = value as? String { return string }
        if let dict = value as? [String: Any] {
            if let raw = dict["raw"] as? String { return raw }
            let host = (dict["host"] as? [String])?.joined(separator: ".") ?? ""
            let path = (dict["path"] as? [String])?.joined(separator: "/") ?? ""
            let proto = (dict["protocol"] as? String) ?? "https"
            return "\(proto)://\(host)/\(path)"
        }
        return ""
    }
}

public struct PostmanBackupImport: Sendable {
    public var collections: [RequestCollection]
    public var environments: [RequestEnvironment]

    public init(collections: [RequestCollection], environments: [RequestEnvironment]) {
        self.collections = collections
        self.environments = environments
    }
}

public enum PostmanBackupImportError: Error, LocalizedError, Sendable {
    case emptyBackup

    public var errorDescription: String? {
        switch self {
        case .emptyBackup:
            return "The Postman backup did not contain any collections or environments."
        }
    }
}

public struct PostmanBackupLocator {
    public var postmanDirectory: URL

    public init(postmanDirectory: URL = Self.defaultPostmanDirectory) {
        self.postmanDirectory = postmanDirectory
    }

    public static var defaultPostmanDirectory: URL {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Postman", isDirectory: true)
        #else
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Postman", isDirectory: true) ?? URL(fileURLWithPath: "/")
        #endif
    }

    public func backupFiles() -> [URL] {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: postmanDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return []
        }
        return files
            .filter { Self.isBackupFileName($0.lastPathComponent) }
            .sorted { lhs, rhs in
                let leftKey = Self.backupSortKey(for: lhs)
                let rightKey = Self.backupSortKey(for: rhs)
                if leftKey != rightKey { return leftKey > rightKey }
                return lhs.lastPathComponent > rhs.lastPathComponent
            }
    }

    public func latestBackupFile() -> URL? {
        backupFiles().first
    }

    private static func isBackupFileName(_ name: String) -> Bool {
        name.hasPrefix("backup-") && name.hasSuffix(".json")
    }

    private static func backupSortKey(for url: URL) -> String {
        let name = url.lastPathComponent
        if isBackupFileName(name) { return name }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return "\(modified?.timeIntervalSince1970 ?? 0)"
    }
}

/// Imports the full backup JSON that Postman Desktop writes under
/// `~/Library/Application Support/Postman/backup-*.json`.
public struct PostmanBackupImporter: Sendable {
    public init() {}

    public func importBackup(_ data: Data) throws -> PostmanBackupImport {
        let backup = try JSONDecoder().decode(PostmanBackup.self, from: data)
        let collections = backup.collections.compactMap(Self.collection(from:))
        let environments = backup.environments.compactMap(Self.environment(from:))
        guard !collections.isEmpty || !environments.isEmpty else {
            throw PostmanBackupImportError.emptyBackup
        }
        return PostmanBackupImport(collections: collections, environments: environments)
    }

    private static func collection(from legacy: PostmanBackup.Collection) -> RequestCollection? {
        let requests = legacy.requests
        let folders = legacy.folders
        guard !requests.isEmpty || !folders.isEmpty else { return nil }

        let rootRequests = orderedRequests(parentID: nil, explicitIDs: legacy.order, allRequests: requests)
        let rootFolders = orderedFolders(parentID: nil, explicitIDs: legacy.foldersOrder, allFolders: folders,
                                         allRequests: requests)
        return RequestCollection(
            name: legacy.name.nonEmpty ?? "Postman Backup",
            requests: rootRequests.compactMap(request(from:)),
            folders: rootFolders
        )
    }

    private static func folder(from legacy: PostmanBackup.Folder,
                               allFolders: [PostmanBackup.Folder],
                               allRequests: [PostmanBackup.Request]) -> RequestCollection {
        let childRequests = orderedRequests(parentID: legacy.id, explicitIDs: legacy.order,
                                            allRequests: allRequests)
        let childFolders = orderedFolders(parentID: legacy.id, explicitIDs: legacy.foldersOrder,
                                          allFolders: allFolders, allRequests: allRequests)
        return RequestCollection(
            name: legacy.name.nonEmpty ?? "Folder",
            requests: childRequests.compactMap(request(from:)),
            folders: childFolders
        )
    }

    private static func orderedRequests(parentID: String?,
                                        explicitIDs: [String],
                                        allRequests: [PostmanBackup.Request]) -> [PostmanBackup.Request] {
        let siblings = allRequests.filter { normalizedID($0.folderID) == normalizedID(parentID) }
        return ordered(siblings, explicitIDs: explicitIDs) { $0.id }
    }

    private static func orderedFolders(parentID: String?,
                                       explicitIDs: [String],
                                       allFolders: [PostmanBackup.Folder],
                                       allRequests: [PostmanBackup.Request]) -> [RequestCollection] {
        let siblings = allFolders.filter { normalizedID($0.parentID) == normalizedID(parentID) }
        return ordered(siblings, explicitIDs: explicitIDs) { $0.id }
            .map { folder(from: $0, allFolders: allFolders, allRequests: allRequests) }
    }

    private static func ordered<Value>(_ values: [Value], explicitIDs: [String],
                                       id: (Value) -> String?) -> [Value] {
        guard !explicitIDs.isEmpty else { return values }
        var consumed = Set<String>()
        var result: [Value] = []
        for explicitID in explicitIDs {
            guard let match = values.first(where: { id($0) == explicitID }) else { continue }
            result.append(match)
            consumed.insert(explicitID)
        }
        result.append(contentsOf: values.filter { value in
            guard let valueID = id(value) else { return true }
            return !consumed.contains(valueID)
        })
        return result
    }

    private static func request(from legacy: PostmanBackup.Request) -> APIRequest? {
        let rawURL = legacy.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawURL.isEmpty else { return nil }

        let split = splitURLAndQuery(rawURL)
        let headers = headerItems(from: legacy)
        let contentType = headers.first {
            $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame
        }?.value ?? "application/json"

        var request = APIRequest(
            id: legacy.id.flatMap(UUID.init(uuidString:)) ?? UUID(),
            name: legacy.name.nonEmpty ?? rawURL,
            method: legacy.method.nonEmpty?.uppercased() ?? "GET",
            url: split.url,
            queryParams: queryItems(from: legacy, fallback: split.queryParams),
            headers: headers,
            contentType: contentType,
            auth: auth(from: legacy.auth)
        )
        applyBody(from: legacy, contentType: contentType, to: &request)
        applyScripts(from: legacy.events, to: &request)
        return request
    }

    private static func environment(from legacy: PostmanBackup.Environment) -> RequestEnvironment? {
        let variables = legacy.values.map { item in
            KeyValueItem(name: item.key, value: item.value, enabled: item.enabled)
        }.filter { !$0.name.isEmpty }
        guard !(legacy.name.isEmpty && variables.isEmpty) else { return nil }
        return RequestEnvironment(id: legacy.id.flatMap(UUID.init(uuidString:)) ?? UUID(),
                                  name: legacy.name.nonEmpty ?? "Postman Environment",
                                  variables: variables)
    }

    private static func headerItems(from legacy: PostmanBackup.Request) -> [KeyValueItem] {
        if !legacy.headerData.isEmpty {
            return legacy.headerData.map {
                KeyValueItem(name: $0.key, value: $0.value, enabled: $0.enabled)
            }.filter { !$0.name.isEmpty }
        }
        return legacy.headers
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> KeyValueItem? in
                let text = String(line)
                guard let separator = text.firstIndex(of: ":") else { return nil }
                let name = String(text[..<separator]).trimmingCharacters(in: .whitespaces)
                let value = String(text[text.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return nil }
                return KeyValueItem(name: name, value: value)
            }
    }

    private static func queryItems(from legacy: PostmanBackup.Request,
                                   fallback: [KeyValueItem]) -> [KeyValueItem] {
        let explicit = legacy.queryParams.map {
            KeyValueItem(name: $0.key, value: $0.value, enabled: $0.enabled)
        }.filter { !$0.name.isEmpty }
        return explicit.isEmpty ? fallback : explicit
    }

    private static func applyBody(from legacy: PostmanBackup.Request,
                                  contentType: String,
                                  to request: inout APIRequest) {
        switch legacy.dataMode.lowercased() {
        case "raw":
            request.rawBody = legacy.rawModeData
            request.bodyMode = isJSONBody(legacy.rawModeData, contentType: contentType) ? .json : .raw
        case "urlencoded":
            request.bodyMode = .formURLEncoded
            request.bodyForm = bodyFields(from: legacy.data)
        case "formdata", "multipart":
            request.bodyMode = .multipart
            request.bodyForm = bodyFields(from: legacy.data)
        case "graphql":
            request.bodyMode = .graphql
            request.graphqlQuery = legacy.rawModeData
        default:
            if !legacy.rawModeData.isEmpty {
                request.rawBody = legacy.rawModeData
                request.bodyMode = isJSONBody(legacy.rawModeData, contentType: contentType) ? .json : .raw
            }
        }
    }

    private static func bodyFields(from fields: [PostmanBackup.KeyValue]) -> [BodyField] {
        fields.map { field in
            let isFile = field.type.caseInsensitiveCompare("file") == .orderedSame
            return BodyField(name: field.key, value: isFile ? "" : field.value,
                             enabled: field.enabled, isFile: isFile,
                             fileName: isFile ? field.value : "")
        }.filter { !$0.name.isEmpty }
    }

    private static func auth(from legacy: PostmanBackup.Auth?) -> AuthConfig {
        guard let legacy else { return AuthConfig() }
        var auth = AuthConfig()
        switch legacy.type.lowercased() {
        case "bearer":
            auth.type = .bearer
            auth.token = value(in: legacy.bearer, named: "token") ?? legacy.bearer.first?.value ?? ""
        case "basic":
            auth.type = .basic
            auth.username = value(in: legacy.basic, named: "username") ?? ""
            auth.password = value(in: legacy.basic, named: "password") ?? ""
        case "apikey", "api-key", "api key":
            auth.type = .apiKey
            auth.key = value(in: legacy.apiKey, named: "key") ?? legacy.apiKey.first?.key ?? ""
            auth.value = value(in: legacy.apiKey, named: "value") ?? legacy.apiKey.first?.value ?? ""
            if let placement = value(in: legacy.apiKey, named: "in") {
                auth.addToHeader = placement.caseInsensitiveCompare("query") != .orderedSame
            }
        default:
            break
        }
        return auth
    }

    private static func value(in items: [PostmanBackup.KeyValue], named name: String) -> String? {
        items.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func applyScripts(from events: [PostmanBackup.Event], to request: inout APIRequest) {
        for event in events {
            let script = event.script.text
            guard !script.isEmpty else { continue }
            switch event.listen.lowercased() {
            case "test":
                request.testScript = append(script, to: request.testScript)
            case "prerequest", "pre-request":
                request.preRequestScript = append(script, to: request.preRequestScript)
            default:
                continue
            }
        }
    }

    private static func append(_ addition: String, to existing: String) -> String {
        existing.isEmpty ? addition : "\(existing)\n\(addition)"
    }

    private static func splitURLAndQuery(_ rawURL: String) -> (url: String, queryParams: [KeyValueItem]) {
        guard var components = URLComponents(string: rawURL),
              let queryItems = components.queryItems,
              !queryItems.isEmpty else {
            return manualSplitURLAndQuery(rawURL)
        }
        components.queryItems = nil
        components.percentEncodedQuery = nil
        let stripped = components.string?.nonEmpty ?? rawURL
        let params = queryItems.map {
            KeyValueItem(name: $0.name, value: $0.value ?? "")
        }.filter { !$0.name.isEmpty }
        return (stripped, params)
    }

    private static func manualSplitURLAndQuery(_ rawURL: String) -> (url: String, queryParams: [KeyValueItem]) {
        guard let question = rawURL.firstIndex(of: "?") else { return (rawURL, []) }
        let base = String(rawURL[..<question])
        let query = rawURL[rawURL.index(after: question)...]
        let params = query.split(separator: "&").compactMap { pair -> KeyValueItem? in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawName = parts.first else { return nil }
            let name = String(rawName).removingPercentEncoding ?? String(rawName)
            guard !name.isEmpty else { return nil }
            let value = parts.dropFirst().first.map(String.init) ?? ""
            return KeyValueItem(name: name, value: value.removingPercentEncoding ?? value)
        }
        return (base, params)
    }

    private static func isJSONBody(_ body: String, contentType: String) -> Bool {
        if contentType.lowercased().contains("json") { return true }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
    }

    private static func normalizedID(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }
}

private struct PostmanBackup: Decodable {
    var collections: [Collection]
    var environments: [Environment]

    enum CodingKeys: CodingKey {
        case collections
        case environments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        collections = try container.decodeIfPresent([Collection].self, forKey: .collections) ?? []
        environments = try container.decodeIfPresent([Environment].self, forKey: .environments) ?? []
    }

    struct Collection: Decodable {
        var id: String?
        var name: String
        var order: [String]
        var foldersOrder: [String]
        var folders: [Folder]
        var requests: [Request]

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case order
            case foldersOrder = "folders_order"
            case folders
            case requests
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id)
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            order = try container.decodeIfPresent([String].self, forKey: .order) ?? []
            foldersOrder = try container.decodeIfPresent([String].self, forKey: .foldersOrder) ?? []
            folders = try container.decodeIfPresent([Folder].self, forKey: .folders) ?? []
            requests = try container.decodeIfPresent([Request].self, forKey: .requests) ?? []
        }
    }

    struct Folder: Decodable {
        var id: String?
        var name: String
        var parentID: String?
        var order: [String]
        var foldersOrder: [String]

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case parentID = "folder"
            case order
            case foldersOrder = "folders_order"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id)
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
            order = try container.decodeIfPresent([String].self, forKey: .order) ?? []
            foldersOrder = try container.decodeIfPresent([String].self, forKey: .foldersOrder) ?? []
        }
    }

    struct Request: Decodable {
        var id: String?
        var folderID: String?
        var name: String
        var method: String
        var url: String
        var headers: String
        var headerData: [KeyValue]
        var queryParams: [KeyValue]
        var dataMode: String
        var rawModeData: String
        var data: [KeyValue]
        var auth: Auth?
        var events: [Event]

        enum CodingKeys: String, CodingKey {
            case id
            case folderID = "folder"
            case name
            case method
            case url
            case headers
            case headerData
            case queryParams
            case dataMode
            case rawModeData
            case data
            case auth
            case event
            case events
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id)
            folderID = try container.decodeIfPresent(String.self, forKey: .folderID)
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            method = try container.decodeIfPresent(String.self, forKey: .method) ?? "GET"
            url = try container.decodeIfPresent(FlexibleString.self, forKey: .url)?.value ?? ""
            headers = try container.decodeIfPresent(String.self, forKey: .headers) ?? ""
            headerData = try container.decodeIfPresent([KeyValue].self, forKey: .headerData) ?? []
            queryParams = try container.decodeIfPresent([KeyValue].self, forKey: .queryParams) ?? []
            dataMode = try container.decodeIfPresent(String.self, forKey: .dataMode) ?? ""
            rawModeData = try container.decodeIfPresent(FlexibleString.self, forKey: .rawModeData)?.value ?? ""
            data = try container.decodeIfPresent([KeyValue].self, forKey: .data) ?? []
            auth = try container.decodeIfPresent(Auth.self, forKey: .auth)
            let event = try container.decodeIfPresent([Event].self, forKey: .event) ?? []
            let events = try container.decodeIfPresent([Event].self, forKey: .events) ?? []
            self.events = event + events
        }
    }

    struct Environment: Decodable {
        var id: String?
        var name: String
        var values: [KeyValue]

        enum CodingKeys: CodingKey {
            case id
            case name
            case values
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id)
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            values = try container.decodeIfPresent([KeyValue].self, forKey: .values) ?? []
        }
    }

    struct Auth: Decodable {
        var type: String
        var bearer: [KeyValue]
        var basic: [KeyValue]
        var apiKey: [KeyValue]

        enum CodingKeys: String, CodingKey {
            case type
            case bearer
            case basic
            case apiKey
            case apikey
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
            bearer = try container.decodeIfPresent([KeyValue].self, forKey: .bearer) ?? []
            basic = try container.decodeIfPresent([KeyValue].self, forKey: .basic) ?? []
            let camel = try container.decodeIfPresent([KeyValue].self, forKey: .apiKey) ?? []
            let lower = try container.decodeIfPresent([KeyValue].self, forKey: .apikey) ?? []
            apiKey = camel + lower
        }
    }

    struct Event: Decodable {
        var listen: String
        var script: Script

        enum CodingKeys: CodingKey {
            case listen
            case script
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            listen = try container.decodeIfPresent(String.self, forKey: .listen) ?? ""
            script = try container.decodeIfPresent(Script.self, forKey: .script) ?? Script(text: "")
        }
    }

    struct Script: Decodable {
        var text: String

        enum CodingKeys: CodingKey {
            case exec
        }

        init(text: String) {
            self.text = text
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            text = try container.decodeIfPresent(ScriptText.self, forKey: .exec)?.value ?? ""
        }
    }

    struct KeyValue: Decodable {
        var key: String
        var value: String
        var enabled: Bool
        var type: String

        enum CodingKeys: CodingKey {
            case key
            case name
            case value
            case enabled
            case disabled
            case type
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            key = try container.decodeIfPresent(FlexibleString.self, forKey: .key)?.value
                ?? container.decodeIfPresent(FlexibleString.self, forKey: .name)?.value
                ?? ""
            value = try container.decodeIfPresent(FlexibleString.self, forKey: .value)?.value ?? ""
            let isDisabled = try container.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
            enabled = (try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true) && !isDisabled
            type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        }
    }

    struct ScriptText: Decodable {
        var value: String

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let lines = try? container.decode([String].self) {
                value = lines.joined(separator: "\n")
            } else {
                value = try container.decode(String.self)
            }
        }
    }

    struct FlexibleString: Decodable {
        var value: String

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                value = ""
            } else if let string = try? container.decode(String.self) {
                value = string
            } else if let bool = try? container.decode(Bool.self) {
                value = String(bool)
            } else if let int = try? container.decode(Int.self) {
                value = String(int)
            } else if let double = try? container.decode(Double.self) {
                value = String(double)
            } else {
                throw DecodingError.typeMismatch(
                    String.self,
                    DecodingError.Context(codingPath: decoder.codingPath,
                                          debugDescription: "Expected string-compatible value")
                )
            }
        }
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
