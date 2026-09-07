import Foundation
import HTTrailCore
import ImageFilterCore
import OSLog
import PurelineSupport

/// Downstream adapter between HTTrail's existing response-breakpoint seam and
/// the vendored image-safety pipeline. No loopback HTTP request is made here.
enum ImageFilterProxyBridge {
    private static let logger = Logger(
        subsystem: "com.davidpovarsky.pureline.PacketTunnel",
        category: "direct-image-filter"
    )
    static let maximumImageBytes = 4 * 1024 * 1024

    static func apply(config: SharedConfig, to engine: InterceptEngine) {
        engine.breakpointHandler = nil
        engine.apply(config)
    }

    static func configure(server: ProxyServer, diagnostics: PurelinePacketTunnelDiagnostics) {
        server.streamingResponseInspectionPolicy = { request, metadata in
            guard DirectImageFilterSettings.isEnabled,
                  (200..<300).contains(metadata.statusCode),
                  Self.isPlausibleRaster(request: request, metadata: metadata) else { return nil }
            if let encoding = metadata.header("Content-Encoding")?.lowercased(),
               !encoding.isEmpty, encoding != "identity" { return nil }
            if let length = metadata.header("Content-Length").flatMap(Int.init), length > maximumImageBytes {
                diagnostics.record(category: "image-filter", event: "image filtering skipped because payload exceeded limits", details: [
                    "host": request.host, "contentLength": String(length), "limit": String(maximumImageBytes)
                ])
                return nil
            }
            return maximumImageBytes
        }
        server.streamingResponseInspector = { request, response in
            let analyzer = DirectImageSafetyAnalyzer.shared
            guard let edit = await transform(
                response: response, request: request, analyzer: analyzer, diagnostics: diagnostics
            ) else { return nil }
            return edit.response
        }
    }

    private static func transform(
        response: CapturedResponse,
        request: CapturedRequest,
        analyzer: DirectImageSafetyAnalyzer,
        diagnostics: PurelinePacketTunnelDiagnostics
    ) async -> BreakpointEdit? {
        guard response.statusCode >= 200, response.statusCode < 300,
              !response.body.isEmpty,
              response.body.count <= maximumImageBytes else { return nil }

        let contentType = response.contentType?.split(separator: ";", maxSplits: 1).first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard ImageSniffer.isRaster(data: response.body, contentType: contentType) else { return nil }

        if let encoding = response.header("Content-Encoding")?.lowercased(),
           !encoding.isEmpty, encoding != "identity" {
            logger.debug("Skipping encoded image response \(request.url, privacy: .private(mask: .hash))")
            return nil
        }

        do {
            let preparedNow = try await analyzer.prepareIfNeeded()
            if preparedNow {
                diagnostics.record(category: "image-filter", event: "model preparation completed", details: [
                    "model": "NudeNet320n"
                ])
            }
        } catch {
            diagnostics.record(category: "image-filter", event: "model load failure; fail open", details: [
                "model": "NudeNet320n", "error": String(describing: error)
            ])
            return nil
        }

        do {
            diagnostics.record(category: "image-filter", event: "inference start", details: [
                "host": request.host, "bytes": String(response.body.count)
            ])
            let decision = try await analyzer.classify(
                imageData: response.body,
                mimeType: contentType ?? "application/octet-stream"
            )
            guard !decision.allowed else {
                logger.debug(
                    "Allowed image people=\(decision.personCount, privacy: .public) womanScore=\(decision.highestWomanScore ?? -1, privacy: .public)"
                )
                return nil
            }

            logger.notice(
                "Blocked image risk=\(decision.risk, privacy: .public) class=\(decision.triggeredClass ?? "unknown", privacy: .public) confidence=\(decision.confidence, privacy: .public)"
            )
            var blocked = response
            blocked.body = blockedPlaceholderData()
            blocked.bodyTruncated = nil
            blocked.headers.removeAll { header in
                ["Content-Type", "Content-Length", "Content-Encoding", "Content-MD5", "ETag"]
                    .contains { $0.caseInsensitiveCompare(header.name) == .orderedSame }
            }
            blocked.headers.append(HeaderPair(name: "Content-Type", value: "image/svg+xml; charset=utf-8"))
            blocked.headers.append(HeaderPair(name: "Cache-Control", value: "no-store"))
            blocked.headers.append(HeaderPair(name: "X-HTTrail-Image-Filter", value: "blocked"))
            return BreakpointEdit(response: blocked)
        } catch {
            // Fail open: classifier trouble must never turn a previously working
            // HTTrail capture session into broken browsing.
            logger.error("Direct image classification failed: \(String(describing: error), privacy: .public)")
            diagnostics.record(category: "image-filter", event: "inference failure; fail open", details: [
                "host": request.host, "error": String(describing: error)
            ])
            return nil
        }
    }

    private static func isPlausibleRaster(request: CapturedRequest, metadata: StreamingResponseMetadata) -> Bool {
        if let contentType = metadata.header("Content-Type")?.lowercased() {
            if contentType.hasPrefix("image/") && !contentType.contains("svg") { return true }
            if !contentType.isEmpty && !contentType.hasPrefix("application/octet-stream") { return false }
        }
        let path = request.path.lowercased().split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
        return [".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp", ".tif", ".tiff", ".heic", ".heif", ".avif"]
            .contains { path.hasSuffix($0) }
    }

    private static func blockedPlaceholderData() -> Data {
        Data("""
        <svg xmlns="http://www.w3.org/2000/svg" width="640" height="400" viewBox="0 0 640 400">
          <rect width="640" height="400" fill="#111827"/>
          <path d="M320 105l92 34v70c0 58-38 111-92 132-54-21-92-74-92-132v-70z" fill="#374151"/>
          <path d="M286 200l25 25 48-55" fill="none" stroke="#9CA3AF" stroke-width="14" stroke-linecap="round" stroke-linejoin="round"/>
          <text x="320" y="365" text-anchor="middle" fill="#D1D5DB" font-family="-apple-system,BlinkMacSystemFont,sans-serif" font-size="24">Blocked by Image Filter</text>
        </svg>
        """.utf8)
    }
}
