import Foundation

/// Chrome-DevTools-style resource buckets used by the capture filter. "All" is
/// represented by an empty selection set (no enum case).
public enum ResourceType: String, CaseIterable, Codable, Sendable {
    case xhr, html, js, css, image, other

    public var label: String {
        switch self {
        case .xhr: return "XHR/JSON"
        case .html: return "HTML"
        case .js: return "JS"
        case .css: return "CSS"
        case .image: return "Image"
        case .other: return "Other"
        }
    }

    public var systemImage: String {
        switch self {
        case .xhr: return "arrow.left.arrow.right"
        case .html: return "doc.richtext"
        case .js: return "curlybraces"
        case .css: return "paintbrush"
        case .image: return "photo"
        case .other: return "ellipsis.circle"
        }
    }

    /// Classify a flow by its response Content-Type, falling back to the request
    /// URL's path extension when the type is missing or `application/octet-stream`.
    public static func classify(_ flow: Flow) -> ResourceType {
        let ct = (flow.response?.contentType ?? "").lowercased()
        if let byType = fromContentType(ct) { return byType }
        if let byExt = fromExtension(pathExtension(of: flow.request.path)) { return byExt }
        return .other
    }

    private static func fromContentType(_ ct: String) -> ResourceType? {
        if ct.isEmpty || ct.hasPrefix("application/octet-stream") { return nil }
        if ct.hasPrefix("image/") { return .image }
        if ct.contains("text/css") { return .css }
        if ct.contains("javascript") || ct.contains("ecmascript") { return .js }
        if ct.contains("text/html") { return .html }
        if ct.contains("json") || ct.contains("xml")
            || ct.contains("application/grpc") || ct.contains("text/event-stream") { return .xhr }
        return .other
    }

    private static func fromExtension(_ ext: String) -> ResourceType? {
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "bmp": return .image
        case "css": return .css
        case "js", "mjs": return .js
        case "html", "htm": return .html
        case "json", "xml": return .xhr
        default: return nil
        }
    }

    private static func pathExtension(of path: String) -> String {
        let withoutQuery = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        return (withoutQuery as NSString).pathExtension.lowercased()
    }
}
