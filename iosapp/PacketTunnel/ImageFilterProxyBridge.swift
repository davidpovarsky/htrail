import Foundation
import HTTrailCore
import ImageFilterCore
import OSLog

/// Downstream adapter between HTTrail's existing response-breakpoint seam and
/// the vendored image-safety pipeline. No loopback HTTP request is made here.
enum ImageFilterProxyBridge {
    private static let logger = Logger(
        subsystem: "com.davidpovarsky.httrail.PacketTunnel",
        category: "direct-image-filter"
    )
    private static let internalRulePrefix = "__HTTrailDirectImageFilter:"
    private static let maximumImageBytes = 10 * 1024 * 1024

    /// URL patterns that cover ordinary raster-image fetches without forcing
    /// every HTML/JSON/download response through HTTrail's buffered path.
    private static let imageURLPatterns = [
        "*.jpg*", "*.jpeg*", "*.png*", "*.webp*", "*.gif*", "*.bmp*",
        "*.tif*", "*.tiff*", "*.heic*", "*.heif*", "*.avif*"
    ]

    static func apply(config: SharedConfig, to engine: InterceptEngine) {
        guard DirectImageFilterSettings.isEnabled else {
            engine.breakpointHandler = nil
            engine.apply(config)
            return
        }

        var runtime = config
        runtime.rules.removeAll { $0.name.hasPrefix(internalRulePrefix) }
        runtime.rules.append(contentsOf: imageURLPatterns.enumerated().map { index, pattern in
            var rule = InterceptRule()
            rule.name = "\(internalRulePrefix)\(index)"
            rule.enabled = true
            rule.kind = .breakpoint
            rule.urlPattern = pattern
            rule.breakRequest = false
            rule.breakResponse = true
            return rule
        })

        let analyzer = DirectImageSafetyAnalyzer.shared
        engine.breakpointHandler = { event in
            guard case .response = event.phase, let response = event.response else { return nil }
            return await transform(response: response, request: event.request, analyzer: analyzer)
        }
        engine.apply(runtime)
    }

    private static func transform(
        response: CapturedResponse,
        request: CapturedRequest,
        analyzer: DirectImageSafetyAnalyzer
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
            return nil
        }
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
