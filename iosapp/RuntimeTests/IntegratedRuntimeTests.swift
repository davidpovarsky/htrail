import Darwin
import Foundation
import CoreGraphics
import ImageIO
import Vision
import HTTrailCore
@testable import ImageFilterCore
import XCTest

final class IntegratedRuntimeTests: XCTestCase {
    func testFailOpenPolicySkipsOversizedImagesAndResourcePressure() {
        XCTAssertEqual(
            PurelineRuntimePolicy.imageDisposition(
                contentLength: PurelineRuntimePolicy.imageInspectionBytes + 1,
                availableMemoryBytes: UInt64.max
            ), .passThrough
        )
        XCTAssertEqual(
            PurelineRuntimePolicy.imageDisposition(contentLength: 100, availableMemoryBytes: 1),
            .passThrough
        )
        XCTAssertEqual(PurelineRuntimePolicy.classifierConcurrency, 1)
    }

    func testPersistentCompatibilityBypassRoundTripAndExpiry() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bypass-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PurelineCompatibilityBypassStore(url: url)
        let now = Date()
        let active = PinnedHostInfo(host: "pinned.test", expiresAt: now.addingTimeInterval(60))
        let expired = PinnedHostInfo(host: "old.test", expiresAt: now.addingTimeInterval(-1))
        store.save([active, expired], now: now)
        let loaded = store.load(now: now)
        XCTAssertEqual(loaded.active.map(\.host), [active.host])
        guard let loadedActive = loaded.active.first else {
            return XCTFail("active bypass was not restored")
        }
        XCTAssertEqual(
            loadedActive.expiresAt.timeIntervalSince1970,
            active.expiresAt.timeIntervalSince1970,
            accuracy: 1.0 // The store intentionally persists secondsSince1970.
        )
        XCTAssertTrue(loaded.expired.isEmpty, "expired entries are pruned on save")
    }

    func testBoundedCaptureNeverExceedsPreviewOrAggregateBudgets() {
        let limits = PurelineCaptureLimits(
            requestPreviewBytes: 16, responsePreviewBytes: 24,
            totalBodyBytes: 64, flowCount: 4
        )
        let sink = PurelineBoundedFlowSink(limits: limits, store: nil)
        for index in 0..<10 {
            let request = CapturedRequest(
                method: "POST", url: "https://example.test/\(index)", scheme: "https",
                host: "example.test", port: 443, path: "/\(index)", httpVersion: "HTTP/1.1",
                headers: [], body: Data(repeating: 1, count: 100), timestamp: Date()
            )
            let response = CapturedResponse(
                statusCode: 200, reasonPhrase: "OK", httpVersion: "HTTP/1.1",
                headers: [], body: Data(repeating: 2, count: 100), timestamp: Date()
            )
            sink.record(Flow(request: request, response: response, state: .completed, startedAt: Date(), secure: true))
        }
        let flows = sink.retainedFlowsNewestFirst()
        XCTAssertLessThanOrEqual(flows.count, 4)
        XCTAssertLessThanOrEqual(sink.snapshot().retainedBodyBytes, 64)
        XCTAssertTrue(flows.allSatisfy { $0.request.body.count <= 16 })
        XCTAssertTrue(flows.allSatisfy { ($0.response?.body.count ?? 0) <= 24 })
        XCTAssertTrue(flows.contains { $0.request.bodyTruncated == true })
        XCTAssertTrue(flows.contains { $0.response?.bodyTruncated == true })
    }

    func testPacketTunnelDiagnosticsRingBufferIsBoundedAndUnexpectedRunIsAccurate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = PurelinePacketTunnelDiagnostics(directory: directory, maximumEvents: 8, maximumBytes: 4096)
        _ = first.beginRun()
        for index in 0..<40 { first.record(category: "test", event: "event-\(index)") }
        XCTAssertLessThanOrEqual(first.events().count, 8)

        let second = PurelinePacketTunnelDiagnostics(directory: directory, maximumEvents: 8, maximumBytes: 4096)
        _ = second.beginRun()
        let events = second.events()
        XCTAssertTrue(events.contains { $0.event == PurelinePacketTunnelDiagnostics.unexpectedTerminationMessage })
        XCTAssertFalse(events.contains { $0.event.localizedCaseInsensitiveContains("jetsam") })
        second.endRun(stopReason: 0)
    }

    func testPacketTunnelDiagnosticsRedactsSensitiveValues() {
        let value = PurelinePacketTunnelDiagnostics.sanitizeText(
            "https://example.test/path?token=secret&ok=yes Authorization: Bearer abc.def"
        )
        XCTAssertFalse(value.contains("secret"))
        XCTAssertFalse(value.contains("abc.def"))
    }

    private func fixtureData() throws -> Data {
        guard let url = Bundle(for: Self.self).url(
            forResource: "ClassificationImageSelected",
            withExtension: "png"
        ) else {
            XCTFail("ClassificationImageSelected.png is missing from the runtime-test bundle")
            throw NSError(domain: "HTTrailRuntimeTests", code: 1)
        }
        return try Data(contentsOf: url)
    }

    @MainActor
    func testDirectImageSafetyPipelineLoadsModelsAndRunsRepeatedInference() async throws {
        let imageData = try fixtureData()
        let analyzer = DirectImageSafetyAnalyzer.shared
        let before = Self.memorySnapshot()

        let prepareStart = ContinuousClock.now
        await analyzer.prepare()
        let prepareMs = Self.milliseconds(since: prepareStart)
        let afterPrepare = Self.memorySnapshot()

        var inferenceDurations: [Int] = []
        var lastDecision: DirectImageSafetyDecision?
        for _ in 0..<3 {
            let start = ContinuousClock.now
            lastDecision = try await analyzer.classify(imageData: imageData, mimeType: "image/png")
            inferenceDurations.append(Self.milliseconds(since: start))
        }
        let afterInference = Self.memorySnapshot()

        guard let decision = lastDecision else {
            XCTFail("No direct image-safety decision was produced")
            return
        }

        XCTAssertGreaterThanOrEqual(decision.personCount, 0)
        XCTAssertFalse(decision.risk.isEmpty)

        let metrics: [String: Any] = [
            "fixtureBytes": imageData.count,
            "prepareMs": prepareMs,
            "inferenceMs": inferenceDurations,
            "averageInferenceMs": inferenceDurations.isEmpty ? 0 : inferenceDurations.reduce(0, +) / inferenceDurations.count,
            "memoryBefore": before,
            "memoryAfterPrepare": afterPrepare,
            "memoryAfterInference": afterInference,
            "physicalFootprintDeltaAfterPrepare": Self.delta(afterPrepare["physicalFootprintBytes"], before["physicalFootprintBytes"]),
            "physicalFootprintDeltaAfterInference": Self.delta(afterInference["physicalFootprintBytes"], before["physicalFootprintBytes"]),
            "decision": [
                "allowed": decision.allowed,
                "risk": decision.risk,
                "confidence": decision.confidence,
                "triggeredClass": decision.triggeredClass ?? NSNull(),
                "personCount": decision.personCount,
                "highestWomanScore": decision.highestWomanScore.map(Double.init) ?? NSNull()
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
        let json = String(decoding: data, as: UTF8.self)
        let attachment = XCTAttachment(string: json)
        attachment.name = "Direct image-safety runtime metrics"
        attachment.lifetime = .keepAlways
        add(attachment)

        let compact = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
        print("HTTRAIL_RUNTIME_METRICS \(String(decoding: compact, as: UTF8.self))")
        print("HTTRAIL_RUNTIME_STEP direct_image_filter=pass")
    }

    func testPacketTunnelDirectDecisionUsesOnlyNudeNet() {
        XCTAssertTrue(DirectImageSafetyAnalyzer.packetTunnelUsesMobileCLIP)
        XCTAssertTrue(DirectImageSafetyAnalyzer.packetTunnelUsesNudeNet)
    }

    func testConfigurationValidationImportAndRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PurelineFilterConfigurationStore(directory: directory)
        let data = try PurelineFilterConfiguration.builtIn.normalizedData()
        let installed = try store.install(data: data, importedFilename: "test.json")
        XCTAssertEqual(installed.configuration, .builtIn)
        XCTAssertEqual(try store.exportActive(), data)
        XCTAssertEqual(try PurelineFilterConfigurationValidator.decodeAndValidate(store.exportActive()), .builtIn)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.activeURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.lastGoodURL.path))
    }

    func testMalformedUnsupportedAndUnsafeConfigurationsAreRejected() throws {
        XCTAssertThrowsError(try PurelineFilterConfigurationValidator.decodeAndValidate(Data("{".utf8)))
        var invalid = PurelineFilterConfiguration.builtIn
        invalid.schemaVersion = 99
        XCTAssertThrowsError(try PurelineFilterConfigurationValidator.decodeAndValidate(invalid.normalizedData()))
        invalid = .builtIn; invalid.mobileCLIP2Policy.womanMinScore = 1.02
        XCTAssertThrowsError(try PurelineFilterConfigurationValidator.decodeAndValidate(invalid.normalizedData()))
        invalid = .builtIn; invalid.runtime.maxConcurrentInference = 99
        XCTAssertThrowsError(try PurelineFilterConfigurationValidator.decodeAndValidate(invalid.normalizedData()))
        invalid = .builtIn; invalid.pipeline.maximumImageBytes = PurelineFilterConfigurationValidator.maximumImageBytes + 1
        XCTAssertThrowsError(try PurelineFilterConfigurationValidator.decodeAndValidate(invalid.normalizedData()))
    }

    func testInvalidConfigurationNeverReplacesLastGoodAndAcknowledgementMatchesRevision() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PurelineFilterConfigurationStore(directory: directory)
        let good = try store.restoreDefault()
        XCTAssertThrowsError(try store.install(data: Data("not json".utf8), importedFilename: "bad.json"))
        XCTAssertEqual(try store.loadActive(), good)
        try store.acknowledge(good.revision)
        XCTAssertEqual(store.loadAcknowledgement()?.hash, good.revision.hash)
        XCTAssertNotNil(store.loadAcknowledgement()?.appliedAt)
    }

    func testCombinedPolicyMatchesCrossPlatformORSemantics() {
        let config = PurelineFilterConfiguration.builtIn
        let woman = PurelineMobileCLIPEvidence(source: "humanRectangle", woman: 0.50, man: 0.20, uncertain: 0)
        let allowPerson = PurelineMobileCLIPEvidence(source: "humanRectangle", woman: 0.41, man: 0.20, uncertain: 0)
        let nude = PurelineNudeNetEvidence(label: "FEMALE_BREAST_EXPOSED", confidence: 0.31)
        XCTAssertTrue(PurelineImageSafetyPolicy.blocks(mobileCLIP: [woman], nudeNet: [], configuration: config))
        XCTAssertTrue(PurelineImageSafetyPolicy.blocks(mobileCLIP: [allowPerson], nudeNet: [nude], configuration: config))
        XCTAssertFalse(PurelineImageSafetyPolicy.blocks(mobileCLIP: [allowPerson], nudeNet: [], configuration: config))
        XCTAssertTrue(PurelineImageSafetyPolicy.mobileCLIPBlocks(.init(source: "humanRectangle", woman: 0.1, man: 0.1, uncertain: 0.91), policy: config.mobileCLIP2Policy))
        XCTAssertFalse(PurelineImageSafetyPolicy.mobileCLIPBlocks(.init(source: "humanRectangle", woman: 0.50, man: 0.45, uncertain: 0), policy: config.mobileCLIP2Policy))
        XCTAssertTrue(PurelineImageSafetyPolicy.mobileCLIPBlocks(.init(source: "faceFallback", woman: 0.49, man: 0.20, uncertain: 0), policy: config.mobileCLIP2Policy))
        XCTAssertTrue(PurelineImageSafetyPolicy.mobileCLIPBlocks(.init(source: "wholeImageFallback", woman: 0.59, man: 0.20, uncertain: 0), policy: config.mobileCLIP2Policy))
        XCTAssertTrue(PurelineImageSafetyPolicy.mobileCLIPBlocks(.init(source: "humanRectangle", woman: 0.71, man: 0.70, uncertain: 0), policy: config.mobileCLIP2Policy))
    }

    func testModelPreparationIsTrueSingleFlightAndRetriesAfterFailure() async throws {
        for _ in 0..<2 { // one lifecycle for each expensive model wrapper
            let counter = AttemptCounter()
            let lifecycle = PurelineModelLifecycle {
                await counter.increment()
                try await Task.sleep(for: .milliseconds(50))
            }
            let created = try await withThrowingTaskGroup(of: Bool.self) { group in
                for _ in 0..<10 { group.addTask { try await lifecycle.prepareIfNeeded() } }
                var values: [Bool] = []
                for try await value in group { values.append(value) }
                return values
            }
            XCTAssertEqual(created.filter { $0 }.count, 1)
            let attempts = await counter.value()
            XCTAssertEqual(attempts, 1)
            let snapshot = await lifecycle.snapshot()
            XCTAssertEqual(snapshot.attempts, 1); XCTAssertEqual(snapshot.completions, 1)
        }

        let counter = AttemptCounter()
        let failing = PurelineModelLifecycle {
            let attempt = await counter.increment()
            if attempt == 1 { throw CocoaError(.fileReadCorruptFile) }
        }
        do { _ = try await failing.prepareIfNeeded(); XCTFail("first preparation should fail") } catch {}
        let retryPrepared = try await failing.prepareIfNeeded()
        XCTAssertTrue(retryPrepared)
        let retryAttempts = await counter.value()
        XCTAssertEqual(retryAttempts, 2)
    }

    func testInspectionAdmissionRejectsOverflowWithoutExceedingBudget() async {
        let admission = PurelineInspectionAdmissionController()
        var config = PurelineFilterConfiguration.builtIn
        config.runtime.maxConcurrentImageInspections = 1
        config.runtime.maxQueuedImageInspections = 2
        admission.apply(config.runtime, maximumImageBytes: config.pipeline.maximumImageBytes)
        XCTAssertTrue(admission.tryReserve(id: "one", bytes: 100))
        XCTAssertTrue(admission.tryReserve(id: "two", bytes: 100))
        XCTAssertTrue(admission.tryReserve(id: "three", bytes: 100))
        XCTAssertFalse(admission.tryReserve(id: "overflow", bytes: 100))
        XCTAssertFalse(admission.tryReserve(id: "oversized", bytes: config.pipeline.maximumImageBytes + 1))
        let snapshot = admission.snapshot()
        XCTAssertEqual(snapshot.active, 1); XCTAssertEqual(snapshot.queued, 2)
        XCTAssertLessThanOrEqual(snapshot.inFlightBytes, PurelineInspectionAdmissionController.hardInFlightByteCeiling)
        admission.release(id: "one"); admission.release(id: "two"); admission.release(id: "three")
        XCTAssertEqual(admission.snapshot().inFlightBytes, 0)
    }

    func testTerminalFlowReleasesReservationEvenWithoutResponse() {
        let admission = PurelineInspectionAdmissionController()
        let request = imageRequest()
        let id = PurelineImageResponsePolicy.inspectionID(request)
        let downstream = PurelineBoundedFlowSink(limits: .packetTunnel, store: nil)
        let sink = PurelineCompletionFlowSink(downstream: downstream) {
            admission.release(id: PurelineImageResponsePolicy.inspectionID($0))
        }
        XCTAssertTrue(admission.tryReserve(id: id, bytes: 100))
        sink.record(Flow(request: request, response: nil, state: .pending, startedAt: Date(), secure: true))
        XCTAssertEqual(admission.snapshot().active, 1)
        sink.record(Flow(request: request, response: nil, state: .failed, startedAt: Date(), secure: true))
        XCTAssertEqual(admission.snapshot().inFlightBytes, 0)
        XCTAssertTrue(admission.tryReserve(id: id, bytes: 100))
        sink.record(Flow(request: request, response: nil, state: .completed, startedAt: Date(), secure: true))
        XCTAssertEqual(admission.snapshot().active, 0)
        XCTAssertEqual(downstream.retainedFlowsNewestFirst().count, 3)
    }

    func testReleasedQueuedInspectionDoesNotAcquireOrHang() async {
        let admission = PurelineInspectionAdmissionController()
        XCTAssertTrue(admission.tryReserve(id: "active", bytes: 100))
        XCTAssertTrue(admission.tryReserve(id: "queued", bytes: 100))
        let finished = expectation(description: "released inspection is cancelled")
        Task {
            let acquired = await admission.acquire(id: "queued")
            XCTAssertFalse(acquired)
            finished.fulfill()
        }
        await Task.yield()
        admission.release(id: "queued")
        await fulfillment(of: [finished], timeout: 2)
        admission.release(id: "active")
        XCTAssertEqual(admission.snapshot().inFlightBytes, 0)
    }

    func testReducedConcurrencyWaitsForExistingInspectionsAndInference() async {
        let admission = PurelineInspectionAdmissionController()
        var config = PurelineFilterConfiguration.builtIn
        config.runtime.maxConcurrentImageInspections = 2
        config.runtime.maxConcurrentInference = 2
        admission.apply(config.runtime, maximumImageBytes: config.pipeline.maximumImageBytes)
        for id in ["first", "second", "queued"] { XCTAssertTrue(admission.tryReserve(id: id, bytes: 100)) }
        await admission.acquireInference()
        await admission.acquireInference()
        config.runtime.maxConcurrentImageInspections = 1
        config.runtime.maxConcurrentInference = 1
        admission.apply(config.runtime, maximumImageBytes: config.pipeline.maximumImageBytes)
        let inspection = expectation(description: "queued inspection resumed at new limit")
        let inference = expectation(description: "queued inference resumed at new limit")
        Task {
            let acquired = await admission.acquire(id: "queued")
            XCTAssertTrue(acquired)
            inspection.fulfill()
        }
        Task { await admission.acquireInference(); inference.fulfill() }
        await Task.yield()
        admission.release(id: "first")
        admission.releaseInference()
        XCTAssertEqual(admission.snapshot().active, 1)
        XCTAssertEqual(admission.snapshot().queued, 1)
        XCTAssertEqual(admission.snapshot().inferenceActive, 1)
        admission.release(id: "second")
        admission.releaseInference()
        await fulfillment(of: [inspection, inference], timeout: 2)
        admission.release(id: "queued")
        admission.releaseInference()
        XCTAssertEqual(admission.snapshot().inFlightBytes, 0)
        XCTAssertEqual(admission.snapshot().inferenceActive, 0)
    }

    func testStrictImagePolicyBlocksLimitsAndPreservesExplicitFailOpen() throws {
        var config = PurelineFilterConfiguration.builtIn
        config.pipeline.maximumImageBytes = 100
        config.runtime.maxQueuedImageInspections = 0
        let admission = PurelineInspectionAdmissionController()
        admission.apply(config.runtime, maximumImageBytes: 100)
        let request = imageRequest()
        func decide(_ length: String?, encoding: String? = nil, memory: UInt64 = .max,
                    type: String = "image/jpeg") -> PurelineImageResponsePolicy.Decision {
            var headers = [HeaderPair(name: "Content-Type", value: type)]
            if let length { headers.append(HeaderPair(name: "Content-Length", value: length)) }
            if let encoding { headers.append(HeaderPair(name: "Content-Encoding", value: encoding)) }
            return PurelineImageResponsePolicy.decide(request: request,
                metadata: .init(statusCode: 200, reasonPhrase: "OK", httpVersion: "HTTP/1.1", headers: headers),
                configuration: config, enabled: true, availableMemoryBytes: memory, admission: admission)
        }
        for decision in [decide("101"), decide("50", memory: 0), decide("50", encoding: "gzip"),
                         decide("50", type: "image/svg+xml")] {
            guard case .respond(let response) = decision.disposition else { XCTFail("strict policy must replace rejected images"); continue }
            XCTAssertEqual(response.contentType, "image/svg+xml; charset=utf-8")
            XCTAssertEqual(response.header("Cache-Control"), "no-store")
            XCTAssertNil(response.header("Content-Encoding"))
            XCTAssertFalse(decision.failsOpen)
        }
        XCTAssertTrue(admission.tryReserve(id: "occupant", bytes: 50))
        guard case .respond = decide("50").disposition else { return XCTFail("strict admission overflow must replace") }
        admission.release(id: "occupant")
        config.failurePolicy.imageTooLarge = .failOpen
        let explicit = decide("101")
        guard case .stream = explicit.disposition else { return XCTFail("explicit failOpen must be preserved") }
        XCTAssertTrue(explicit.failsOpen)
        XCTAssertEqual(admission.snapshot().inFlightBytes, 0)
        let decoded = try PurelineFilterConfigurationValidator.decodeAndValidate(config.normalizedData())
        XCTAssertEqual(decoded.failurePolicy.imageTooLarge, .failOpen)
        XCTAssertEqual(decoded.failurePolicy.modelUnavailable, .block)
    }

    func testUnknownLengthImageReservesCapWhileOFFReservesNothing() {
        let config = PurelineFilterConfiguration.builtIn
        let admission = PurelineInspectionAdmissionController()
        let request = imageRequest()
        let metadata = StreamingResponseMetadata(statusCode: 200, reasonPhrase: "OK", httpVersion: "HTTP/1.1",
                                                  headers: [HeaderPair(name: "Content-Type", value: "image/jpeg")])
        let off = PurelineImageResponsePolicy.decide(request: request, metadata: metadata, configuration: config,
                                                    enabled: false, availableMemoryBytes: 0, admission: admission)
        guard case .stream = off.disposition else { return XCTFail("OFF must stream") }
        XCTAssertEqual(admission.snapshot().inFlightBytes, 0)
        let active = PurelineImageResponsePolicy.decide(request: request, metadata: metadata, configuration: config,
                                                       enabled: true, availableMemoryBytes: .max, admission: admission)
        guard case .inspect(let maximum, let fallback) = active.disposition else { return XCTFail("unknown length must be bounded") }
        XCTAssertEqual(maximum, config.pipeline.maximumImageBytes)
        XCTAssertNotNil(fallback)
        XCTAssertEqual(admission.snapshot().inFlightBytes, maximum)
        admission.release(id: PurelineImageResponsePolicy.inspectionID(request))
    }

    func testIOS27MobileCLIPUsesVerifiedCPUOnlyPolicy() {
        XCTAssertEqual(MobileCLIPService.computeUnitCandidateNames(forOSMajorVersion: 27), ["cpuOnly"])
        XCTAssertEqual(MobileCLIPService.computeUnitPolicyReason(forOSMajorVersion: 27), "ios27MPSGraphSDPAWorkaround")
    }

    func testIOS27HumanAndFaceVisionRequestsUseSupportedCPUDevices() throws {
        let detector = PurelineHumanDetectionService()
        let human = try detector.makeHumanRequest()
        let face = try detector.makeFaceRequest()
        XCTAssertFalse(human.upperBodyOnly)
        XCTAssertEqual(human.revision, VNDetectHumanRectanglesRequest().revision)
        XCTAssertEqual(face.revision, VNDetectFaceRectanglesRequest().revision)
        if #available(iOS 27.0, *) {
            let requests: [VNRequest] = [human, face]
            for request in requests {
                let supported = try request.supportedComputeStageDevices
                XCTAssertNotNil(supported[.main])
                for stage in supported.keys {
                    guard let selected = request.computeDevice(for: stage), case .cpu = selected else {
                        return XCTFail("Every supported Vision stage must use its advertised CPU device")
                    }
                }
            }
        }
    }

    func testAntiBotDetectionRequiresStrongChallengeSignals() {
        let normal = CapturedResponse(statusCode: 403, reasonPhrase: "Forbidden", httpVersion: "HTTP/1.1", headers: [], body: Data("denied".utf8), timestamp: Date())
        XCTAssertFalse(PurelineAntiBotChallengeDetector.isStrongChallenge(normal))
        let challenge = CapturedResponse(statusCode: 403, reasonPhrase: "Forbidden", httpVersion: "HTTP/1.1",
            headers: [HeaderPair(name: "Server", value: "cloudflare"), HeaderPair(name: "CF-Ray", value: "abc")],
            body: Data("<title>Just a moment...</title><script src='challenge-platform'></script>".utf8), timestamp: Date())
        XCTAssertTrue(PurelineAntiBotChallengeDetector.isStrongChallenge(challenge))
    }

    func testDisabledDirectFilteringDoesNotPrepareClassifier() async {
        let analyzer = DirectImageSafetyAnalyzer()
        var disabled = PurelineFilterConfiguration.builtIn
        disabled.enabled = false
        await analyzer.apply(configuration: disabled, revisionHash: "disabled")
        await analyzer.prepare()
        let attempts = await analyzer.preparationAttemptCount()
        XCTAssertEqual(attempts, 0)
    }

    func testDisabledDirectFilteringSkipsDecodeAndInference() async throws {
        let analyzer = DirectImageSafetyAnalyzer()
        var disabled = PurelineFilterConfiguration.builtIn
        disabled.enabled = false
        await analyzer.apply(configuration: disabled, revisionHash: "disabled-classification")
        let decision = try await analyzer.classify(imageData: Data([0, 1, 2]), mimeType: "image/jpeg")
        XCTAssertTrue(decision.allowed)
        XCTAssertEqual(decision.risk, "disabled")
        XCTAssertTrue(decision.modelsRun.isEmpty)
        let attempts = await analyzer.preparationAttemptCount()
        XCTAssertEqual(attempts, 0)
    }

    func testBoundedImageDecodePreservesOrientationAndDimensionLimit() throws {
        let data = try encodedTestImage(width: 400, height: 200, orientation: 6)
        var pipeline = PurelineFilterConfiguration.builtIn.pipeline
        pipeline.maximumPixelDimension = 64
        let image = try XCTUnwrap(PurelineImageDecoder.decode(data, pipeline: pipeline))
        XCTAssertEqual(image.width, 32)
        XCTAssertEqual(image.height, 64)
    }

    func testBoundedImageDecodeEnforcesPixelAndEncodedByteLimits() throws {
        let data = try encodedTestImage(width: 2_000, height: 1_000)
        var pipeline = PurelineFilterConfiguration.builtIn.pipeline
        pipeline.maximumPixelDimension = 2_048
        pipeline.maximumTotalPixels = 20_000
        let image = try XCTUnwrap(PurelineImageDecoder.decode(data, pipeline: pipeline))
        XCTAssertLessThanOrEqual(image.width * image.height, 20_000)
        XCTAssertLessThanOrEqual(image.width, 200)
        XCTAssertLessThanOrEqual(image.height, 100)
        pipeline.maximumImageBytes = data.count - 1
        XCTAssertNil(PurelineImageDecoder.decode(data, pipeline: pipeline))
        XCTAssertNil(PurelineImageDecoder.decode(Data([0, 1, 2]), pipeline: pipeline))
    }

    func testAnimatedImageIsUnsupportedBeforeModelsCanApproveFrameZero() async throws {
        let data = try encodedTestImage(width: 20, height: 20, frameCount: 2)
        XCTAssertEqual(PurelineImageDecoder.frameCount(data), 2)
        XCTAssertNil(PurelineImageDecoder.decode(data, pipeline: PurelineFilterConfiguration.builtIn.pipeline))
        let analyzer = DirectImageSafetyAnalyzer()
        do {
            _ = try await analyzer.classify(imageData: data, mimeType: "image/gif")
            XCTFail("uninspected animation frames must not be approved")
        } catch DirectImageSafetyError.unsupportedImage { }
        let attempts = await analyzer.preparationAttemptCount()
        XCTAssertEqual(attempts, 0)
    }

    private func imageRequest() -> CapturedRequest {
        CapturedRequest(method: "GET", url: "https://example.test/image.jpg", scheme: "https", host: "example.test",
                        port: 443, path: "/image.jpg", httpVersion: "HTTP/1.1", headers: [], body: Data(), timestamp: Date())
    }

    private func encodedTestImage(width: Int, height: Int, orientation: Int = 1, frameCount: Int = 1) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let type = frameCount > 1 ? "com.compuserve.gif" : "public.jpeg"
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type as CFString, frameCount, nil))
        for _ in 0..<frameCount {
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testOriginalFullVendorPipelineRemainsAvailable() async {
        _ = await ImageSafetyPipelineService.shared.readiness()
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let duration = start.duration(to: .now)
        return Int(duration.components.seconds * 1_000)
            + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }

    private static func delta(_ lhs: Any?, _ rhs: Any?) -> Int64 {
        let left = (lhs as? NSNumber)?.int64Value ?? 0
        let right = (rhs as? NSNumber)?.int64Value ?? 0
        return left - right
    }

    private static func memorySnapshot() -> [String: Any] {
        [
            "physicalFootprintBytes": NSNumber(value: physicalFootprintBytes()),
            "osAvailableMemoryBytes": NSNumber(value: UInt64(os_proc_available_memory())),
            "systemPhysicalMemoryBytes": NSNumber(value: ProcessInfo.processInfo.physicalMemory)
        ]
    }

    private static func physicalFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }
}

private actor AttemptCounter {
    private var count = 0
    @discardableResult func increment() -> Int { count += 1; return count }
    func value() -> Int { count }
}
