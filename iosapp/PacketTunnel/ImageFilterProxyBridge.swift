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
        server.streamingResponseDispositionPolicy = { request, metadata in
            let config = withStateLock { currentSnapshot?.configuration } ?? .builtIn
            let decision = PurelineImageResponsePolicy.decide(
                request: request, metadata: metadata, configuration: config,
                enabled: DirectImageFilterSettings.isEnabled,
                availableMemoryBytes: PurelineRuntimePolicy.currentAvailableMemoryBytes(), admission: admission
            )
            if let reason = decision.reason {
                diagnostics.record(category: "image-filter", event: "inspection policy applied", details: [
                    "host": request.host, "reason": reason,
                    "action": decision.failsOpen ? "configured-fail-open" : "safe-placeholder"
                ])
            }
            return decision.disposition
        }
        server.streamingResponseInspector = { request, response in
            let id = PurelineImageResponsePolicy.inspectionID(request)
            guard await admission.acquire(id: id) else {
                guard DirectImageFilterSettings.isEnabled else { return nil }
                return PurelineImageResponsePolicy.placeholder(response: response, reason: "inspection-cancelled")
            }
            defer { admission.release(id: id) }
            guard DirectImageFilterSettings.isEnabled else {
                diagnostics.record(category: "image-filter", event: "inspection cancelled because direct filtering is off")
                return nil
            }
            await admission.acquireInference()
            defer { admission.releaseInference() }
            guard DirectImageFilterSettings.isEnabled else {
                diagnostics.record(category: "image-filter", event: "inspection cancelled while waiting for inference")
                return nil
            }
            let analyzer = DirectImageSafetyAnalyzer.shared
            guard let edit = await transform(
                response: response, request: request, analyzer: analyzer, diagnostics: diagnostics
            ) else { return nil }
            return edit.response
        }
    }

    static func responseCompleted(_ request: CapturedRequest) {
        admission.release(id: PurelineImageResponsePolicy.inspectionID(request))
    }

    private static func transform(
        response: CapturedResponse,
        request: CapturedRequest,
        analyzer: DirectImageSafetyAnalyzer,
        diagnostics: PurelinePacketTunnelDiagnostics
    ) async -> BreakpointEdit? {
        let config = withStateLock { currentSnapshot?.configuration } ?? .builtIn
        guard DirectImageFilterSettings.isEnabled, config.enabled else { return nil }
        let contentType = response.contentType?.split(separator: ";", maxSplits: 1).first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard !response.body.isEmpty, response.body.count <= config.pipeline.maximumImageBytes else {
            return failureEdit(action: config.failurePolicy.imageTooLarge, response: response, reason: "image-size")
        }
        guard ImageSniffer.isRaster(data: response.body, contentType: contentType) else {
            return failureEdit(action: config.failurePolicy.classifierError, response: response, reason: "invalid-image")
        }
        do {
            let before = PurelineRuntimePolicy.currentAvailableMemoryBytes()
            let counters = admission.snapshot()
            let lifecycle = await analyzer.modelLifecycleSnapshots()
            if config.models.mobileCLIP2, lifecycle.mobileCLIP.0 != .ready {
                diagnostics.record(category: "image-filter", event: "model preparation pending before inference", details: [
                    "model": "MobileCLIP2-S2", "revision": withStateLock { currentSnapshot?.revision.hash } ?? "built-in",
                    "availableMemoryBytes": String(before)
                ])
            }
            if config.models.nudeNet, lifecycle.nudeNet.0 != .ready {
                diagnostics.record(category: "image-filter", event: "model preparation pending before inference", details: [
                    "model": "NudeNet320n", "revision": withStateLock { currentSnapshot?.revision.hash } ?? "built-in",
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
            return BreakpointEdit(response: PurelineImageResponsePolicy.placeholder(response: response, reason: "blocked"))
        } catch {
            let action: PurelineFilterConfiguration.FailureAction
            switch error {
            case DirectImageSafetyError.modelUnavailable: action = config.failurePolicy.modelUnavailable
            case DirectImageSafetyError.unsupportedImage: action = config.failurePolicy.unsupportedEncoding
            default: action = config.failurePolicy.classifierError
            }
            logger.error("Direct image classification failed: \(String(describing: error), privacy: .public)")
            diagnostics.record(category: "image-filter", event: "inference failure", details: [
                "host": request.host, "error": String(describing: error),
                "action": action == .block ? "safe-placeholder" : "configured-fail-open"
            ])
            guard DirectImageFilterSettings.isEnabled else { return nil }
            return failureEdit(action: action, response: response, reason: "inference-failure")
        }
    }

    private static func failureEdit(action: PurelineFilterConfiguration.FailureAction,
                                    response: CapturedResponse, reason: String) -> BreakpointEdit? {
        action == .block ? BreakpointEdit(response: PurelineImageResponsePolicy.placeholder(response: response, reason: reason)) : nil
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

}
