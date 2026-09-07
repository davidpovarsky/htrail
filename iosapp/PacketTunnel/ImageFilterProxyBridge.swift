import Foundation
import HTTrailCore
import ImageFilterCore
import OSLog

/// Downstream adapter between HTTrail's existing response-breakpoint seam and
/// the vendored image-safety pipeline. No loopback HTTP request is made here.
enum ImageFilterProxyBridge {
    private static let logger = Logger(
        subsystem: "com.davidpovarsky.pureline.PacketTunnel",
        category: "direct-image-filter"
    )
    private static let configurationStore = PurelineFilterConfigurationStore.shared
    private static let admission = PurelineInspectionAdmissionController.shared
    private static let stateLock = NSLock()
    private static var currentSnapshot: PurelineFilterConfigurationSnapshot?
    private static var lastRequestedState: Bool?

    static func apply(config: SharedConfig, to engine: InterceptEngine) {
        engine.breakpointHandler = nil
        engine.apply(config)
    }

    static func refreshRuntimeConfiguration(diagnostics: PurelinePacketTunnelDiagnostics) async {
        do {
            let snapshot = try configurationStore.loadActive()
            let prior = withStateLock { currentSnapshot }
            let requested = DirectImageFilterSettings.isEnabled
            if prior?.revision.hash != snapshot.revision.hash {
                diagnostics.record(category: "configuration", event: "new filter configuration observed", details: [
                    "name": snapshot.configuration.name, "revision": String(snapshot.revision.sequence),
                    "hash": snapshot.revision.hash
                ])
                await DirectImageSafetyAnalyzer.shared.apply(
                    configuration: snapshot.configuration, revisionHash: snapshot.revision.hash
                )
                if prior?.configuration.models.mobileCLIP2 == true && !snapshot.configuration.models.mobileCLIP2 {
                    diagnostics.record(category: "image-filter", event: "model disabled immediately; loaded memory unload deferred", details: ["model": "MobileCLIP2-S2"])
                }
                if prior?.configuration.models.nudeNet == true && !snapshot.configuration.models.nudeNet {
                    diagnostics.record(category: "image-filter", event: "model disabled immediately; loaded memory unload deferred", details: ["model": "NudeNet320n"])
                }
                admission.apply(snapshot.configuration.runtime, maximumImageBytes: snapshot.configuration.pipeline.maximumImageBytes)
                try configurationStore.acknowledge(snapshot.revision)
                withStateLock { currentSnapshot = snapshot }
                recordEffectiveState(snapshot: snapshot, requested: requested, diagnostics: diagnostics, event: "filter configuration applied")
            }
            let changed = withStateLock { () -> Bool in
                defer { lastRequestedState = requested }
                return lastRequestedState != requested
            }
            if changed { recordEffectiveState(snapshot: snapshot, requested: requested, diagnostics: diagnostics, event: "direct filtering state changed") }
        } catch {
            diagnostics.record(category: "configuration", event: "configuration rejected in PacketTunnel", details: ["error": String(describing: error)])
        }
    }

    static func configure(server: ProxyServer, diagnostics: PurelinePacketTunnelDiagnostics) {
        Task { await refreshRuntimeConfiguration(diagnostics: diagnostics) }
        server.streamingResponseInspectionPolicy = { request, metadata in
            guard DirectImageFilterSettings.isEnabled,
                  let snapshot = withStateLock({ currentSnapshot }), snapshot.configuration.enabled,
                  (200..<300).contains(metadata.statusCode),
                  Self.isPlausibleRaster(request: request, metadata: metadata) else { return nil }
            if let encoding = metadata.header("Content-Encoding")?.lowercased(),
               !encoding.isEmpty, encoding != "identity" { return nil }
            let config = snapshot.configuration
            guard let length = metadata.header("Content-Length").flatMap(Int.init),
                  length > 0, length <= config.pipeline.maximumImageBytes,
                  PurelineRuntimePolicy.currentAvailableMemoryBytes() >= config.runtime.minimumAvailableMemoryBytes else {
                diagnostics.record(category: "image-filter", event: "image inspection fail-open before buffering", details: [
                    "host": request.host, "contentLength": metadata.header("Content-Length") ?? "unknown",
                    "limit": String(config.pipeline.maximumImageBytes),
                    "availableMemoryBytes": String(PurelineRuntimePolicy.currentAvailableMemoryBytes())
                ])
                return nil
            }
            let id = inspectionID(request)
            guard admission.tryReserve(id: id, bytes: length) else {
                let counters = admission.snapshot()
                diagnostics.record(category: "image-filter", event: "inspection admission overflow; fail open", details: [
                    "host": request.host, "bytes": String(length), "active": String(counters.active),
                    "queued": String(counters.queued), "inFlightBytes": String(counters.inFlightBytes)
                ])
                return nil
            }
            return config.pipeline.maximumImageBytes
        }
        server.streamingResponseInspector = { request, response in
            let id = inspectionID(request)
            await admission.acquire(id: id)
            defer { admission.release(id: id) }
            guard DirectImageFilterSettings.isEnabled else {
                diagnostics.record(category: "image-filter", event: "inspection cancelled because direct filtering is off")
                return nil
            }
            await admission.acquireInference()
            defer { admission.releaseInference() }
            let analyzer = DirectImageSafetyAnalyzer.shared
            guard let edit = await transform(
                response: response, request: request, analyzer: analyzer, diagnostics: diagnostics
            ) else { return nil }
            return edit.response
        }
    }

    static func responseCompleted(_ request: CapturedRequest) {
        admission.release(id: inspectionID(request))
    }

    private static func transform(
        response: CapturedResponse,
        request: CapturedRequest,
        analyzer: DirectImageSafetyAnalyzer,
        diagnostics: PurelinePacketTunnelDiagnostics
    ) async -> BreakpointEdit? {
        guard let snapshot = withStateLock({ currentSnapshot }) else { return nil }
        let maximumImageBytes = snapshot.configuration.pipeline.maximumImageBytes
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
            let before = PurelineRuntimePolicy.currentAvailableMemoryBytes()
            let counters = admission.snapshot()
            let lifecycle = await analyzer.modelLifecycleSnapshots()
            if snapshot.configuration.models.mobileCLIP2, lifecycle.mobileCLIP.0 != .ready {
                diagnostics.record(category: "image-filter", event: "model preparation pending before inference", details: [
                    "model": "MobileCLIP2-S2", "revision": snapshot.revision.hash,
                    "availableMemoryBytes": String(before)
                ])
            }
            if snapshot.configuration.models.nudeNet, lifecycle.nudeNet.0 != .ready {
                diagnostics.record(category: "image-filter", event: "model preparation pending before inference", details: [
                    "model": "NudeNet320n", "revision": snapshot.revision.hash,
                    "availableMemoryBytes": String(before)
                ])
            }
            diagnostics.record(category: "image-filter", event: "inference start", details: [
                "host": request.host, "bytes": String(response.body.count),
                "availableMemoryBytes": String(before), "active": String(counters.active),
                "queued": String(counters.queued), "inFlightBytes": String(counters.inFlightBytes)
            ])
            let started = ContinuousClock.now
            let decision = try await analyzer.classify(
                imageData: response.body,
                mimeType: contentType ?? "application/octet-stream"
            )
            for model in decision.modelsPrepared {
                diagnostics.record(category: "image-filter", event: "model preparation completed", details: [
                    "model": model, "availableMemoryBytes": String(PurelineRuntimePolicy.currentAvailableMemoryBytes())
                ])
            }
            diagnostics.record(category: "image-filter", event: "inference end", details: [
                "host": request.host, "durationMs": String(milliseconds(since: started)),
                "modelsRun": decision.modelsRun.joined(separator: ","),
                "availableMemoryBytes": String(PurelineRuntimePolicy.currentAvailableMemoryBytes())
            ])
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

    private static func inspectionID(_ request: CapturedRequest) -> String {
        "\(request.timestamp.timeIntervalSince1970)-\(request.method)-\(request.url)"
    }

    private static func recordEffectiveState(snapshot: PurelineFilterConfigurationSnapshot, requested: Bool,
                                             diagnostics: PurelinePacketTunnelDiagnostics, event: String) {
        let config = snapshot.configuration
        diagnostics.record(category: "configuration", event: event, details: [
            "directFilteringRequested": String(requested),
            "directFilteringEffective": String(requested && config.enabled),
            "name": config.name, "revision": String(snapshot.revision.sequence), "hash": snapshot.revision.hash,
            "mobileCLIP2": String(config.models.mobileCLIP2), "nudeNet": String(config.models.nudeNet),
            "nudeNetFullImage": String(config.models.nudeNet && config.nudeNet.runFullImage),
            "nudeNetPersonCrops": String(config.models.nudeNet && config.nudeNet.runPersonCrops),
            "maxConcurrentInference": String(config.runtime.maxConcurrentInference),
            "maxConcurrentImageInspections": String(config.runtime.maxConcurrentImageInspections),
            "maxQueuedImageInspections": String(config.runtime.maxQueuedImageInspections),
            "maximumImageBytes": String(config.pipeline.maximumImageBytes)
        ])
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let duration = start.duration(to: .now)
        return Int(duration.components.seconds * 1_000) + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }

    private static func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock(); defer { stateLock.unlock() }; return body()
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
