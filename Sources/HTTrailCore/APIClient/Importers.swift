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
