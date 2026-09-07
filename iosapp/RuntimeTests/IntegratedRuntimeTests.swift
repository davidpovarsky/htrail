import Darwin
import Foundation
import ImageFilterCore
import XCTest

final class IntegratedRuntimeTests: XCTestCase {
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
