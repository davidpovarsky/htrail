import Foundation
import HTTrailCore
import ImageFilterCore

/// Downstream image policy; HTTrail stays transparent unless this adapter opts
/// in. OFF never reserves memory or invokes the classifier. An explicit
/// failOpen configuration remains supported and is reported by the caller.
public enum PurelineImageResponsePolicy {
    public struct Decision {
        public let disposition: StreamingResponseDisposition
        public let reason: String?
        public let failsOpen: Bool
    }

    public static func decide(request: CapturedRequest, metadata: StreamingResponseMetadata,
                              configuration: PurelineFilterConfiguration, enabled: Bool,
                              availableMemoryBytes: UInt64,
                              admission: PurelineInspectionAdmissionController) -> Decision {
        guard enabled, configuration.enabled, request.method.uppercased() != "HEAD",
              (200..<300).contains(metadata.statusCode), metadata.statusCode != 204,
              metadata.header("Content-Length") != "0",
              isPlausibleImage(request: request, metadata: metadata) else {
            return Decision(disposition: .stream, reason: nil, failsOpen: false)
        }
        let path = request.path.lowercased().split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        if metadata.header("Content-Type")?.lowercased().contains("svg") == true
            || path.hasSuffix(".svg") || path.hasSuffix(".svgz") {
            // This runtime does not inspect SVG's embedded/referenced images.
            return failure(configuration.failurePolicy.unsupportedEncoding, metadata: metadata, reason: "unsupported-svg")
        }
        if metadata.statusCode == 206 {
            return failure(configuration.failurePolicy.classifierError, metadata: metadata, reason: "partial-image")
        }
        if let encoding = metadata.header("Content-Encoding")?.lowercased(),
           !encoding.isEmpty, encoding != "identity" {
            return failure(configuration.failurePolicy.unsupportedEncoding, metadata: metadata, reason: "unsupported-encoding")
        }
        let maximumBytes = configuration.pipeline.maximumImageBytes
        let length = metadata.header("Content-Length").flatMap(Int.init)
        if let length, length <= 0 || length > maximumBytes {
            return failure(configuration.failurePolicy.imageTooLarge, metadata: metadata, reason: "image-size")
        }
        guard availableMemoryBytes >= configuration.runtime.minimumAvailableMemoryBytes else {
            return failure(configuration.failurePolicy.memoryPressure, metadata: metadata, reason: "memory-pressure")
        }
        // Unknown/chunked bodies reserve the complete cap before reading. Their
        // size can no longer bypass inspection or overcommit the byte budget.
        guard admission.tryReserve(id: inspectionID(request), bytes: length ?? maximumBytes) else {
            let action: PurelineFilterConfiguration.FailureAction =
                configuration.runtime.inspectionQueueOverflowAction == .block ? .block : .failOpen
            return failure(action, metadata: metadata, reason: "inspection-capacity")
        }
        let fallback = configuration.failurePolicy.imageTooLarge == .block
            ? placeholder(metadata: metadata, reason: "inspection-incomplete") : nil
        return Decision(disposition: .inspect(maximumBytes: maximumBytes, failureResponse: fallback), reason: nil, failsOpen: false)
    }

    public static func inspectionID(_ request: CapturedRequest) -> String {
        "\(request.timestamp.timeIntervalSince1970)-\(request.method)-\(request.url)"
    }

    public static func placeholder(metadata: StreamingResponseMetadata, reason: String) -> CapturedResponse {
        let replaced = ["content-type", "content-length", "content-encoding", "transfer-encoding",
                        "content-md5", "etag", "content-range", "accept-ranges", "cache-control", "expires"]
        var headers = metadata.headers.filter { !replaced.contains($0.name.lowercased()) }
        headers.append(HeaderPair(name: "Content-Type", value: "image/svg+xml; charset=utf-8"))
        headers.append(HeaderPair(name: "Cache-Control", value: "no-store"))
        headers.append(HeaderPair(name: "X-HTTrail-Image-Filter", value: reason))
        return CapturedResponse(statusCode: 200, reasonPhrase: "OK", httpVersion: metadata.httpVersion,
                                headers: headers, body: placeholderData, timestamp: Date())
    }

    public static func placeholder(response: CapturedResponse, reason: String) -> CapturedResponse {
        placeholder(metadata: .init(statusCode: response.statusCode, reasonPhrase: response.reasonPhrase,
                                    httpVersion: response.httpVersion, headers: response.headers), reason: reason)
    }

    private static func failure(_ action: PurelineFilterConfiguration.FailureAction,
                                metadata: StreamingResponseMetadata, reason: String) -> Decision {
        Decision(disposition: action == .block ? .respond(placeholder(metadata: metadata, reason: reason)) : .stream,
                 reason: reason, failsOpen: action == .failOpen)
    }

    private static func isPlausibleImage(request: CapturedRequest, metadata: StreamingResponseMetadata) -> Bool {
        if let contentType = metadata.header("Content-Type")?.lowercased() {
            if contentType.hasPrefix("image/") { return true }
            if !contentType.isEmpty && !contentType.hasPrefix("application/octet-stream") { return false }
        }
        let path = request.path.lowercased().split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
        return [".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp", ".tif", ".tiff", ".heic", ".heif", ".avif", ".svg", ".svgz"]
            .contains { path.hasSuffix($0) }
    }

    private static let placeholderData = Data("""
    <svg xmlns="http://www.w3.org/2000/svg" width="640" height="400" viewBox="0 0 640 400">
      <rect width="640" height="400" fill="#111827"/>
      <path d="M320 105l92 34v70c0 58-38 111-92 132-54-21-92-74-92-132v-70z" fill="#374151"/>
      <path d="M286 200l25 25 48-55" fill="none" stroke="#9CA3AF" stroke-width="14" stroke-linecap="round" stroke-linejoin="round"/>
      <text x="320" y="365" text-anchor="middle" fill="#D1D5DB" font-family="-apple-system,BlinkMacSystemFont,sans-serif" font-size="24">Blocked by Image Filter</text>
    </svg>
    """.utf8)
}
