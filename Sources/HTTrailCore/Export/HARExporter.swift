import Foundation

/// Exports captured flows to HAR 1.2 (HTTP Archive) — the interchange format
/// Charles, Chrome DevTools, Proxyman, etc. all read.
public struct HARExporter: Sendable {
    public init() {}

    public func export(_ flows: [Flow]) throws -> Data {
        let entries = flows.map { entry(for: $0) }
        let log: [String: Any] = [
            "version": "1.2",
            "creator": ["name": "HTTrail", "version": "0.1.0"],
            "entries": entries
        ]
        let har: [String: Any] = ["log": log]
        return try JSONSerialization.data(withJSONObject: har, options: [.prettyPrinted])
    }

    private func entry(for flow: Flow) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        let req = flow.request

        let queryItems = URLComponents(string: req.url)?.queryItems ?? []
        let request: [String: Any] = [
            "method": req.method,
            "url": req.url,
            "httpVersion": req.httpVersion,
            "headers": req.headers.map { ["name": $0.name, "value": $0.value] },
            "queryString": queryItems.map { ["name": $0.name, "value": $0.value ?? ""] },
            "headersSize": -1,
            "bodySize": req.body.count,
            "postData": postData(body: req.body, contentType: req.header("Content-Type"))
        ]

        var response: [String: Any] = [
            "status": flow.statusCode ?? 0,
            "statusText": flow.response?.reasonPhrase ?? "",
            "httpVersion": flow.response?.httpVersion ?? "HTTP/1.1",
            "headers": (flow.response?.headers ?? []).map { ["name": $0.name, "value": $0.value] },
            "headersSize": -1,
            "bodySize": flow.response?.body.count ?? 0
        ]
        let bodyData = flow.response?.body ?? Data()
        response["content"] = [
            "size": bodyData.count,
            "mimeType": flow.response?.contentType ?? "application/octet-stream",
            "text": String(data: bodyData, encoding: .utf8) ?? bodyData.base64EncodedString(),
            "encoding": String(data: bodyData, encoding: .utf8) == nil ? "base64" : NSNull()
        ]

        return [
            "startedDateTime": iso.string(from: flow.startedAt),
            "time": Double(flow.durationMS ?? 0),
            "request": request,
            "response": response,
            "cache": [:],
            "timings": ["send": 0, "wait": Double(flow.durationMS ?? 0), "receive": 0]
        ]
    }

    private func postData(body: Data, contentType: String?) -> Any {
        guard !body.isEmpty else { return NSNull() }
        return [
            "mimeType": contentType ?? "application/octet-stream",
            "text": String(data: body, encoding: .utf8) ?? body.base64EncodedString()
        ]
    }
}
